#!/usr/bin/env bash
# Phase 212, KACT-02, D-01: candidate-pin dispatch for the trusted seed workflow.
#
# A maintainer can seed a pin-bump PR's engine BEFORE merging it: dispatch okf-seed-engine on
# the default branch with `lock-ref` set to the PR branch (or `pull/<N>/head` for a fork). The
# seed job then reads that ref's `.okf/engine.lock` as DATA ONLY: one file, sparse checkout,
# never sourced or executed. This script validates the ref text and decides whether the
# candidate lock may be seeded.
#
#   candidate-lock.sh ref <input> [--github-output]
#       Rules, applied in order:
#         1. empty, longer than 200 characters, or starting with `-`        -> refuse
#         2. exactly pull/<n>/head with n >= 1 (no leading zero)             -> ref=refs/pull/<n>/head
#         3. any other input starting with pull/, refs/, heads/, tags/ or
#            remotes/                                                        -> refuse (reserved ref prefix)
#         4. a plain branch name (letters, digits, `.`, `_`, `-`, `/`), with no `..`,
#            no empty or trailing-dot component, and no component ending in `.lock`
#                                                                            -> ref=refs/heads/<name>
#         5. anything else                                                   -> refuse
#       The reserved prefixes are refused BEFORE the branch rule so that `refs/heads/x`,
#       `pull/0/head` and `pull/12/merge` can never pass as ordinary branch names.
#
#   candidate-lock.sh compare <default-lock> <candidate-lock> [--github-output]
#       Resolves both locks with the strict parser (../actions/okf-engine/lock.sh, which refuses
#       a non-regular or symlinked file) and requires an equal `release_repo`. A candidate that
#       points at another release repository is refused: land a release_repo change on the
#       default branch first. Prints `lock-file=<candidate path>`.
#
# Output goes to stdout, or is appended to $GITHUB_OUTPUT with --github-output, and ONLY on
# success. Errors are `::error::` lines on stdout. The release repository is never derived from
# the KB repository's own owner (KACT-04).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_SH="$HERE/../actions/okf-engine/lock.sh"

die() {
    printf '::error::candidate lock: %s\n' "$1"
    exit 1
}

emit() { # <name=value> <want_output>
    if [ "$2" -eq 1 ]; then
        [ -n "${GITHUB_OUTPUT:-}" ] || die "GITHUB_OUTPUT is not set"
        printf '%s\n' "$1" >>"$GITHUB_OUTPUT"
    else
        printf '%s\n' "$1"
    fi
}

parse_flags() { # sets WANT_OUTPUT from the remaining arguments
    WANT_OUTPUT=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --github-output) WANT_OUTPUT=1 ;;
            *) die "unknown option" ;;
        esac
        shift
    done
}

cmd_ref() {
    [ "$#" -ge 1 ] || die "usage: candidate-lock.sh ref <input> [--github-output]"
    local input="$1"
    shift
    parse_flags "$@"

    # 1. empty, too long, or option-like
    [ -n "$input" ] || die "lock-ref is empty"
    [ "${#input}" -le 200 ] || die "lock-ref is longer than 200 characters"
    case "$input" in -*) die "lock-ref must not start with '-'" ;; esac

    # 2. exactly pull/<n>/head
    if [[ $input =~ ^pull/([1-9][0-9]{0,9})/head$ ]]; then
        emit "ref=refs/pull/${BASH_REMATCH[1]}/head" "$WANT_OUTPUT"
        return 0
    fi

    # 3. reserved prefixes, before the ordinary branch rule
    case "$input" in
        pull/* | refs/* | heads/* | tags/* | remotes/*)
            die "reserved ref prefix: use a plain branch name or pull/<number>/head"
            ;;
    esac

    # 4. an ordinary branch name
    [[ $input =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || die "lock-ref is not a valid branch name"
    case "$input" in
        *..*) die "lock-ref must not contain '..'" ;;
        *.lock | *.lock/*) die "lock-ref must not end a component in '.lock'" ;;
        *. | *./*) die "lock-ref must not end a component in '.'" ;;
    esac
    emit "ref=refs/heads/$input" "$WANT_OUTPUT"
}

resolve_lock() { # <lock-file>; sets RESOLVED, or prints the parser's message and exits 1
    if ! RESOLVED="$(bash "$LOCK_SH" resolve "$1" 2>&1)"; then
        printf '%s\n' "$RESOLVED"
        exit 1
    fi
}

field_of() { # <field>; reads RESOLVED
    printf '%s\n' "$RESOLVED" | sed -n "s/^$1=//p" | head -n 1
}

cmd_compare() {
    [ "$#" -ge 2 ] || die "usage: candidate-lock.sh compare <default-lock> <candidate-lock> [--github-output]"
    local default_lock="$1" candidate_lock="$2"
    shift 2
    parse_flags "$@"

    local default_repo candidate_repo
    resolve_lock "$default_lock"
    default_repo="$(field_of release_repo)"
    resolve_lock "$candidate_lock"
    candidate_repo="$(field_of release_repo)"
    [ -n "$default_repo" ] && [ -n "$candidate_repo" ] || die "could not read release_repo"
    if [ "$default_repo" != "$candidate_repo" ]; then
        die "the candidate's release_repo differs from the default branch's; land release_repo changes on the default branch first"
    fi
    emit "lock-file=$candidate_lock" "$WANT_OUTPUT"
}

case "${1:-}" in
    ref)
        shift
        cmd_ref "$@"
        ;;
    compare)
        shift
        cmd_compare "$@"
        ;;
    *) die "usage: candidate-lock.sh ref <input> | compare <default-lock> <candidate-lock>" ;;
esac
