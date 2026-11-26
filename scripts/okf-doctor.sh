#!/usr/bin/env bash
# Phase 214 (KTPL-01, D-14, D-15): read back the repository settings that okf-bootstrap.sh applies and
# report every drifted item. READ-ONLY: it uses `gh api` GET calls only and never writes anything.
#
#   okf-doctor.sh --repo <owner/name> [--variables-from-env]
#
#   --repo                 the repository to check (required)
#   --variables-from-env   read OKF_AGENT_BOT_LOGIN, OKF_MAINTENANCE_ENABLED and OKF_BUNDLE_PATH from the
#                          environment instead of the repository variables API (the weekly CI doctor's
#                          App has no Variables permission). An empty value counts as unset.
#
# One line per item, in a stable order:
#   ok <item>
#   drift <item>: <reason>           the setting is wrong or missing
#   cannot-read <item>: <reason>     the setting could not be read (a 403 names the GitHub App
#                                    permission the read needs; a 404 on a settings endpoint is never
#                                    read as "all good")
#   note <item>: <text>              context for an ok item (only actions.fork-approval on a private
#                                    repository whose fork pull requests run no workflows: stricter than
#                                    the floor, so ok; and ruleset.bypass under --variables-from-env, where
#                                    the read-only token is not given bypass_actors); never counted, never
#                                    a drift
# The last line is `okf-doctor: <N> drift, <M> ok`, where N counts every item that is not ok (drift and
# cannot-read alike). Only secret NAMES are ever listed, never a value.
#
# Item ids: ruleset, ruleset.bypass, ruleset.review, ruleset.check.<context>, ruleset.history,
# actions.workflow-token, actions.can-approve, actions.fork-approval, environment.<env>,
# environment.<env>.branch-policy, secret.<env>.<NAME>, repo-secret.<NAME>, label.<name>,
# variable.OKF_AGENT_BOT_LOGIN, variable.OKF_MAINTENANCE_ENABLED, variable.OKF_BUNDLE_PATH,
# codeowners.placeholder, codeowners.coverage, codeowners.errors.
#
# Exit 0: every item is ok. 1: any drift or unreadable item. 2: usage error or an unreachable repository.
# It compares against the same files the bootstrap applies: okf-settings/ruleset.json, environments.tsv
# and labels.tsv (shared through okf-settings/common.sh), so the two scripts cannot disagree.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OKF_PROG="okf-doctor"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=okf-settings/common.sh
. "$HERE/okf-settings/common.sh"

VARIABLES_FROM_ENV=0
REPO_ARG=""

usage() {
    printf 'usage: %s --repo <owner/name> [--variables-from-env]\n' "$OKF_PROG" >&2
    exit "${1:-2}"
}

# report_reasons <item> <reasons, one per line>: ok when empty, cannot-read when a reason starts with `?`.
report_reasons() {
    local item="$1" reasons="$2" line joined="" unreadable=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            \?*)
                unreadable=1
                line="${line#\?}"
                ;;
        esac
        joined="${joined:+$joined; }$line"
    done <<<"$reasons"
    if [ -z "$joined" ]; then
        okf_report ok "$item"
    elif [ "$unreadable" = 1 ]; then
        okf_report cannot-read "$item" "$joined"
    else
        okf_report drift "$item" "$joined"
    fi
}

# report_all <kind> <reason> <items...>: the same finding for several items.
report_all() {
    local kind="$1" reason="$2" item
    shift 2
    for item in "$@"; do okf_report "$kind" "$item" "$reason"; done
}

ruleset_items() {
    local list="$OKF_TMP/rulesets.json" live="$OKF_TMP/ruleset-live.json" id item reasons
    local -a items=()
    while IFS= read -r item; do items+=("$item"); done < <(okf_ruleset_items)
    if ! okf_api_get ruleset "repos/$OKF_REPO/rulesets" "$list" --paginate; then
        report_all cannot-read "$OKF_GET_REASON" "${items[@]}"
        return 0
    fi
    id="$(jq -s -r --arg n "$OKF_RULESET_NAME" '[(add // [])[] | select(.name == $n and ((.source_type // "Repository") == "Repository")) | .id][0] // empty' "$list" 2>/dev/null || true)"
    if [ -z "$id" ]; then
        report_all drift "no ruleset named $OKF_RULESET_NAME exists" "${items[@]}"
        return 0
    fi
    if ! [[ $id =~ ^[0-9]{1,20}$ ]] || ! okf_api_get ruleset "repos/$OKF_REPO/rulesets/$id" "$live"; then
        report_all cannot-read "${OKF_GET_REASON:-the ruleset list returned an unusable id}" "${items[@]}"
        return 0
    fi
    for item in "${items[@]}"; do
        reasons="$(okf_ruleset_reasons "$item" "$live")"
        # CI mode: GitHub returns bypass_actors only to a caller that can write the ruleset, and the maintenance
        # token is read-only by design (D-17), so an absent list is a note here, never a drift that cannot clear.
        # A list that IS returned is checked as in operator mode.
        if [ "$VARIABLES_FROM_ENV" = 1 ] && [ "$item" = ruleset.bypass ] && [[ $reasons == '?bypass_actors was not returned'* ]]; then
            printf 'note ruleset.bypass: bypass actors cannot be read with this read-only token; run scripts/okf-doctor.sh with your own login to check them\n'
            continue
        fi
        report_reasons "$item" "$reasons"
    done
}

# actions_items: the default workflow token, whether Actions may approve pull requests, fork approval.
actions_items() {
    local f="$OKF_TMP/workflow.json" tok app fork="$OKF_TMP/fork.json" reasons=""
    if okf_api_get actions.workflow-token "repos/$OKF_REPO/actions/permissions/workflow" "$f"; then
        tok="$(jq -r '.default_workflow_permissions | tostring' "$f" 2>/dev/null || true)"
        app="$(jq -r '.can_approve_pull_request_reviews | tostring' "$f" 2>/dev/null || true)"
        if [ "$tok" = read ]; then
            okf_report ok actions.workflow-token
        else
            okf_report drift actions.workflow-token "the default workflow token is $tok, not read"
        fi
        if [ "$app" = false ]; then
            okf_report ok actions.can-approve
        else
            okf_report drift actions.can-approve "Actions may approve pull requests"
        fi
    else
        okf_report cannot-read actions.workflow-token "$OKF_GET_REASON"
        okf_report cannot-read actions.can-approve "$OKF_GET_REASON"
    fi
    if [ "$OKF_PRIVATE" = true ]; then
        if okf_api_get actions.fork-approval "repos/$OKF_REPO/actions/permissions/fork-pr-workflows-private-repos" "$fork"; then
            reasons="$(okf_fork_private_reasons "$fork" | okf_join_lines)"
            report_reasons actions.fork-approval "$reasons"
            if [ -z "$reasons" ] && okf_fork_private_off "$fork"; then
                printf 'note actions.fork-approval: fork pull requests run no workflows at all, which is stricter than the floor (a fork pull request gets no okf-check run; push its branch to this repository to get one)\n'
            fi
        else
            okf_report cannot-read actions.fork-approval "$OKF_GET_REASON"
        fi
    elif okf_api_get actions.fork-approval "repos/$OKF_REPO/actions/permissions/fork-pr-contributor-approval" "$fork"; then
        tok="$(jq -r '.approval_policy // ""' "$fork" 2>/dev/null || true)"
        if [ "$tok" = all_external_contributors ]; then
            okf_report ok actions.fork-approval
        else
            okf_report drift actions.fork-approval "fork pull request approval is ${tok:-unset}, not all_external_contributors"
        fi
    else
        okf_report cannot-read actions.fork-approval "$OKF_GET_REASON"
    fi
}

# branch_policy_item <env> <environment-json-file>
branch_policy_item() {
    local env="$1" envf="$2" item="environment.$1.branch-policy" pf="$OKF_TMP/pol-$1.json" ef="$OKF_TMP/entries-$1.json"
    if okf_api_get "$item" "repos/$OKF_REPO/environments/$env/deployment-branch-policies" "$pf" --paginate; then
        okf_policy_entries "$pf" >"$ef"
    elif [ "$OKF_GET_STATUS" = absent ]; then
        printf '[]' >"$ef"
    else
        okf_report cannot-read "$item" "$OKF_GET_REASON"
        return 0
    fi
    report_reasons "$item" "$( { okf_env_flag_reasons "$envf"; okf_policy_reasons "$ef"; } )"
}

# secret_items <env> <names, comma separated> <environment state>
secret_items() {
    local env="$1" names="$2" state="$3" sf="$OKF_TMP/secrets-$1.json" have name
    local -a list
    IFS=',' read -r -a list <<<"$names"
    if [ "$state" = absent ]; then
        for name in "${list[@]}"; do okf_report drift "secret.$env.$name" "environment $env does not exist"; done
        return 0
    fi
    if ! okf_api_get "secret.$env" "repos/$OKF_REPO/environments/$env/secrets" "$sf" --paginate; then
        for name in "${list[@]}"; do okf_report cannot-read "secret.$env.$name" "$OKF_GET_REASON"; done
        return 0
    fi
    have="$(jq -s -r '.[] | (.secrets // [])[] | .name' "$sf" 2>/dev/null | tr '\n' ' ')"
    for name in "${list[@]}"; do
        case " $have " in
            *" $name "*) okf_report ok "secret.$env.$name" ;;
            *) okf_report drift "secret.$env.$name" "not set in environment $env; place it by hand: gh secret set $name --env $env --repo $OKF_REPO" ;;
        esac
    done
}

# environment_items: each environment, its deployment policy and its secret names.
environment_items() {
    local env names envf state
    while IFS=$'\t' read -r env names <&3; do
        envf="$OKF_TMP/env-$env.json"
        if okf_api_get "environment.$env" "repos/$OKF_REPO/environments/$env" "$envf"; then
            state=present
            okf_report ok "environment.$env"
            branch_policy_item "$env" "$envf"
        elif [ "$OKF_GET_STATUS" = absent ]; then
            state=absent
            okf_report drift "environment.$env" "environment does not exist"
            okf_report drift "environment.$env.branch-policy" "environment does not exist"
        else
            state=unreadable
            okf_report cannot-read "environment.$env" "$OKF_GET_REASON"
            okf_report cannot-read "environment.$env.branch-policy" "the environment could not be read (see environment.$env)"
        fi
        secret_items "$env" "$names" "$state"
    done 3< <(okf_tsv_rows "$OKF_ENVIRONMENTS_TSV")
}

# repo_secret_items: a repository-level secret with a name reserved for an environment is drift.
repo_secret_items() {
    local sf="$OKF_TMP/repo-secrets.json" env names name have="" ok_read=1
    local -a list
    okf_api_get repo-secret.list "repos/$OKF_REPO/actions/secrets" "$sf" --paginate || ok_read=0
    if [ "$ok_read" = 1 ]; then
        have="$(jq -s -r '.[] | (.secrets // [])[] | .name' "$sf" 2>/dev/null | tr '\n' ' ')"
    fi
    while IFS=$'\t' read -r env names <&3; do
        IFS=',' read -r -a list <<<"$names"
        for name in "${list[@]}"; do
            if [ "$ok_read" = 0 ]; then
                okf_report cannot-read "repo-secret.$name" "$OKF_GET_REASON"
            else
                case " $have " in
                    *" $name "*) okf_report drift "repo-secret.$name" "a repository-level secret with this name exists; it belongs in environment $env only" ;;
                    *) okf_report ok "repo-secret.$name" ;;
                esac
            fi
        done
    done 3< <(okf_tsv_rows "$OKF_ENVIRONMENTS_TSV")
}

label_items() {
    local label f="$OKF_TMP/label.json"
    while IFS=$'\t' read -r label _ _ <&3; do
        if okf_api_get "label.$label" "repos/$OKF_REPO/labels/$(okf_uri "$label")" "$f"; then
            okf_report ok "label.$label"
        elif [ "$OKF_GET_STATUS" = absent ]; then
            okf_report drift "label.$label" "label does not exist"
        else
            okf_report cannot-read "label.$label" "$OKF_GET_REASON"
        fi
    done 3< <(okf_tsv_rows "$OKF_LABELS_TSV")
}

# variable_value <NAME>: VAR_STATE (set | unset | cannot-read), VAR_VALUE, VAR_REASON.
VAR_STATE=""
VAR_VALUE=""
VAR_REASON=""
variable_value() {
    local name="$1" f="$OKF_TMP/variable-$1.json"
    VAR_VALUE=""
    VAR_REASON=""
    if [ "$VARIABLES_FROM_ENV" = 1 ]; then
        VAR_VALUE="${!name:-}"
        if [ -n "$VAR_VALUE" ]; then VAR_STATE="set"; else VAR_STATE="unset"; fi
        return 0
    fi
    if okf_api_get "variable.$name" "repos/$OKF_REPO/actions/variables/$name" "$f"; then
        VAR_VALUE="$(jq -r '.value // ""' "$f" 2>/dev/null || true)"
        if [ -n "$VAR_VALUE" ]; then VAR_STATE="set"; else VAR_STATE="unset"; fi
    elif [ "$OKF_GET_STATUS" = absent ]; then
        VAR_STATE="unset"
    else
        VAR_STATE="cannot-read"
        VAR_REASON="$OKF_GET_REASON"
    fi
}

# bundle_root: the default branch's .okf/publish.toml bundle_root (default okf, one trailing / removed)
# into BUNDLE_ROOT. BUNDLE_STATE is ok, none (there is no publish target) or cannot-read (BUNDLE_REASON).
BUNDLE_STATE=""
BUNDLE_REASON=""
BUNDLE_ROOT=""
bundle_root() {
    local f="$OKF_TMP/publish.json" toml="$OKF_TMP/publish.toml" root
    BUNDLE_STATE="ok"
    BUNDLE_REASON=""
    BUNDLE_ROOT=""
    if ! okf_api_get contents.publish-toml "repos/$OKF_REPO/contents/.okf/publish.toml" "$f"; then
        if [ "$OKF_GET_STATUS" = absent ]; then
            BUNDLE_STATE="none"
        else
            BUNDLE_STATE="cannot-read"
            BUNDLE_REASON="$OKF_GET_REASON"
        fi
        return 0
    fi
    if [ "$(jq -r '.encoding // ""' "$f" 2>/dev/null)" != base64 ] || ! jq -r '(.content // "") | gsub("[\\r\\n]"; "") | @base64d' "$f" >"$toml" 2>/dev/null; then
        BUNDLE_STATE="cannot-read"
        BUNDLE_REASON=".okf/publish.toml could not be decoded"
        return 0
    fi
    root="$(python3 -I -c 'import sys, tomllib
v = tomllib.loads(sys.stdin.read()).get("bundle_root", "okf")
print(v if isinstance(v, str) else "")' <"$toml" 2>/dev/null)" || {
        BUNDLE_STATE="cannot-read"
        BUNDLE_REASON=".okf/publish.toml could not be parsed (needs Python 3.11 or newer for tomllib)"
        return 0
    }
    root="${root%/}"
    if ! [[ $root =~ ^[A-Za-z0-9._/-]{1,200}$ ]]; then
        BUNDLE_STATE="cannot-read"
        BUNDLE_REASON="bundle_root in .okf/publish.toml is not a usable directory name"
        return 0
    fi
    BUNDLE_ROOT="$root"
}

variable_items() {
    local bot_re='^[a-z0-9][a-z0-9-]*\[bot\]$' effective
    variable_value OKF_AGENT_BOT_LOGIN
    case "$VAR_STATE" in
        cannot-read) okf_report cannot-read variable.OKF_AGENT_BOT_LOGIN "$VAR_REASON" ;;
        unset) okf_report drift variable.OKF_AGENT_BOT_LOGIN "the variable is not set (okf-bootstrap.sh --agent-app-slug sets it)" ;;
        *)
            if [[ $VAR_VALUE =~ $bot_re ]]; then
                okf_report ok variable.OKF_AGENT_BOT_LOGIN
            else
                okf_report drift variable.OKF_AGENT_BOT_LOGIN "the value is not of the form <app-slug>[bot]"
            fi
            ;;
    esac
    variable_value OKF_MAINTENANCE_ENABLED
    case "$VAR_STATE" in
        cannot-read) okf_report cannot-read variable.OKF_MAINTENANCE_ENABLED "$VAR_REASON" ;;
        unset) okf_report drift variable.OKF_MAINTENANCE_ENABLED "the variable is not set, so the maintenance workflows stay off (okf-bootstrap.sh sets it)" ;;
        *)
            if [ "$VAR_VALUE" = true ]; then
                okf_report ok variable.OKF_MAINTENANCE_ENABLED
            else
                okf_report drift variable.OKF_MAINTENANCE_ENABLED "the variable is not true"
            fi
            ;;
    esac
    variable_value OKF_BUNDLE_PATH
    if [ "$VAR_STATE" = cannot-read ]; then
        okf_report cannot-read variable.OKF_BUNDLE_PATH "$VAR_REASON"
        return 0
    fi
    bundle_root
    case "$BUNDLE_STATE" in
        cannot-read) okf_report cannot-read variable.OKF_BUNDLE_PATH "$BUNDLE_REASON" ;;
        none) okf_report ok variable.OKF_BUNDLE_PATH ;;
        *)
            if [ "$VAR_STATE" = set ]; then effective="${VAR_VALUE%/}"; else effective="bundle"; fi
            if [ "$effective" = "$BUNDLE_ROOT" ]; then
                okf_report ok variable.OKF_BUNDLE_PATH
            elif [ "$VAR_STATE" = set ]; then
                okf_report drift variable.OKF_BUNDLE_PATH "the variable is $VAR_VALUE but .okf/publish.toml bundle_root is $BUNDLE_ROOT"
            else
                okf_report drift variable.OKF_BUNDLE_PATH "the variable is unset (the check uses bundle) but .okf/publish.toml bundle_root is $BUNDLE_ROOT"
            fi
            ;;
    esac
}

# codeowners_items: placeholder owner, effective coverage of the protected paths, GitHub's own errors.
codeowners_items() {
    local f="$OKF_TMP/codeowners.json" text="$OKF_TMP/CODEOWNERS" ef="$OKF_TMP/codeowners-errors.json"
    local line status path reasons drift_list="" read_list="" ph
    if okf_api_get codeowners.placeholder "repos/$OKF_REPO/contents/.github/CODEOWNERS" "$f"; then
        if [ "$(jq -r '.encoding // ""' "$f" 2>/dev/null)" != base64 ] || ! jq -r '(.content // "") | gsub("[\\r\\n]"; "") | @base64d' "$f" >"$text" 2>/dev/null; then
            okf_report cannot-read codeowners.placeholder ".github/CODEOWNERS could not be decoded"
            okf_report cannot-read codeowners.coverage ".github/CODEOWNERS could not be decoded"
        else
            ph="$(python3 -I "$OKF_CODEOWNERS_PY" placeholder <"$text" 2>/dev/null || true)"
            case "$ph" in
                "ok placeholder") okf_report ok codeowners.placeholder ;;
                "drift placeholder: "*) okf_report drift codeowners.placeholder "${ph#drift placeholder: }" ;;
                *) okf_report cannot-read codeowners.placeholder "the CODEOWNERS evaluation failed" ;;
            esac
            while IFS= read -r line; do
                status="${line%% *}"
                path="${line#* }"
                case "$status" in
                    ok) ;;
                    drift) drift_list="${drift_list:+$drift_list; }$path" ;;
                    cannot-read) read_list="${read_list:+$read_list; }$path" ;;
                esac
            done < <(python3 -I "$OKF_CODEOWNERS_PY" coverage <"$text" 2>/dev/null || true)
            if [ -n "$read_list" ]; then
                okf_report cannot-read codeowners.coverage "$read_list"
            elif [ -n "$drift_list" ]; then
                okf_report drift codeowners.coverage "$drift_list"
            else
                okf_report ok codeowners.coverage
            fi
        fi
    elif [ "$OKF_GET_STATUS" = absent ]; then
        okf_report drift codeowners.placeholder "no .github/CODEOWNERS file"
        okf_report drift codeowners.coverage "no .github/CODEOWNERS file"
    else
        okf_report cannot-read codeowners.placeholder "$OKF_GET_REASON"
        okf_report cannot-read codeowners.coverage "$OKF_GET_REASON"
    fi
    if okf_api_get codeowners.errors "repos/$OKF_REPO/codeowners/errors" "$ef"; then
        reasons="$(jq -r '(.errors // []) | .[] | "line \((.line | tonumber? // 0)) \((.kind // "error") | tostring | gsub("[^A-Za-z0-9 _.-]"; "") | .[0:40])"' "$ef" 2>/dev/null | okf_join_lines)"
        if [ -z "$reasons" ]; then
            okf_report ok codeowners.errors
        else
            okf_report drift codeowners.errors "GitHub reports: $reasons"
        fi
    elif [ "$OKF_GET_STATUS" = absent ]; then
        okf_report drift codeowners.errors "no CODEOWNERS file to validate"
    else
        okf_report cannot-read codeowners.errors "$OKF_GET_REASON"
    fi
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo)
                [ $# -ge 2 ] || usage
                REPO_ARG="$2"
                shift 2
                ;;
            --variables-from-env)
                VARIABLES_FROM_ENV=1
                shift
                ;;
            -h | --help) usage 0 ;;
            *) usage ;;
        esac
    done
    [ -n "$REPO_ARG" ] || usage
    okf_repo_validate "$REPO_ARG"
    okf_require_tools
    okf_tsv_check
    okf_tmp_init
    okf_repo_facts

    ruleset_items
    actions_items
    environment_items
    repo_secret_items
    label_items
    variable_items
    codeowners_items

    printf 'okf-doctor: %s drift, %s ok\n' "$((OKF_DRIFT + OKF_UNREADABLE))" "$OKF_OK"
    [ "$((OKF_DRIFT + OKF_UNREADABLE))" -eq 0 ]
}

main "$@"
