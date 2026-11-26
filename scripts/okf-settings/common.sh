#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034 # a sourced library: its variables are read by the scripts that source it
# Phase 214 (KTPL-01, D-14): the expected-state library that okf-bootstrap.sh and okf-doctor.sh both
# source, so the script that applies the repository settings and the script that checks them cannot
# disagree. Sourced, never executed. It only defines functions and variables.
#
# What lives here:
#   okf_repo_validate <owner/name>     the --repo argument rule (exit 2 on a bad value)
#   okf_repo_facts                     one read of the repository: OKF_DEFAULT_BRANCH, OKF_PRIVATE
#   okf_api_get <item> <endpoint> <out> [--paginate]
#                                      a classified read: sets OKF_GET_STATUS (ok | absent | cannot-read)
#                                      and OKF_GET_REASON; a 404 is `absent` only for the items in
#                                      okf_404_is_absent, a 403 names the permission the read needs
#   okf_api_write <item> <gh api args> a classified write: prints one `cannot-write` / `request-error`
#                                      line on failure and never touches a secrets endpoint
#   okf_report ok|drift|cannot-read <item> [reason]
#                                      one report line (printable ASCII, at most 300 characters of
#                                      reason, so the weekly CI doctor can republish it) plus counters
#   okf_ruleset_reasons <item> <file>  why a live ruleset fails one doctor item (empty = compliant;
#                                      a leading `?` marks "cannot tell", not drift)
#   okf_ruleset_compliant <file>       every ruleset item at once (reasons in OKF_RULESET_REASONS)
#   okf_ruleset_repair_body <live> <out>
#                                      the merge-only repair: raises each field below the floor and
#                                      keeps every stronger live setting
#   okf_fork_private_off <file>        a private repository's fork policy runs no fork workflow at all
#   okf_fork_private_reasons <file>    why a private repository's fork policy is below the floor
#                                      (empty when it holds, or when fork workflows are off)
#
# Data files next to this one: ruleset.json (the floor and the create body), environments.tsv
# (environment and its secret names), labels.tsv, codeowners.py (last-match CODEOWNERS evaluation).
#
# The library never reads, writes or prints a secret VALUE: only secret NAMES are ever listed.

OKF_SETTINGS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OKF_RULESET_JSON="$OKF_SETTINGS_DIR/ruleset.json"
OKF_ENVIRONMENTS_TSV="$OKF_SETTINGS_DIR/environments.tsv"
OKF_LABELS_TSV="$OKF_SETTINGS_DIR/labels.tsv"
OKF_CODEOWNERS_PY="$OKF_SETTINGS_DIR/codeowners.py"
OKF_RULESET_NAME="okf-default-branch"

OKF_PROG="${OKF_PROG:-okf}"
OKF_REPO=""
OKF_DEFAULT_BRANCH=""
OKF_PRIVATE="false"
OKF_TMP=""
OKF_GET_STATUS=""
OKF_GET_REASON=""
OKF_RULESET_REASONS=""
OKF_OK=0
OKF_DRIFT=0
OKF_UNREADABLE=0

okf_invalid() {
    printf '%s: invalid %s\n' "$OKF_PROG" "$1" >&2
    exit 2
}

# okf_tmp_init: a private scratch directory removed on exit.
okf_tmp_init() {
    OKF_TMP="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$OKF_TMP'" EXIT
}

okf_require_tools() {
    local tool
    for tool in gh jq python3; do
        command -v "$tool" >/dev/null 2>&1 || {
            printf '%s: %s is required and was not found\n' "$OKF_PROG" "$tool" >&2
            exit 2
        }
    done
}

# okf_sanitize <text> [max]: printable ASCII only, one line, at most <max> (default 300) characters.
okf_sanitize() {
    printf '%s' "$1" | LC_ALL=C tr -cd ' -~' | LC_ALL=C cut -c "1-${2:-300}"
}

# okf_repo_validate <owner/name>
okf_repo_validate() {
    local re='^[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}$' name
    [[ ${1:-} =~ $re ]] || okf_invalid "--repo (expected owner/name)"
    name="${1#*/}"
    case "$name" in . | ..) okf_invalid "--repo (expected owner/name)" ;; esac
    OKF_REPO="$1"
}

# okf_repo_facts: one read of the repository. An unreachable repository is exit 2.
okf_repo_facts() {
    local out="$OKF_TMP/repo.json" re='^[A-Za-z0-9._/-]{1,255}$'
    if ! gh api "repos/$OKF_REPO" >"$out" 2>"$out.err"; then
        printf '%s: cannot read %s\n' "$OKF_PROG" "$OKF_REPO" >&2
        exit 2
    fi
    OKF_DEFAULT_BRANCH="$(jq -r '.default_branch // empty' "$out" 2>/dev/null || true)"
    OKF_PRIVATE="$(jq -r 'if .private == true then "true" else "false" end' "$out" 2>/dev/null || echo false)"
    [[ $OKF_DEFAULT_BRANCH =~ $re ]] || {
        printf '%s: cannot read %s (no usable default branch)\n' "$OKF_PROG" "$OKF_REPO" >&2
        exit 2
    }
}

# okf_http_status <stderr-file>: the HTTP status `gh` reported, or empty.
okf_http_status() {
    sed -n 's/.*HTTP \([0-9][0-9][0-9]\).*/\1/p' "$1" 2>/dev/null | head -n 1
}

# okf_error_message <stdout-file> <stderr-file>: GitHub's own message (and validation errors).
okf_error_message() {
    local msg
    msg="$(jq -r 'try ([(.message? // empty)] + ((.errors? // []) | if type == "array" then map(if type == "object" then (.message? // .code? // empty) else tostring end) else [] end) | map(tostring) | join("; ")) catch ""' "$1" 2>/dev/null || true)"
    if [ -z "$msg" ]; then
        msg="$(sed -n '1s/^gh: //; 1s/ (HTTP [0-9]*)$//; 1p' "$2" 2>/dev/null || true)"
    fi
    okf_sanitize "$msg" 300
}

# okf_404_is_absent <item>: the items for which a 404 means "this does not exist".
# Everything else (rulesets, Actions settings, secrets lists, collaborators) treats a 404 as unreadable.
okf_404_is_absent() {
    case "$1" in
        environment.* | label.* | variable.* | contents.* | codeowners.*) return 0 ;;
    esac
    return 1
}

# okf_permission_for <item>: the GitHub App permission a read of the item needs (RESEARCH Pitfall 5).
okf_permission_for() {
    case "$1" in
        ruleset* | label.* | collaborators) printf 'Metadata: read' ;;
        actions.*) printf 'Administration: read' ;;
        environment.*) printf 'Actions: read' ;;
        secret.*) printf 'Environments: read' ;;
        repo-secret.*) printf 'Secrets: read' ;;
        variable.*) printf 'Variables: read' ;;
        codeowners.* | contents.*) printf 'Contents: read' ;;
        *) printf 'Administration: read' ;;
    esac
}

# okf_plan_limit_reason <item>: what a plan-limit refusal means for this item.
okf_plan_limit_reason() {
    case "$1" in
        ruleset*) printf "the repository's plan does not support rulesets (see CI.md section 2)" ;;
        environment.*) printf "the repository's plan does not support environment deployment policies (see CI.md section 2)" ;;
        *) printf "the repository's plan does not allow this setting (see CI.md section 2)" ;;
    esac
}

# okf_api_get <item> <endpoint> <out-file> [--paginate]
# Returns 0 only for a 2xx response. OKF_GET_STATUS is ok | absent | cannot-read.
okf_api_get() {
    local item="$1" endpoint="$2" out="$3" mode="${4:-}" code msg
    OKF_GET_STATUS="ok"
    OKF_GET_REASON=""
    if [ "$mode" = "--paginate" ]; then
        if gh api --paginate "$endpoint" >"$out" 2>"$out.err"; then return 0; fi
    else
        if gh api "$endpoint" >"$out" 2>"$out.err"; then return 0; fi
    fi
    code="$(okf_http_status "$out.err")"
    msg="$(okf_error_message "$out" "$out.err")"
    case "$code" in
        404)
            if okf_404_is_absent "$item"; then
                OKF_GET_STATUS="absent"
                OKF_GET_REASON="not found (HTTP 404)"
            else
                OKF_GET_STATUS="cannot-read"
                OKF_GET_REASON="not found (HTTP 404)"
            fi
            ;;
        403)
            OKF_GET_STATUS="cannot-read"
            if printf '%s' "$msg" | grep -qi 'rate limit'; then
                OKF_GET_REASON="rate limited (HTTP 403)"
            else
                OKF_GET_REASON="needs $(okf_permission_for "$item") (HTTP 403)"
            fi
            ;;
        401)
            OKF_GET_STATUS="cannot-read"
            OKF_GET_REASON="not authenticated (HTTP 401)"
            ;;
        "")
            OKF_GET_STATUS="cannot-read"
            OKF_GET_REASON="the GitHub API call failed"
            ;;
        *)
            OKF_GET_STATUS="cannot-read"
            OKF_GET_REASON="HTTP $code"
            ;;
    esac
    return 1
}

# okf_api_write <item> <gh api args...>: 0 on success. On failure prints one classified line and returns 1:
#   plan limit (403 naming upgrade / not available / plan)  cannot-write <item>: <plan reason>
#   any other 403                                           cannot-write <item>: needs Administration: write
#   422                                                     request-error <item>: <GitHub's own reason>
# It refuses any secrets endpoint: this library never writes a secret (D-14).
okf_api_write() {
    local item="$1" arg code msg out err
    shift
    for arg in "$@"; do
        case "$arg" in
            */secrets | */secrets/*)
                printf '%s: internal error: refusing a write to a secrets endpoint\n' "$OKF_PROG" >&2
                exit 70
                ;;
        esac
    done
    out="$OKF_TMP/write.out"
    err="$OKF_TMP/write.err"
    if gh api "$@" >"$out" 2>"$err"; then return 0; fi
    code="$(okf_http_status "$err")"
    msg="$(okf_error_message "$out" "$err")"
    case "$code" in
        403)
            if printf '%s' "$msg" | grep -qiE 'upgrade|not available|plan'; then
                printf 'cannot-write %s: %s\n' "$item" "$(okf_plan_limit_reason "$item")"
            else
                printf 'cannot-write %s: needs Administration: write\n' "$item"
            fi
            ;;
        422) printf 'request-error %s: %s\n' "$item" "${msg:-GitHub rejected the request (HTTP 422)}" ;;
        "") printf 'cannot-write %s: the GitHub API call failed\n' "$item" ;;
        *) printf 'cannot-write %s: HTTP %s\n' "$item" "$code" ;;
    esac
    return 1
}

# okf_report ok|drift|cannot-read <item> [reason]
okf_report() {
    local kind="$1" item="$2" reason
    reason="$(okf_sanitize "${3:-}" 300)"
    case "$kind" in
        ok)
            printf 'ok %s\n' "$item"
            OKF_OK=$((OKF_OK + 1))
            ;;
        drift)
            printf 'drift %s: %s\n' "$item" "$reason"
            OKF_DRIFT=$((OKF_DRIFT + 1))
            ;;
        cannot-read)
            printf 'cannot-read %s: %s\n' "$item" "$reason"
            OKF_UNREADABLE=$((OKF_UNREADABLE + 1))
            ;;
    esac
}

# okf_tsv_rows <file>: the data rows (no comment, no blank line).
okf_tsv_rows() {
    grep -v '^#' "$1" | grep -v '^[[:space:]]*$' || true
}

# okf_expected_contexts: the required status check contexts named by ruleset.json.
okf_expected_contexts() {
    jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' "$OKF_RULESET_JSON"
}

# okf_ruleset_items: every ruleset doctor item id, in report order.
okf_ruleset_items() {
    local ctx
    printf '%s\n' ruleset ruleset.bypass ruleset.review
    while IFS= read -r ctx; do printf 'ruleset.check.%s\n' "$ctx"; done < <(okf_expected_contexts)
    printf '%s\n' ruleset.history
}

# okf_ruleset_reasons <item> <ruleset-json-file>
# One reason per line when the live ruleset falls below the floor in ruleset.json; empty when it
# does not. A reason starting with `?` means the response cannot answer the question.
okf_ruleset_reasons() {
    local item="$1" file="$2" rc=0
    case "$item" in
        ruleset)
            jq -r '
              (if .enforcement != "active" then "enforcement is \(.enforcement // "unset"), not active" else empty end),
              (if .target != "branch" then "target is \(.target // "unset"), not branch" else empty end),
              (if ((.conditions.ref_name.include // []) | any(. == "~DEFAULT_BRANCH")) then empty
               else "the ref include list does not contain ~DEFAULT_BRANCH" end)
            ' "$file" || rc=$?
            ;;
        ruleset.bypass)
            jq -r '
              if (.bypass_actors | type) != "array" then "?bypass_actors was not returned (the reader may lack Administration: read)"
              elif (.bypass_actors | length) > 0 then "\(.bypass_actors | length) bypass actor(s) can skip the rules"
              else empty end
            ' "$file" || rc=$?
            ;;
        ruleset.review)
            jq -r --slurpfile exp "$OKF_RULESET_JSON" '
              ($exp[0].rules | map(select(.type == "pull_request"))[0].parameters) as $want
              | [(.rules // [])[] | select(.type == "pull_request")] as $r
              | if ($r | length) == 0 then "there is no pull_request rule"
                else $r[0].parameters as $p
                  | (if (($p.required_approving_review_count // 0) < $want.required_approving_review_count)
                       then "required approvals is \($p.required_approving_review_count // 0), below \($want.required_approving_review_count)" else empty end),
                    (if $p.require_code_owner_review != true then "code-owner review is not required" else empty end),
                    (if $p.require_last_push_approval != true then "approval of the last push is not required" else empty end),
                    (if $p.dismiss_stale_reviews_on_push != true then "stale approvals are not dismissed on push" else empty end)
                end
            ' "$file" || rc=$?
            ;;
        ruleset.check.*)
            jq -r --slurpfile exp "$OKF_RULESET_JSON" --arg ctx "${item#ruleset.check.}" '
              ($exp[0].rules | map(select(.type == "required_status_checks"))[0].parameters.required_status_checks
                 | map(select(.context == $ctx))[0].integration_id) as $iid
              | [((.rules // [])[] | select(.type == "required_status_checks") | (.parameters.required_status_checks // [])[] | select(.context == $ctx))] as $c
              | if ($c | length) == 0 then "required status check \($ctx) is missing"
                elif ($c | all(.integration_id == $iid)) then empty
                else "required status check \($ctx) is not bound to integration \($iid) (GitHub Actions)" end
            ' "$file" || rc=$?
            ;;
        ruleset.history)
            jq -r '
              ([(.rules // [])[] | .type]) as $types
              | (if ($types | any(. == "non_fast_forward")) then empty else "force pushes are not blocked (no non_fast_forward rule)" end),
                (if ($types | any(. == "deletion")) then empty else "deletion is not blocked (no deletion rule)" end)
            ' "$file" || rc=$?
            ;;
        *) rc=1 ;;
    esac
    if [ "$rc" -ne 0 ]; then printf '?the ruleset response could not be read\n'; fi
}

# okf_ruleset_compliant <ruleset-json-file>: 0 when every ruleset item is compliant. The reasons of
# every failing item, joined with `; `, are left in OKF_RULESET_REASONS.
okf_ruleset_compliant() {
    local item line joined=""
    while IFS= read -r item; do
        while IFS= read -r line; do
            [ -n "$line" ] && joined="${joined:+$joined; }${line#\?}"
        done < <(okf_ruleset_reasons "$item" "$1")
    done < <(okf_ruleset_items)
    OKF_RULESET_REASONS="$joined"
    [ -z "$joined" ]
}

# okf_ruleset_repair_body <live-ruleset-json> <out-file>
# The merge-only repair body (D-14): built FROM the live ruleset, it enforces the ruleset, empties the
# bypass list, adds ~DEFAULT_BRANCH to the includes, raises the approvals to at least the floor, turns
# each review boolean on, adds the required contexts (ours forced to the Actions integration), turns
# the strict policy on and adds non_fast_forward and deletion. Every stronger live value, every extra
# rule, context and include is kept.
okf_ruleset_repair_body() {
    jq --slurpfile exp "$OKF_RULESET_JSON" '
      def uniq: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
      def mergepr($want):
        . as $p
        | $p + {
            required_approving_review_count: ([($p.required_approving_review_count // 0), $want.required_approving_review_count] | max),
            require_code_owner_review: (($p.require_code_owner_review // false) or $want.require_code_owner_review),
            require_last_push_approval: (($p.require_last_push_approval // false) or $want.require_last_push_approval),
            dismiss_stale_reviews_on_push: (($p.dismiss_stale_reviews_on_push // false) or $want.dismiss_stale_reviews_on_push)
          };
      def mergesc($want):
        . as $p
        | ($want.required_status_checks) as $wc
        | ($p.required_status_checks // []) as $have
        | $p + {
            required_status_checks: (
              ($have | map(. as $c | if any($wc[]; .context == $c.context)
                              then $c + {integration_id: ($wc | map(select(.context == $c.context))[0].integration_id)}
                              else $c end))
              + [$wc[] | select(.context as $x | ($have | any(.context == $x)) | not)]),
            strict_required_status_checks_policy: (($p.strict_required_status_checks_policy // false) or $want.strict_required_status_checks_policy)
          };
      $exp[0] as $e
      | ($e.rules | map(select(.type == "pull_request"))[0].parameters) as $wantpr
      | ($e.rules | map(select(.type == "required_status_checks"))[0].parameters) as $wantsc
      | (.rules // []) as $rules
      | {
          name: .name,
          target: (.target // "branch"),
          enforcement: "active",
          bypass_actors: [],
          conditions: ((.conditions // {}) | .ref_name = ((.ref_name // {}) | .include = (((.include // []) + $e.conditions.ref_name.include) | uniq) | .exclude = (.exclude // []))),
          rules: (
            ($rules | map(
              (if .type == "pull_request" then .parameters = ((.parameters // {}) | mergepr($wantpr))
               elif .type == "required_status_checks" then .parameters = ((.parameters // {}) | mergesc($wantsc))
               else . end)
              | {type} + (if has("parameters") and .parameters != null then {parameters} else {} end)))
            + [$e.rules[] | select(.type as $t | ($rules | any(.type == $t)) | not)]
          )
        }
    ' "$1" >"$2"
}

# okf_uri <text>: the text percent-encoded for a URL path segment.
okf_uri() {
    jq -rn --arg v "$1" '$v | @uri'
}

# okf_env_flag_reasons <environment-json-file>: why the environment is not limited to custom branch
# policies (one reason per line; empty when it is).
okf_env_flag_reasons() {
    jq -r '
      if .deployment_branch_policy == null then "deployment branches are not restricted to selected branches"
      else (if .deployment_branch_policy.custom_branch_policies != true then "custom branch policies are off" else empty end),
           (if .deployment_branch_policy.protected_branches != false then "the protected-branches rule is on" else empty end)
      end
    ' "$1" 2>/dev/null || printf '?the environment response could not be read\n'
}

# okf_policy_entries <paginated-policy-list-file>: every deployment policy as one JSON array, all pages.
okf_policy_entries() {
    jq -s -c '[.[] | (.branch_policies // [])[]]' "$1" 2>/dev/null || printf '[]'
}

# okf_policy_reasons <entries-json-file>: why the policy list is not EXACTLY the one default-branch
# policy `{name: <default>, type: branch}`. An extra branch or tag policy is drift, never ignored.
okf_policy_reasons() {
    jq -r --arg b "$OKF_DEFAULT_BRANCH" '
      (if any(.[]; .name == $b and .type == "branch") then empty else "no policy for \($b)" end),
      (.[] | select((.name == $b and .type == "branch") | not) | "extra \(.type // "unknown") policy \(.name // "?")")
    ' "$1"
}

# okf_policy_extras <entries-json-file>: id <TAB> type for each policy that is not the default branch.
okf_policy_extras() {
    jq -r --arg b "$OKF_DEFAULT_BRANCH" '.[] | select((.name == $b and .type == "branch") | not) | "\(.id)\t\(.type // "unknown")"' "$1"
}

# okf_fork_private_off <private-fork-policy-json-file>: 0 when the policy reads
# run_workflows_from_fork_pull_requests == false exactly, so no fork pull request runs any workflow. That
# is STRICTER than the floor (no fork workflow can receive a write token, a secret or a variable because
# none runs), and an organisation policy can force it: GitHub then answers "Policy is forbidden by entity
# owner" to every write that turns fork workflows on. A missing or non-boolean value is NOT off.
okf_fork_private_off() {
    jq -e '.run_workflows_from_fork_pull_requests == false' "$1" >/dev/null 2>&1
}

# okf_fork_private_reasons <private-fork-policy-json-file>: why the policy is below the floor, one reason
# per line; empty when it holds. Fork workflows off (okf_fork_private_off) satisfies the floor outright.
# With them on (or the flag unreadable) the floor is: approval required, no write token and no secrets or
# variables sent to fork workflows.
okf_fork_private_reasons() {
    okf_fork_private_off "$1" && return 0
    jq -r '
      (if .run_workflows_from_fork_pull_requests != true then "fork pull requests do not run workflows" else empty end),
      (if .send_write_tokens_to_workflows != false then "write tokens are sent to fork workflows" else empty end),
      (if .send_secrets_and_variables != false then "secrets and variables are sent to fork workflows" else empty end),
      (if .require_approval_for_fork_pr_workflows != true then "fork workflows run without approval" else empty end)
    ' "$1" 2>/dev/null || printf '?the fork pull request settings could not be read\n'
}

# okf_tsv_check: the data files must hold only well-formed rows (a malformed row is an internal error).
okf_tsv_check() {
    local env names label color
    while IFS=$'\t' read -r env names <&3; do
        [[ $env =~ ^[a-z0-9][a-z0-9-]*$ && $names =~ ^[A-Z0-9_]+(,[A-Z0-9_]+)*$ ]] || {
            printf '%s: internal error: malformed row in environments.tsv\n' "$OKF_PROG" >&2
            exit 70
        }
    done 3< <(okf_tsv_rows "$OKF_ENVIRONMENTS_TSV")
    while IFS=$'\t' read -r label color _ <&3; do
        [[ $label =~ ^[a-z]+:[a-z-]+$ && $color =~ ^[0-9a-f]{6}$ ]] || {
            printf '%s: internal error: malformed row in labels.tsv\n' "$OKF_PROG" >&2
            exit 70
        }
    done 3< <(okf_tsv_rows "$OKF_LABELS_TSV")
}

# okf_join_lines: stdin lines joined with `; ` (empty lines dropped).
okf_join_lines() {
    local line joined=""
    while IFS= read -r line; do
        [ -n "$line" ] && joined="${joined:+$joined; }${line#\?}"
    done
    printf '%s' "$joined"
}
