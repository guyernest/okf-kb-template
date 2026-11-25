#!/usr/bin/env bash
# Phase 214 (KTPL-03, KTPL-05; D-01, D-04; threats T-214-16, T-214-17, T-214-54): the gate of the
# okf-agent workflow. It decides, from live GitHub state, whether the person who added the
# `agent:propose` label may start the agent, and it records every refusal.
#
#   gate.sh check     the live permission check, then the triage re-validation of the live issue.
#                     Saves the live issue for the snapshot step. Always exits 0 once the inputs
#                     are valid: a refusal is an outcome (outputs verdict=refused), not a failure.
#   gate.sh refuse    record one refusal (a job summary line and one issue comment) for the reason
#                     in OKF_REASON (permission and role in OKF_PERMISSION and OKF_ROLE).
#   gate.sh branch    find the proposal branch `agent/issue-<n>` (KTPL-04, D-08) and record the facts the
#                     credentialed jobs need: code-ref (the default branch commit that ran this gate),
#                     start-ref (the branch tip, or code-ref when there is no branch), branch-exists and
#                     check-base (the merge-base of the two). The tip is read from the remote-tracking ref
#                     of this checkout and must equal the commit the branches API reports; a branch whose
#                     changes since the merge-base touch anything outside the bundle root is refused.
#   gate.sh decide    emit the final verdict from the earlier steps' outcomes; a failed snapshot or
#                     upload becomes a recorded refusal through the same recorder.
#   gate.sh release   delete the `agent:propose` label so a maintainer can trigger again. A label
#                     that is already gone (404) is fine.
#
# Env (the only inputs): GH_TOKEN, OKF_REPO (owner/name), OKF_ISSUE, OKF_SENDER, OKF_SENDER_TYPE,
# RUNNER_TEMP, GITHUB_OUTPUT and GITHUB_STEP_SUMMARY; branch also reads OKF_ENGINE, OKF_CODE_REF,
# OKF_PERMISSION and OKF_ROLE; decide also reads GATE_VERDICT, GATE_REASON, GATE_PERMISSION, GATE_ROLE,
# GATE_KIND, GATE_TRIGGERED_BY, CONFIG_OUTCOME, BRANCH_OUTCOME, BRANCH_VERDICT, BRANCH_REASON,
# SNAPSHOT_OUTCOME, SNAPSHOT_REASON, SKILL_OUTCOME and UPLOAD_OUTCOME (step outputs written by this script
# and by snapshot.py after strict shape checks).
#
# Reason codes: allowed, not-a-plain-login, not-a-user, lookup-failed, permission, not-triaged,
# changed-after-trigger, config-invalid, snapshot-failed, branch-moved, branch-not-bundle-only,
# skill-render-failed.
#
# Trust: the event gives only a login, a type and an issue number. Each is checked against a strict
# pattern before it is used or written anywhere. Nothing from the issue text is ever printed, put in
# a comment or written to GITHUB_OUTPUT: the comment and the summary are composed from fixed words,
# a validated login and validated one-word values. The author association in the event, the labels
# that were on the issue when it was triggered and any bot exemption are never trusted; only one live
# read of `collaborators/<login>/permission` decides, and only `admin` and `write` pass (the API
# reports the maintain role as write and the triage role as read).
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OKF_DIR="$(cd "$HERE/.." && pwd)"
CONTRACT="$OKF_DIR/issue-contract.json"
TRIAGE="$OKF_DIR/triage.py"

TRIGGER_LABEL_PATH='agent%3Apropose'
LOGIN_RE='^[A-Za-z0-9][A-Za-z0-9-]{0,38}$'
ISSUE_RE='^[1-9][0-9]{0,9}$'
REPO_RE='^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$'
WORD_RE='^[A-Za-z0-9 ._-]{1,40}$'
SAFE_RE='^[A-Za-z0-9 ._-]{0,64}$'
KIND_RE='^[a-z][a-z-]{0,30}$'
SHA_RE='^[0-9a-f]{40}$'
REASONS=' allowed not-a-plain-login not-a-user lookup-failed permission not-triaged changed-after-trigger config-invalid snapshot-failed branch-moved branch-not-bundle-only skill-render-failed '
SCOPE_SCRIPT="$HERE/../../actions/okf-check/diff-scope.sh"

OUT_FILE="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/null}"

usage_error() {
    printf 'okf-agent gate: %s\n' "$1" >&2
    exit 2
}

# emit <key> <value>: one step output; a value outside the plain alphabet becomes `unknown`.
emit() {
    local value="$2"
    [[ $value =~ $SAFE_RE ]] || value=unknown
    printf '%s=%s\n' "$1" "$value" >>"$OUT_FILE"
}

# word <value>: the value when it is a short plain word or phrase, else `unknown`.
word() {
    if [[ ${1:-} =~ $WORD_RE ]]; then printf '%s' "$1"; else printf 'unknown'; fi
}

require_context() {
    [[ ${OKF_REPO:-} =~ $REPO_RE ]] || usage_error 'OKF_REPO is not an owner/name repository'
    [[ ${OKF_ISSUE:-} =~ $ISSUE_RE ]] || usage_error 'OKF_ISSUE is not a plain positive integer'
}

# actor_label: how the refusal names the actor. Only a plain login is ever written out.
actor_label() {
    if [[ ${OKF_SENDER:-} =~ $LOGIN_RE ]]; then
        printf '@%s' "$OKF_SENDER"
    else
        printf 'an actor whose login is not a plain GitHub login'
    fi
}

# write_summary <verdict> <reason> <permission> <role>: the job summary line.
write_summary() {
    local who
    if [[ ${OKF_SENDER:-} =~ $LOGIN_RE ]]; then who="\`$OKF_SENDER\`"; else who='(not a plain login)'; fi
    {
        printf '### okf-agent trigger\n\n'
        # shellcheck disable=SC2016  # the backticks are literal markdown
        printf 'Actor %s (type %s): permission `%s`, role `%s`, reason `%s`: **%s**\n' \
            "$who" "$(word "${OKF_SENDER_TYPE:-}")" "$(word "$3")" "$(word "$4")" "$(word "$2")" "$1"
    } >>"$SUMMARY_FILE"
}

# record_refusal <reason> <permission> <role>: the summary line plus one issue comment.
record_refusal() {
    write_summary refused "$1" "$2" "$3"
    if [[ ${OKF_REPO:-} =~ $REPO_RE && ${OKF_ISSUE:-} =~ $ISSUE_RE ]]; then
        local text
        text="okf-agent ignored a trigger from $(actor_label) (permission: $(word "$2"), reason: $(word "$1"))."
        if ! gh api -X POST "repos/$OKF_REPO/issues/$OKF_ISSUE/comments" -f "body=$text" >/dev/null 2>&1; then
            printf '::warning::okf-agent: the refusal comment could not be posted\n'
        fi
    fi
}

# refuse_and_exit <reason> <permission> <role>: outputs, the record, and a clean exit.
refuse_and_exit() {
    emit verdict refused
    emit reason "$1"
    emit permission "$(word "$2")"
    emit role "$(word "$3")"
    record_refusal "$1" "$2" "$3"
    exit 0
}

# ------------------------------------------------------------------ check

cmd_check() {
    require_context
    local dir="${RUNNER_TEMP:?RUNNER_TEMP is not set}/okf-gate"
    umask 077
    mkdir -p "$dir"

    [[ ${OKF_SENDER:-} =~ $LOGIN_RE ]] || refuse_and_exit not-a-plain-login unknown unknown
    [ "${OKF_SENDER_TYPE:-}" = User ] || refuse_and_exit not-a-user unknown unknown

    # One live permission read. 404 ("is not a user", as for an App) is a refusal, never a retry.
    local resp rc=0
    resp="$(gh api "repos/$OKF_REPO/collaborators/$OKF_SENDER/permission" 2>"$dir/permission.err")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        if grep -q 'HTTP 404' "$dir/permission.err"; then
            refuse_and_exit not-a-user unknown unknown
        fi
        refuse_and_exit lookup-failed unknown unknown
    fi
    local permission role
    permission="$(jq -r '.permission | strings' <<<"$resp" 2>/dev/null)" || permission=''
    role="$(jq -r '.role_name // empty | strings' <<<"$resp" 2>/dev/null)" || role=''
    [[ $permission =~ ^[a-z]{1,16}$ ]] || refuse_and_exit lookup-failed unknown unknown
    [[ $role =~ $WORD_RE ]] || role=unknown
    case "$permission" in
        admin | write) ;;
        *) refuse_and_exit permission "$permission" "$role" ;;
    esac

    # One live read of the issue, with the HTML rendering (it carries the signed private-attachment
    # URLs). The snapshot step compares it with the event and builds the snapshot from this same file.
    local issue_file="$dir/issue.json"
    if ! gh api -H 'Accept: application/vnd.github.full+json' "repos/$OKF_REPO/issues/$OKF_ISSUE" >"$issue_file" 2>"$dir/issue.err"; then
        refuse_and_exit lookup-failed "$permission" "$role"
    fi
    jq -e --argjson n "$OKF_ISSUE" '(type == "object") and (.number == $n) and (has("pull_request") | not)' "$issue_file" >/dev/null 2>&1 \
        || refuse_and_exit not-triaged "$permission" "$role"

    # The labels: okf:triaged plus exactly one report-kind label, both read from the issue contract.
    local labels
    labels="$(jq -n --slurpfile c "$CONTRACT" --slurpfile i "$issue_file" '
        ([$i[0].labels[]? | if type == "object" then .name else . end | select(type == "string")]) as $labels
        | {
            triaged: ($labels | any(. == $c[0].triaged_label)),
            kinds: [$c[0].kinds | to_entries[] | select(.value.label as $l | $labels | any(. == $l)) | .key]
          }' 2>/dev/null)" || refuse_and_exit not-triaged "$permission" "$role"
    jq -e '.triaged == true and (.kinds | length) == 1' <<<"$labels" >/dev/null 2>&1 \
        || refuse_and_exit not-triaged "$permission" "$role"
    local kind
    kind="$(jq -r '.kinds[0]' <<<"$labels")"
    [[ $kind =~ $KIND_RE ]] || refuse_and_exit not-triaged "$permission" "$role"

    # The label alone is not proof of validity: the shared triage validator runs on the live body.
    if ! python3 -I "$TRIAGE" --decide-only --issue-json "$issue_file" >"$dir/decision.json" 2>"$dir/triage.err"; then
        refuse_and_exit not-triaged "$permission" "$role"
    fi
    jq -e --arg k "$kind" '.valid == true and .kind == $k' "$dir/decision.json" >/dev/null 2>&1 \
        || refuse_and_exit not-triaged "$permission" "$role"

    emit verdict allowed
    emit reason allowed
    emit permission "$permission"
    emit role "$role"
    emit kind "$kind"
    emit issue "$OKF_ISSUE"
    emit triggered-by "$OKF_SENDER"
    write_summary allowed allowed "$permission" "$role"
}

# ------------------------------------------------------------------ branch

# branch_refuse <reason>: outputs and the record for a refusal found by the branch step. The permission and
# role come from the check step's outputs (OKF_PERMISSION and OKF_ROLE).
branch_refuse() {
    emit verdict refused
    emit reason "$1"
    record_refusal "$1" "${OKF_PERMISSION:-unknown}" "${OKF_ROLE:-unknown}"
    exit 0
}

cmd_branch() {
    require_context
    local code_ref="${OKF_CODE_REF:-}" engine="${OKF_ENGINE:-}"
    [[ $code_ref =~ $SHA_RE ]] || usage_error 'OKF_CODE_REF is not a full commit id'
    { [ -n "$engine" ] && [ -x "$engine" ]; } || usage_error 'OKF_ENGINE is not an executable'
    git rev-parse --verify --quiet "${code_ref}^{commit}" >/dev/null || usage_error 'OKF_CODE_REF is not a commit of this checkout'

    local dir="${RUNNER_TEMP:?RUNNER_TEMP is not set}/okf-gate"
    umask 077
    mkdir -p "$dir"
    local resp rc=0
    resp="$(gh api "repos/$OKF_REPO/branches/agent%2Fissue-$OKF_ISSUE" 2>"$dir/branch.err")" || rc=$?

    local start_ref="$code_ref" exists=false
    if [ "$rc" -ne 0 ]; then
        grep -q 'HTTP 404' "$dir/branch.err" || branch_refuse lookup-failed
    else
        local api_sha local_sha
        api_sha="$(jq -r '.commit.sha | strings' <<<"$resp" 2>/dev/null)" || api_sha=''
        [[ $api_sha =~ $SHA_RE ]] || branch_refuse lookup-failed
        # The tip is read from this checkout (it holds every branch) and never downloaded here: a later
        # download on a private repository would have no credential. It must be the object the API names.
        local_sha="$(git rev-parse --verify --quiet "refs/remotes/origin/agent/issue-${OKF_ISSUE}^{commit}" 2>/dev/null)" || local_sha=''
        [ -n "$local_sha" ] && [ "$local_sha" = "$api_sha" ] || branch_refuse branch-moved
        start_ref="$api_sha"
        exists=true
    fi

    local check_base
    check_base="$(git merge-base "$code_ref" "$start_ref" 2>/dev/null)" || branch_refuse branch-not-bundle-only
    [[ $check_base =~ $SHA_RE ]] || branch_refuse branch-not-bundle-only

    if [ "$exists" = true ]; then
        local scope_rc=0
        OKF_ENGINE="$engine" OKF_SCOPE_ROOT_REV="$code_ref" bash "$SCOPE_SCRIPT" check "$check_base" "$start_ref" >"$dir/scope.out" 2>"$dir/scope.err" || scope_rc=$?
        case "$scope_rc" in
            0) ;;
            1) branch_refuse branch-not-bundle-only ;;
            *) branch_refuse lookup-failed ;;
        esac
    fi

    emit verdict allowed
    emit reason allowed
    emit code-ref "$code_ref"
    emit start-ref "$start_ref"
    emit branch-exists "$exists"
    emit check-base "$check_base"
}

# ------------------------------------------------------------------ refuse

cmd_refuse() {
    require_context
    local reason="${OKF_REASON:-}"
    case "$REASONS" in *" $reason "*) ;; *) usage_error 'OKF_REASON is not a known reason code' ;; esac
    [ "$reason" != allowed ] || usage_error 'OKF_REASON must be a refusal reason'
    record_refusal "$reason" "${OKF_PERMISSION:-unknown}" "${OKF_ROLE:-unknown}"
}

# ------------------------------------------------------------------ decide

cmd_decide() {
    local verdict=refused reason="${GATE_REASON:-}" recorded=no
    if [ "${GATE_VERDICT:-}" = allowed ]; then
        if [ "${BRANCH_OUTCOME:-}" != success ]; then
            reason=lookup-failed
        elif [ "${BRANCH_VERDICT:-}" = refused ]; then
            # The branch step recorded its own refusal; only its reason is repeated here.
            reason=lookup-failed
            case "$REASONS" in *" ${BRANCH_REASON:-} "*) reason="$BRANCH_REASON" ;; esac
            recorded=yes
        elif [ "${BRANCH_VERDICT:-}" != allowed ]; then
            reason=lookup-failed
        elif [ "${CONFIG_OUTCOME:-}" != success ]; then
            reason=config-invalid
        elif [ "${SNAPSHOT_OUTCOME:-}" != success ]; then
            case "${SNAPSHOT_REASON:-}" in
                changed-after-trigger) reason=changed-after-trigger ;;
                *) reason=snapshot-failed ;;
            esac
        elif [ "${SKILL_OUTCOME:-}" != success ]; then
            reason=skill-render-failed
        elif [ "${UPLOAD_OUTCOME:-}" != success ]; then
            reason=snapshot-failed
        else
            verdict=allowed
        fi
        if [ "$verdict" = refused ] && [ "$recorded" = no ]; then
            record_refusal "$reason" "${GATE_PERMISSION:-unknown}" "${GATE_ROLE:-unknown}"
        fi
    elif [ -z "${GATE_VERDICT:-}" ]; then
        # The check step did not finish, so nothing was recorded yet.
        reason=lookup-failed
        record_refusal "$reason" unknown unknown
    fi
    emit verdict "$verdict"
    emit reason "$([ "$verdict" = allowed ] && printf allowed || printf '%s' "$reason")"
    if [ "$verdict" = allowed ]; then
        [[ ${OKF_ISSUE:-} =~ $ISSUE_RE ]] && emit issue "$OKF_ISSUE"
        [[ ${GATE_TRIGGERED_BY:-} =~ $LOGIN_RE ]] && emit triggered-by "$GATE_TRIGGERED_BY"
        [[ ${GATE_KIND:-} =~ $KIND_RE ]] && emit kind "$GATE_KIND"
    fi
    return 0
}

# ------------------------------------------------------------------ release

cmd_release() {
    require_context
    local err rc=0
    err="$(mktemp)"
    gh api -X DELETE "repos/$OKF_REPO/issues/$OKF_ISSUE/labels/$TRIGGER_LABEL_PATH" >/dev/null 2>"$err" || rc=$?
    if [ "$rc" -ne 0 ] && ! grep -q 'HTTP 404' "$err"; then
        rm -f "$err"
        printf '::error::okf-agent: the trigger label could not be removed\n'
        exit 1
    fi
    rm -f "$err"
}

case "${1:-}" in
    check) cmd_check ;;
    branch) cmd_branch ;;
    refuse) cmd_refuse ;;
    decide) cmd_decide ;;
    release) cmd_release ;;
    *) usage_error 'usage: gate.sh check | branch | refuse | decide | release' ;;
esac
