#!/usr/bin/env bash
# Phase 214 (KTPL-01, KTPL-04; D-19; threats T-214-29, T-214-30, T-214-31, T-214-66): the secret scan. It runs the
# gitleaks CLI (never the gitleaks Action: its licence is commercial for organisations), pinned by version and by the
# sha256 of the release archive AND of the extracted binary, over what a pull request will land.
#
#   secret-scan.sh pr                     two passes, both must be clean:
#                                           1. every commit of the pull request (merge-base..head), so a secret that was
#                                              added and later removed still fails;
#                                           2. the net diff (merge-base to head, added lines only), so content that exists
#                                              only in a merge commit's resolution is found.
#   secret-scan.sh patch <worktree> <base>  the net pass alone, over `git diff --cached <base>` of a worktree: the agent's
#                                           proposal, scanned by `propose.sh prepare` before anything is pushed.
#
# Env (both): OKF_LOCK_FILE, OKF_CONFIG_FILE (paths of the pinned lock and the gitleaks configuration; the workflow
# materializes them from the pull request's BASE commit), RUNNER_TEMP (an absolute path; scratch space, the scan keeps its
# files under $RUNNER_TEMP/okf-secret-scan and the bare mirror at $RUNNER_TEMP/okf-scan.git). pr adds OKF_BASE_SHA and
# OKF_HEAD_SHA (full commit ids) and runs from the root of the checkout. Optional, either mode: OKF_SCAN_RULES_FILE, a path
# the rule id of every finding is appended to (`propose.sh` reads it to name the rules in its comment). Test seam: OKF_GITLEAKS_LOCK replaces the lock
# path, and is honoured ONLY when OKF_SECRET_SCAN_TEST=1 (a pull request cannot set an environment variable of this job).
#
# Exit: 0 clean, 1 at least one finding, 2 the scan could not run (a refusal is never a pass).
# Output: the number of findings and, per finding, the rule id, the file and the line. NEVER the secret: gitleaks runs
# with --redact, its own output is not echoed on the finding path, and the report fields printed are only those three.
#
# Trust statement. The pull request controls its files, so nothing it can edit steers this scan:
#   * this script, the lock and the configuration are read from the pull request's BASE commit by the workflow (the PR's
#     copy is used only when the base lacks the file, with a notice); a PR that edits the workflow file itself relies on
#     code-owner review, as in plan 214-07;
#   * the commit pass scans a BARE mirror (no working tree) from an EMPTY working directory, because gitleaks loads
#     `<source>/.gitleaksignore` and `.gitleaks.toml` by itself whatever --gitleaks-ignore-path says;
#   * --gitleaks-ignore-path points at an empty directory, --ignore-gitleaks-allow disables inline `gitleaks:allow`
#     comments, and gitleaks runs in an empty environment, so GITLEAKS_CONFIG and GITLEAKS_CONFIG_TOML are not set;
#   * a leak exits with a distinct code (99), so a gitleaks error (a broken configuration exits 1) is never read as a
#     finding and never as a pass.
set -euo pipefail
export LC_ALL=C

LEAK_EXIT=99
RE_SHA='^[0-9a-f]{40}$'
RE_HASH='^[0-9a-f]{64}$'
RE_VERSION='^[0-9]+\.[0-9]+\.[0-9]+$'
RE_LINE='^([A-Za-z0-9_.-]{1,64})=(.*)$'
RE_RULE='^[A-Za-z0-9._-]{1,64}$'
PLACEHOLDER_HASH='0000000000000000000000000000000000000000000000000000000000000000'
LOCK_MAX_BYTES=4096
MAX_DOWNLOAD=104857600
MAX_LISTED=50

refuse() {
    printf 'okf-secret-scan: %s\n' "$1" >&2
    exit 2
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# abs_file <path>: the absolute path of an existing regular, non-symlink file (the scan runs from another directory).
abs_file() {
    local path="$1" dir
    { [ -f "$path" ] && [ ! -L "$path" ]; } || return 1
    dir="$(cd "$(dirname "$path")" && pwd)" || return 1
    printf '%s/%s\n' "$dir" "$(basename "$path")"
}

# ------------------------------------------------------------------ the pin

LOCK_VERSION=""
LOCK_X64_ARCHIVE=""
LOCK_X64_BINARY=""
LOCK_ARM64_ARCHIVE=""
LOCK_ARM64_BINARY=""

# parse_lock <file>: a strict parse of the lock as DATA (never sourced). A refusal never echoes a value back.
parse_lock() {
    local lock="$1" size nul cr line key val lineno=0
    local seen_version=0 seen_xa=0 seen_xb=0 seen_aa=0 seen_ab=0
    { [ -f "$lock" ] && [ ! -L "$lock" ]; } || refuse 'the gitleaks lock must be a regular file'
    size="$(wc -c <"$lock" | tr -d ' ')"
    [ "$size" -le "$LOCK_MAX_BYTES" ] || refuse "the gitleaks lock is larger than $LOCK_MAX_BYTES bytes"
    nul="$(LC_ALL=C tr -cd '\000' <"$lock" | wc -c | tr -d ' ')"
    [ "$nul" -eq 0 ] || refuse 'the gitleaks lock contains a NUL byte'
    cr="$(LC_ALL=C tr -cd '\r' <"$lock" | wc -c | tr -d ' ')"
    [ "$cr" -eq 0 ] || refuse 'the gitleaks lock must use LF line endings'
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        [ -z "$line" ] && continue
        case "$line" in '#'*) continue ;; esac
        [[ $line =~ $RE_LINE ]] || refuse "the gitleaks lock has a malformed line $lineno"
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        case "$key" in
            version)
                [ "$seen_version" -eq 0 ] || refuse "the gitleaks lock repeats a key on line $lineno"
                [[ $val =~ $RE_VERSION ]] || refuse "the gitleaks lock has an invalid version on line $lineno"
                seen_version=1
                LOCK_VERSION="$val"
                ;;
            x64.archive_sha256)
                [ "$seen_xa" -eq 0 ] || refuse "the gitleaks lock repeats a key on line $lineno"
                [[ $val =~ $RE_HASH ]] || refuse "the gitleaks lock has an invalid sha256 on line $lineno"
                seen_xa=1
                LOCK_X64_ARCHIVE="$val"
                ;;
            x64.binary_sha256)
                [ "$seen_xb" -eq 0 ] || refuse "the gitleaks lock repeats a key on line $lineno"
                [[ $val =~ $RE_HASH ]] || refuse "the gitleaks lock has an invalid sha256 on line $lineno"
                seen_xb=1
                LOCK_X64_BINARY="$val"
                ;;
            arm64.archive_sha256)
                [ "$seen_aa" -eq 0 ] || refuse "the gitleaks lock repeats a key on line $lineno"
                [[ $val =~ $RE_HASH ]] || refuse "the gitleaks lock has an invalid sha256 on line $lineno"
                seen_aa=1
                LOCK_ARM64_ARCHIVE="$val"
                ;;
            arm64.binary_sha256)
                [ "$seen_ab" -eq 0 ] || refuse "the gitleaks lock repeats a key on line $lineno"
                [[ $val =~ $RE_HASH ]] || refuse "the gitleaks lock has an invalid sha256 on line $lineno"
                seen_ab=1
                LOCK_ARM64_BINARY="$val"
                ;;
            *) refuse "the gitleaks lock has an unknown key on line $lineno" ;;
        esac
    done <"$lock"
    [ "$seen_version" -eq 1 ] || refuse 'the gitleaks lock has no version'
}

ARCH=""
ARCHIVE_SHA=""
BINARY_SHA=""

# pick_arch: the runner's architecture, mapped to the release asset's name, and the pinned digests for it.
pick_arch() {
    case "$(uname -m)" in
        x86_64)
            ARCH=x64
            ARCHIVE_SHA="$LOCK_X64_ARCHIVE"
            BINARY_SHA="$LOCK_X64_BINARY"
            ;;
        aarch64 | arm64)
            ARCH=arm64
            ARCHIVE_SHA="$LOCK_ARM64_ARCHIVE"
            BINARY_SHA="$LOCK_ARM64_BINARY"
            ;;
        *) refuse 'unsupported architecture (the scan runs on x86_64 and aarch64 only)' ;;
    esac
    [ -n "$ARCHIVE_SHA" ] && [ -n "$BINARY_SHA" ] || refuse "the gitleaks lock has no digests for $ARCH"
}

GITLEAKS_BIN=""

# fetch_gitleaks <scan dir>: download the pinned release for this architecture, prove both digests, extract only the
# `gitleaks` member. Nothing runs before every check has passed.
fetch_gitleaks() {
    local scan="$1" archive url got
    archive="$scan/dl/gitleaks.tar.gz"
    url="https://github.com/gitleaks/gitleaks/releases/download/v${LOCK_VERSION}/gitleaks_${LOCK_VERSION}_linux_${ARCH}.tar.gz"
    curl --proto '=https' --proto-redir '=https' --fail --location --max-redirs 5 --max-filesize "$MAX_DOWNLOAD" \
        --connect-timeout 20 --max-time 300 --silent --show-error --url "$url" -o "$archive" 2>"$scan/dl/curl.err" ||
        refuse "the gitleaks $LOCK_VERSION release for $ARCH could not be downloaded"
    got="$(sha256_of "$archive")"
    if [ "$got" != "$ARCHIVE_SHA" ]; then
        refuse "the gitleaks archive sha256 does not match .okf/gitleaks.lock (expected $ARCHIVE_SHA, got $got); refusing to run"
    fi
    tar -xzf "$archive" -C "$scan/bin" gitleaks 2>"$scan/dl/tar.err" || refuse 'the gitleaks archive has no gitleaks member; refusing to run'
    GITLEAKS_BIN="$scan/bin/gitleaks"
    { [ -f "$GITLEAKS_BIN" ] && [ ! -L "$GITLEAKS_BIN" ]; } || refuse 'the gitleaks member is not a regular file; refusing to run'
    got="$(sha256_of "$GITLEAKS_BIN")"
    if [ "$BINARY_SHA" = "$PLACEHOLDER_HASH" ]; then
        refuse "the binary digest for $ARCH in .okf/gitleaks.lock is still the all-zero placeholder (the archive's binary hashes to $got); resolve it with 'just gitleaks-lock-digests'"
    fi
    if [ "$got" != "$BINARY_SHA" ]; then
        refuse "the gitleaks binary sha256 does not match .okf/gitleaks.lock (expected $BINARY_SHA, got $got); refusing to run"
    fi
    chmod 0755 "$GITLEAKS_BIN"
}

# ------------------------------------------------------------------ running the scanner

SCAN=""
EMPTY_WD=""
EMPTY_IGNORE=""
EMPTY_HOME=""
CONFIG=""
LOCK=""

# prepare_scan: validated environment, the pinned lock and configuration, a fresh scratch tree and the verified binary.
prepare_scan() {
    local temp="${RUNNER_TEMP:-}"
    case "$temp" in /*) ;; *) refuse 'RUNNER_TEMP must be an absolute path' ;; esac
    [ -d "$temp" ] || refuse 'RUNNER_TEMP is not a directory'
    LOCK="${OKF_LOCK_FILE:-}"
    if [ "${OKF_SECRET_SCAN_TEST:-}" = 1 ] && [ -n "${OKF_GITLEAKS_LOCK:-}" ]; then LOCK="$OKF_GITLEAKS_LOCK"; fi
    [ -n "$LOCK" ] || refuse 'OKF_LOCK_FILE is not set'
    [ -n "${OKF_CONFIG_FILE:-}" ] || refuse 'OKF_CONFIG_FILE is not set'
    CONFIG="$(abs_file "$OKF_CONFIG_FILE")" || refuse 'the gitleaks configuration must be a regular file'
    parse_lock "$LOCK"
    pick_arch
    SCAN="$temp/okf-secret-scan"
    rm -rf "$SCAN"
    mkdir -p "$SCAN/dl" "$SCAN/bin" "$SCAN/reports" "$SCAN/tmp" "$SCAN/empty-wd" "$SCAN/empty-ignore" "$SCAN/empty-home"
    EMPTY_WD="$SCAN/empty-wd"
    EMPTY_IGNORE="$SCAN/empty-ignore"
    EMPTY_HOME="$SCAN/empty-home"
    fetch_gitleaks "$SCAN"
}

# run_gitleaks <report> <stdin file or -> <subcommand and its arguments...>: one pass, from an empty directory and an empty
# environment. Prints the exit status.
run_gitleaks() {
    local report="$1" input="$2" rc=0
    shift 2
    local sub="$1"
    shift
    local common=(--config "$CONFIG" --gitleaks-ignore-path "$EMPTY_IGNORE" --ignore-gitleaks-allow --redact --no-banner
        --exit-code "$LEAK_EXIT" --report-format json --report-path "$report")
    if [ "$input" = - ]; then
        (cd "$EMPTY_WD" && env -i PATH="$PATH" HOME="$EMPTY_HOME" LC_ALL=C TMPDIR="$SCAN/tmp" \
            "$GITLEAKS_BIN" "$sub" "${common[@]}" "$@" </dev/null) >"$report.out" 2>"$report.err" || rc=$?
    else
        (cd "$EMPTY_WD" && env -i PATH="$PATH" HOME="$EMPTY_HOME" LC_ALL=C TMPDIR="$SCAN/tmp" \
            "$GITLEAKS_BIN" "$sub" "${common[@]}" "$@" <"$input") >"$report.out" 2>"$report.err" || rc=$?
    fi
    printf '%s\n' "$rc"
}

# net_diff <out file> <git args...>: the added lines of a diff, with the file headers, for `gitleaks stdin`. Removed lines are
# dropped on purpose (a pull request that deletes an old secret must not fail on the deletion).
net_diff() {
    local out="$1" raw rc=0
    shift
    raw="$out.raw"
    "$@" >"$raw" || refuse 'git diff failed; the net diff could not be scanned'
    awk 'substr($0, 1, 1) != "-" && substr($0, 1, 2) != "@@" && substr($0, 1, 6) != "index " && substr($0, 1, 1) != "\\"' "$raw" >"$out" || rc=$?
    [ "$rc" -eq 0 ] || refuse 'the net diff could not be filtered'
}

FINDINGS_TOTAL=0
LISTED=0

# list_findings <label> <report>: print the rule, the file and the line of each finding. Nothing else of a finding.
list_findings() {
    local label="$1" report="$2" rows rule file line
    [ -f "$report" ] && [ ! -L "$report" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    # An empty File (the net-diff pass) gets a placeholder here: `read` with a tab IFS collapses an empty field and would shift the line number into the file slot (F-K-1).
    rows="$(jq -r '.[]? | [(.RuleID // "?" | tostring), (.File // "" | tostring | if . == "" then "(net diff)" else . end), (.StartLine // 0 | tostring)] | @tsv' "$report" 2>/dev/null)" || return 0
    while IFS=$'\t' read -r rule file line; do
        [ -n "$rule$file$line" ] || continue
        [[ $rule =~ $RE_RULE ]] || rule='?'
        [[ $line =~ ^[0-9]{1,9}$ ]] || line=0
        file="$(printf '%s' "$file" | LC_ALL=C tr -d '\000-\037\177`' | cut -c1-200)"
        [ -n "$file" ] || file='(net diff)'
        LISTED=$((LISTED + 1))
        if [ "$LISTED" -le "$MAX_LISTED" ]; then
            # shellcheck disable=SC2016  # the backticks are literal markdown fences around the file name
            printf '  %s: `%s` line %s (%s)\n' "$rule" "$file" "$line" "$label"
        fi
        if [ -n "${OKF_SCAN_RULES_FILE:-}" ]; then printf '%s\n' "$rule" >>"$OKF_SCAN_RULES_FILE"; fi
    done <<<"$rows"
}

# count_findings <report>: the number of findings in a report (0 when it is missing or unreadable).
count_findings() {
    local report="$1" n
    [ -f "$report" ] && [ ! -L "$report" ] || { printf '0\n'; return 0; }
    if command -v jq >/dev/null 2>&1; then
        n="$(jq -r 'if type == "array" then length else 0 end' "$report" 2>/dev/null)" || n=0
    else
        n="$(grep -c '"RuleID"' "$report" 2>/dev/null)" || n=0
    fi
    [[ $n =~ ^[0-9]{1,9}$ ]] || n=0
    printf '%s\n' "$n"
}

# operational_failure <label> <status> <report>: gitleaks failed in a way that is not a finding.
operational_failure() {
    local label="$1" rc="$2" report="$3" tail=""
    if [ -s "$report.err" ]; then
        tail="$(tail -n 1 "$report.err" | LC_ALL=C tr -cd '[:print:]' | cut -c1-200)"
    fi
    printf 'okf-secret-scan: gitleaks (%s) exited with status %s, which is not a result%s\n' "$label" "$rc" "${tail:+: $tail}" >&2
}

# ------------------------------------------------------------------ pr

cmd_pr() {
    local base="${OKF_BASE_SHA:-}" head="${OKF_HEAD_SHA:-}" mb mirror commits
    [[ $base =~ $RE_SHA ]] || refuse 'OKF_BASE_SHA is not a full commit id'
    [[ $head =~ $RE_SHA ]] || refuse 'OKF_HEAD_SHA is not a full commit id'
    git cat-file -e "${base}^{commit}" 2>/dev/null || refuse 'the base commit is not in this checkout'
    git cat-file -e "${head}^{commit}" 2>/dev/null || refuse 'the head commit is not in this checkout'
    mb="$(git merge-base "$base" "$head" 2>/dev/null)" || refuse 'the base and head commits have no merge base'
    [[ $mb =~ $RE_SHA ]] || refuse 'the merge base is not a commit id'
    commits="$(git rev-list --count "$mb..$head")" || refuse 'the commits of the pull request could not be counted'
    prepare_scan

    # A bare mirror has no working tree, so no `.gitleaksignore` or `.gitleaks.toml` of the pull request can be found.
    mirror="$RUNNER_TEMP/okf-scan.git"
    rm -rf "$mirror"
    git clone --quiet --bare --no-local . "$mirror" 2>"$SCAN/clone.err" || refuse 'the checkout could not be mirrored for the scan'
    git -C "$mirror" cat-file -e "${head}^{commit}" 2>/dev/null || refuse 'the head commit is not in the mirror'
    git -C "$mirror" cat-file -e "${mb}^{commit}" 2>/dev/null || refuse 'the merge base is not in the mirror'

    local diff="$SCAN/net.diff" rc_commits rc_diff
    net_diff "$diff" git diff -U0 --no-color --no-ext-diff --no-textconv "$mb" "$head"
    rc_commits="$(run_gitleaks "$SCAN/reports/commits.json" - git --log-opts="$mb..$head" "$mirror")"
    rc_diff="$(run_gitleaks "$SCAN/reports/diff.json" "$diff" stdin)"

    local found=0 failed=0
    case "$rc_commits" in 0) ;; "$LEAK_EXIT") found=1 ;; *)
        failed=1
        operational_failure commits "$rc_commits" "$SCAN/reports/commits.json"
        ;;
    esac
    case "$rc_diff" in 0) ;; "$LEAK_EXIT") found=1 ;; *)
        failed=1
        operational_failure 'net diff' "$rc_diff" "$SCAN/reports/diff.json"
        ;;
    esac
    if [ "$found" -eq 1 ]; then
        FINDINGS_TOTAL=$(($(count_findings "$SCAN/reports/commits.json") + $(count_findings "$SCAN/reports/diff.json")))
        printf 'okf-secret-scan: FAIL: %s possible secret(s) found; the values are never printed\n' "$FINDINGS_TOTAL"
        list_findings commits "$SCAN/reports/commits.json"
        list_findings 'net diff' "$SCAN/reports/diff.json"
        if [ "$LISTED" -gt "$MAX_LISTED" ]; then printf '  (%s more not listed)\n' "$((LISTED - MAX_LISTED))"; fi
        exit 1
    fi
    [ "$failed" -eq 0 ] || exit 2
    printf 'okf-secret-scan: no secrets found in %s commits and the net diff\n' "$commits"
}

# ------------------------------------------------------------------ patch

cmd_patch() {
    [ "$#" -eq 2 ] || refuse 'usage: secret-scan.sh patch <worktree> <base>'
    local wt="$1" base="$2" rc
    [ -d "$wt" ] || refuse 'the worktree is not a directory'
    [[ $base =~ $RE_SHA ]] || refuse 'the base is not a full commit id'
    git -C "$wt" cat-file -e "${base}^{commit}" 2>/dev/null || refuse 'the base commit is not in the worktree'
    prepare_scan
    local diff="$SCAN/net.diff"
    net_diff "$diff" git -C "$wt" diff --cached -U0 --no-color --no-ext-diff --no-textconv "$base"
    rc="$(run_gitleaks "$SCAN/reports/diff.json" "$diff" stdin)"
    case "$rc" in
        0) printf 'okf-secret-scan: no secrets found in the proposed change\n' ;;
        "$LEAK_EXIT")
            FINDINGS_TOTAL="$(count_findings "$SCAN/reports/diff.json")"
            printf 'okf-secret-scan: FAIL: %s possible secret(s) found; the values are never printed\n' "$FINDINGS_TOTAL"
            list_findings 'net diff' "$SCAN/reports/diff.json"
            if [ "$LISTED" -gt "$MAX_LISTED" ]; then printf '  (%s more not listed)\n' "$((LISTED - MAX_LISTED))"; fi
            exit 1
            ;;
        *)
            operational_failure 'net diff' "$rc" "$SCAN/reports/diff.json"
            exit 2
            ;;
    esac
}

case "${1:-}" in
    pr)
        [ "$#" -eq 1 ] || refuse 'usage: secret-scan.sh pr'
        cmd_pr
        ;;
    patch)
        shift
        cmd_patch "$@"
        ;;
    *) refuse 'usage: secret-scan.sh pr | patch <worktree> <base>' ;;
esac
