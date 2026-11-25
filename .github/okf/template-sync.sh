#!/usr/bin/env bash
# Phase 214 (KTPL-06; D-12, D-17, D-18; threats T-214-32, T-214-33, T-214-34): the template sync. A repository created
# from an exported template pulls later template and action updates through ONE reviewable pull request that
# overwrites exactly the files `.okf/template-manifest` lists and nothing else.
#
#   template-sync.sh      run from the root of the default-branch checkout (fetch-depth 0, no stored credentials)
#
# What it does, in order. Everything up to "write" is read-only; a refusal pushes nothing and deletes nothing.
#   1. Read `.okf/template-version` of the default branch: `repo=` and `tag=` (and `commit=`). `tag=unreleased` is a
#      copy that was never exported: refuse.
#   2. Pick the target tag: the validated input (OKF_TAG_INPUT), else the highest `okf-kb-template-v<semver>` tag of
#      the template repository by version order. Clone it shallow and ANONYMOUSLY (D-18: the template is public) into a
#      new temporary directory and record the peeled commit sha.
#   3. Read and validate BOTH manifests with the same rules: this tag's (the files to copy) and the repository's own
#      previous one on the default branch (the files that may be deleted). A line is a plain relative path or the one
#      special line `merge-codeowners .github/CODEOWNERS`. A path that is absolute, has a dot or dot-dot component, fails
#      the path alphabet, or is on the deny-list refuses the WHOLE sync. The deny-list is in THIS script, not in the
#      manifest: the bundle root, `.okf/maintainers`, `.okf/publish.toml`, `.okf/profile.json`, `.okf/agent.toml`,
#      `.okf/template-version`, `README.md`, the rules skill's run-time profile render, every CODEOWNERS location
#      (it is merged, never copied), and `.git`. Each entry of the new manifest must be a regular file in the template
#      (git mode 100644 or 100755); a symbolic link, submodule or directory refuses.
#   4. For every destination (copied, deleted, CODEOWNERS, the version file) refuse when the path or any parent
#      component is a symbolic link or a submodule in the repository, or the path itself is a directory.
#   5. A changed `.okf/engine.lock` must keep its `release_repo` (candidate-lock.sh compare; land a release_repo change
#      on the default branch first, CI.md section 5). `minimum_engine` of `.okf/publish.toml` is never touched.
#   6. Write: `git checkout -B okf-template-sync <default tip>`, copy each entry (the executable bit follows the
#      template), delete the old-manifest entries the new one dropped, merge CODEOWNERS (every existing line kept; a
#      template rule the repository lacks is appended with the owners of the repository's own `/.github/` rule), write
#      `.okf/template-version`, stage only those paths. Nothing staged is outcome `up-to-date` and nothing is opened.
#   7. Commit as the App bot with the trailers `Okf-Template-Tag` and `Okf-Template-Commit`. When the remote
#      `okf-template-sync` already holds exactly this tree directly on top of the current default tip, push NOTHING
#      (outcome `unchanged`: a re-push would dismiss approvals and re-run CI); otherwise regenerate the branch with
#      `--force-with-lease` (commits a person pushed to it are replaced, the PR body says so). Create or edit the one
#      pull request. This script never calls a reviews or merge endpoint.
#
# Output (GITHUB_OUTPUT): outcome (up-to-date | unchanged | pushed | refused), lock-changed (true|false), head-sha.
# Exit: 0 done, 1 refused or a step failed, 2 an invalid input.
#
# Env: GH_TOKEN (the maintenance App installation token), OKF_REPO, OKF_DEFAULT_BRANCH, OKF_ENGINE (the verified engine,
# only for the bundle root), OKF_TAG_INPUT (may be empty), OKF_APP_SLUG. Test seam: OKF_TEMPLATE_URL_BASE replaces
# `https://github.com` for the TEMPLATE repository only, and only when OKF_TEMPLATE_SYNC_TEST=1.
# shellcheck disable=SC2016  # backticks inside single quotes are literal markdown in the pull request body, on purpose
set -euo pipefail
export LC_ALL=C
export GIT_TERMINAL_PROMPT=0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE_SCRIPT="$HERE/../actions/okf-check/diff-scope.sh"
CANDIDATE_SCRIPT="$HERE/candidate-lock.sh"

REPO_RE='^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$'
BRANCH_RE='^[A-Za-z0-9._/-]{1,200}$'
SLUG_RE='^[a-z0-9][a-z0-9-]{0,39}$'
TAG_RE='^okf-kb-template-v[0-9]+\.[0-9]+\.[0-9]+$'
SHA_RE='^[0-9a-f]{40}$'
PATH_RE='^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'
SYNC_BRANCH='okf-template-sync'
MARKER='<!-- okf-template-sync:v1 -->'
MERGE_LINE='merge-codeowners .github/CODEOWNERS'
PUSH_KEY='http.https://github.com/.extraheader'
MAX_ENTRIES=1000
MAX_LISTED=100
MANIFEST_PATH='.okf/template-manifest'
VERSION_PATH='.okf/template-version'
LOCK_PATH='.okf/engine.lock'
CODEOWNERS_PATH='.github/CODEOWNERS'

emit() { printf '%s\n' "$1" >>"${GITHUB_OUTPUT:-/dev/null}"; }

invalid() {
    printf 'okf-template-sync: %s\n' "$1" >&2
    exit 2
}

refuse() {
    printf '::error::okf-template-sync: %s\n' "$1"
    emit 'outcome=refused'
    exit 1
}

# safe_path <path>: the path when it is in the plain alphabet, else a fixed placeholder (an entry is untrusted text).
safe_path() {
    if [[ $1 =~ $PATH_RE ]]; then printf '%s' "$1"; else printf '<path withheld>'; fi
}

# ------------------------------------------------------------------ inputs

[ -n "${GH_TOKEN:-}" ] || invalid 'GH_TOKEN is not set'
[[ ${OKF_REPO:-} =~ $REPO_RE ]] || invalid 'OKF_REPO is not owner/name'
[[ ${OKF_DEFAULT_BRANCH:-} =~ $BRANCH_RE ]] || invalid 'OKF_DEFAULT_BRANCH is not a plain branch name'
case "$OKF_DEFAULT_BRANCH" in *..*) invalid 'OKF_DEFAULT_BRANCH has a dot dot' ;; esac
[[ ${OKF_APP_SLUG:-} =~ $SLUG_RE ]] || invalid 'OKF_APP_SLUG is not a plain slug'
{ [ -n "${OKF_ENGINE:-}" ] && [ -f "$OKF_ENGINE" ] && [ -x "$OKF_ENGINE" ] && [ ! -L "$OKF_ENGINE" ]; } || invalid 'OKF_ENGINE is not a regular executable'
TAG_INPUT="${OKF_TAG_INPUT:-}"
if [ -n "$TAG_INPUT" ] && [[ ! $TAG_INPUT =~ $TAG_RE ]]; then
    invalid 'the tag input must look like okf-kb-template-v<major>.<minor>.<patch>'
fi

REPO="$OKF_REPO"
DEFAULT_BRANCH="$OKF_DEFAULT_BRANCH"
OWNER="${REPO%%/*}"
TEMPLATE_BASE='https://github.com'
if [ "${OKF_TEMPLATE_SYNC_TEST:-}" = 1 ] && [ -n "${OKF_TEMPLATE_URL_BASE:-}" ]; then
    TEMPLATE_BASE="$OKF_TEMPLATE_URL_BASE"
fi
KB_URL="https://github.com/$REPO.git"

git rev-parse --git-dir >/dev/null 2>&1 || invalid 'not run inside a git checkout'
BASE_SHA="$(git rev-parse --verify --quiet "refs/remotes/origin/$DEFAULT_BRANCH^{commit}")" || invalid "no remote-tracking ref origin/$DEFAULT_BRANCH (the checkout needs fetch-depth 0)"
[[ $BASE_SHA =~ $SHA_RE ]] || invalid 'the default branch tip is not a full commit id'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
TPL="$WORK/template"

# anon_git: git with no token and no credential helper (the template is public, D-18).
anon_git() { env -u GH_TOKEN -u GITHUB_TOKEN git -c credential.helper= "$@"; }

# auth_git: git with the App token in this ONE command's environment (never argv, never .git/config).
auth_git() {
    local basic
    basic="$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="$PUSH_KEY" GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $basic" git "$@"
}

# ------------------------------------------------------------------ 1. where this repository came from

entry="$(git ls-tree "$BASE_SHA" -- "$VERSION_PATH")"
case "$entry" in
    '100644 blob '*) ;;
    *) refuse 'this repository was not created from an exported template (.okf/template-version is missing)' ;;
esac
git cat-file blob "$BASE_SHA:$VERSION_PATH" >"$WORK/template-version"
cur_repo='' cur_tag='' cur_commit=''
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        '' | '#'*) continue ;;
        repo=*) cur_repo="${line#repo=}" ;;
        tag=*) cur_tag="${line#tag=}" ;;
        commit=*) cur_commit="${line#commit=}" ;;
        *) refuse '.okf/template-version has a line that is not repo=, tag= or commit=' ;;
    esac
done <"$WORK/template-version"
if [ "$cur_tag" = unreleased ]; then
    refuse 'this repository was not created from an exported template (tag=unreleased)'
fi
[[ $cur_repo =~ $REPO_RE ]] || refuse '.okf/template-version has no valid repo='
[[ $cur_tag =~ $TAG_RE ]] || refuse '.okf/template-version has no valid tag='
if [ -n "$cur_commit" ] && [[ ! $cur_commit =~ $SHA_RE ]]; then refuse '.okf/template-version has an invalid commit='; fi

# ------------------------------------------------------------------ 2. the target tag, cloned anonymously

TEMPLATE_URL="$TEMPLATE_BASE/$cur_repo.git"
if [ -n "$TAG_INPUT" ]; then
    TARGET_TAG="$TAG_INPUT"
else
    anon_git ls-remote --tags --refs "$TEMPLATE_URL" >"$WORK/tags" 2>"$WORK/ls-remote.err" || refuse "cannot list the tags of $cur_repo"
    newest="$(sed -n 's#^[0-9a-f]\{40\}[[:space:]]refs/tags/okf-kb-template-v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$#\1#p' "$WORK/tags" |
        sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
    [ -n "$newest" ] || refuse "$cur_repo has no okf-kb-template-v<semver> tag"
    TARGET_TAG="okf-kb-template-v$newest"
fi
[[ $TARGET_TAG =~ $TAG_RE ]] || invalid 'the chosen tag is not a template tag'
anon_git clone --quiet --depth 1 --branch "$TARGET_TAG" -c advice.detachedHead=false -- "$TEMPLATE_URL" "$TPL" 2>"$WORK/clone.err" || refuse "cannot fetch $TARGET_TAG of $cur_repo"
TPL_COMMIT="$(git -C "$TPL" rev-parse HEAD)"
[[ $TPL_COMMIT =~ $SHA_RE ]] || refuse 'the template tag does not resolve to a commit'

# ------------------------------------------------------------------ 3. the manifests

BUNDLE_ROOT="$(OKF_ENGINE="$OKF_ENGINE" bash "$SCOPE_SCRIPT" bundle-root "$BASE_SHA" 2>"$WORK/bundle-root.err")" || refuse 'cannot read the bundle root of the default branch (.okf/publish.toml)'
[[ $BUNDLE_ROOT =~ $PATH_RE ]] || refuse 'the bundle root is not a plain path'
BUNDLE_ROOT_LC="$(printf '%s' "$BUNDLE_ROOT" | tr '[:upper:]' '[:lower:]')"

# denied_reason <path>: prints a reason and returns 0 when the path must never be written or deleted by the sync.
denied_reason() {
    local lc
    lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$lc" in
        .git | .git/* | */.git | */.git/*)
            printf 'the .git directory'
            return 0
            ;;
        .gitmodules)
            printf 'submodule configuration'
            return 0
            ;;
        .okf/maintainers | .okf/publish.toml | .okf/profile.json | .okf/agent.toml | .okf/template-version | readme.md)
            printf 'a repository-owned file'
            return 0
            ;;
        .claude/skills/okf-kb-rules/references/profile.md)
            printf 'a run-time render, not a template file'
            return 0
            ;;
        .github/codeowners | codeowners | docs/codeowners)
            printf 'CODEOWNERS is merged by its own manifest line, never copied'
            return 0
            ;;
    esac
    if [ "$lc" = "$BUNDLE_ROOT_LC" ] || [ "${lc#"$BUNDLE_ROOT_LC"/}" != "$lc" ]; then
        printf 'the knowledge bundle'
        return 0
    fi
    return 1
}

# load_manifest <content-file> <label> <entries-out> <merge-out>: validate one manifest. A refusal ends the run.
load_manifest() {
    local file="$1" label="$2" entries="$3" merge="$4" line lineno=0 reason p count
    : >"$entries"
    printf 'no\n' >"$merge"
    [ "$(wc -c <"$file" | tr -d ' ')" -le 65536 ] || refuse "the $label manifest is larger than 64 KiB"
    if [ -n "$(tr -d '\n\t -~' <"$file")" ]; then
        refuse "the $label manifest has a control character or a non-ASCII byte"
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        case "$line" in '' | '#'*) continue ;; esac
        if [ "$line" = "$MERGE_LINE" ]; then
            printf 'yes\n' >"$merge"
            continue
        fi
        [[ $line =~ $PATH_RE ]] || refuse "the $label manifest line $lineno is not a plain relative path"
        case "/$line/" in */./* | */../*) refuse "the $label manifest line $lineno has a dot or dot-dot component" ;; esac
        case "$line" in -*) refuse "the $label manifest line $lineno starts with a dash" ;; esac
        if reason="$(denied_reason "$line")"; then
            refuse "the $label manifest names a protected path, $(safe_path "$line") ($reason)"
        fi
        p="$line"
        printf '%s\n' "$p" >>"$entries"
    done <"$file"
    sort -u -o "$entries" "$entries"
    count="$(wc -l <"$entries" | tr -d ' ')"
    [ "$count" -le "$MAX_ENTRIES" ] || refuse "the $label manifest lists more than $MAX_ENTRIES files"
}

entry="$(git -C "$TPL" ls-tree HEAD -- "$MANIFEST_PATH")"
case "$entry" in
    '100644 blob '* | '100755 blob '*) ;;
    *) refuse "the template $TARGET_TAG has no $MANIFEST_PATH" ;;
esac
git -C "$TPL" cat-file blob "HEAD:$MANIFEST_PATH" >"$WORK/new-manifest"
load_manifest "$WORK/new-manifest" new "$WORK/new-entries" "$WORK/new-merge"

entry="$(git ls-tree "$BASE_SHA" -- "$MANIFEST_PATH")"
if [ -z "$entry" ]; then
    : >"$WORK/old-entries"
    printf 'no\n' >"$WORK/old-merge"
else
    case "$entry" in
        '100644 blob '* | '100755 blob '*) ;;
        *) refuse "the repository's previous $MANIFEST_PATH is not a regular file" ;;
    esac
    git cat-file blob "$BASE_SHA:$MANIFEST_PATH" >"$WORK/old-manifest"
    load_manifest "$WORK/old-manifest" previous "$WORK/old-entries" "$WORK/old-merge"
fi

# The new manifest itself is always written, listed or not: the next sync reads it as the previous manifest.
printf '%s\n' "$MANIFEST_PATH" >>"$WORK/new-entries"
sort -u -o "$WORK/new-entries" "$WORK/new-entries"

# Every entry of the new manifest is a regular file of the template: record its mode.
: >"$WORK/new-entries.tsv"
while IFS= read -r p; do
    rec="$(git -C "$TPL" ls-tree HEAD -- "$p")"
    mode="${rec%% *}"
    rec_path="${rec#*$'\t'}"
    if [ -z "$rec" ] || [ "$rec_path" != "$p" ]; then
        refuse "the manifest lists $(safe_path "$p"), which is not in the template"
    fi
    case "$mode" in
        100644 | 100755) printf '%s\t%s\n' "$mode" "$p" >>"$WORK/new-entries.tsv" ;;
        120000) refuse "the template has a symbolic link at $(safe_path "$p")" ;;
        160000) refuse "the template has a submodule at $(safe_path "$p")" ;;
        *) refuse "the manifest lists $(safe_path "$p"), which is not a regular file of the template" ;;
    esac
done <"$WORK/new-entries"

MERGE_CODEOWNERS=no
if [ "$(cat "$WORK/new-merge")" = yes ]; then MERGE_CODEOWNERS=yes; fi

# Deleted: in the previous manifest, not in the new one (the manifest itself and the version file never are).
comm -23 "$WORK/old-entries" "$WORK/new-entries" >"$WORK/deleted"

# ------------------------------------------------------------------ 4. the destinations

# check_destination <path>: refuse when the path or any parent is a symbolic link or a submodule in the repository,
# or when the path itself is a directory.
check_destination() {
    local path="$1" prefix='' part rec mode
    local -a parts
    IFS=/ read -r -a parts <<<"$path"
    for part in "${parts[@]}"; do
        prefix="${prefix:+$prefix/}$part"
        rec="$(git ls-tree "$BASE_SHA" -- "$prefix")"
        [ -n "$rec" ] || return 0
        mode="${rec%% *}"
        if [ "$prefix" = "$path" ]; then
            case "$mode" in
                100644 | 100755) ;;
                120000) refuse "the destination $(safe_path "$path") is a symbolic link in this repository" ;;
                160000) refuse "the destination $(safe_path "$path") is a submodule in this repository" ;;
                *) refuse "the destination $(safe_path "$path") is a directory in this repository" ;;
            esac
        else
            case "$mode" in
                040000) ;;
                120000) refuse "the parent $(safe_path "$prefix") of $(safe_path "$path") is a symbolic link in this repository" ;;
                160000) refuse "the parent $(safe_path "$prefix") of $(safe_path "$path") is a submodule in this repository" ;;
                *) refuse "the parent $(safe_path "$prefix") of $(safe_path "$path") is not a directory in this repository" ;;
            esac
        fi
    done
}

while IFS= read -r p; do check_destination "$p"; done <"$WORK/new-entries"
while IFS= read -r p; do check_destination "$p"; done <"$WORK/deleted"
check_destination "$VERSION_PATH"
if [ "$MERGE_CODEOWNERS" = yes ]; then check_destination "$CODEOWNERS_PATH"; fi

# ------------------------------------------------------------------ 5. the engine pin

if grep -qxF "$LOCK_PATH" "$WORK/new-entries"; then
    if [ -n "$(git ls-tree "$BASE_SHA" -- "$LOCK_PATH")" ]; then
        git cat-file blob "$BASE_SHA:$LOCK_PATH" >"$WORK/old-engine.lock"
        git -C "$TPL" cat-file blob "HEAD:$LOCK_PATH" >"$WORK/new-engine.lock"
        if ! compare_out="$(bash "$CANDIDATE_SCRIPT" compare "$WORK/old-engine.lock" "$WORK/new-engine.lock" 2>&1)"; then
            printf '%s\n' "$compare_out" | head -n 5 | tr -d '\r'
            refuse "the template's $LOCK_PATH cannot replace this repository's (land a release_repo change on the default branch first, CI.md section 5)"
        fi
    fi
fi

# ------------------------------------------------------------------ 6. write

git checkout --quiet -B "$SYNC_BRANCH" "$BASE_SHA"

: >"$WORK/touched"
while IFS=$'\t' read -r mode p; do
    mkdir -p -- "$(dirname -- "$p")"
    rm -f -- "$p"
    git -C "$TPL" cat-file blob "HEAD:$p" >"$p"
    if [ "$mode" = 100755 ]; then chmod 755 "$p"; else chmod 644 "$p"; fi
    printf '%s\n' "$p" >>"$WORK/touched"
done <"$WORK/new-entries.tsv"

while IFS= read -r p; do
    [ -n "$p" ] || continue
    rm -f -- "$p"
    # A path the repository never tracked has nothing to stage.
    if [ -n "$(git ls-tree "$BASE_SHA" -- "$p")" ]; then printf '%s\n' "$p" >>"$WORK/touched"; fi
done <"$WORK/deleted"

: >"$WORK/codeowners-added"
CODEOWNERS_NOTE=''
if [ "$MERGE_CODEOWNERS" = yes ]; then
    entry="$(git -C "$TPL" ls-tree HEAD -- "$CODEOWNERS_PATH")"
    case "$entry" in
        '100644 blob '* | '100755 blob '*) ;;
        *) refuse "the manifest asks for a CODEOWNERS merge but the template has no regular $CODEOWNERS_PATH" ;;
    esac
    git -C "$TPL" cat-file blob "HEAD:$CODEOWNERS_PATH" >"$WORK/template-codeowners"
    : >"$WORK/have-patterns"
    repo_owners=''
    have_file=no
    if [ -f "$CODEOWNERS_PATH" ]; then
        have_file=yes
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%%#*}"
            [ -n "${line//[[:space:]]/}" ] || continue
            read -r -a words <<<"$line"
            printf '%s\n' "${words[0]}" >>"$WORK/have-patterns"
            case "${words[0]}" in
                /.github/ | /.github | '/.github/**')
                    if [ -z "$repo_owners" ] && [ "${#words[@]}" -gt 1 ]; then repo_owners="${words[*]:1}"; fi
                    ;;
            esac
        done <"$CODEOWNERS_PATH"
    fi
    if [ "$have_file" = no ]; then
        cp "$WORK/template-codeowners" "$CODEOWNERS_PATH"
        CODEOWNERS_NOTE='This repository had no CODEOWNERS; the template file was copied. Replace the owner token with this repository'"'"'s maintainers before relying on it.'
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%%#*}"
            [ -n "${line//[[:space:]]/}" ] || continue
            printf '%s\n' "$line" >>"$WORK/codeowners-added"
        done <"$WORK/template-codeowners"
    else
        # The template's own owners stand in only when the repository has no /.github/ rule to copy owners from.
        fallback=''
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%%#*}"
            [ -n "${line//[[:space:]]/}" ] || continue
            read -r -a words <<<"$line"
            if [ -z "$fallback" ] && [ "${#words[@]}" -gt 1 ]; then fallback="${words[*]:1}"; fi
            case "${words[0]}" in /.github/ | /.github | '/.github/**') if [ "${#words[@]}" -gt 1 ]; then fallback="${words[*]:1}"; fi ;; esac
        done <"$WORK/template-codeowners"
        use_owners="$repo_owners"
        if [ -z "$use_owners" ]; then
            use_owners="$fallback"
            CODEOWNERS_NOTE='This repository has no /.github/ rule to take owners from, so the appended rules keep the template'"'"'s owner token. Replace it with this repository'"'"'s maintainers.'
        fi
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%%#*}"
            [ -n "${line//[[:space:]]/}" ] || continue
            read -r -a words <<<"$line"
            if grep -qxF -- "${words[0]}" "$WORK/have-patterns"; then continue; fi
            printf '%s\n' "${words[0]}" >>"$WORK/have-patterns"
            printf '%s %s\n' "${words[0]}" "$use_owners" >>"$WORK/codeowners-added"
        done <"$WORK/template-codeowners"
        if [ -s "$WORK/codeowners-added" ]; then
            if [ -s "$CODEOWNERS_PATH" ] && [ -n "$(tail -c 1 "$CODEOWNERS_PATH")" ]; then printf '\n' >>"$CODEOWNERS_PATH"; fi
            printf '# Added by okf-template-sync (%s):\n' "$TARGET_TAG" >>"$CODEOWNERS_PATH"
            cat "$WORK/codeowners-added" >>"$CODEOWNERS_PATH"
        fi
    fi
    printf '%s\n' "$CODEOWNERS_PATH" >>"$WORK/touched"
fi

mkdir -p -- "$(dirname -- "$VERSION_PATH")"
rm -f -- "$VERSION_PATH"
{
    printf '# okf-template-sync: where this repository'"'"'s template files came from (see .okf/template-manifest).\n'
    printf 'repo=%s\n' "$cur_repo"
    printf 'tag=%s\n' "$TARGET_TAG"
    printf 'commit=%s\n' "$TPL_COMMIT"
} >"$VERSION_PATH"
printf '%s\n' "$VERSION_PATH" >>"$WORK/touched"

sort -u -o "$WORK/touched" "$WORK/touched"
git --literal-pathspecs add -f -A --pathspec-from-file="$WORK/touched"

if git diff --cached --quiet; then
    printf 'okf-template-sync: outcome=up-to-date (%s already matches %s)\n' "$REPO" "$TARGET_TAG"
    emit 'outcome=up-to-date'
    emit 'lock-changed=false'
    emit "head-sha=$BASE_SHA"
    exit 0
fi

LOCK_CHANGED=false
if git diff --cached --name-only | grep -qxF "$LOCK_PATH"; then LOCK_CHANGED=true; fi
git diff --cached --no-renames --name-status >"$WORK/status"

# ------------------------------------------------------------------ 7. commit, push, pull request

bot_id="$(gh api "users/${OKF_APP_SLUG}%5Bbot%5D" --jq .id 2>/dev/null)" || bot_id=''
[[ $bot_id =~ ^[0-9]{1,12}$ ]] || refuse 'cannot read the maintenance App bot identity'
bot_name="${OKF_APP_SLUG}[bot]"
bot_email="${bot_id}+${OKF_APP_SLUG}[bot]@users.noreply.github.com"
{
    printf 'okf-template-sync: %s -> %s\n\n' "$cur_tag" "$TARGET_TAG"
    printf 'Template files of %s at %s.\n\n' "$cur_repo" "$TARGET_TAG"
    printf 'Okf-Template-Tag: %s\n' "$TARGET_TAG"
    printf 'Okf-Template-Commit: %s\n' "$TPL_COMMIT"
} >"$WORK/commit-message"
GIT_AUTHOR_NAME="$bot_name" GIT_AUTHOR_EMAIL="$bot_email" GIT_COMMITTER_NAME="$bot_name" GIT_COMMITTER_EMAIL="$bot_email" \
    git -c core.hooksPath=/dev/null -c commit.gpgsign=false commit --quiet -F "$WORK/commit-message" >"$WORK/commit.out" 2>&1 || refuse 'the commit failed'
HEAD_SHA="$(git rev-parse HEAD)"
NEW_TREE="$(git rev-parse 'HEAD^{tree}')"

remote_sha="$(auth_git ls-remote "$KB_URL" "refs/heads/$SYNC_BRANCH" 2>"$WORK/ls-remote-kb.err" | cut -f1)" || remote_sha=''
OUTCOME=pushed
BRANCH_HEAD="$HEAD_SHA"
if [ -n "$remote_sha" ]; then
    if auth_git fetch --quiet --no-tags "$KB_URL" "refs/heads/$SYNC_BRANCH" >"$WORK/fetch.out" 2>&1; then
        remote_tree="$(git rev-parse --verify --quiet 'FETCH_HEAD^{tree}' || true)"
        remote_parent="$(git rev-parse --verify --quiet 'FETCH_HEAD^' || true)"
        if [ "$remote_tree" = "$NEW_TREE" ] && [ "$remote_parent" = "$BASE_SHA" ]; then
            OUTCOME=unchanged
            BRANCH_HEAD="$(git rev-parse --verify --quiet FETCH_HEAD)"
        fi
    fi
fi
if [ "$OUTCOME" = pushed ]; then
    # The lease names the sha the remote branch had (or nothing): a branch that moved since is not overwritten.
    auth_git push --quiet "--force-with-lease=refs/heads/$SYNC_BRANCH:$remote_sha" "$KB_URL" "HEAD:refs/heads/$SYNC_BRANCH" >"$WORK/push.out" 2>&1 || {
        printf '::error::okf-template-sync: the push of %s failed\n' "$SYNC_BRANCH"
        emit 'outcome=failed'
        exit 1
    }
fi

# The pull request body is deterministic, so an unchanged run leaves it alone.
{
    printf '%s\n' "$MARKER"
    printf '## okf-template-sync\n\n'
    printf '| | |\n|---|---|\n'
    printf '| Template | `%s` |\n' "$cur_repo"
    printf '| From | `%s` |\n' "$cur_tag"
    printf '| To | `%s` (`%s`) |\n\n' "$TARGET_TAG" "$TPL_COMMIT"
    printf 'This pull request overwrites exactly the template-owned files listed in `.okf/template-manifest` and nothing else: the bundle, `.okf/maintainers`, `.okf/publish.toml`, `.okf/profile.json`, `.okf/agent.toml`, `README.md` and the owner lines of CODEOWNERS are this repository'"'"'s own and are never touched.\n\n'
    printf '### Added or changed\n\n'
    count=0
    while IFS=$'\t' read -r st p; do
        [ "$st" = D ] && continue
        count=$((count + 1))
        if [ "$count" -le "$MAX_LISTED" ]; then printf -- '- `%s`\n' "$p"; fi
    done <"$WORK/status"
    if [ "$count" -gt "$MAX_LISTED" ]; then printf -- '- (%s more not listed)\n' "$((count - MAX_LISTED))"; fi
    printf '\n### Removed (dropped from the template manifest)\n\n'
    count=0
    while IFS=$'\t' read -r st p; do
        [ "$st" = D ] || continue
        count=$((count + 1))
        if [ "$count" -le "$MAX_LISTED" ]; then printf -- '- `%s`\n' "$p"; fi
    done <"$WORK/status"
    [ "$count" -gt 0 ] || printf 'None.\n'
    printf '\n### CODEOWNERS\n\n'
    if [ -s "$WORK/codeowners-added" ]; then
        printf 'Existing lines are kept; these rules were appended:\n\n'
        while IFS= read -r line; do printf -- '- `%s`\n' "$line"; done <"$WORK/codeowners-added"
        if [ -n "$CODEOWNERS_NOTE" ]; then printf '\n%s\n' "$CODEOWNERS_NOTE"; fi
    else
        printf 'No change.\n'
    fi
    printf '\n### Engine pin\n\n'
    if [ "$LOCK_CHANGED" = true ]; then
        printf 'This pull request changes `.okf/engine.lock`. The `seed` job of this workflow seeds the candidate engine and re-runs the failed `okf-check` on this branch so the required check can turn green; `minimum_engine` in `.okf/publish.toml` is yours to raise.\n'
    else
        printf 'The engine pin is unchanged.\n'
    fi
    printf '\nThe sync branch is regenerated when the template or the default branch moves; commits pushed to it by people are replaced. This workflow never approves or merges its pull request.\n'
} >"$WORK/pr-body"
pr_title="okf-template-sync: $cur_tag -> $TARGET_TAG"

existing="$(gh api "repos/$REPO/pulls?head=$OWNER:$SYNC_BRANCH&state=open" --jq '.[0].number // empty' 2>/dev/null)" || existing=''
if [[ $existing =~ ^[1-9][0-9]{0,9}$ ]]; then
    have_title="$(gh api "repos/$REPO/pulls?head=$OWNER:$SYNC_BRANCH&state=open" --jq '.[0].title // empty' 2>/dev/null)" || have_title=''
    have_body="$(gh api "repos/$REPO/pulls?head=$OWNER:$SYNC_BRANCH&state=open" --jq '.[0].body // empty' 2>/dev/null | tr -d '\r')" || have_body=''
    want_body="$(cat "$WORK/pr-body")"
    if [ "$have_title" != "$pr_title" ] || [ "$have_body" != "$want_body" ]; then
        gh api -X PATCH "repos/$REPO/pulls/$existing" -f "title=$pr_title" -f "body=$want_body" >/dev/null
        printf 'okf-template-sync: pull request #%s refreshed\n' "$existing"
    else
        printf 'okf-template-sync: pull request #%s is current\n' "$existing"
    fi
else
    number="$(gh api -X POST "repos/$REPO/pulls" -f "title=$pr_title" -f "head=$SYNC_BRANCH" -f "base=$DEFAULT_BRANCH" -f "body=$(cat "$WORK/pr-body")" --jq .number)"
    [[ $number =~ ^[1-9][0-9]{0,9}$ ]] || { printf '::error::okf-template-sync: the pull request response has no number\n'; exit 1; }
    printf 'okf-template-sync: pull request #%s opened\n' "$number"
fi

printf 'okf-template-sync: outcome=%s (%s -> %s, engine pin changed: %s)\n' "$OUTCOME" "$cur_tag" "$TARGET_TAG" "$LOCK_CHANGED"
emit "outcome=$OUTCOME"
emit "lock-changed=$LOCK_CHANGED"
emit "head-sha=$BRANCH_HEAD"
