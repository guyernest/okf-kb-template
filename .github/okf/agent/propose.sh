#!/usr/bin/env bash
# Phase 214 (KTPL-04; D-05 to D-08, D-17; threats T-214-22 to T-214-24, T-214-49, T-214-55, T-214-57): the
# deterministic `propose` job. The agent's patch is model output and is treated as hostile input; this
# script is the only place the agent App's write token is ever used.
#
#   propose.sh prepare   Validate the proposal with no credential in the environment. Prints the step output
#                        `outcome`: ready, no-change, scope, provenance, index, findings, patch, branch-moved,
#                        contained, secret or agent-incomplete. Always exits 0 once the inputs are valid; details for the
#                        issue comment go to $RUNNER_TEMP/okf-propose/detail.txt (validated words only). The last check
#                        before `ready` is the pinned secret scan (D-19, plan 214-08) over the staged proposal: a finding,
#                        or a scan that could not run, is outcome `secret` and nothing is pushed.
#   propose.sh publish   (outcome ready) Commit with the trailers, push `agent/issue-<n>` without force and open
#                        or update the one pull request. Never calls a reviews or merge endpoint.
#   propose.sh report    (any other outcome) One issue comment of fixed sentences plus the validated details.
#
# Default-branch code only: this script, provenance.py, diff-scope.sh and the engine come from the checkout this
# job runs in (the gate-recorded default-branch commit). A proposal branch is DATA: it is read from the
# remote-tracking ref of this checkout, its tip must be the object the gate recorded, and the commit is built in a
# separate data worktree whose files are never executed or sourced.
#
# Env (prepare): OKF_ENGINE, OKF_REPO, OKF_ISSUE, OKF_KIND, OKF_CODE_REF, OKF_START_REF, OKF_BRANCH_EXISTS,
# OKF_CHECK_BASE, OKF_DEFAULT_BRANCH, RUNNER_TEMP, GITHUB_OUTPUT. publish adds GH_TOKEN (the App installation
# token), OKF_APP_SLUG, OKF_RUN_URL, OKF_TRIGGERED_BY, OKF_MODEL and OKF_ENGINE_VERSION_LINE. report reads
# GH_TOKEN, OKF_REPO, OKF_ISSUE, OKF_RUN_URL and OKF_OUTCOME.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE_SCRIPT="$HERE/../../actions/okf-check/diff-scope.sh"
PROVENANCE="$HERE/provenance.py"

SHA_RE='^[0-9a-f]{40}$'
ISSUE_RE='^[1-9][0-9]{0,9}$'
REPO_RE='^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$'
KIND_RE='^[a-z][a-z-]{0,30}$'
BRANCH_RE='^[A-Za-z0-9._/-]{1,200}$'
LOGIN_RE='^[A-Za-z0-9][A-Za-z0-9-]{0,38}$'
SLUG_RE='^[a-z0-9][a-z0-9-]{0,39}$'
MODEL_RE='^[][A-Za-z0-9._:/-]{1,100}$'
URL_RE='^https://[A-Za-z0-9._/-]{1,255}$'
VERSION_RE='^[A-Za-z0-9 ._(),+:-]{1,200}$'
DATE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
PATH_RE='^[A-Za-z0-9._/ -]{1,255}$'
REASON_RE='^[a-z-]{1,40}$'
RULE_RE='^[a-z0-9.-]{1,64}$'
OUTCOMES=' ready no-change scope provenance index findings patch branch-moved contained secret agent-incomplete '
PATCH_LIMIT=5242880
MAX_DETAIL=40
MARKER='<!-- okf-agent:v1 -->'
PUSH_KEY='http.https://github.com/.extraheader'

OUT_FILE="${GITHUB_OUTPUT:-/dev/null}"

invalid() {
    printf 'propose: %s\n' "$1" >&2
    exit 2
}

TEMP_DIR="${RUNNER_TEMP:-}"
STATE=""
WT=""
RESULT=""

init_dirs() {
    [ -n "$TEMP_DIR" ] || invalid 'RUNNER_TEMP is not set'
    STATE="$TEMP_DIR/okf-propose"
    WT="$TEMP_DIR/okf-proposal"
    RESULT="$TEMP_DIR/okf-result"
}

# need_common: the validated context shared by every command.
need_common() {
    [[ ${OKF_REPO:-} =~ $REPO_RE ]] || invalid 'OKF_REPO is not owner/name'
    [[ ${OKF_ISSUE:-} =~ $ISSUE_RE ]] || invalid 'OKF_ISSUE is not a plain positive integer'
}

# need_engine_context: the validated context of prepare and publish.
need_engine_context() {
    need_common
    [[ ${OKF_KIND:-} =~ $KIND_RE ]] || invalid 'OKF_KIND is not a kind word'
    [[ ${OKF_CODE_REF:-} =~ $SHA_RE ]] || invalid 'OKF_CODE_REF is not a full commit id'
    [[ ${OKF_START_REF:-} =~ $SHA_RE ]] || invalid 'OKF_START_REF is not a full commit id'
    case "${OKF_BRANCH_EXISTS:-}" in true | false) ;; *) invalid 'OKF_BRANCH_EXISTS is not true or false' ;; esac
    [[ ${OKF_DEFAULT_BRANCH:-} =~ $BRANCH_RE ]] || invalid 'OKF_DEFAULT_BRANCH is not a plain branch name'
    case "$OKF_DEFAULT_BRANCH" in *..*) invalid 'OKF_DEFAULT_BRANCH has a dot dot' ;; esac
}

# ------------------------------------------------------------------ prepare

detail_count=0
# detail <text>: one validated line for the issue comment (the caller has already checked the alphabet).
detail() {
    detail_count=$((detail_count + 1))
    if [ "$detail_count" -le "$MAX_DETAIL" ]; then
        printf '%s\n' "$1" >>"$STATE/detail.txt"
    fi
}

# safe_path <path>: the path when it is in the plain alphabet, else a fixed placeholder.
safe_path() {
    if [[ $1 =~ $PATH_RE ]]; then printf '%s' "$1"; else printf '<path withheld>'; fi
}

# finish <outcome>: record the outcome and stop. A refusal is an outcome, not a failure.
finish() {
    case "$OUTCOMES" in *" $1 "*) ;; *) invalid 'unknown outcome' ;; esac
    if [ "$detail_count" -gt "$MAX_DETAIL" ]; then
        printf '(%s more not listed)\n' "$((detail_count - MAX_DETAIL))" >>"$STATE/detail.txt"
    fi
    printf 'outcome=%s\n' "$1" >>"$OUT_FILE"
    exit 0
}

# reset_worktree: remove an earlier data worktree of this job's checkout.
reset_worktree() {
    git worktree prune >/dev/null 2>&1 || true
    if [ -e "$WT" ]; then
        git worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
        git worktree prune >/dev/null 2>&1 || true
    fi
}

cmd_prepare() {
    init_dirs
    need_engine_context
    local engine="${OKF_ENGINE:-}" repo="$OKF_REPO" issue="$OKF_ISSUE" code_ref="$OKF_CODE_REF" start_ref="$OKF_START_REF"
    local exists="$OKF_BRANCH_EXISTS" default_branch="$OKF_DEFAULT_BRANCH" check_base="${OKF_CHECK_BASE:-}"
    { [ -f "$engine" ] && [ -x "$engine" ] && [ ! -L "$engine" ]; } || invalid 'OKF_ENGINE is not a regular executable'
    [[ $check_base =~ $SHA_RE ]] || invalid 'OKF_CHECK_BASE is not a full commit id'
    [ "$(git rev-parse HEAD)" = "$code_ref" ] || invalid 'the checkout is not the recorded default-branch commit'
    git cat-file -e "${check_base}^{commit}" 2>/dev/null || invalid 'OKF_CHECK_BASE is not a commit of this checkout'

    rm -rf "$STATE"
    mkdir -p "$STATE"
    : >"$STATE/detail.txt"
    export OKF_PROPOSAL_DIR="$WT"
    local root
    root="$(OKF_ENGINE="$engine" bash "$SCOPE_SCRIPT" bundle-root "$code_ref")"

    # The agent's result: a finished run, a package that says ok, and the same base the gate recorded.
    local status="" packaged="" base="" day=""
    [ ! -L "$RESULT/status.txt" ] && [ -f "$RESULT/status.txt" ] && status="$(head -c 32 "$RESULT/status.txt" | tr -d '\n')"
    # A run stopped by a containment check (plan 214-15) carries only its reason: nothing else of it is read.
    case "$status" in
        contained:*)
            local why="${status#contained:}"
            [[ $why =~ $REASON_RE ]] || why=unknown
            printf '%s\n' "$why" >"$STATE/contained.txt"
            finish contained
            ;;
    esac
    [ "$status" = success ] || finish agent-incomplete
    [ ! -L "$RESULT/package.txt" ] && [ -f "$RESULT/package.txt" ] && packaged="$(head -c 32 "$RESULT/package.txt" | tr -d '\n')"
    case "$packaged" in
        ok) ;;
        patch) finish patch ;;
        *) finish agent-incomplete ;;
    esac
    [ ! -L "$RESULT/base.txt" ] && [ -f "$RESULT/base.txt" ] && base="$(head -c 64 "$RESULT/base.txt" | tr -d '\n')"
    [ "$base" = "$start_ref" ] || finish agent-incomplete
    [ ! -L "$RESULT/date.txt" ] && [ -f "$RESULT/date.txt" ] && day="$(head -c 16 "$RESULT/date.txt" | tr -d '\n')"
    [[ $day =~ $DATE_RE ]] || finish agent-incomplete
    local patch="$RESULT/agent.patch" size
    { [ -f "$patch" ] && [ ! -L "$patch" ]; } || finish agent-incomplete
    size="$(wc -c <"$patch" | tr -d ' ')"
    [ "$size" -le "$PATCH_LIMIT" ] || finish patch
    [ "$size" -gt 0 ] || finish no-change

    # The proposal branch must still be the object the gate recorded (and must still be absent when it was).
    local branch="agent/issue-$issue" tip=""
    tip="$(git rev-parse --verify --quiet "refs/remotes/origin/${branch}^{commit}" 2>/dev/null)" || tip=""
    if [ "$exists" = true ]; then
        [ "$tip" = "$start_ref" ] || finish branch-moved
    else
        [ -z "$tip" ] || finish branch-moved
        [ "$start_ref" = "$code_ref" ] || finish branch-moved
    fi
    git cat-file -e "${start_ref}^{commit}" 2>/dev/null || finish branch-moved

    # Read the patch's paths and headers BEFORE applying anything.
    local summary numstat entry path bad=0
    summary="$STATE/apply-summary.txt"
    numstat="$STATE/apply-numstat.bin"
    git apply --summary "$patch" >"$summary" 2>"$STATE/apply.err" || finish patch
    git apply --numstat -z "$patch" >"$numstat" 2>>"$STATE/apply.err" || finish patch
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        case "$entry" in
            ' create mode 100644 '*) ;;
            *)
                bad=1
                path="${entry##* mode * }"
                detail "$(safe_path "$path")"
                ;;
        esac
    done <"$summary"
    [ "$bad" -eq 0 ] || finish scope
    local fields added deleted
    while IFS= read -r -d '' entry; do
        added="${entry%%$'\t'*}"
        fields="${entry#*$'\t'}"
        deleted="${fields%%$'\t'*}"
        path="${fields#*$'\t'}"
        if [ "$added" = - ] || [ "$deleted" = - ]; then
            finish patch
        fi
        case "$path" in
            "$root"/*) ;;
            *)
                bad=1
                detail "$(safe_path "$path")"
                continue
                ;;
        esac
        case "/$path/" in
            */../* | */./* | *//*)
                bad=1
                detail "$(safe_path "$path")"
                ;;
        esac
    done <"$numstat"
    [ "$bad" -eq 0 ] || finish scope

    # Apply in a data worktree built from the proposal tip (or the default-branch commit): nothing in it is
    # executed, every script and the engine come from this checkout.
    reset_worktree
    git -c core.hooksPath=/dev/null worktree add --detach "$WT" "$start_ref" >"$STATE/worktree.out" 2>&1 || invalid 'cannot create the data worktree'
    if ! git -C "$WT" apply --index --whitespace=nowarn "$patch" 2>"$STATE/apply2.err"; then
        finish patch
    fi

    # D-07: only added or modified regular files under the bundle root, measured against the merge-base.
    local scope_rc=0
    (cd "$WT" && OKF_ENGINE="$engine" OKF_SCOPE_ROOT_REV="$code_ref" bash "$SCOPE_SCRIPT" check "$check_base" --cached) >"$STATE/scope.out" 2>"$STATE/scope.err" || scope_rc=$?
    if [ "$scope_rc" -ne 0 ]; then
        detail "diff scope check exit $scope_rc"
        finish scope
    fi

    # What the patch itself added or changed, relative to the tip it was built on.
    local records="$STATE/changed.bin" meta st rel
    local -a docs=() added_docs=()
    : >"$STATE/changed.txt"
    git -C "$WT" diff --raw -z --no-renames --cached "$start_ref" >"$records" || invalid 'cannot list the changes'
    while IFS= read -r -d '' meta; do
        IFS= read -r -d '' path || invalid 'the change list is truncated'
        st="${meta##* }"
        rel="${path#"$root"/}"
        if [[ $path =~ $PATH_RE ]]; then printf '%s\n' "$path" >>"$STATE/changed.txt"; fi
        case "$rel" in
            index.md | */index.md) ;;
            *.md)
                docs+=("$path")
                [ "$st" != A ] || added_docs+=("$rel")
                ;;
        esac
    done <"$records"

    # D-05: parsed provenance, never a literal grep.
    local profile_arg=() prov_out="$STATE/provenance.out" prov_rc=0 reason
    if git cat-file -e "refs/remotes/origin/${default_branch}:.okf/profile.json" 2>/dev/null; then
        profile_arg=(--profile)
    fi
    if [ "${#docs[@]}" -gt 0 ]; then
        (cd "$WT" && python3 -I "$PROVENANCE" --date "$day" --issue-url "${GITHUB_SERVER_URL:-https://github.com}/$repo/issues/$issue" ${profile_arg[@]+"${profile_arg[@]}"} -- "${docs[@]}") >"$prov_out" 2>"$STATE/provenance.err" || prov_rc=$?
        if [ "$prov_rc" -ne 0 ]; then
            while IFS=$'\t' read -r reason path; do
                [[ $reason =~ ^[a-z-]{1,40}$ ]] || reason=refused
                detail "$reason: $(safe_path "$path")"
            done <"$prov_out"
            finish provenance
        fi
    fi

    # D-08: the engine's own check, without --trusted-human-review, against the merge-base.
    local findings="$STATE/findings.json" check_rc=0
    (cd "$WT" && "$engine" check "$root" --base "$check_base" --format json --out "$findings") >"$STATE/check.out" 2>"$STATE/check.err" || check_rc=$?
    if [ "$check_rc" -ne 0 ]; then
        findings_detail "$findings" "$check_rc"
        finish findings
    fi

    # D-06: every added document must be listed by its directory's index.md.
    local doc dir index_doc missing=0 hits
    for doc in "${added_docs[@]+"${added_docs[@]}"}"; do
        dir="$(dirname "$doc")"
        if [ "$dir" = . ]; then index_doc=index.md; else index_doc="$dir/index.md"; fi
        hits="$(jq --arg a "$doc" --arg b "$index_doc" '[(.repo_findings // [])[] | select((.rule == "index-line-missing" or .rule == "repo.index-line-missing") and (.doc == $a or .doc == $b))] | length' "$findings" 2>/dev/null)" || hits=1
        if [ "${hits:-1}" != 0 ]; then
            missing=1
            detail "$(safe_path "$doc")"
        fi
    done
    [ "$missing" -eq 0 ] || finish index

    # D-19 (plan 214-08, T-214-66): the pinned secret scan over what the proposal would change against the merge-base, run
    # with this checkout's own script, pin and configuration (the default-branch commit, never the proposal branch). The
    # branch is public on a public repository, so a finding or a scan that cannot run pushes nothing.
    local scan_rc=0
    : >"$STATE/secret-rules.txt"
    OKF_LOCK_FILE=.okf/gitleaks.lock OKF_CONFIG_FILE=.okf/gitleaks.toml OKF_SCAN_RULES_FILE="$STATE/secret-rules.txt" \
        bash .github/okf/secret-scan.sh patch "$WT" "$check_base" >"$STATE/secret-scan.out" 2>"$STATE/secret-scan.err" || scan_rc=$?
    if [ "$scan_rc" -ne 0 ]; then
        if [ "$scan_rc" -eq 1 ]; then printf 'found\n' >"$STATE/secret-reason.txt"; else printf 'error\n' >"$STATE/secret-reason.txt"; fi
        finish secret
    fi

    # Every check passed: record outcome=ready.
    finish ready
}

# findings_detail <findings.json> <exit code>: the error and warning counts and the (severity, rule, document)
# triples, sorted in that order; every word is checked against its alphabet first.
findings_detail() {
    local file="$1" code="$2" rows="" errors=0 warnings=0 severity rule doc
    if [ "$code" -ge 2 ] || [ ! -f "$file" ] || [ -L "$file" ]; then
        detail "the self-check did not complete (exit $code)"
        return 0
    fi
    rows="$(jq -r '[((.repo_findings // [])[]), ((.profile_findings // [])[])]
        | map(select(type == "object" and (.severity | type) == "string" and (.rule | type) == "string" and (.doc | type) == "string"))
        | sort_by([.severity, .rule, .doc])[]
        | [.severity, .rule, .doc] | @tsv' "$file" 2>/dev/null)" || rows=""
    while IFS=$'\t' read -r severity rule doc; do
        [ -n "$severity" ] || continue
        case "$severity" in
            error) errors=$((errors + 1)) ;;
            warning) warnings=$((warnings + 1)) ;;
            *) continue ;;
        esac
    done <<<"$rows"
    detail "errors: $errors, warnings: $warnings"
    while IFS=$'\t' read -r severity rule doc; do
        [ -n "$severity" ] || continue
        case "$severity" in error | warning) ;; *) continue ;; esac
        [[ $rule =~ $RULE_RE ]] || rule='?'
        detail "$severity $rule $(safe_path "$doc")"
    done <<<"$rows"
}

# ------------------------------------------------------------------ publish

# read_state_lines <file>: the validated paths recorded by prepare, one per line.
cmd_publish() {
    init_dirs
    need_engine_context
    local slug="${OKF_APP_SLUG:-}" run_url="${OKF_RUN_URL:-}" login="${OKF_TRIGGERED_BY:-}" model="${OKF_MODEL:-}"
    local version="${OKF_ENGINE_VERSION_LINE:-}" repo="$OKF_REPO" issue="$OKF_ISSUE" kind="$OKF_KIND"
    local code_ref="$OKF_CODE_REF" default_branch="$OKF_DEFAULT_BRANCH"
    [ -n "${GH_TOKEN:-}" ] || invalid 'GH_TOKEN is not set'
    [[ $slug =~ $SLUG_RE ]] || invalid 'OKF_APP_SLUG is not a plain slug'
    [[ $run_url =~ $URL_RE ]] || invalid 'OKF_RUN_URL is not an https URL'
    [[ $login =~ $LOGIN_RE ]] || invalid 'OKF_TRIGGERED_BY is not a plain login'
    [[ $model =~ $MODEL_RE ]] || invalid 'OKF_MODEL is not a plain model id'
    [[ $version =~ $VERSION_RE ]] || version=unknown
    [ -d "$WT" ] && [ -f "$STATE/changed.txt" ] || invalid 'there is no validated proposal to publish'

    local branch="agent/issue-$issue" owner="${repo%%/*}"
    local bot_id email name
    bot_id="$(gh api "users/${slug}%5Bbot%5D" --jq .id 2>/dev/null)" || bot_id=''
    [[ $bot_id =~ ^[0-9]{1,12}$ ]] || invalid 'cannot read the agent App bot identity'
    name="${slug}[bot]"
    email="${bot_id}+${slug}[bot]@users.noreply.github.com"

    local message="$STATE/commit-message.txt"
    {
        printf 'okf-agent: %s for #%s\n\n' "$kind" "$issue"
        printf 'Proposed by the okf-agent from issue #%s at the request of %s.\n\n' "$issue" "$login"
        printf 'Okf-Issue: #%s\n' "$issue"
        printf 'Okf-Run: %s\n' "$run_url"
        printf 'Okf-Triggered-By: %s\n' "$login"
        printf 'Okf-Model: %s\n' "$model"
    } >"$message"
    GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" \
        git -C "$WT" -c core.hooksPath=/dev/null -c commit.gpgsign=false \
        commit --quiet -F "$message" >"$STATE/commit.out" 2>&1 || invalid 'the commit failed'

    # The App token reaches git only through the environment of this one command: never argv, never .git/config.
    local basic push_rc=0
    basic="$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="$PUSH_KEY" GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $basic" \
        git -C "$WT" push "https://github.com/$repo.git" "HEAD:refs/heads/agent/issue-$issue" >"$STATE/push.out" 2>&1 || push_rc=$?
    if [ "$push_rc" -ne 0 ]; then
        if grep -qiE 'rejected|non-fast-forward|fetch first' "$STATE/push.out"; then
            OKF_OUTCOME=branch-moved cmd_report
            exit 0
        fi
        printf '::error::okf-agent: the push of %s failed\n' "$branch"
        exit 1
    fi

    # The pull request: one per issue. An open one is edited, never duplicated.
    local behind='' listed='' count=0 line
    if ! git -C "$WT" merge-base --is-ancestor "$code_ref" HEAD 2>/dev/null; then
        behind='This branch is behind the default branch. Merge or rebase the default branch before approving.'
    fi
    while IFS= read -r line; do
        count=$((count + 1))
        if [ "$count" -le 50 ]; then listed="$listed- \`$line\`"$'\n'; fi
    done <"$STATE/changed.txt"
    if [ "$count" -gt 50 ]; then listed="$listed- ($((count - 50)) more not listed)"$'\n'; fi
    local body="$STATE/pr-body.md"
    {
        printf '%s\n' "$MARKER"
        printf '## okf-agent proposal\n\n'
        printf '| | |\n|---|---|\n'
        printf '| Issue | #%s |\n' "$issue"
        printf "| Kind | \`%s\` |\n" "$kind"
        printf '| Run | %s |\n' "$run_url"
        printf '| Triggered by | @%s |\n' "$login"
        printf "| Model | \`%s\` |\n" "$model"
        printf "| Engine | \`%s\` |\n\n" "$version"
        printf '### Changed files\n\n%s\n' "$listed"
        if [ -n "$behind" ]; then printf '%s\n\n' "$behind"; fi
        printf 'The agent cannot approve or merge. A maintainer reviews the change; a human review stamp is theirs to add.\n\n'
        printf 'Closes #%s\n' "$issue"
    } >"$body"

    local existing number
    existing="$(gh api "repos/$repo/pulls?head=$owner:$branch&state=open" --jq '.[0].number // empty' 2>/dev/null)" || existing=''
    if [[ $existing =~ $ISSUE_RE ]]; then
        gh api -X PATCH "repos/$repo/pulls/$existing" -f "body=$(cat "$body")" >/dev/null
        number="$existing"
    else
        number="$(gh api -X POST "repos/$repo/pulls" -f "title=okf-agent: $kind for #$issue" -f "head=$branch" -f "base=$default_branch" -f "body=$(cat "$body")" --jq .number)"
        [[ $number =~ $ISSUE_RE ]] || invalid 'the pull request response has no number'
    fi
    gh api -X POST "repos/$repo/issues/$issue/comments" -f "body=okf-agent proposed a change for this issue: pull request #$number ($run_url)." >/dev/null
    printf 'okf-agent: pull request #%s is up to date\n' "$number"
}

# ------------------------------------------------------------------ report

cmd_report() {
    init_dirs
    need_common
    local outcome="${OKF_OUTCOME:-}" run_url="${OKF_RUN_URL:-}" text="" line why=""
    if [ "${OKF_OUTCOME:-}" = contained ] && [ -f "$STATE/contained.txt" ] && [ ! -L "$STATE/contained.txt" ]; then
        why="$(head -c 64 "$STATE/contained.txt" | tr -d '\n')"
    fi
    [[ $why =~ $REASON_RE ]] || why='reason unavailable'
    local secret_why='' secret_rules='' rule
    if [ "${OKF_OUTCOME:-}" = secret ]; then
        if [ -f "$STATE/secret-reason.txt" ] && [ ! -L "$STATE/secret-reason.txt" ]; then
            secret_why="$(head -c 16 "$STATE/secret-reason.txt" | tr -d '\n')"
        fi
        if [ "$secret_why" = found ] && [ -f "$STATE/secret-rules.txt" ] && [ ! -L "$STATE/secret-rules.txt" ]; then
            while IFS= read -r rule; do
                [[ $rule =~ $RULE_RE ]] || continue
                case ", $secret_rules, " in *", $rule, "*) continue ;; esac
                secret_rules="${secret_rules:+$secret_rules, }$rule"
            done < <(sort -u "$STATE/secret-rules.txt" | head -n 10)
        fi
        [ -n "$secret_rules" ] || secret_rules='rule not named'
    fi
    case "$OUTCOMES" in *" $outcome "*) ;; *) outcome=agent-incomplete ;; esac
    [ "$outcome" != ready ] || outcome=agent-incomplete
    [[ $run_url =~ $URL_RE ]] || run_url='(run link unavailable)'
    case "$outcome" in
        no-change) text="okf-agent finished and proposed no change for this issue. No branch and no pull request were created. If a change is expected, make the report clearer and add the \`agent:propose\` label again." ;;
        scope) text='okf-agent refused its own proposal: it changed something outside the knowledge bundle, or changed files in a way that is not allowed (a delete, a rename, a link, an executable). Nothing was pushed.' ;;
        provenance) text="okf-agent refused its own proposal: a changed document lacks the required provenance (an \`agent:okf-agent\` verified entry dated for this run and, unless the profile says otherwise, this issue as a source). Nothing was pushed." ;;
        index) text="okf-agent refused its own proposal: an added document is not listed in its directory \`index.md\`. Nothing was pushed." ;;
        findings) text='okf-agent refused its own proposal: the self-check reported errors (or did not complete). Nothing was pushed.' ;;
        patch) text='okf-agent refused its own proposal: the patch was binary, too large or could not be applied. Nothing was pushed.' ;;
        contained) text="The agent run was stopped by a containment check ($why); nothing was pushed." ;;
        secret)
            if [ "$secret_why" = found ]; then
                text="A possible secret was found in the proposed change ($secret_rules); nothing was pushed."
            else
                text='The secret scan could not run; nothing was pushed.'
            fi
            ;;
        branch-moved) text="The proposal branch for this issue changed while the agent ran, so nothing was pushed and nothing was overwritten. Add the \`agent:propose\` label again to build on the current branch." ;;
        *) text="okf-agent did not complete. No branch and no pull request were created. A maintainer can add the \`agent:propose\` label again." ;;
    esac
    text="$text"$'\n\n'"Run: $run_url"
    if [ -s "$STATE/detail.txt" ] && [ "$outcome" != branch-moved ] && [ "$outcome" != no-change ] && [ "$outcome" != agent-incomplete ] && [ "$outcome" != contained ] && [ "$outcome" != secret ]; then
        text="$text"$'\n\n'
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            text="$text- \`$line\`"$'\n'
        done <"$STATE/detail.txt"
    fi
    if [ -z "${GH_TOKEN:-}" ]; then
        printf '::warning::okf-agent: no token, the issue comment was not posted\n'
        return 0
    fi
    if ! gh api -X POST "repos/$OKF_REPO/issues/$OKF_ISSUE/comments" -f "body=$text" >/dev/null 2>&1; then
        printf '::warning::okf-agent: the report comment could not be posted\n'
    fi
}

case "${1:-}" in
    prepare) cmd_prepare ;;
    publish) cmd_publish ;;
    report) cmd_report ;;
    *) invalid 'usage: propose.sh prepare | publish | report' ;;
esac
