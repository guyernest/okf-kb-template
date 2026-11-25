#!/usr/bin/env bash
# Phase 214 (KTPL-01, D-09; threat T-214-28): the rules-skill drift test of the required check. The committed
# `.claude/skills/okf-kb-rules/` must equal what the PINNED engine renders with `okf-check skill --no-profile`.
#
# The render is profile-independent on purpose: `references/profile.md` is rendered for the agent at run time
# (plan 214-04) and is never committed, so a repository that has a runbook profile stays green across engine
# bumps. An extra committed file, `references/profile.md` included, is drift.
#
#   skill-drift.sh      run from the repository root (the checkout of the pull request)
#
# Env: OKF_ENGINE (the verified engine), RUNNER_TEMP (scratch space; the render goes to
# $RUNNER_TEMP/okf-skill).
# Exit: 0 the committed skill equals the render, 1 it differs (the differing relative names are printed between
# ::stop-commands:: fences), 2 the render could not be made.
#
# This script is run from the PR's BASE commit by okf-check.yml, never from the pull request it judges.
set -euo pipefail
export LC_ALL=C

SKILL_DIR=.claude/skills/okf-kb-rules
MAX_LISTED=50

fail() {
    printf 'okf-check: %s\n' "$1"
    exit 2
}

[ -n "${OKF_ENGINE:-}" ] && [ -x "${OKF_ENGINE:-}" ] || fail 'OKF_ENGINE is not an executable'
[ -n "${RUNNER_TEMP:-}" ] || fail 'RUNNER_TEMP is not set'

work="$RUNNER_TEMP/okf-skill"
rendered="$work/okf-kb-rules"
rm -rf "$work"
mkdir -p "$work"
if ! "$OKF_ENGINE" skill --out "$rendered" --repo-root . --no-profile >"$work/render.out" 2>"$work/render.err"; then
    fail 'the rules skill could not be rendered'
fi

# Entries that are neither a plain file nor a directory (a link, a device) are drift whatever they point at.
committed_list="$work/committed.txt"
rendered_list="$work/rendered.txt"
differing="$work/differing.txt"
: >"$differing"
if [ -d "$SKILL_DIR" ] && [ ! -L "$SKILL_DIR" ]; then
    (cd "$SKILL_DIR" && find . -mindepth 1 \( -type l -o \( ! -type f ! -type d \) \) | sort) | while IFS= read -r rel; do
        printf '%s\n' "$rel" >>"$differing"
    done
    (cd "$SKILL_DIR" && find . -mindepth 1 -type f | sort) >"$committed_list"
else
    : >"$committed_list"
fi
(cd "$rendered" && find . -mindepth 1 -type f | sort) >"$rendered_list"

# Missing from the commit, extra in the commit, and files whose bytes differ.
comm -13 "$committed_list" "$rendered_list" >>"$differing"
comm -23 "$committed_list" "$rendered_list" >>"$differing"
extra_profile=0
while IFS= read -r rel; do
    if [ -f "$rendered/$rel" ] && [ ! -L "$SKILL_DIR/$rel" ] && ! cmp -s "$SKILL_DIR/$rel" "$rendered/$rel"; then
        printf '%s\n' "$rel" >>"$differing"
    fi
    if [ "$rel" = ./references/profile.md ] && [ ! -f "$rendered/$rel" ]; then
        extra_profile=1
    fi
done <"$committed_list"

if [ -s "$differing" ]; then
    token="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    count="$(sort -u "$differing" | wc -l | tr -d ' ')"
    printf "okf-check: the rules skill differs from the pinned engine's output; regenerate it with okf-check skill --no-profile --out .claude/skills/okf-kb-rules\n"
    if [ "$extra_profile" -eq 1 ]; then
        printf 'references/profile.md is rendered for the agent at run time and is never committed\n'
    fi
    printf '::stop-commands::%s\n' "$token"
    sort -u "$differing" | head -n "$MAX_LISTED" | while IFS= read -r rel; do
        printf '%s\n' "$rel" | tr -d '\000-\037\177' | head -c 300
        printf '\n'
    done
    if [ "$count" -gt "$MAX_LISTED" ]; then
        printf '... and %s more\n' "$((count - MAX_LISTED))"
    fi
    printf '::%s::\n' "$token"
    exit 1
fi
printf 'okf-check: the committed rules skill equals the pinned engine'"'"'s output\n'
