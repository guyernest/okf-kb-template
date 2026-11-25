#!/usr/bin/env bash
# Phase 212, KACT-02, D-01, D-03, D-04: the trusted seed download of the pinned okf-check engine.
#
# Reads only environment variables set by the action (all re-validated here, so the script is
# safe to run on its own): OKF_VERSION, OKF_RELEASE_REPO, OKF_ARCH, OKF_TRIPLE,
# OKF_ARCHIVE_SHA256, OKF_BINARY_SHA256, optional OKF_CACHE_DIR (default
# $HOME/.cache/okf-engine) and GH_TOKEN (used only by `gh`, never printed).
#
# Order: download with the read token -> archive sha256 against the lock -> `checksums.txt`
# cross-check (the lock is authoritative; a disagreement refuses) -> the archive holds exactly
# one regular-file member `okf-check` -> extract into a fresh directory and require a regular,
# non-symlink, single-link file -> binary sha256 -> install into the cache directory. The
# token-free `--version` check is the action's verify step, which runs before the cache save,
# so nothing is ever cached unverified. Nothing here turns on shell tracing: the token must
# never reach a log.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RE_VERSION='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
RE_REPO='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
RE_HASH='^[0-9a-f]{64}$'

fail() {
    printf '::error::%s\n' "$1"
    exit 1
}

: "${OKF_VERSION:?OKF_VERSION is required}"
: "${OKF_RELEASE_REPO:?OKF_RELEASE_REPO is required}"
: "${OKF_ARCH:?OKF_ARCH is required}"
: "${OKF_TRIPLE:?OKF_TRIPLE is required}"
: "${OKF_ARCHIVE_SHA256:?OKF_ARCHIVE_SHA256 is required}"
: "${OKF_BINARY_SHA256:?OKF_BINARY_SHA256 is required}"
CACHE_DIR="${OKF_CACHE_DIR:-$HOME/.cache/okf-engine}"

[[ $OKF_VERSION =~ $RE_VERSION ]] || fail "seed: invalid engine version"
[[ $OKF_RELEASE_REPO =~ $RE_REPO ]] || fail "seed: invalid release repository"
case "${OKF_RELEASE_REPO%%/*}" in . | ..) fail "seed: invalid release repository" ;; esac
case "${OKF_RELEASE_REPO#*/}" in . | ..) fail "seed: invalid release repository" ;; esac
[[ $OKF_ARCHIVE_SHA256 =~ $RE_HASH ]] || fail "seed: invalid archive sha256"
[[ $OKF_BINARY_SHA256 =~ $RE_HASH ]] || fail "seed: invalid binary sha256"
case "$OKF_ARCH/$OKF_TRIPLE" in
    x86_64/x86_64-unknown-linux-musl | aarch64/aarch64-unknown-linux-musl) ;;
    *) fail "seed: unsupported architecture" ;;
esac

TAG="okf-check-v${OKF_VERSION}"
ARCHIVE="okf-check-${OKF_VERSION}-${OKF_TRIPLE}.tar.gz"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

link_count() {
    stat -c %h "$1" 2>/dev/null || stat -f %l "$1"
}

[ -n "${GH_TOKEN:-}" ] || fail "seed: no read token was provided; set ENGINE_RELEASE_TOKEN (Contents: read on $OKF_RELEASE_REPO, not expired)"

work="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$work'" EXIT

# 1. download (gh's stderr is captured, not echoed: it may name URLs)
if ! gh release download "$TAG" --repo "$OKF_RELEASE_REPO" \
    --pattern "$ARCHIVE" --pattern checksums.txt --dir "$work" 2>"$work/gh.err"; then
    fail "seed: could not download $TAG from $OKF_RELEASE_REPO; check that ENGINE_RELEASE_TOKEN (Contents: read on $OKF_RELEASE_REPO) is set and not expired"
fi
[ -f "$work/$ARCHIVE" ] || fail "seed: release $TAG in $OKF_RELEASE_REPO has no asset $ARCHIVE"
[ -f "$work/checksums.txt" ] || fail "seed: release $TAG in $OKF_RELEASE_REPO has no checksums.txt"

# 2. archive hash against the lock
got_archive="$(sha256_of "$work/$ARCHIVE")"
if [ "$got_archive" != "$OKF_ARCHIVE_SHA256" ]; then
    fail "archive sha256 mismatch for ${OKF_VERSION}/${OKF_ARCH}: expected $OKF_ARCHIVE_SHA256, got $got_archive; refusing to run"
fi

# 3. checksums.txt is a second source; the lock is authoritative
if ! grep -qF -- "  $ARCHIVE" "$work/checksums.txt"; then
    fail "checksums.txt disagrees with .okf/engine.lock: it has no entry for $ARCHIVE"
fi
if ! grep -qxF -- "${OKF_ARCHIVE_SHA256}  ${ARCHIVE}" "$work/checksums.txt"; then
    fail "checksums.txt disagrees with .okf/engine.lock: the entry for $ARCHIVE differs from the pinned archive sha256"
fi

# 4. exactly one member, a regular file named okf-check
members="$(tar -tzf "$work/$ARCHIVE")" || fail "seed: the archive cannot be listed"
if [ "$members" != "okf-check" ]; then
    fail "unexpected archive member: the archive must hold exactly one member named okf-check"
fi
verbose="$(tar -tvzf "$work/$ARCHIVE")" || fail "seed: the archive cannot be listed"
if [ "$(printf '%s\n' "$verbose" | wc -l | tr -d ' ')" -ne 1 ] || [ "${verbose:0:1}" != "-" ]; then
    fail "archive member okf-check is not a regular file"
fi

# 5. extract into a fresh directory; require a regular, non-symlink, single-link file
extract="$work/extract"
mkdir "$extract"
tar -xzf "$work/$ARCHIVE" -C "$extract" --no-same-owner okf-check
bin="$extract/okf-check"
if [ ! -f "$bin" ] || [ -L "$bin" ] || [ "$(link_count "$bin")" != "1" ] || [ "$(find "$extract" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -ne 1 ]; then
    fail "archive member okf-check is not a regular file"
fi

# 6. binary hash: one refusal text for the seed and the restore paths
bash "$HERE/verify-engine.sh" hash "$bin" "$OKF_BINARY_SHA256" "$OKF_VERSION" "$OKF_ARCH"

# 7. only now does anything reach the cache directory
mkdir -p "$CACHE_DIR"
install -m 0755 "$bin" "$CACHE_DIR/okf-check"
printf 'okf-check %s (%s) downloaded and verified\n' "$OKF_VERSION" "$OKF_ARCH"
