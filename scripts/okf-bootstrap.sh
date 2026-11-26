#!/usr/bin/env bash
# Phase 214 (KTPL-01, D-14, D-16, D-17): apply the repository settings a knowledge-base repository
# needs, codifying kb-template/.github/okf/CI.md. Settings as code: a template repository carries no
# settings, so without this a second KB repository is left open.
#
#   okf-bootstrap.sh --repo <owner/name> [--dry-run] [--repair] [--agent-app-slug <slug>]
#
#   --repo              the repository to configure (required)
#   --dry-run           read everything, write nothing, print what would be written
#   --repair            tighten an existing `okf-default-branch` ruleset that is below the floor
#                       (merge-only: it raises each field below the floor, empties the bypass list and
#                       keeps every stronger live setting). Without it a drifted ruleset is reported.
#   --agent-app-slug    the agent GitHub App's slug; sets the repository variable OKF_AGENT_BOT_LOGIN
#                       to `<slug>[bot]` (read by the required check)
#
# Run it with an ADMIN's `gh` login (it needs Administration: write). It uses `gh api` only.
#
# It applies, each step read-then-write-only-if-different (list reads are paginated):
#   the default-branch ruleset `okf-default-branch` (required checks okf-check and okf-secret-scan bound
#   to the GitHub Actions integration, code-owner review, one approval, last-push approval, stale-review
#   dismissal, no force push, no deletion, no bypass), the environments okf-engine-seed, publish, agent
#   and okf-maintenance each limited to the default branch, the Actions settings (default workflow token
#   read, Actions may not approve pull requests, fork pull request approval; a private repository whose fork
#   workflows are already OFF is compliant and is not written), the six D-16 labels and the
#   repository variables OKF_AGENT_BOT_LOGIN and OKF_MAINTENANCE_ENABLED=true.
#
# It NEVER writes a secret: it lists, per environment, the secret NAMES still missing together with the
# `gh secret set` command for the human. It never loosens and never removes anything: an environment
# with any protection rule besides its branch policy is left alone, an extra deployment policy is
# reported with the command for a human, and no other ruleset, environment or reviewer is modified.
#
# Output: one line per item (`ok`, `applied`, `drift`, `cannot-read`, `cannot-write`, `request-error`,
# `dry-run`), `place by hand:` lines for missing secrets, `note ...` lines, then
# `okf-bootstrap: <A> applied, <O> ok, <U> unresolved`.
# Exit 0: nothing unresolved. 1: an item is unresolved (drift not repaired, a read or write failed).
# 2: usage error or an unreachable repository.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OKF_PROG="okf-bootstrap"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=okf-settings/common.sh
. "$HERE/okf-settings/common.sh"

B_APPLIED=0
B_WOULD=0
B_OK=0
B_UNRESOLVED=0
DRY_RUN=0
REPAIR=0
SLUG=""
REPO_ARG=""

usage() {
    {
        printf 'usage: %s --repo <owner/name> [--dry-run] [--repair] [--agent-app-slug <slug>]\n' "$OKF_PROG"
    } >&2
    exit "${1:-2}"
}

b_ok() {
    printf 'ok %s\n' "$1"
    B_OK=$((B_OK + 1))
}

b_drift() {
    printf 'drift %s: %s\n' "$1" "$(okf_sanitize "$2")"
    B_UNRESOLVED=$((B_UNRESOLVED + 1))
}

b_unreadable() {
    printf 'cannot-read %s: %s\n' "$1" "$(okf_sanitize "$OKF_GET_REASON")"
    B_UNRESOLVED=$((B_UNRESOLVED + 1))
}

# apply <item> <what> <gh api args...>: one write. A dry run only says what it would do.
apply() {
    local item="$1" what="$2"
    shift 2
    if [ "$DRY_RUN" = 1 ]; then
        printf 'dry-run %s: would %s\n' "$item" "$what"
        B_WOULD=$((B_WOULD + 1))
        return 0
    fi
    if okf_api_write "$item" "$@"; then
        printf 'applied %s: %s\n' "$item" "$what"
        B_APPLIED=$((B_APPLIED + 1))
        return 0
    fi
    B_UNRESOLVED=$((B_UNRESOLVED + 1))
    return 1
}

# ruleset_step: create `okf-default-branch`, accept a compliant one, report or repair a drifted one.
ruleset_step() {
    local list="$OKF_TMP/rulesets.json" live="$OKF_TMP/ruleset-live.json" id body="$OKF_TMP/ruleset-body.json"
    if ! okf_api_get ruleset "repos/$OKF_REPO/rulesets" "$list" --paginate; then
        b_unreadable ruleset
        return 0
    fi
    id="$(jq -s -r --arg n "$OKF_RULESET_NAME" '[(add // [])[] | select(.name == $n and ((.source_type // "Repository") == "Repository")) | .id][0] // empty' "$list" 2>/dev/null || true)"
    if [ -z "$id" ]; then
        cp "$OKF_RULESET_JSON" "$body"
        apply ruleset "create the ruleset $OKF_RULESET_NAME" -X POST "repos/$OKF_REPO/rulesets" --input "$body" || true
        return 0
    fi
    [[ $id =~ ^[0-9]{1,20}$ ]] || {
        b_drift ruleset "the ruleset list returned an unusable id"
        return 0
    }
    if ! okf_api_get ruleset "repos/$OKF_REPO/rulesets/$id" "$live"; then
        b_unreadable ruleset
        return 0
    fi
    if okf_ruleset_compliant "$live"; then
        b_ok ruleset
        return 0
    fi
    if [ "$REPAIR" != 1 ]; then
        b_drift ruleset "$OKF_RULESET_REASONS; re-run with --repair to tighten it"
        return 0
    fi
    okf_ruleset_repair_body "$live" "$body" || {
        b_drift ruleset "the live ruleset could not be merged for repair"
        return 0
    }
    apply ruleset "tighten the ruleset $OKF_RULESET_NAME" -X PUT "repos/$OKF_REPO/rulesets/$id" --input "$body" || true
}

# ENV_READY: environments that exist (or, in a dry run, would exist) so their secret names can be listed.
ENV_READY=""
ENV_NEW=""

in_list() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }

# policy_step <env> <can-write: 1|0> <flag reasons>: the deployment policy list must be exactly the one
# default-branch policy. A missing policy is added (never in a protected environment); an extra policy
# is reported with the command for a human and never removed here.
policy_step() {
    local env="$1" can_write="$2" flags="$3" item="environment.$1.branch-policy"
    local pf="$OKF_TMP/pol-$1.json" ef="$OKF_TMP/entries-$1.json" reasons id kind has_default
    if okf_api_get "$item" "repos/$OKF_REPO/environments/$env/deployment-branch-policies" "$pf" --paginate; then
        okf_policy_entries "$pf" >"$ef"
    elif [ "$OKF_GET_STATUS" = absent ]; then
        printf '[]' >"$ef"
    else
        b_unreadable "$item"
        return 0
    fi
    has_default="$(jq --arg b "$OKF_DEFAULT_BRANCH" 'any(.[]; .name == $b and .type == "branch")' "$ef")"
    if [ "$can_write" = 1 ] && [ "$has_default" != true ]; then
        apply "$item" "add the policy for $OKF_DEFAULT_BRANCH" -X POST "repos/$OKF_REPO/environments/$env/deployment-branch-policies" \
            -f "name=$OKF_DEFAULT_BRANCH" -f type=branch || return 0
        has_default=true
        jq --arg b "$OKF_DEFAULT_BRANCH" '. + [{id: 0, name: $b, type: "branch"}]' "$ef" >"$ef.new"
        mv "$ef.new" "$ef"
    fi
    if [ "$can_write" = 1 ]; then
        reasons="$(okf_policy_reasons "$ef" | okf_join_lines)"
    else
        reasons="$( { printf '%s\n' "$flags"; okf_policy_reasons "$ef"; } | okf_join_lines)"
    fi
    if [ -n "$reasons" ]; then
        if [ "$can_write" = 0 ]; then
            b_drift "$item" "$reasons; left alone because the environment has other protection rules (reviewers, a wait timer or a custom rule)"
        else
            b_drift "$item" "$reasons; remove the extra policy by hand"
        fi
        while IFS=$'\t' read -r id kind; do
            [[ $id =~ ^[1-9][0-9]{0,19}$ ]] || continue
            printf '  to remove it by hand: gh api -X DELETE repos/%s/environments/%s/deployment-branch-policies/%s   (%s policy)\n' \
                "$OKF_REPO" "$env" "$id" "$(okf_sanitize "$kind" 20)"
        done < <(okf_policy_extras "$ef")
    else
        b_ok "$item"
    fi
}

# environment_step <env>
environment_step() {
    local env="$1" item="environment.$1" f="$OKF_TMP/env-$1.json" exists=0 other=0 flags=""
    if okf_api_get "$item" "repos/$OKF_REPO/environments/$env" "$f"; then
        exists=1
        other="$(jq '[(.protection_rules // [])[] | select(.type != "branch_policy")] | length' "$f" 2>/dev/null || echo 0)"
        flags="$(okf_env_flag_reasons "$f")"
    elif [ "$OKF_GET_STATUS" != absent ]; then
        b_unreadable "$item"
        return 0
    fi
    if [ "$exists" = 1 ] && [ "$other" -gt 0 ]; then
        # reviewers, a wait timer or a custom rule: never re-PUT (the PUT could discard them)
        b_ok "$item"
        ENV_READY="$ENV_READY $env"
        policy_step "$env" 0 "$flags"
        return 0
    fi
    if [ "$exists" = 0 ] || [ -n "$flags" ]; then
        apply "$item" "limit $env to custom branch policies" -X PUT "repos/$OKF_REPO/environments/$env" \
            -F 'deployment_branch_policy[protected_branches]=false' -F 'deployment_branch_policy[custom_branch_policies]=true' || return 0
        if [ "$DRY_RUN" = 1 ] && [ "$exists" = 0 ]; then
            printf 'dry-run %s.branch-policy: would add the policy for %s\n' "$item" "$OKF_DEFAULT_BRANCH"
            B_WOULD=$((B_WOULD + 1))
            ENV_READY="$ENV_READY $env"
            ENV_NEW="$ENV_NEW $env"
            return 0
        fi
    else
        b_ok "$item"
    fi
    ENV_READY="$ENV_READY $env"
    policy_step "$env" 1 ""
}

# secret_names_step <env> <names, comma separated>: list the missing names; write nothing.
secret_names_step() {
    local env="$1" names="$2" sf="$OKF_TMP/secrets-$1.json" have="" name
    local -a list
    in_list "$ENV_READY" "$env" || return 0
    IFS=',' read -r -a list <<<"$names"
    if ! in_list "$ENV_NEW" "$env"; then
        if okf_api_get "secret.$env" "repos/$OKF_REPO/environments/$env/secrets" "$sf" --paginate; then
            have="$(jq -s -r '.[] | (.secrets // [])[] | .name' "$sf" 2>/dev/null | tr '\n' ' ')"
        else
            b_unreadable "secret.$env"
            return 0
        fi
    fi
    for name in "${list[@]}"; do
        if in_list "$have" "$name"; then continue; fi
        printf 'place by hand: gh secret set %s --env %s --repo %s\n' "$name" "$env" "$OKF_REPO"
    done
}

# actions_step: default workflow token read-only, Actions may not approve pull requests.
actions_step() {
    local f="$OKF_TMP/workflow.json" tok app tok_ok=0 app_ok=0
    if ! okf_api_get actions.workflow-token "repos/$OKF_REPO/actions/permissions/workflow" "$f"; then
        b_unreadable actions.workflow-token
        return 0
    fi
    tok="$(jq -r '.default_workflow_permissions | tostring' "$f" 2>/dev/null || true)"
    app="$(jq -r '.can_approve_pull_request_reviews | tostring' "$f" 2>/dev/null || true)"
    [ "$tok" = read ] && tok_ok=1
    [ "$app" = false ] && app_ok=1
    if [ "$tok_ok" = 1 ] && [ "$app_ok" = 1 ]; then
        b_ok actions.workflow-token
        b_ok actions.can-approve
        return 0
    fi
    [ "$tok_ok" = 1 ] && b_ok actions.workflow-token
    [ "$app_ok" = 1 ] && b_ok actions.can-approve
    apply "$([ "$tok_ok" = 1 ] && echo actions.can-approve || echo actions.workflow-token)" \
        "set the default workflow token to read and stop Actions approving pull requests" \
        -X PUT "repos/$OKF_REPO/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false || true
}

# fork_step: fork pull request approval (the public endpoint, or the private one for a private repository).
# A private repository whose fork policy already reads run_workflows_from_fork_pull_requests=false is
# compliant and never written: the organisation may forbid the write, and it is stricter than the floor.
# A refused write while fork workflows are on and below the floor stays a reported request-error.
fork_step() {
    local f="$OKF_TMP/fork.json"
    if [ "$OKF_PRIVATE" = true ]; then
        if ! okf_api_get actions.fork-approval "repos/$OKF_REPO/actions/permissions/fork-pr-workflows-private-repos" "$f"; then
            b_unreadable actions.fork-approval
            return 0
        fi
        # Fork workflows OFF (often an organisation policy) is stricter than the floor: ok, no write.
        # Otherwise the floor is approval required, no write token, no secrets or variables.
        if [ -z "$(okf_fork_private_reasons "$f")" ]; then
            b_ok actions.fork-approval
        else
            apply actions.fork-approval "run fork workflows with no write token and no secrets, after approval" \
                -X PUT "repos/$OKF_REPO/actions/permissions/fork-pr-workflows-private-repos" \
                -F run_workflows_from_fork_pull_requests=true -F send_write_tokens_to_workflows=false \
                -F send_secrets_and_variables=false -F require_approval_for_fork_pr_workflows=true || true
        fi
        return 0
    fi
    if ! okf_api_get actions.fork-approval "repos/$OKF_REPO/actions/permissions/fork-pr-contributor-approval" "$f"; then
        b_unreadable actions.fork-approval
        return 0
    fi
    if [ "$(jq -r '.approval_policy // ""' "$f" 2>/dev/null)" = all_external_contributors ]; then
        b_ok actions.fork-approval
    else
        apply actions.fork-approval "require approval for every external contributor's fork workflow" \
            -X PUT "repos/$OKF_REPO/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors || true
    fi
}

# label_step <name> <color> <description>
label_step() {
    local name="$1" color="$2" desc="$3" item="label.$1" f="$OKF_TMP/label.json"
    if okf_api_get "$item" "repos/$OKF_REPO/labels/$(okf_uri "$name")" "$f"; then
        if jq -e --arg c "$color" --arg d "$desc" '((.color // "") | ascii_downcase) == $c and (.description // "") == $d' "$f" >/dev/null 2>&1; then
            b_ok "$item"
        else
            apply "$item" "correct the colour and description" -X PATCH "repos/$OKF_REPO/labels/$(okf_uri "$name")" -f "color=$color" -f "description=$desc" || true
        fi
    elif [ "$OKF_GET_STATUS" = absent ]; then
        apply "$item" "create the label" -X POST "repos/$OKF_REPO/labels" -f "name=$name" -f "color=$color" -f "description=$desc" || true
    else
        b_unreadable "$item"
    fi
}

# variable_step <name> <value>
variable_step() {
    local name="$1" value="$2" item="variable.$1" f="$OKF_TMP/variable.json"
    if okf_api_get "$item" "repos/$OKF_REPO/actions/variables/$name" "$f"; then
        if [ "$(jq -r '.value // ""' "$f" 2>/dev/null)" = "$value" ]; then
            b_ok "$item"
        else
            apply "$item" "set the variable to $value" -X PATCH "repos/$OKF_REPO/actions/variables/$name" -f "name=$name" -f "value=$value" || true
        fi
    elif [ "$OKF_GET_STATUS" = absent ]; then
        apply "$item" "create the variable with the value $value" -X POST "repos/$OKF_REPO/actions/variables" -f "name=$name" -f "value=$value" || true
    else
        b_unreadable "$item"
    fi
}

# agent_variable_step: OKF_AGENT_BOT_LOGIN from --agent-app-slug; without it only a note when it is unset.
agent_variable_step() {
    local f="$OKF_TMP/variable-bot.json"
    if [ -n "$SLUG" ]; then
        variable_step OKF_AGENT_BOT_LOGIN "${SLUG}[bot]"
        return 0
    fi
    if okf_api_get variable.OKF_AGENT_BOT_LOGIN "repos/$OKF_REPO/actions/variables/OKF_AGENT_BOT_LOGIN" "$f"; then
        b_ok variable.OKF_AGENT_BOT_LOGIN
    elif [ "$OKF_GET_STATUS" = absent ]; then
        printf 'note agent-app-slug: --agent-app-slug was not given and OKF_AGENT_BOT_LOGIN is unset; the required check cannot tell the agent from a person until it is set (re-run with --agent-app-slug <slug>)\n'
    else
        b_unreadable variable.OKF_AGENT_BOT_LOGIN
    fi
}

# collaborator_note: the ruleset needs an approval from someone other than the last pusher.
collaborator_note() {
    local f="$OKF_TMP/collaborators.json" n
    if okf_api_get collaborators "repos/$OKF_REPO/collaborators?affiliation=all&permission=push" "$f" --paginate; then
        n="$(jq -s '[.[] | .[]?] | length' "$f" 2>/dev/null || echo 0)"
        if [ "$n" -le 1 ]; then
            printf 'note solo-maintainer: %s account(s) can approve; the ruleset needs one code-owner approval from someone other than the last pusher (see README)\n' "$n"
        fi
    else
        printf 'note collaborators: could not read them (%s); check by hand that a second code owner can approve\n' "$(okf_sanitize "$OKF_GET_REASON")"
    fi
}

main() {
    local env names label color desc
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo)
                [ $# -ge 2 ] || usage
                REPO_ARG="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --repair)
                REPAIR=1
                shift
                ;;
            --agent-app-slug)
                [ $# -ge 2 ] || usage
                SLUG="$2"
                shift 2
                ;;
            -h | --help) usage 0 ;;
            *) usage ;;
        esac
    done
    [ -n "$REPO_ARG" ] || usage
    okf_repo_validate "$REPO_ARG"
    if [ -n "$SLUG" ]; then
        [[ $SLUG =~ ^[a-z0-9][a-z0-9-]{0,38}$ ]] || okf_invalid "--agent-app-slug"
    fi
    okf_require_tools
    okf_tsv_check
    okf_tmp_init
    okf_repo_facts

    ruleset_step
    while IFS=$'\t' read -r env names <&3; do
        environment_step "$env"
    done 3< <(okf_tsv_rows "$OKF_ENVIRONMENTS_TSV")
    actions_step
    fork_step
    while IFS=$'\t' read -r label color desc <&3; do
        label_step "$label" "$color" "$desc"
    done 3< <(okf_tsv_rows "$OKF_LABELS_TSV")
    agent_variable_step
    variable_step OKF_MAINTENANCE_ENABLED true
    while IFS=$'\t' read -r env names <&3; do
        secret_names_step "$env" "$names"
    done 3< <(okf_tsv_rows "$OKF_ENVIRONMENTS_TSV")
    collaborator_note

    if [ "$DRY_RUN" = 1 ]; then
        printf 'okf-bootstrap: dry run, %s change(s) would be written, %s ok, %s unresolved\n' "$B_WOULD" "$B_OK" "$B_UNRESOLVED"
    else
        printf 'okf-bootstrap: %s applied, %s ok, %s unresolved\n' "$B_APPLIED" "$B_OK" "$B_UNRESOLVED"
    fi
    [ "$B_UNRESOLVED" -eq 0 ]
}

main "$@"
