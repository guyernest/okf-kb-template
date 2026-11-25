#!/usr/bin/env bash
# Phase 214 (KTPL-04; D-07; threats T-214-22, T-214-49): the scope gate for agent-authored changes. A diff
# is in scope only when every entry is an added or modified regular file (mode 100644) under the bundle
# root. Deletes, renames, copies, type changes, symbolic links, executables and submodules are refused,
# and so is anything outside the bundle root.
#
#   diff-scope.sh bundle-root <rev>
#       Print the bundle root read from `.okf/publish.toml` as it exists at <rev> (the DEFAULT branch's
#       commit, never a proposal). The engine reads and validates the file (`okf-check publish
#       --print-bundle-root`); the result is checked again against a plain path alphabet. A missing or
#       invalid file is exit 2: the gate fails closed.
#   diff-scope.sh check <base> (--cached | <head>)
#       Compare <base> with the index (--cached) or with <head> and refuse every entry that is not in scope.
#       The root comes from the commit named by OKF_SCOPE_ROOT_REV when it is set, else from <base>; it is
#       never read from the head. Exit 0 in scope, 1 at least one refusal (printed between
#       ::stop-commands:: fences, control characters removed), 2 when the question could not be answered.
#
#   diff-scope.sh pr
#       The required check's own scope step (D-07, plan 214-07). Reads its inputs from the environment (below).
#       For EVERY pull request the bundle path the check validated (OKF_BUNDLE_PATH) must equal the default
#       branch's bundle root, so the check, the agent and the publisher agree on one directory (reason
#       `bundle-path-mismatch`, exit 1). For an agent-authored pull request (the head ref starts with `agent/`,
#       or the author is a Bot whose login equals OKF_AGENT_BOT_LOGIN) every change must be in scope, measured
#       from `git merge-base <base> <head>` to the head (reason `scope`, exit 1): the base branch's own later
#       commits are never blamed on the pull request. Any other pull request is not restricted (exit 0). An
#       invalid input or a git failure is exit 2 (reason `config`). The reason goes to $GITHUB_OUTPUT.
#
# Env: OKF_ENGINE (the verified engine, bundle-root and check), OKF_SCOPE_ROOT_REV (optional, see above).
# `pr` adds OKF_BASE_SHA, OKF_HEAD_SHA (40 hex), OKF_HEAD_REF (compared only, never printed), OKF_AUTHOR_LOGIN,
# OKF_AUTHOR_TYPE, OKF_AGENT_BOT_LOGIN (may be empty), OKF_BUNDLE_PATH and OKF_DEFAULT_BRANCH.
#
# `git diff` is run with its output going to a file and its exit status is read BEFORE any record is
# looked at: a producer that fails inside a process substitution cannot be seen by the loop that reads
# it, and an empty stream would read as "nothing outside the bundle root".
set -euo pipefail
export LC_ALL=C

ROOT_RE='^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'
MAX_LISTED=50

PR_MODE=0

invalid() {
    printf 'diff-scope: %s\n' "$1" >&2
    if [ "$PR_MODE" -eq 1 ]; then
        printf 'reason=config\n' >>"${GITHUB_OUTPUT:-/dev/null}"
    fi
    exit 2
}

# commit_of <rev>: the full commit id, or exit 2.
commit_of() {
    local rev="$1" id
    [ -n "$rev" ] || invalid 'an empty revision'
    case "$rev" in -*) invalid 'a revision may not start with a dash' ;; esac
    id="$(git rev-parse --verify --quiet "${rev}^{commit}" 2>/dev/null)" || invalid 'the revision is not a commit of this repository'
    printf '%s' "$id"
}

# root_at <rev>: the validated bundle root at that commit.
root_at() {
    local rev="$1" id entry tmp root segment
    id="$(commit_of "$rev")"
    [ -n "${OKF_ENGINE:-}" ] && [ -x "${OKF_ENGINE:-}" ] || invalid 'OKF_ENGINE is not an executable'
    entry="$(git ls-tree -z "$id" -- .okf/publish.toml 2>/dev/null | tr '\0' '\n')" || invalid 'cannot read the tree'
    case "$entry" in
        '100644 blob '*) ;;
        *) invalid '.okf/publish.toml is missing or not a regular file at the revision' ;;
    esac
    tmp="$(mktemp -d)"
    mkdir "$tmp/.okf"
    if ! git show "$id:.okf/publish.toml" >"$tmp/.okf/publish.toml" 2>/dev/null; then
        rm -rf "$tmp"
        invalid 'cannot read .okf/publish.toml at the revision'
    fi
    root="$("$OKF_ENGINE" publish --repo-root "$tmp" --print-bundle-root 2>/dev/null)" || {
        rm -rf "$tmp"
        invalid '.okf/publish.toml has no valid bundle_root'
    }
    rm -rf "$tmp"
    [[ $root =~ $ROOT_RE ]] || invalid 'the bundle root is outside the plain path alphabet'
    local IFS=/
    for segment in $root; do
        case "$segment" in . | ..) invalid 'the bundle root has a dot segment' ;; esac
    done
    printf '%s' "$root"
}

# refuse_line <reason> <path>: one refusal, the path with control characters removed and capped.
refusal_file=""
refusals=0
refuse_line() {
    local clean
    clean="$(printf '%s' "$2" | tr -d '\000-\037\177' | head -c 300)"
    refusals=$((refusals + 1))
    if [ "$refusals" -le "$MAX_LISTED" ]; then
        printf 'refused (%s): %s\n' "$1" "$clean" >>"$refusal_file"
    fi
}

cmd_bundle_root() {
    [ "$#" -eq 1 ] || invalid 'usage: diff-scope.sh bundle-root <rev>'
    printf '%s\n' "$(root_at "$1")"
}

cmd_check() {
    [ "$#" -eq 2 ] || invalid 'usage: diff-scope.sh check <base> (--cached | <head>)'
    local head_arg="$2" base_id root records meta path status old_mode new_mode token
    base_id="$(commit_of "$1")"
    root="$(root_at "${OKF_SCOPE_ROOT_REV:-$base_id}")"

    records="$(mktemp)"
    refusal_file="$(mktemp)"
    if [ "$head_arg" = --cached ]; then
        git diff --raw -z --no-renames --cached "$base_id" >"$records" 2>/dev/null || invalid 'git diff failed'
    else
        local head_id
        head_id="$(commit_of "$head_arg")"
        git diff --raw -z --no-renames "$base_id" "$head_id" >"$records" 2>/dev/null || invalid 'git diff failed'
    fi

    while IFS= read -r -d '' meta; do
        IFS= read -r -d '' path || invalid 'the diff record is truncated'
        if [[ $meta =~ ^:([0-7]{6})\ ([0-7]{6})\ [0-9a-f]+\ [0-9a-f]+\ ([A-Z])[0-9]*$ ]]; then
            old_mode="${BASH_REMATCH[1]}"
            new_mode="${BASH_REMATCH[2]}"
            status="${BASH_REMATCH[3]}"
        else
            refuse_line 'unreadable record' "$path"
            continue
        fi
        case "$status" in
            A)
                [ "$new_mode" = 100644 ] || refuse_line 'not a regular file' "$path"
                ;;
            M)
                { [ "$new_mode" = 100644 ] && [ "$old_mode" = 100644 ]; } || refuse_line 'not a regular file' "$path"
                ;;
            D) refuse_line 'delete' "$path" ;;
            T) refuse_line 'type change' "$path" ;;
            *) refuse_line "status $status" "$path" ;;
        esac
        case "$path" in
            "$root"/*) ;;
            *) refuse_line 'outside the bundle root' "$path" ;;
        esac
    done <"$records"

    if [ "$refusals" -gt 0 ]; then
        token="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        printf 'diff-scope: %s change(s) outside the allowed scope (bundle root %s)\n' "$refusals" "$root"
        printf '::stop-commands::%s\n' "$token"
        cat "$refusal_file"
        if [ "$refusals" -gt "$MAX_LISTED" ]; then
            printf '... and %s more\n' "$((refusals - MAX_LISTED))"
        fi
        printf '::%s::\n' "$token"
        rm -f "$records" "$refusal_file"
        exit 1
    fi
    rm -f "$records" "$refusal_file"
}

SHA_RE='^[0-9a-f]{40}$'
BRANCH_RE='^[A-Za-z0-9._/-]{1,200}$'
BOT_LOGIN_RE='^[a-z0-9][a-z0-9-]*\[bot\]$'

# reason_out <reason>: the step output the verdict reads.
reason_out() {
    printf 'reason=%s\n' "$1" >>"${GITHUB_OUTPUT:-/dev/null}"
}

# plain <value>: the value when it is in the plain bundle-path alphabet, else a fixed placeholder.
plain() {
    if [[ $1 =~ $ROOT_RE ]]; then printf '%s' "$1"; else printf '<not a plain path>'; fi
}

cmd_pr() {
    [ "$#" -eq 0 ] || invalid 'usage: diff-scope.sh pr'
    PR_MODE=1
    local base="${OKF_BASE_SHA:-}" head="${OKF_HEAD_SHA:-}" head_ref="${OKF_HEAD_REF:-}" login="${OKF_AUTHOR_LOGIN:-}"
    local type="${OKF_AUTHOR_TYPE:-}" bot="${OKF_AGENT_BOT_LOGIN:-}" bundle_path="${OKF_BUNDLE_PATH:-}" default_branch="${OKF_DEFAULT_BRANCH:-}"
    [[ $base =~ $SHA_RE ]] || invalid 'OKF_BASE_SHA is not a full commit id'
    [[ $head =~ $SHA_RE ]] || invalid 'OKF_HEAD_SHA is not a full commit id'
    [[ $default_branch =~ $BRANCH_RE ]] || invalid 'OKF_DEFAULT_BRANCH is not a plain branch name'
    case "$default_branch" in *..*) invalid 'OKF_DEFAULT_BRANCH has a dot dot' ;; esac
    if [ -n "$bot" ] && ! [[ $bot =~ $BOT_LOGIN_RE ]]; then
        printf 'okf-check: repository variable OKF_AGENT_BOT_LOGIN is not a bot login (expected <agent-app-slug>[bot])\n'
        reason_out config
        exit 2
    fi

    # Every pull request: the path the check validated is the bundle root the agent and the publisher use.
    local root_rev="refs/remotes/origin/$default_branch" root
    root="$(root_at "$root_rev")"
    bundle_path="${bundle_path%/}"
    if [ "$bundle_path" != "$root" ]; then
        printf 'okf-check: OKF_BUNDLE_PATH (%s) differs from bundle_root (%s) in .okf/publish.toml\n' "$(plain "$bundle_path")" "$root"
        reason_out bundle-path-mismatch
        exit 1
    fi

    local agent=0
    case "$head_ref" in agent/*) agent=1 ;; esac
    if [ "$type" = Bot ] && [ -n "$bot" ] && [ "$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$bot" | tr '[:upper:]' '[:lower:]')" ]; then
        agent=1
    fi
    if [ "$agent" -eq 0 ]; then
        printf 'okf-check: not an agent pull request; the bundle-root scope does not apply\n'
        return 0
    fi

    # Agent-authored: from the merge-base, so commits the base gained after the branch point are not the PR's.
    local mb out rc=0 refused
    commit_of "$base" >/dev/null
    commit_of "$head" >/dev/null
    mb="$(git merge-base "$base" "$head" 2>/dev/null)" || invalid 'no merge base between the base and the head'
    [[ $mb =~ $SHA_RE ]] || invalid 'the merge base is not a commit id'
    out="$(mktemp)"
    (OKF_SCOPE_ROOT_REV="$root_rev" cmd_check "$mb" "$head") >"$out" || rc=$?
    case "$rc" in
        0)
            printf 'okf-check: agent pull request scope: 0 refused\n'
            rm -f "$out"
            ;;
        1)
            refused="$(sed -n 's/^diff-scope: \([0-9][0-9]*\) change.*$/\1/p' "$out" | head -n 1)"
            printf 'okf-check: agent pull request scope: %s refused\n' "${refused:-some}"
            cat "$out"
            rm -f "$out"
            reason_out scope
            exit 1
            ;;
        *)
            rm -f "$out"
            reason_out config
            exit 2
            ;;
    esac
}

case "${1:-}" in
    bundle-root)
        shift
        cmd_bundle_root "$@"
        ;;
    check)
        shift
        cmd_check "$@"
        ;;
    pr)
        shift
        cmd_pr "$@"
        ;;
    *) invalid 'usage: diff-scope.sh bundle-root <rev> | check <base> (--cached | <head>) | pr' ;;
esac
