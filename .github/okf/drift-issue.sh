#!/usr/bin/env bash
# Phase 214 (KTPL-01; D-15, D-17; threat T-214-35): keep ONE open issue labelled `okf:drift`, created by the maintenance
# App, current with what the weekly `okf-doctor` run found.
#
#   drift-issue.sh      run by the doctor workflow after the doctor, whatever its outcome
#
#   doctor exit 1   drift or an unreadable item: update the open issue in place (its body is replaced), or open one
#   doctor exit 0   clean: when an issue is open, comment that the drift is gone and close it; otherwise do nothing
#   doctor exit 2   the doctor could not run (an unreachable repository or a usage error), or no exit code was recorded:
#                   the issue says so, with the run URL, instead of listing drift
#
# Only issues created by the App itself (`<slug>[bot]`, a Bot account) that carry the label are ever touched: an
# `okf:drift` issue a person opened is left alone, and a new one is opened beside it. Should several App-created ones be
# open, the lowest number is kept and the others are closed with a comment, so there is exactly one.
#
# The body is built from fixed sentences, the run URL and the doctor's own lines, and from nothing else: a doctor line is
# copied only when it matches `drift|cannot-read <item>[: <reason>]` in the plain alphabet (the whole line capped at 400
# characters; the doctor itself caps a reason at 300), plus the final `okf-doctor: <N> drift, <M> ok` line. Anything else in the report is dropped. The doctor
# prints names, never values. This script never calls a reviews or merge endpoint.
#
# Env: GH_TOKEN (the maintenance App token, `issues: write`), OKF_REPO, OKF_APP_SLUG, OKF_DOCTOR_EXIT (0, 1 or 2; empty means
# the doctor step recorded nothing), OKF_DOCTOR_REPORT (the report file), OKF_RUN_URL.
# shellcheck disable=SC2016  # backticks inside single quotes are literal markdown in the issue body, on purpose
set -euo pipefail
export LC_ALL=C

REPO_RE='^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$'
SLUG_RE='^[a-z0-9][a-z0-9-]{0,39}$'
URL_RE='^https://[A-Za-z0-9._/-]{1,255}$'
LINE_RE='^(drift|cannot-read) [A-Za-z0-9._:/@-]+(: [ -~]*)?$'
LINE_MAX=400
SUMMARY_RE='^okf-doctor: [0-9]{1,6} drift, [0-9]{1,6} ok$'
NUMBER_RE='^[1-9][0-9]{0,9}$'
LABEL='okf:drift'
TITLE='okf-doctor: repository settings drift'
MARKER='<!-- okf-doctor:v1 -->'
MAX_LINES=200

invalid() {
    printf 'drift-issue: %s\n' "$1" >&2
    exit 2
}

[ -n "${GH_TOKEN:-}" ] || invalid 'GH_TOKEN is not set'
[[ ${OKF_REPO:-} =~ $REPO_RE ]] || invalid 'OKF_REPO is not owner/name'
[[ ${OKF_APP_SLUG:-} =~ $SLUG_RE ]] || invalid 'OKF_APP_SLUG is not a plain slug'
[[ ${OKF_RUN_URL:-} =~ $URL_RE ]] || invalid 'OKF_RUN_URL is not an https URL'
case "${OKF_DOCTOR_EXIT:-}" in 0 | 1 | 2 | '') ;; *) invalid 'OKF_DOCTOR_EXIT is not 0, 1 or 2' ;; esac

REPO="$OKF_REPO"
RUN_URL="$OKF_RUN_URL"
BOT="${OKF_APP_SLUG}[bot]"
CODE="${OKF_DOCTOR_EXIT:-2}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The doctor's lines, filtered: drift lines and the one summary line, never anything else.
: >"$WORK/lines"
SUMMARY_LINE=''
if [ -n "${OKF_DOCTOR_REPORT:-}" ] && [ -f "$OKF_DOCTOR_REPORT" ] && [ ! -L "$OKF_DOCTOR_REPORT" ]; then
    count=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "${#line}" -le "$LINE_MAX" ] && [[ $line =~ $LINE_RE ]]; then
            count=$((count + 1))
            if [ "$count" -le "$MAX_LINES" ]; then printf '%s\n' "$line" >>"$WORK/lines"; fi
        elif [[ $line =~ $SUMMARY_RE ]]; then
            SUMMARY_LINE="$line"
        fi
    done <"$OKF_DOCTOR_REPORT"
    if [ "$count" -gt "$MAX_LINES" ]; then printf '(%s more not listed)\n' "$((count - MAX_LINES))" >>"$WORK/lines"; fi
fi

# The open issues this App created with the label (the creator filter is server side; the check on the account is ours).
LIST="repos/$REPO/issues?labels=okf%3Adrift&state=open&creator=${OKF_APP_SLUG}%5Bbot%5D&per_page=100"
gh api --paginate "$LIST" \
    --jq ".[] | select(.pull_request == null and .user.login == \"$BOT\" and .user.type == \"Bot\") | .number" >"$WORK/open" 2>"$WORK/list.err" ||
    {
        printf '::error::drift-issue: cannot list the open %s issues\n' "$LABEL"
        exit 1
    }
sort -n -u -o "$WORK/open" "$WORK/open"
FIRST=''
EXTRA=()
while IFS= read -r n; do
    [[ $n =~ $NUMBER_RE ]] || continue
    if [ -z "$FIRST" ]; then FIRST="$n"; else EXTRA+=("$n"); fi
done <"$WORK/open"

# close_extras: exactly one open issue remains.
close_extras() {
    local n
    for n in ${EXTRA[@]+"${EXTRA[@]}"}; do
        gh api -X POST "repos/$REPO/issues/$n/comments" -f "body=Closing: okf-doctor keeps a single drift issue (#$FIRST)." >/dev/null
        gh api -X PATCH "repos/$REPO/issues/$n" -f state=closed >/dev/null
    done
}

if [ "$CODE" = 0 ]; then
    if [ -n "$FIRST" ]; then
        gh api -X POST "repos/$REPO/issues/$FIRST/comments" -f "body=okf-doctor found no drift in $RUN_URL. Closing this issue; it opens again if drift returns." >/dev/null
        gh api -X PATCH "repos/$REPO/issues/$FIRST" -f state=closed >/dev/null
        close_extras
        printf 'drift-issue: no drift; closed issue #%s\n' "$FIRST"
    else
        printf 'drift-issue: no drift and no open issue\n'
    fi
    exit 0
fi

{
    printf '%s\n' "$MARKER"
    printf '## %s\n\n' "$TITLE"
    if [ "$CODE" = 1 ]; then
        printf 'The weekly `okf-doctor` run found settings that differ from what this repository expects. Fix them (the bootstrap script applies the same settings) and the next clean run closes this issue.\n\n'
        printf '```\n'
        cat "$WORK/lines"
        if [ -n "$SUMMARY_LINE" ]; then printf '%s\n' "$SUMMARY_LINE"; fi
        printf '```\n\n'
    else
        printf 'The weekly `okf-doctor` run could not complete: the repository could not be reached, the doctor was misused, or it recorded no result. No drift is reported; see the run for the reason.\n\n'
    fi
    printf 'Run: %s\n' "$RUN_URL"
} >"$WORK/body"

if [ -n "$FIRST" ]; then
    gh api -X PATCH "repos/$REPO/issues/$FIRST" -f "title=$TITLE" -f "body=$(cat "$WORK/body")" >/dev/null
    close_extras
    printf 'drift-issue: updated issue #%s\n' "$FIRST"
else
    number="$(gh api -X POST "repos/$REPO/issues" -f "title=$TITLE" -f "body=$(cat "$WORK/body")" -f "labels[]=$LABEL" --jq .number)"
    [[ $number =~ $NUMBER_RE ]] || {
        printf '::error::drift-issue: the issue response has no number\n'
        exit 1
    }
    printf 'drift-issue: opened issue #%s\n' "$number"
fi
