#!/usr/bin/env bash
# Phase 214 (KTPL-04, KTPL-05; D-04, D-05, D-08; threats T-214-21, T-214-25, T-214-49, T-214-56): the
# workspace of the `agent` job, and the packaging of what the model changed.
#
#   workspace.sh prepare   (before the model runs)
#       a. reads the bundle root from the DEFAULT branch commit (diff-scope.sh bundle-root);
#       b. when a proposal branch exists, overlays ITS bundle files onto the workspace as data (mode
#          100644 only, and the remote-tracking ref must still be the object the gate recorded);
#       c. records the tree of that state (the base the patch is measured against);
#       d. writes .okf-snapshot/workspace.md, so the model needs no git, and excludes the snapshot from git;
#       e. installs the fixed-argument wrapper `okf-agent-check` (and its private copy of the engine)
#          outside the workspace, read-only, first on PATH;
#       f. renders the fixed prompt from prompt.md with validated values only.
#   workspace.sh prepare --probe   (okf-agent-probe: the boundary and caps probe)
#       The same workspace, wrapper and bundle root with no issue, snapshot or proposal branch (the check base is the
#       commit itself), a fresh random canary planted outside the workspace in $RUNNER_TEMP/okf-probe (only its sha256
#       is recorded), and the probe and caps prompts rendered from probe-prompt.md and caps-prompt.md with validated
#       values only (outputs `prompt` and `caps-prompt`).
#   workspace.sh package   (after the model ran, always; run from the trusted copy, plan 214-15)
#       Turns the workspace's changes into agent.patch (text only, capped), with base.txt, date.txt and
#       status.txt (the agent step's outcome) in $RUNNER_TEMP/okf-result. A binary entry, or a patch over
#       the cap, writes package.txt = patch and no patch. It refuses to run git unless `contain.sh verify`
#       passed (the marker $RUNNER_TEMP/okf-agent/verify.ok), leaves a status-only result for a contained run,
#       and runs every git command with no system or global config, no fsmonitor and no hooks.
#
# Every script, the engine pin and the prompt come from the default-branch checkout this job runs in; the
# proposal branch contributes only the content of its bundle files.
#
# Env (prepare): OKF_ENGINE, OKF_ENGINE_SHA256, OKF_REPO, OKF_ISSUE, OKF_KIND, OKF_CODE_REF, OKF_START_REF,
# OKF_BRANCH_EXISTS, OKF_CHECK_BASE, OKF_DEFAULT_BRANCH, RUNNER_TEMP, GITHUB_OUTPUT, GITHUB_PATH,
# GITHUB_SERVER_URL. Env (package): OKF_AGENT_OUTCOME, RUNNER_TEMP.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE_SCRIPT="$HERE/../../actions/okf-check/diff-scope.sh"
PROMPT_TEMPLATE="$HERE/prompt.md"
PROBE_TEMPLATE="$HERE/probe-prompt.md"
CAPS_TEMPLATE="$HERE/caps-prompt.md"

SHA_RE='^[0-9a-f]{40}$'
SHA256_RE='^[0-9a-f]{64}$'
ISSUE_RE='^[1-9][0-9]{0,9}$'
REPO_RE='^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$'
KIND_RE='^[a-z][a-z-]{0,30}$'
BRANCH_RE='^[A-Za-z0-9._/-]{1,200}$'
SERVER_RE='^https://[A-Za-z0-9.-]+$'
PATH_RE='^[A-Za-z0-9._/ -]{1,255}$'
PLAIN_PATH_RE='^/[A-Za-z0-9._/-]{1,255}$'
REASON_RE='^[a-z-]{1,40}$'
PROMPT_LIMIT=16384
PATCH_LIMIT=5242880

OUT_FILE="${GITHUB_OUTPUT:-/dev/null}"

invalid() {
    printf 'workspace: %s\n' "$1" >&2
    exit 2
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# ------------------------------------------------------------------ prepare

cmd_prepare() {
    local probe=false
    case "${1:-}" in
        --probe) probe=true ;;
        '') ;;
        *) invalid 'usage: workspace.sh prepare [--probe]' ;;
    esac
    local temp="${RUNNER_TEMP:?RUNNER_TEMP is not set}"
    local engine="${OKF_ENGINE:-}" engine_sha="${OKF_ENGINE_SHA256:-}" repo="${OKF_REPO:-}" issue="${OKF_ISSUE:-}"
    local kind="${OKF_KIND:-}" code_ref="${OKF_CODE_REF:-}" start_ref="${OKF_START_REF:-}"
    local exists="${OKF_BRANCH_EXISTS:-}" check_base="${OKF_CHECK_BASE:-}" default_branch="${OKF_DEFAULT_BRANCH:-}"
    local server="${GITHUB_SERVER_URL:-https://github.com}"
    if [ "$probe" = true ]; then
        # The probe has no issue, no kind and no proposal branch: it runs on the commit itself.
        issue=1
        kind=probe
        start_ref="$code_ref"
        exists=false
    fi

    { [ -f "$engine" ] && [ -x "$engine" ] && [ ! -L "$engine" ]; } || invalid 'OKF_ENGINE is not a regular executable'
    [[ $engine_sha =~ $SHA256_RE ]] || invalid 'OKF_ENGINE_SHA256 is not a sha256'
    [ "$(sha256_of "$engine")" = "$engine_sha" ] || invalid 'the engine does not match its pinned sha256'
    [[ $repo =~ $REPO_RE ]] || invalid 'OKF_REPO is not owner/name'
    [[ $issue =~ $ISSUE_RE ]] || invalid 'OKF_ISSUE is not a plain positive integer'
    [[ $kind =~ $KIND_RE ]] || invalid 'OKF_KIND is not a kind word'
    [[ $code_ref =~ $SHA_RE ]] || invalid 'OKF_CODE_REF is not a full commit id'
    [[ $start_ref =~ $SHA_RE ]] || invalid 'OKF_START_REF is not a full commit id'
    [[ $check_base =~ $SHA_RE ]] || invalid 'OKF_CHECK_BASE is not a full commit id'
    case "$exists" in true | false) ;; *) invalid 'OKF_BRANCH_EXISTS is not true or false' ;; esac
    [[ $default_branch =~ $BRANCH_RE ]] || invalid 'OKF_DEFAULT_BRANCH is not a plain branch name'
    case "$default_branch" in *..*) invalid 'OKF_DEFAULT_BRANCH has a dot dot' ;; esac
    [[ $server =~ $SERVER_RE ]] || invalid 'GITHUB_SERVER_URL is not an https origin'
    [ "$(git rev-parse HEAD)" = "$code_ref" ] || invalid 'the checkout is not the recorded default-branch commit'
    git cat-file -e "${start_ref}^{commit}" 2>/dev/null || invalid 'OKF_START_REF is not a commit of this checkout'
    git cat-file -e "${check_base}^{commit}" 2>/dev/null || invalid 'OKF_CHECK_BASE is not a commit of this checkout'

    # a. the bundle root, from the default branch's own publish file.
    local root
    root="$(OKF_ENGINE="$engine" bash "$SCOPE_SCRIPT" bundle-root "$code_ref")"
    printf 'bundle-root=%s\n' "$root" >>"$OUT_FILE"

    # b. the proposal branch's bundle, as data. The tip must still be the object the gate recorded.
    local branch="agent/issue-$issue"
    if [ "$exists" = true ]; then
        local tip
        tip="$(git rev-parse --verify --quiet "refs/remotes/origin/${branch}^{commit}")" || invalid 'the proposal branch is gone'
        [ "$tip" = "$start_ref" ] || invalid 'the proposal branch moved since the gate read it'
        local listing entry
        listing="$(mktemp)"
        git ls-tree -r -z "$start_ref" -- "$root" >"$listing"
        if [ -s "$listing" ]; then
            while IFS= read -r -d '' entry; do
                case "$entry" in
                    '100644 blob '*) ;;
                    *) invalid 'the proposal branch has a bundle entry that is not a regular file' ;;
                esac
            done <"$listing"
            git checkout "$start_ref" -- "$root/"
        fi
        rm -f "$listing"
    fi

    # c. the base the patch is measured against.
    local state="$temp/okf-agent"
    mkdir -p "$state"
    git write-tree >"$state/base-tree"
    printf '%s\n' "$start_ref" >"$state/base.txt"
    date -u +%Y-%m-%d >"$state/date.txt"
    local today
    today="$(cat "$state/date.txt")"

    # d. what the model may need to know about the branch, without a git tool.
    if [ "$probe" = true ]; then mkdir -p .okf-snapshot; fi
    [ -d .okf-snapshot ] || invalid 'the snapshot was not downloaded'
    local differing=0 shown=0 path
    {
        printf '# Workspace\n\n'
        printf -- "- Bundle root: \`%s\`\n" "$root"
        printf -- "- Default branch: \`%s\`\n" "$default_branch"
        printf -- "- Proposal branch \`%s\` exists: %s\n" "$branch" "$exists"
        if [ "$exists" = true ]; then
            printf '\nThe bundle files below already differ from the default branch on the proposal branch. They are in the workspace now; build on them.\n\n'
            while IFS= read -r -d '' path; do
                differing=$((differing + 1))
                if [[ $path =~ $PATH_RE ]] && [ "$shown" -lt 100 ]; then
                    printf -- "- \`%s\`\n" "$path"
                    shown=$((shown + 1))
                fi
            done < <(git diff --name-only -z --no-renames "$code_ref" "$start_ref" -- "$root")
            if [ "$differing" -gt "$shown" ]; then
                printf -- '- (%s more not listed)\n' "$((differing - shown))"
            fi
        fi
    } >.okf-snapshot/workspace.md
    printf '/.okf-snapshot/\n' >>"$(git rev-parse --git-path info/exclude)"

    # e. the fixed-argument self-check wrapper, outside the workspace and read-only.
    local bin="$temp/okf-bin" home="$temp/okf-agent-home" findings="$temp/okf-agent-findings.json" workspace
    workspace="$(pwd)"
    [[ $workspace =~ ^/[A-Za-z0-9._/-]+$ ]] || invalid 'the workspace path is outside the plain path alphabet'
    [[ $temp =~ ^/[A-Za-z0-9._/-]+$ ]] || invalid 'RUNNER_TEMP is outside the plain path alphabet'
    if [ -d "$bin" ]; then chmod -R u+w "$bin"; fi
    rm -rf "$bin"
    mkdir -p "$bin" "$home"
    chmod 0700 "$home"
    cp "$engine" "$bin/okf-check"
    [ "$(sha256_of "$bin/okf-check")" = "$engine_sha" ] || invalid 'the engine copy does not match its pinned sha256'
    write_wrapper "$bin/okf-agent-check" "$workspace" "$root" "$check_base" "$engine_sha" "$bin/okf-check" "$home" "$findings"
    chmod 0555 "$bin/okf-check" "$bin/okf-agent-check" "$bin"
    printf '%s\n' "$bin" >>"${GITHUB_PATH:-/dev/null}"

    # f. the fixed prompt, with validated values only.
    if [ "$probe" = true ]; then
        prepare_probe "$temp"
        return 0
    fi
    [ -f "$PROMPT_TEMPLATE" ] && [ ! -L "$PROMPT_TEMPLATE" ] || invalid 'prompt.md is missing'
    local prompt issue_url
    issue_url="$server/$repo/issues/$issue"
    prompt="$(cat "$PROMPT_TEMPLATE")"
    prompt="${prompt//'{{ISSUE}}'/$issue}"
    prompt="${prompt//'{{KIND}}'/$kind}"
    prompt="${prompt//'{{ISSUE_URL}}'/$issue_url}"
    prompt="${prompt//'{{BUNDLE_ROOT}}'/$root}"
    prompt="${prompt//'{{DEFAULT_BRANCH}}'/$default_branch}"
    prompt="${prompt//'{{TODAY}}'/$today}"
    case "$prompt" in *'{{'*) invalid 'the prompt has an unfilled placeholder' ;; esac
    [ "${#prompt}" -le "$PROMPT_LIMIT" ] || invalid 'the prompt is over 16 KiB'
    local delimiter
    delimiter="OKF_PROMPT_$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    {
        printf 'prompt<<%s\n' "$delimiter"
        printf '%s\n' "$prompt"
        printf '%s\n' "$delimiter"
    } >>"$OUT_FILE"
}

# emit_output <name> <value>: a multi-line step output with a random delimiter.
emit_output() {
    local delimiter
    delimiter="OKF_OUT_$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    {
        printf '%s<<%s\n' "$1" "$delimiter"
        printf '%s\n' "$2"
        printf '%s\n' "$delimiter"
    } >>"$OUT_FILE"
}

# render_probe <template> <event-path> <canary-path> <runner-temp>: the template with the three validated values.
render_probe() {
    local template="$1" event="$2" canary="$3" temp="$4" text
    [ -f "$template" ] && [ ! -L "$template" ] || invalid "$(basename "$template") is missing"
    text="$(cat "$template")"
    text="${text//'{{EVENT_PATH}}'/$event}"
    text="${text//'{{CANARY_PATH}}'/$canary}"
    text="${text//'{{RUNNER_TEMP}}'/$temp}"
    case "$text" in *'{{'*) invalid "$(basename "$template") has an unfilled placeholder" ;; esac
    [ "${#text}" -le "$PROMPT_LIMIT" ] || invalid "$(basename "$template") renders over 16 KiB"
    printf '%s' "$text"
}

# prepare_probe <runner-temp>: plant the canary and render the probe and caps prompts.
prepare_probe() {
    local temp="$1" event="${GITHUB_EVENT_PATH:-}" dir canary_file value
    [[ $event =~ $PLAIN_PATH_RE ]] || invalid 'GITHUB_EVENT_PATH is outside the plain path alphabet'
    [[ $temp =~ $PLAIN_PATH_RE ]] || invalid 'RUNNER_TEMP is outside the plain path alphabet'
    dir="$temp/okf-probe"
    canary_file="$dir/outside-canary.txt"
    rm -rf "$dir"
    mkdir -p "$dir"
    value="okf-probe-canary-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '%s\n' "$value" >"$canary_file"
    sha256_of "$canary_file" >"$dir/canary.sha256"
    chmod 0600 "$canary_file"
    emit_output prompt "$(render_probe "$PROBE_TEMPLATE" "$event" "$canary_file" "$temp")"
    emit_output caps-prompt "$(render_probe "$CAPS_TEMPLATE" "$event" "$canary_file" "$temp")"
}

# write_wrapper <file> <workspace> <root> <check-base> <engine-sha256> <engine> <home> <findings>:
# the only command the model may run. Every value is baked in as a literal (all validated by the caller);
# it takes no argument, proves the engine is the pinned one before each run, and runs it with an empty
# environment, so the model key never reaches the engine process. It prints the counts and the sorted
# (severity, rule, document) triples between stop-commands fences, nothing else from the engine.
write_wrapper() {
    local file="$1" workspace="$2" root="$3" base="$4" sha="$5" engine="$6" home="$7" findings="$8" text
    IFS= read -r -d '' text <<'WRAPPER' || true
#!/bin/bash
# okf-agent-check: the fixed-argument self-check (Phase 214, T-214-56). Generated by workspace.sh prepare.
set -uo pipefail
if [ "$#" -ne 0 ]; then
    echo "okf-agent-check takes no argument" >&2
    exit 2
fi
ENGINE='@ENGINE@'
WANT='@SHA@'
FINDINGS='@FINDINGS@'
if command -v sha256sum >/dev/null 2>&1; then
    got="$(sha256sum "$ENGINE" | cut -d' ' -f1)"
else
    got="$(shasum -a 256 "$ENGINE" | cut -d' ' -f1)"
fi
if [ "$got" != "$WANT" ]; then
    echo "okf-agent-check: the engine does not match its pinned checksum" >&2
    exit 2
fi
cd '@WORKSPACE@' || exit 2
rm -f "$FINDINGS"
set +e
env -i PATH=/usr/bin:/bin HOME='@HOME@' LC_ALL=C "$ENGINE" check '@ROOT@' --base '@BASE@' --format json --out "$FINDINGS" >/dev/null 2>&1
code=$?
set -e
token="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
case "$code" in
    0) echo "okf-agent-check: the check passed (exit 0)" ;;
    1) echo "okf-agent-check: the check found errors (exit 1)" ;;
    *) echo "okf-agent-check: no check completed (exit $code)" ;;
esac
if [ "$code" -le 1 ] && [ -f "$FINDINGS" ] && [ ! -L "$FINDINGS" ]; then
    rows="$(jq -r '[((.repo_findings // [])[]), ((.profile_findings // [])[])]
        | map(select(type == "object" and (.severity | type) == "string" and (.rule | type) == "string" and (.doc | type) == "string"))
        | sort_by([.severity, .rule, .doc])[]
        | [.severity, .rule, .doc] | @tsv' "$FINDINGS" 2>/dev/null)" || rows=""
    errors="$(printf '%s\n' "$rows" | grep -c '^error' || true)"
    warnings="$(printf '%s\n' "$rows" | grep -c '^warning' || true)"
    echo "errors: $errors, warnings: $warnings"
    echo "::stop-commands::$token"
    printf '%s\n' "$rows" | head -n 100 | tr -c 'A-Za-z0-9._/ \n\t-' '?' | cut -c1-300
    echo "::$token::"
fi
exit "$code"
WRAPPER
    text="${text//@ENGINE@/$engine}"
    text="${text//@SHA@/$sha}"
    text="${text//@FINDINGS@/$findings}"
    text="${text//@WORKSPACE@/$workspace}"
    text="${text//@HOME@/$home}"
    text="${text//@ROOT@/$root}"
    text="${text//@BASE@/$base}"
    printf '%s\n' "$text" >"$file"
}

# ------------------------------------------------------------------ package

# git_safe <git args...>: git with no system or global config, no fsmonitor and no hooks. Everything the model could
# have written under .git was already compared by `contain.sh verify`; this is the second layer.
git_safe() {
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
}

cmd_package() {
    local temp="${RUNNER_TEMP:?RUNNER_TEMP is not set}"
    local state="$temp/okf-agent" result="$temp/okf-result" status="${OKF_AGENT_OUTCOME:-}" reason=""
    [[ $status =~ ^[a-z]{1,16}$ ]] || status=unknown
    rm -rf "$result"
    mkdir -p "$result"
    # A run contained by an earlier check (contain.sh verify) leaves only its reason: nothing of it is packaged.
    if [ -f "$state/contained.txt" ] && [ ! -L "$state/contained.txt" ]; then
        reason="$(head -c 64 "$state/contained.txt" | tr -d '\n')"
        [[ $reason =~ $REASON_RE ]] || reason=unknown
        printf 'contained:%s\n' "$reason" >"$result/status.txt"
        return 0
    fi
    printf '%s\n' "$status" >"$result/status.txt"
    # A prepare step that did not finish leaves no state: nothing to package.
    if [ ! -f "$state/base-tree" ] || [ ! -f "$state/base.txt" ] || [ ! -f "$state/date.txt" ]; then
        printf 'prepare\n' >"$result/package.txt"
        return 0
    fi
    cp "$state/base.txt" "$result/base.txt"
    cp "$state/date.txt" "$result/date.txt"
    if [ "$status" != success ]; then
        printf 'agent\n' >"$result/package.txt"
        return 0
    fi
    # No git command before the workspace's git state was proven unchanged.
    if [ ! -f "$state/verify.ok" ] || [ -L "$state/verify.ok" ]; then
        printf 'verify\n' >"$result/package.txt"
        return 0
    fi
    local base_tree
    base_tree="$(cat "$state/base-tree")"
    [[ $base_tree =~ $SHA_RE ]] || invalid 'the recorded base tree is not an object id'

    # The snapshot is excluded from git (prepare), so `add -A` never stages it; if anything under it is staged
    # anyway the package is refused rather than shipped.
    git_safe add -A
    if git_safe diff --cached --name-only --no-renames "$base_tree" | grep -q '^\.okf-snapshot/'; then
        printf 'patch\n' >"$result/package.txt"
        return 0
    fi
    # A binary change, or an attribute that hides the content, cannot be reviewed as text: refuse it.
    local numstat binary
    numstat="$(git_safe diff --cached --numstat --no-renames --no-ext-diff --no-textconv "$base_tree")"
    binary="$(printf '%s\n' "$numstat" | grep -c -E '^-	-	' || true)"
    if [ "${binary:-0}" -gt 0 ]; then
        printf 'patch\n' >"$result/package.txt"
        return 0
    fi
    git_safe diff --cached --no-renames --full-index --text --no-ext-diff --no-textconv "$base_tree" >"$result/agent.patch"
    local size
    size="$(wc -c <"$result/agent.patch" | tr -d ' ')"
    if [ "$size" -gt "$PATCH_LIMIT" ]; then
        rm -f "$result/agent.patch"
        printf 'patch\n' >"$result/package.txt"
        return 0
    fi
    printf 'ok\n' >"$result/package.txt"
}

case "${1:-}" in
    prepare) shift && cmd_prepare "$@" ;;
    package) cmd_package ;;
    *) invalid 'usage: workspace.sh prepare [--probe] | package' ;;
esac
