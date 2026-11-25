#!/usr/bin/env bash
# Phase 214 (KTPL-06; D-12, 212 D-01; threat T-214-36): turn the sync pull request's required check green when the
# sync moved the engine pin.
#
# A pull request never downloads an engine (212 D-02), so a sync pull request that changes `.okf/engine.lock` stays red until
# the candidate pin is seeded; and a workflow dispatch is ASYNCHRONOUS, so dispatching the seed is not the same as the seed
# having finished. This script does the whole sequence, bounded (20 minutes per wait), and ties every step to the
# candidate's head sha:
#
#   1. Dispatch `okf-seed-engine` on the default branch with `lock-ref=okf-template-sync` (a dispatch made with the
#      workflow token may start a run).
#   2. Find THAT run (the newest `workflow_dispatch` run of the workflow on the default branch created since just
#      before the dispatch), wait for it to complete and require `success`; otherwise stop, with the reason in the job
#      summary, and re-run nothing.
#   3. Find the `okf-check` run (a `pull_request` run) for the sync branch's head sha and wait for it to complete. A green
#      run is left alone. Any other conclusion gets `rerun-failed-jobs` (the first run read its cache before the seed), and
#      the re-run is awaited until its attempt counter has moved and it has completed: it must end `success`.
#
# It dispatches exactly one workflow, re-runs exactly one run, and never calls a reviews or merge endpoint.
#
# Env: GH_TOKEN (the job's token, `actions: write`), OKF_REPO, OKF_DEFAULT_BRANCH, OKF_HEAD_SHA (the sync branch's head,
# 40 hex). Test seam: OKF_POLL_SECONDS (default 15; each wait polls at most 1200 / OKF_POLL_SECONDS times).
# Exit: 0 the check is green, 1 the seed or the check did not end green (reason in the job summary), 2 an invalid input.
set -euo pipefail
export LC_ALL=C

REPO_RE='^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$'
BRANCH_RE='^[A-Za-z0-9._/-]{1,200}$'
SHA_RE='^[0-9a-f]{40}$'
ID_RE='^[1-9][0-9]{0,15}$'
WORD_RE='^[a-z_-]{1,40}$'
SEED_WORKFLOW='okf-seed-engine.yml'
BOUND_SECONDS=1200

invalid() {
    printf 'okf-seed-and-recheck: %s\n' "$1" >&2
    exit 2
}

[ -n "${GH_TOKEN:-}" ] || invalid 'GH_TOKEN is not set'
[[ ${OKF_REPO:-} =~ $REPO_RE ]] || invalid 'OKF_REPO is not owner/name'
[[ ${OKF_DEFAULT_BRANCH:-} =~ $BRANCH_RE ]] || invalid 'OKF_DEFAULT_BRANCH is not a plain branch name'
case "$OKF_DEFAULT_BRANCH" in *..*) invalid 'OKF_DEFAULT_BRANCH has a dot dot' ;; esac
[[ ${OKF_HEAD_SHA:-} =~ $SHA_RE ]] || invalid 'OKF_HEAD_SHA is not a full commit id'
POLL="${OKF_POLL_SECONDS:-15}"
[[ $POLL =~ ^[1-9][0-9]{0,3}$ ]] || invalid 'OKF_POLL_SECONDS is not a small positive integer'

REPO="$OKF_REPO"
BRANCH="$OKF_DEFAULT_BRANCH"
SHA="$OKF_HEAD_SHA"
MAX_POLLS=$((BOUND_SECONDS / POLL))
[ "$MAX_POLLS" -ge 1 ] || MAX_POLLS=1
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

note() {
    printf 'okf-seed-and-recheck: %s\n' "$1"
    printf -- '- %s\n' "$1" >>"$SUMMARY"
}

fail() {
    printf '::error::okf-seed-and-recheck: %s\n' "$1"
    printf '\n**The seed or the re-check did not complete:** %s\n' "$1" >>"$SUMMARY"
    exit 1
}

# iso_of <epoch>: an ISO-8601 UTC time (GNU or BSD date).
iso_of() {
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# word <text>: the text when it is a plain enumerated word (a conclusion), else a fixed placeholder.
word() {
    if [[ $1 =~ $WORD_RE ]]; then printf '%s' "$1"; else printf 'unknown'; fi
}

# wait_run <id> <minimum attempt>: print "<attempt> <conclusion>" once the run has completed at that attempt or later.
wait_run() {
    local id="$1" minimum="$2" i line attempt status conclusion
    for ((i = 0; i < MAX_POLLS; i++)); do
        line="$(gh api "repos/$REPO/actions/runs/$id" --jq '"\(.run_attempt // 1) \(.status) \(.conclusion // "-")"' 2>/dev/null)" || line=''
        read -r attempt status conclusion <<<"$line"
        if [ "${status:-}" = completed ] && [[ ${attempt:-} =~ ^[0-9]{1,6}$ ]] && [ "$attempt" -ge "$minimum" ]; then
            printf '%s %s\n' "$attempt" "$(word "${conclusion:--}")"
            return 0
        fi
        sleep "$POLL"
    done
    return 1
}

# A little before now: the runner's clock and GitHub's may differ by seconds.
START="$(iso_of "$(($(date +%s) - 30))")"

printf '### okf-template-sync: seeding the candidate engine pin\n\n' >>"$SUMMARY"
gh api -X POST "repos/$REPO/actions/workflows/$SEED_WORKFLOW/dispatches" -f "ref=$BRANCH" -f 'inputs[lock-ref]=okf-template-sync' >/dev/null ||
    fail "could not dispatch $SEED_WORKFLOW on $BRANCH"
note "dispatched $SEED_WORKFLOW on the default branch for the candidate pin"

seed_id=''
for ((i = 0; i < MAX_POLLS; i++)); do
    seed_id="$(gh api "repos/$REPO/actions/workflows/$SEED_WORKFLOW/runs?event=workflow_dispatch&branch=$BRANCH&per_page=20" \
        --jq "[.workflow_runs[] | select(.created_at >= \"$START\")] | sort_by(.created_at) | last | select(.) | .id" 2>/dev/null)" || seed_id=''
    if [[ $seed_id =~ $ID_RE ]]; then break; fi
    seed_id=''
    sleep "$POLL"
done
[ -n "$seed_id" ] || fail "no dispatched run of $SEED_WORKFLOW appeared within $((MAX_POLLS * POLL)) seconds"

result="$(wait_run "$seed_id" 1)" || fail "the $SEED_WORKFLOW run $seed_id did not complete within $((MAX_POLLS * POLL)) seconds"
conclusion="${result#* }"
[ "$conclusion" = success ] || fail "the $SEED_WORKFLOW run $seed_id ended with: $conclusion; nothing was re-run"
note "$SEED_WORKFLOW run $seed_id succeeded"

check_id=''
for ((i = 0; i < MAX_POLLS; i++)); do
    check_id="$(gh api "repos/$REPO/actions/runs?head_sha=$SHA" \
        --jq '[.workflow_runs[] | select(.name == "okf-check" and .event == "pull_request")] | sort_by(.created_at) | last | select(.) | .id' 2>/dev/null)" || check_id=''
    if [[ $check_id =~ $ID_RE ]]; then break; fi
    check_id=''
    sleep "$POLL"
done
[ -n "$check_id" ] || fail "no okf-check run for $SHA appeared within $((MAX_POLLS * POLL)) seconds"

result="$(wait_run "$check_id" 1)" || fail "the okf-check run $check_id did not complete within $((MAX_POLLS * POLL)) seconds"
attempt="${result%% *}"
conclusion="${result#* }"
if [ "$conclusion" = success ]; then
    note "okf-check run $check_id is already green; left alone"
    exit 0
fi
note "okf-check run $check_id ended with $conclusion (it read its cache before the seed); re-running its failed jobs"
gh api -X POST "repos/$REPO/actions/runs/$check_id/rerun-failed-jobs" >/dev/null || fail "could not re-run the failed jobs of okf-check run $check_id"

result="$(wait_run "$check_id" "$((attempt + 1))")" || fail "the re-run of okf-check run $check_id did not complete within $((MAX_POLLS * POLL)) seconds"
conclusion="${result#* }"
note "the re-run of okf-check run $check_id ended with: $conclusion"
[ "$conclusion" = success ] || fail "okf-check on $SHA is still not green after the seed (conclusion: $conclusion)"
