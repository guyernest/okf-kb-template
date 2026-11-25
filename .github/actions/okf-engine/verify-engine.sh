#!/usr/bin/env bash
# Phase 212, KACT-02, D-02, D-04: prove the engine on disk is the pinned one, and own the
# fail-closed message a PR job prints when the engine was never seeded.
#
#   verify-engine.sh verify <binary> <expected-sha256> <expected-version> [--github-output]
#   verify-engine.sh hash   <binary> <expected-sha256> <expected-version> [arch]
#   verify-engine.sh miss   <version>
#
# `verify` runs on EVERY path (restore hit, seed hit, fresh seed): the sha256 must equal the
# lock's, then the binary is run with a scrubbed environment (no token, nothing inherited)
# and must report the pinned version. `hash` is the sha256 half alone (the seed path calls it
# so both paths print one refusal text). Exit 1 on any refusal.
set -euo pipefail

RE_VERSION='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
RE_HASH='^[0-9a-f]{64}$'
RE_VERSION_TAIL='^\(ruleset [0-9a-f]{12}, commit [0-9A-Za-z-]{1,40}, findings schema [0-9]+\)$'

fail() {
    printf '::error::%s\n' "$1"
    exit 1
}

map_arch() {
    case "$1" in
        x86_64) printf '%s\n' x86_64 ;;
        aarch64 | arm64) printf '%s\n' aarch64 ;;
        *) printf '%s\n' unsupported ;;
    esac
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

check_inputs() {
    local sha="$1" ver="$2"
    [[ $sha =~ $RE_HASH ]] || fail "invalid expected sha256"
    [[ $ver =~ $RE_VERSION ]] || fail "invalid engine version"
}

# check_hash <binary> <expected-sha256> <version> <arch>
check_hash() {
    local bin="$1" want="$2" ver="$3" arch="$4" got
    if [ -L "$bin" ] || [ ! -f "$bin" ]; then
        fail "okf-check binary must be a regular file for $ver/$arch; refusing to run"
    fi
    got="$(sha256_of "$bin")"
    if [ "$got" != "$want" ]; then
        fail "okf-check binary sha256 mismatch for $ver/$arch: expected $want, got $got; refusing to run"
    fi
}

cmd_verify() {
    [ "$#" -ge 3 ] || fail "usage: verify-engine.sh verify <binary> <expected-sha256> <expected-version> [--github-output]"
    local bin="$1" want="$2" ver="$3" want_output=0 arch
    shift 3
    if [ "${1:-}" = "--github-output" ]; then want_output=1; fi
    check_inputs "$want" "$ver"
    arch="$(map_arch "$(uname -m)")"
    check_hash "$bin" "$want" "$ver" "$arch"

    local home out first prefix rest
    home="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$home'" EXIT
    if ! out="$(env -i PATH="/usr/bin:/bin" HOME="$home" "$bin" --version 2>/dev/null)"; then
        fail "okf-check $ver/$arch did not run: --version failed; refusing to run"
    fi
    first="$(printf '%s\n' "$out" | head -n 1)"
    prefix="okf-check ${ver} "
    if [ "${first:0:${#prefix}}" != "$prefix" ]; then
        fail "okf-check reports a different version than the pinned $ver; refusing to run"
    fi
    rest="${first:${#prefix}}"
    [[ $rest =~ $RE_VERSION_TAIL ]] || fail "okf-check --version output is not in the expected format for $ver; refusing to run"

    printf 'okf-check %s verified (sha256 %s)\n' "$ver" "${want:0:12}"
    if [ "$want_output" -eq 1 ]; then
        [ -n "${GITHUB_OUTPUT:-}" ] || fail "GITHUB_OUTPUT is not set"
        case "$bin" in *$'\n'*) fail "binary path must be one line" ;; esac
        printf 'engine=%s\nversion_line=%s\n' "$bin" "$first" >>"$GITHUB_OUTPUT"
    fi
}

cmd_hash() {
    [ "$#" -ge 3 ] || fail "usage: verify-engine.sh hash <binary> <expected-sha256> <expected-version> [arch]"
    local arch="${4:-}"
    check_inputs "$2" "$3"
    [ -n "$arch" ] || arch="$(map_arch "$(uname -m)")"
    check_hash "$1" "$2" "$3" "$arch"
}

cmd_miss() {
    [ "$#" -eq 1 ] || fail "usage: verify-engine.sh miss <version>"
    [[ $1 =~ $RE_VERSION ]] || fail "invalid engine version"
    printf '::error::engine not seeded for %s: run the Seed workflow on the default branch\n' "$1"
    exit 1
}

case "${1:-}" in
    verify)
        shift
        cmd_verify "$@"
        ;;
    hash)
        shift
        cmd_hash "$@"
        ;;
    miss)
        shift
        cmd_miss "$@"
        ;;
    *) fail "usage: verify-engine.sh verify|hash|miss ..." ;;
esac
