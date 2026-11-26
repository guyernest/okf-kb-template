#!/usr/bin/env bash
# Phase 214 (KTPL-05; D-04; threats T-214-58, T-214-59, T-214-61): deterministic containment around the model
# step of the `agent` job. Nothing here depends on what the model does or on Claude Code's permission semantics:
# everything the model could have changed is treated as hostile, and the job only goes on with files it staged
# BEFORE the model ran.
#
#   contain.sh stage             (before the model; run from the checkout) copies workspace.sh, contain.sh and
#                                session-check.py into $RUNNER_TEMP/okf-trusted/ (files and directory mode 0555).
#                                Every step after the model runs those copies, never a file in the workspace.
#   contain.sh baseline [--tree] (before the model; from the trusted copy) records mode and sha256 of .git/config,
#                                .git/HEAD, .git/packed-refs and of every file under .git/info/, .git/hooks/ and
#                                .git/objects/info/. With --tree it also records the digest of every file outside
#                                .git/ (the boundary probe compares it). .git/config is hashed after the one
#                                normalisation described below, on the baseline and on the check alike.
#   contain.sh verify            (first step after the model, before ANY git command) recomputes that state with no
#                                git command and compares. A difference records `contained:workspace-tampered`,
#                                leaves a status-only result and exits 1. A match writes the marker
#                                $RUNNER_TEMP/okf-agent/verify.ok, which `workspace.sh package` requires.
#   contain.sh key-check         (needs OKF_MODEL_KEY in the step env) searches the packaged result for the model key
#                                as a fixed string and never prints it. A match deletes the patch and records
#                                `contained:secret-in-patch`; the result artifact is readable by anyone who can
#                                read the repository. It runs no git command.
#
# The one tolerated change under .git/ (plan 214-14, run 45714939436): the pinned anthropics/claude-code-action
# configures git itself BEFORE the model starts (src/github/operations/git-config.ts, configureGitAuth, called by
# src/modes/agent/index.ts, at the pin of okf-agent.yml). In the mode and with the inputs the agent job uses it runs
#     git config user.name  "claude[bot]"
#     git config user.email "41898282+claude[bot]@users.noreply.github.com"
#     git remote set-url origin https://x-access-token:<token>@github.com/<owner>/<repo>.git
# (its credential-helper branch needs the inputs `allowed_bots` / `allowed_non_write_users`, which neither workflow can set: lint L20 and L25 hold the action's `with:` keys to exactly four). The
# comparison of .git/config therefore ignores exactly these and nothing else: a `[user]` section whose body is exactly
# the two lines above, and, in `[remote "origin"]`, a `url` line of exactly the token form above (compared as the
# plain `https://github.com/<owner>/<repo>` it was before). The token's alphabet is letters, digits, `_`, `-` and `.`:
# a real runner's job token is `ghs_` plus about 370 such characters with dots and hyphens in it (plan 214-14, the
# diagnostic run of 2026-11-26; the first form of this tolerance allowed letters, digits and `_` only, so the URL was
# never taken out of the comparison and every run on a real runner was contained). Every other byte of the file, its mode, and every other
# file under .git/ must stay identical; a different key, host, userinfo, port, scheme, owner or repository, a second
# url, an extra remote, `core.fsmonitor`, `core.hooksPath`, `alias.*`, `include*`, `credential.*` all differ.
# The action also writes `core.fsmonitor` (and, for untrusted pull requests, `core.hooksPath`) into .git/config for the
# length of the session and restores the file afterwards (session-guard.ts, snapshotSessionFiles); that is NOT tolerated:
# a run in which the restore did not happen is contained.
#
# A contained result is only status.txt (`contained:<reason>`): the first reason recorded for a run wins.
# Exit codes: 0 clean, 1 contained, 2 the step could not run (missing state, bad environment).
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAIN_PATH_RE='^/[A-Za-z0-9._/-]+$'
REASON_RE='^[a-z-]{1,40}$'
SHOWN_PATH_RE='^\.git/[A-Za-z0-9._/-]{1,200}$'

TEMP="${RUNNER_TEMP:-}"
TRUSTED=""
STATE=""
RESULT=""

invalid() {
    printf 'contain: %s\n' "$1" >&2
    exit 2
}

need_temp() {
    [[ $TEMP =~ $PLAIN_PATH_RE ]] || invalid 'RUNNER_TEMP is not a plain absolute path'
    TRUSTED="$TEMP/okf-trusted"
    STATE="$TEMP/okf-agent"
    RESULT="$TEMP/okf-result"
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

mode_of() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

# config_normalised <file>: the file as it is compared, with only the action's own writes taken out (see the header).
# A file with a NUL byte is not normalised at all, so anything unusual is compared byte for byte.
config_normalised() {
    local file="$1"
    if [ "$(tr -d '\000' <"$file" | wc -c | tr -d ' ')" != "$(wc -c <"$file" | tr -d ' ')" ]; then
        cat "$file"
        printf 'nul-bytes\n'
        return 0
    fi
    awk '
        function flush_user(   i, name_lines, email_lines, other) {
            if (!in_user) return
            in_user = 0
            name_lines = 0; email_lines = 0; other = 0
            for (i = 1; i <= user_n; i++) {
                if (user_body[i] == "\tname = claude[bot]") name_lines++
                else if (user_body[i] == "\temail = 41898282+claude[bot]@users.noreply.github.com") email_lines++
                else other++
            }
            if (name_lines == 1 && email_lines == 1 && other == 0) return
            print "[user]"
            for (i = 1; i <= user_n; i++) print user_body[i]
        }
        function origin_url(value) {
            if (value ~ /^https:\/\/x-access-token:[A-Za-z0-9_.-]+@github\.com\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\.git$/) {
                sub(/^https:\/\/x-access-token:[A-Za-z0-9_.-]+@/, "https://", value)
                sub(/\.git$/, "", value)
            }
            return value
        }
        /^\[/ {
            flush_user()
            section = $0
            if ($0 == "[user]") { in_user = 1; user_n = 0; next }
            print
            next
        }
        in_user { user_body[++user_n] = $0; next }
        section == "[remote \"origin\"]" && substr($0, 1, 7) == "\turl = " { print "\turl = " origin_url(substr($0, 8)); next }
        { print }
        END { flush_user() }
    ' "$file"
    # awk ends every line with a newline: record whether the file did
    if [ -n "$(tail -c 1 "$file")" ]; then printf 'no-final-newline\n'; fi
}

# state_line <path>: one line for a file or a link (mode and content digest, or the link's target). The digest of
# .git/config is the one of its normalised form (the action's own writes taken out, see the header).
state_line() {
    local item="$1"
    case "$item" in
        *$'\n'*)
            printf 'BADNAME\n'
            return 0
            ;;
    esac
    if [ -L "$item" ]; then
        printf 'L %s %s\n' "$(readlink "$item")" "$item"
    elif [ "$item" = .git/config ]; then
        printf 'F %s %s %s\n' "$(mode_of "$item")" "$(config_normalised "$item" | sha256_stdin)" "$item"
    else
        printf 'F %s %s %s\n' "$(mode_of "$item")" "$(sha256_of "$item")" "$item"
    fi
}

# state_lines: the git control state of the workspace, sorted, one line per item. An item that is added, removed,
# changed or re-moded changes the output. No git command runs here.
state_lines() {
    local item dir
    if [ ! -d .git ] || [ -L .git ]; then
        printf 'NOGIT\n'
        return 0
    fi
    {
        for item in .git/config .git/HEAD .git/packed-refs; do
            if [ -L "$item" ] || [ -f "$item" ]; then state_line "$item"; fi
        done
        for dir in .git/info .git/hooks .git/objects/info; do
            [ -d "$dir" ] || continue
            while IFS= read -r -d '' item; do
                state_line "$item"
            done < <(find "$dir" \( -type f -o -type l \) -print0)
        done
    } | sort
}

# mark_contained <reason>: record the first reason of this run and leave a status-only result.
mark_contained() {
    local reason="$1"
    [[ $reason =~ $REASON_RE ]] || invalid 'the containment reason is not a plain word'
    mkdir -p "$STATE"
    [ -s "$STATE/contained.txt" ] || printf '%s\n' "$reason" >"$STATE/contained.txt"
    reason="$(head -c 64 "$STATE/contained.txt" | tr -d '\n')"
    [[ $reason =~ $REASON_RE ]] || reason=unknown
    rm -rf "$RESULT"
    mkdir -p "$RESULT"
    printf 'contained:%s\n' "$reason" >"$RESULT/status.txt"
}

# ------------------------------------------------------------------ stage

cmd_stage() {
    need_temp
    local file
    if [ -e "$TRUSTED" ]; then
        chmod -R u+w "$TRUSTED"
        rm -rf "$TRUSTED"
    fi
    mkdir -p "$TRUSTED"
    for file in workspace.sh contain.sh session-check.py; do
        { [ -f "$HERE/$file" ] && [ ! -L "$HERE/$file" ]; } || invalid "$file is not a regular file next to contain.sh"
        cp "$HERE/$file" "$TRUSTED/$file"
        chmod 0555 "$TRUSTED/$file"
    done
    chmod 0555 "$TRUSTED"
}

# ------------------------------------------------------------------ baseline

cmd_baseline() {
    need_temp
    local tree=false
    case "${1:-}" in
        --tree) tree=true ;;
        '') ;;
        *) invalid 'usage: contain.sh baseline [--tree]' ;;
    esac
    [ -d "$TRUSTED" ] || invalid 'the trusted scripts were not staged'
    local lines
    lines="$(state_lines)"
    [ "$lines" != NOGIT ] || invalid 'the workspace has no .git directory'
    [ -n "$lines" ] || invalid 'there is no git state to record'
    mkdir -p "$STATE"
    rm -f "$STATE/verify.ok" "$STATE/contained.txt"
    chmod u+w "$TRUSTED"
    rm -f "$TRUSTED/git-state.sha256"
    printf '%s\n' "$lines" >"$TRUSTED/git-state.sha256"
    chmod 0444 "$TRUSTED/git-state.sha256"
    chmod 0555 "$TRUSTED"
    if [ "$tree" = true ]; then
        python3 -I "$TRUSTED/session-check.py" --tree-baseline
    fi
}

# ------------------------------------------------------------------ verify

cmd_verify() {
    need_temp
    mkdir -p "$STATE"
    rm -f "$STATE/verify.ok"
    local want="$TRUSTED/git-state.sha256"
    { [ -f "$want" ] && [ ! -L "$want" ]; } || invalid 'no workspace state was recorded (the baseline step did not run)'
    local now
    now="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$now'" EXIT
    state_lines >"$now"
    if cmp -s "$want" "$now"; then
        printf 'ok\n' >"$STATE/verify.ok"
        return 0
    fi
    local first path token
    first="$(comm -3 "$want" "$now" | head -n 1 | sed 's/^[[:space:]]*//')"
    path="$(printf '%s\n' "$first" | awk '{ if ($1 == "F") { $1 = ""; $2 = ""; $3 = ""; sub(/^ +/, ""); print } else if ($1 == "L") { $1 = ""; $2 = ""; sub(/^ +/, ""); print } else { print "(unnamed)" } }')"
    [[ $path =~ $SHOWN_PATH_RE ]] || path='<path withheld>'
    mark_contained workspace-tampered
    token="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf 'contain: the workspace changed under git control; the run is contained (workspace-tampered)\n'
    printf '::stop-commands::%s\n' "$token"
    printf 'first differing path: %s\n' "$path"
    printf '::%s::\n' "$token"
    exit 1
}

# ------------------------------------------------------------------ key-check

cmd_key_check() {
    need_temp
    [ -n "${OKF_MODEL_KEY:-}" ] || invalid 'the model key is not set in this step'
    [ -d "$RESULT" ] || return 0
    local code=0
    grep -rqaF -f - -- "$RESULT" <<<"$OKF_MODEL_KEY" || code=$?
    case "$code" in
        0)
            mark_contained secret-in-patch
            printf 'contain: the packaged result holds the model key; the patch was deleted (secret-in-patch)\n'
            exit 1
            ;;
        1) return 0 ;;
        *)
            mark_contained key-check-failed
            printf 'contain: the model-key search did not complete; the result was dropped (key-check-failed)\n'
            exit 1
            ;;
    esac
}

case "${1:-}" in
    stage) cmd_stage ;;
    baseline) shift && cmd_baseline "$@" ;;
    verify) cmd_verify ;;
    key-check) cmd_key_check ;;
    *) invalid 'usage: contain.sh stage | baseline [--tree] | verify | key-check' ;;
esac
