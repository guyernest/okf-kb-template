#!/usr/bin/env bash
# Phase 212 (KACT-03, KPRV-01, KPRV-03; D-04, D-06, D-07, D-10, D-11): run the pinned okf-check
# engine against a pull request and stage everything the workflow publishes.
#
#   run-check.sh                         the PR check (env contract below); always exits 0 once the
#                                        inputs are valid, whatever the check or the preview did:
#                                        the verdict is the `okf-check verdict` step's job
#   run-check.sh --validate-bundle-path <p>   same rule as the OKF_BUNDLE_PATH input; exit 0 or 2
#   run-check.sh --append-summary <file>      append one summary part to $GITHUB_STEP_SUMMARY, or a
#                                             fixed notice when the part is absent, a symlink or
#                                             over 1,000,000 bytes; always exit 0
#
# Env (the only inputs): OKF_ENGINE, OKF_VERSION_LINE, OKF_PINNED_SHA256, OKF_BUNDLE_PATH,
# OKF_BASE_SHA, OKF_HEAD_SHA, OKF_PR_NUMBER, OKF_AUTHOR_LOGIN, OKF_AUTHOR_TYPE,
# OKF_DEFAULT_BRANCH, OKF_OUT_DIR, plus GITHUB_OUTPUT and GITHUB_STEP_SUMMARY.
#
# Trust: this script runs in a `pull_request` job that holds no secret and no write token.
# The engine's text never drives the runner: it is printed only between ::stop-commands:: and
# its token, and annotations come only from annotations.txt after a strict shape check (D-04).
# Rendering can never change the verdict: every directory the engine writes into exists before
# it runs, and a failed preview is a warning plus a fixed engine-free fallback.
set -euo pipefail
export LC_ALL=C

MARKER='<!-- okf-check-preview:v1 -->'
PART_NOTICE='This summary part could not be shown; the complete findings are findings.json in the okf-findings artifact.'
PART_LIMIT=1000000
MAINTAINERS_LIMIT=16384
MAINTAINERS_ENTRIES=200
MAX_PARTS=5
MAX_ANNOTATIONS=20
PRINT_LIMIT=262144
ANNOTATION_RE='^::(error|warning|notice)( [a-z]+=[^,:]*(,[a-z]+=[^,:]*)*)?::'

invalid() {
    printf '::error::okf-check: invalid input %s\n' "$1"
    exit 2
}

# validate_bundle_path <value> <name>: repository-relative, no `..` segment, an existing directory.
validate_bundle_path() {
    local p="$1" name="$2"
    local re='^[A-Za-z0-9._][A-Za-z0-9._/-]*$'
    [[ $p =~ $re ]] || invalid "$name"
    case "/$p/" in
        */../*) invalid "$name" ;;
    esac
    [ -d "$p" ] || invalid "$name"
}

append_summary() {
    local file="$1" target="${GITHUB_STEP_SUMMARY:-/dev/null}" size
    if [ -f "$file" ] && [ ! -L "$file" ]; then
        size="$(wc -c <"$file" | tr -d ' ')"
        if [ "$size" -le "$PART_LIMIT" ]; then
            cat "$file" >>"$target"
            return 0
        fi
    fi
    printf '%s\n' "$PART_NOTICE" >>"$target"
    return 0
}

case "${1:-}" in
    --validate-bundle-path)
        [ "$#" -eq 2 ] || invalid '--validate-bundle-path'
        validate_bundle_path "$2" 'OKF_BUNDLE_PATH'
        exit 0
        ;;
    --append-summary)
        [ "$#" -eq 2 ] || exit 0
        append_summary "$2"
        exit 0
        ;;
    '') ;;
    *)
        printf '::error::okf-check: unknown argument\n'
        exit 2
        ;;
esac

# ------------------------------------------------------------------ inputs

ENGINE="${OKF_ENGINE:-}"
VERSION_LINE="${OKF_VERSION_LINE:-}"
PINNED_SHA="${OKF_PINNED_SHA256:-}"
BUNDLE="${OKF_BUNDLE_PATH:-}"
BASE_SHA="${OKF_BASE_SHA:-}"
HEAD_SHA="${OKF_HEAD_SHA:-}"
PR_NUMBER="${OKF_PR_NUMBER:-}"
AUTHOR="${OKF_AUTHOR_LOGIN:-}"
AUTHOR_TYPE="${OKF_AUTHOR_TYPE:-}"
DEFAULT_BRANCH="${OKF_DEFAULT_BRANCH:-}"
OUT="${OKF_OUT_DIR:-}"
GH_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GH_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

sha_re='^[0-9a-f]{40}([0-9a-f]{24})?$'
num_re='^[1-9][0-9]{0,9}$'
login_core='[A-Za-z0-9][A-Za-z0-9_-]{0,38}'
login_re="^${login_core}(\\[bot\\])?\$"
branch_re='^[A-Za-z0-9._/-]{1,200}$'
sha256_re='^[0-9a-f]{64}$'

{ [ -f "$ENGINE" ] && [ -x "$ENGINE" ] && [ ! -L "$ENGINE" ]; } || invalid OKF_ENGINE
validate_bundle_path "$BUNDLE" OKF_BUNDLE_PATH
[[ $BASE_SHA =~ $sha_re ]] || invalid OKF_BASE_SHA
[[ $HEAD_SHA =~ $sha_re ]] || invalid OKF_HEAD_SHA
[[ $PR_NUMBER =~ $num_re ]] || invalid OKF_PR_NUMBER
[[ $AUTHOR =~ $login_re ]] || invalid OKF_AUTHOR_LOGIN
case "$AUTHOR_TYPE" in
    User | Bot | Organization | Mannequin) ;;
    *) invalid OKF_AUTHOR_TYPE ;;
esac
[[ $DEFAULT_BRANCH =~ $branch_re ]] || invalid OKF_DEFAULT_BRANCH
case "$DEFAULT_BRANCH" in
    *..*) invalid OKF_DEFAULT_BRANCH ;;
esac
[[ $PINNED_SHA =~ $sha256_re ]] || invalid OKF_PINNED_SHA256
# The version line comes from the verified binary; keep it to a plain, code-span-safe alphabet.
VERSION_LINE="$(printf '%s' "$VERSION_LINE" | head -n 1 | tr -cd 'A-Za-z0-9 ._:()+/=-' | cut -c 1-200)"
[ -n "$VERSION_LINE" ] || invalid OKF_VERSION_LINE
case "$OUT" in
    '' | *$'\n'*) invalid OKF_OUT_DIR ;;
esac
if [ -e "$OUT" ] || [ -L "$OUT" ]; then
    { [ -d "$OUT" ] && [ ! -L "$OUT" ] && [ -z "$(ls -A "$OUT")" ]; } || invalid OKF_OUT_DIR
fi

SHORT_HEAD="${HEAD_SHA:0:12}"
SHORT_BASE="${BASE_SHA:0:12}"
SHORT_PIN="${PINNED_SHA:0:12}"

# Every directory the engine writes into exists before it runs: `check --out` exits 2 when its
# parent is missing.
mkdir -p "$OUT/findings" "$OUT/rendered" "$OUT/preview-artifact" "$OUT/summary"
FINDINGS="$OUT/findings/findings.json"

# ------------------------------------------------------------------ trusted human review (D-10)

# Only a login listed in .okf/maintainers ON THE DEFAULT BRANCH (read from the object store,
# never from the working tree or the PR head) earns --trusted-human-review. A PR's own copy of
# the file, labels, comments, association and bots are never consulted.
TRUSTED=0
LIST_WARNING=""
maint_invalid() {
    LIST_WARNING=".okf/maintainers on the default branch is invalid ($1); trusted human review is off"
}

evaluate_maintainers() {
    local ref="refs/remotes/origin/$DEFAULT_BRANCH" commit entry mode size content line lineno entries
    local login_list_re="^${login_core}\$" author_lc entry_lc matched=0
    if ! commit="$(git rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null)"; then
        LIST_WARNING="the default branch ref $ref is missing; trusted human review is off"
        return 0
    fi
    entry="$(git ls-tree "$commit" -- .okf/maintainers 2>/dev/null || true)"
    [ -n "$entry" ] || return 0 # no list: nobody is trusted, nothing to warn about
    mode="${entry%% *}"
    case "$mode" in
        100644 | 100755) ;;
        *) maint_invalid 'not a regular file'; return 0 ;;
    esac
    size="$(git cat-file -s "$commit:.okf/maintainers" 2>/dev/null || echo 0)"
    if [ "$size" -gt "$MAINTAINERS_LIMIT" ]; then
        maint_invalid "larger than $MAINTAINERS_LIMIT bytes"
        return 0
    fi
    content="$(git show "$commit:.okf/maintainers" 2>/dev/null || true)"
    case "$content" in
        *$'\r'*) maint_invalid 'line 1: carriage return'; return 0 ;;
    esac
    author_lc="$(printf '%s' "$AUTHOR" | tr '[:upper:]' '[:lower:]')"
    lineno=0
    entries=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        case "$line" in
            '' | '#'*) continue ;;
        esac
        if [ -z "${line//[[:space:]]/}" ]; then
            continue
        fi
        if ! [[ $line =~ $login_list_re ]]; then
            maint_invalid "line $lineno"
            return 0
        fi
        entries=$((entries + 1))
        if [ "$entries" -gt "$MAINTAINERS_ENTRIES" ]; then
            maint_invalid "line $lineno: more than $MAINTAINERS_ENTRIES entries"
            return 0
        fi
        entry_lc="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
        if [ "$entry_lc" = "$author_lc" ]; then
            matched=1
        fi
    done <<<"$content"
    if [ "$matched" -eq 1 ] && [ "$AUTHOR_TYPE" = User ]; then
        case "$AUTHOR" in
            *'[bot]') ;;
            *) TRUSTED=1 ;;
        esac
    fi
    return 0
}
evaluate_maintainers

# ------------------------------------------------------------------ the check's own definition under review

# Count (never print) the changed files under .github/ and .okf/. Best effort: an unreachable
# base makes the count `unknown`; it never aborts the script.
CI_COUNT=unknown
if git cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
    if raw="$(git diff --name-only -z "$BASE_SHA" HEAD -- .github .okf 2>/dev/null | tr -cd '\0' | wc -c)"; then
        CI_COUNT=$((raw))
    fi
fi

# ------------------------------------------------------------------ summary header (D-04)

# shellcheck disable=SC2016 # the backticks are markdown code spans, not command substitution
{
    printf '## okf-check\n\n'
    printf 'Engine: `%s` (sha256 `%s`)\n\n' "$VERSION_LINE" "$SHORT_PIN"
    printf 'Pull request #%s: head `%s`, base `%s`.\n\n' "$PR_NUMBER" "$SHORT_HEAD" "$SHORT_BASE"
    if [ "$TRUSTED" -eq 1 ]; then
        printf 'Trusted human review is on for the PR author (listed in .okf/maintainers on the default branch).\n\n'
    fi
    if [ -n "$LIST_WARNING" ]; then
        printf 'Warning: %s.\n\n' "$LIST_WARNING"
    fi
    if [ "$CI_COUNT" = unknown ]; then
        printf 'Warning: the number of changed files under .github/ and .okf/ could not be determined (the base commit is not reachable in this checkout); the check'"'"'s own definition may be under review.\n\n'
    elif [ "$CI_COUNT" -gt 0 ]; then
        noun='files'
        if [ "$CI_COUNT" -eq 1 ]; then
            noun='file'
        fi
        printf 'Warning: this change edits %s %s under .github/ or .okf/; the check'"'"'s own definition is under review, so a code owner must review them.\n\n' "$CI_COUNT" "$noun"
    fi
} >>"$GH_SUMMARY"

# ------------------------------------------------------------------ printing engine text safely

# print_fenced <label> <file>...: print engine-produced text only between ::stop-commands::
# and its resume token. The token is 16 random bytes as hex, unguessable by the engine.
print_fenced() {
    local label="$1" token f
    shift
    token="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '%s\n' "okf-check: $label"
    printf '::stop-commands::%s\n' "$token"
    for f in "$@"; do
        if [ -f "$f" ]; then
            head -c "$PRINT_LIMIT" "$f"
            printf '\n'
        fi
    done
    printf '::%s::\n' "$token"
}

# ------------------------------------------------------------------ check

check_args=(check "$BUNDLE" --base "$BASE_SHA")
if [ "$TRUSTED" -eq 1 ]; then
    check_args+=(--trusted-human-review)
fi
check_args+=(--out "$FINDINGS")

set +e
"$ENGINE" "${check_args[@]}" >"$OUT/check.stdout" 2>"$OUT/check.stderr"
CHECK_EXIT=$?
set -e
print_fenced "check output (exit $CHECK_EXIT)" "$OUT/check.stdout" "$OUT/check.stderr"

# ------------------------------------------------------------------ preview (presentation only)

PREVIEW_OK=0
if { [ "$CHECK_EXIT" -eq 0 ] || [ "$CHECK_EXIT" -eq 1 ]; } && [ -f "$FINDINGS" ]; then
    set +e
    "$ENGINE" preview --findings "$FINDINGS" --bundle "$BUNDLE" --base "$BASE_SHA" --out-dir "$OUT/rendered" \
        >"$OUT/preview.stdout" 2>"$OUT/preview.stderr"
    PREVIEW_EXIT=$?
    set -e
    print_fenced "preview output (exit $PREVIEW_EXIT)" "$OUT/preview.stdout" "$OUT/preview.stderr"
    if [ "$PREVIEW_EXIT" -eq 0 ] \
        && [ -f "$OUT/rendered/comment.md" ] && [ ! -L "$OUT/rendered/comment.md" ] \
        && [ -f "$OUT/rendered/summary-1.md" ] && [ ! -L "$OUT/rendered/summary-1.md" ]; then
        PREVIEW_OK=1
    else
        printf '::warning::okf-check: the preview could not be rendered (exit %s); a fixed notice is used instead\n' "$PREVIEW_EXIT"
    fi
fi

# Annotations come only from annotations.txt and only when every line is one well-formed command.
if [ "$PREVIEW_OK" -eq 1 ] && [ -e "$OUT/rendered/annotations.txt" ]; then
    ann="$OUT/rendered/annotations.txt"
    ann_ok=1
    if [ ! -f "$ann" ] || [ -L "$ann" ]; then
        ann_ok=0
    else
        lines="$(grep -c '' "$ann" || true)"
        bad="$(grep -a -Evc -- "$ANNOTATION_RE" "$ann" || true)"
        cr="$(tr -cd '\r' <"$ann" | wc -c | tr -d ' ')"
        if [ "${lines:-0}" -gt "$MAX_ANNOTATIONS" ] || [ "${bad:-0}" -ne 0 ] || [ "${cr:-0}" -ne 0 ]; then
            ann_ok=0
        fi
    fi
    if [ "$ann_ok" -eq 1 ]; then
        cat "$ann"
    else
        printf '::warning::okf-check: the annotations were rejected (not a well-formed set of at most %s workflow commands)\n' "$MAX_ANNOTATIONS"
    fi
fi

# ------------------------------------------------------------------ fallbacks

if [ "$PREVIEW_OK" -ne 1 ]; then
    rm -rf "$OUT/rendered"
    mkdir -p "$OUT/rendered"
    # shellcheck disable=SC2016 # markdown code span
    {
        printf '%s\n' "$MARKER"
        printf '### okf-check preview\n\n'
        printf 'okf-check did not render a preview for commit `%s` (check exit %s). The check result is in the okf-check job; see its log.\n' "$SHORT_HEAD" "$CHECK_EXIT"
    } >"$OUT/rendered/comment.md"
    printf 'okf-check did not render a summary (check exit %s); see the job log and the okf-findings artifact.\n' "$CHECK_EXIT" >"$OUT/rendered/summary-1.md"
fi

# ------------------------------------------------------------------ stage the artifacts

cp "$OUT/rendered/comment.md" "$OUT/preview-artifact/comment.md"
printf '{"number":%s,"headSha":"%s"}\n' "$PR_NUMBER" "$HEAD_SHA" >"$OUT/preview-artifact/pr.json"

PARTS=0
k=1
while [ "$k" -le "$MAX_PARTS" ]; do
    src="$OUT/rendered/summary-$k.md"
    if [ -e "$src" ] || [ -L "$src" ]; then
        if [ -f "$src" ] && [ ! -L "$src" ]; then
            cp "$src" "$OUT/summary/summary-$k.md"
        else
            printf '%s\n' "$PART_NOTICE" >"$OUT/summary/summary-$k.md"
        fi
        cp "$OUT/summary/summary-$k.md" "$OUT/findings/summary-$k.md"
        PARTS=$k
    else
        break
    fi
    k=$((k + 1))
done

{
    printf 'check-exit=%s\n' "$CHECK_EXIT"
    printf 'preview-dir=%s\n' "$OUT/preview-artifact"
    printf 'findings-dir=%s\n' "$OUT/findings"
    printf 'summary-dir=%s\n' "$OUT/summary"
    printf 'summary-parts=%s\n' "$PARTS"
} >>"$GH_OUTPUT"

exit 0
