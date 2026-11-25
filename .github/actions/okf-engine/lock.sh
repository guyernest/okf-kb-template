#!/usr/bin/env bash
# Phase 212, KACT-02, D-04: resolve the pinned okf-check engine from `.okf/engine.lock`.
#
# The lock is PR-controlled text, so it is PARSED AS DATA; never sourced, evaluated or
# interpolated into a shell command. Strict allow-list of keys, anchored value patterns,
# no value reaches $GITHUB_OUTPUT before the whole file has validated, and values are never
# echoed back in an error message.
#
# Lock format (contract exported to every KB repo; one `key=value` per line, LF only,
# `#` comments and blank lines allowed, at most 4096 bytes, a regular non-symlink file):
#   version=<semver>
#   release_repo=<owner>/<repo>
#   x86_64.archive_sha256=<64 lowercase hex>    sha256 of the release tarball
#   x86_64.binary_sha256=<64 lowercase hex>     sha256 of the extracted `okf-check`
#   aarch64.archive_sha256=<64 lowercase hex>
#   aarch64.binary_sha256=<64 lowercase hex>
# Only the keys for the arch being resolved are required.
#
# Usage: lock.sh resolve <lock-file> [--arch x86_64|aarch64] [--github-output]
# Output: version, release_repo, arch, triple, archive_sha256, binary_sha256, key as
# `name=value` lines (stdout, or appended to $GITHUB_OUTPUT in one write with
# --github-output). The cache key is okf-engine-v1-<arch>-<version>-<binary_sha256>: pinned
# values only, so an unrelated edit to the lock never invalidates the entry.
set -euo pipefail

die() {
    printf '::error::engine lock: %s\n' "$1"
    exit 1
}

RE_VERSION='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
RE_REPO='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
RE_HASH='^[0-9a-f]{64}$'
RE_LINE='^([A-Za-z0-9_.-]{1,64})=(.*)$'
LOCK_MAX_BYTES=4096

map_arch() {
    case "$1" in
        x86_64) printf '%s\n' x86_64 ;;
        aarch64 | arm64) printf '%s\n' aarch64 ;;
        *) return 1 ;;
    esac
}

resolve() {
    local lock="" arch_arg="" want_output=0
    [ "$#" -ge 1 ] || die "usage: lock.sh resolve <lock-file> [--arch x86_64|aarch64] [--github-output]"
    lock="$1"
    shift
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --arch)
                [ "$#" -ge 2 ] || die "--arch needs a value"
                arch_arg="$2"
                shift 2
                ;;
            --github-output)
                want_output=1
                shift
                ;;
            *) die "unknown option" ;;
        esac
    done

    if [ -L "$lock" ] || { [ -e "$lock" ] && [ ! -f "$lock" ]; }; then
        die "engine lock must be a regular file"
    fi
    [ -f "$lock" ] || die "engine lock file not found"

    local size nul cr
    size="$(wc -c <"$lock" | tr -d ' ')"
    [ "$size" -le "$LOCK_MAX_BYTES" ] || die "file is larger than $LOCK_MAX_BYTES bytes"
    nul="$(LC_ALL=C tr -cd '\000' <"$lock" | wc -c | tr -d ' ')"
    [ "$nul" -eq 0 ] || die "file contains a NUL byte"
    cr="$(LC_ALL=C tr -cd '\r' <"$lock" | wc -c | tr -d ' ')"
    [ "$cr" -eq 0 ] || die "file must use LF line endings"

    local s_version=0 s_repo=0 s_xa=0 s_xb=0 s_aa=0 s_ab=0
    local v_version="" v_repo="" v_xa="" v_xb="" v_aa="" v_ab=""
    local line key val lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        [ -z "$line" ] && continue
        case "$line" in '#'*) continue ;; esac
        if ! [[ $line =~ $RE_LINE ]]; then
            die "malformed line $lineno"
        fi
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        [ -n "$val" ] || die "empty value for '$key' on line $lineno"
        case "$key" in
            version)
                [ "$s_version" -eq 0 ] || die "duplicate key '$key' on line $lineno"
                [[ $val =~ $RE_VERSION ]] || die "invalid version on line $lineno"
                s_version=1
                v_version="$val"
                ;;
            release_repo)
                [ "$s_repo" -eq 0 ] || die "duplicate key '$key' on line $lineno"
                [[ $val =~ $RE_REPO ]] || die "invalid release_repo on line $lineno"
                case "${val%%/*}" in . | ..) die "invalid release_repo on line $lineno" ;; esac
                case "${val#*/}" in . | ..) die "invalid release_repo on line $lineno" ;; esac
                s_repo=1
                v_repo="$val"
                ;;
            x86_64.archive_sha256)
                [ "$s_xa" -eq 0 ] || die "duplicate key '$key' on line $lineno"
                [[ $val =~ $RE_HASH ]] || die "invalid $key on line $lineno"
                s_xa=1
                v_xa="$val"
                ;;
            x86_64.binary_sha256)
                [ "$s_xb" -eq 0 ] || die "duplicate key '$key' on line $lineno"
                [[ $val =~ $RE_HASH ]] || die "invalid $key on line $lineno"
                s_xb=1
                v_xb="$val"
                ;;
            aarch64.archive_sha256)
                [ "$s_aa" -eq 0 ] || die "duplicate key '$key' on line $lineno"
                [[ $val =~ $RE_HASH ]] || die "invalid $key on line $lineno"
                s_aa=1
                v_aa="$val"
                ;;
            aarch64.binary_sha256)
                [ "$s_ab" -eq 0 ] || die "duplicate key '$key' on line $lineno"
                [[ $val =~ $RE_HASH ]] || die "invalid $key on line $lineno"
                s_ab=1
                v_ab="$val"
                ;;
            *) die "unknown key '$key' on line $lineno" ;;
        esac
    done <"$lock"

    local arch triple archive_sha binary_sha
    if [ -n "$arch_arg" ]; then
        arch="$(map_arch "$arch_arg")" || die "unsupported architecture"
    else
        arch="$(map_arch "$(uname -m)")" || die "unsupported architecture"
    fi
    [ "$s_version" -eq 1 ] || die "missing key version"
    [ "$s_repo" -eq 1 ] || die "missing key release_repo"
    case "$arch" in
        x86_64)
            [ "$s_xa" -eq 1 ] || die "missing key x86_64.archive_sha256"
            [ "$s_xb" -eq 1 ] || die "missing key x86_64.binary_sha256"
            triple="x86_64-unknown-linux-musl"
            archive_sha="$v_xa"
            binary_sha="$v_xb"
            ;;
        *)
            [ "$s_aa" -eq 1 ] || die "missing key aarch64.archive_sha256"
            [ "$s_ab" -eq 1 ] || die "missing key aarch64.binary_sha256"
            triple="aarch64-unknown-linux-musl"
            archive_sha="$v_aa"
            binary_sha="$v_ab"
            ;;
    esac

    local out
    out="$(printf 'version=%s\nrelease_repo=%s\narch=%s\ntriple=%s\narchive_sha256=%s\nbinary_sha256=%s\nkey=okf-engine-v1-%s-%s-%s\n' \
        "$v_version" "$v_repo" "$arch" "$triple" "$archive_sha" "$binary_sha" "$arch" "$v_version" "$binary_sha")"
    if [ "$want_output" -eq 1 ]; then
        [ -n "${GITHUB_OUTPUT:-}" ] || die "GITHUB_OUTPUT is not set"
        printf '%s\n' "$out" >>"$GITHUB_OUTPUT"
    else
        printf '%s\n' "$out"
    fi
}

case "${1:-}" in
    resolve)
        shift
        resolve "$@"
        ;;
    *) die "usage: lock.sh resolve <lock-file> [--arch x86_64|aarch64] [--github-output]" ;;
esac
