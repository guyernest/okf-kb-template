#!/usr/bin/env bash
# Phase 214 (D-12, D-15, D-17; T-214-33, T-214-68): the event-specific default-branch guard shared by the two
# maintenance workflows (okf-template-sync and okf-doctor), run as the first step after the checkout.
#
# Why not a job-level `if: github.ref_name == github.event.repository.default_branch`: a `schedule` event carries
# no repository object, so that comparison is false and a scheduled run would be skipped for ever, silently.
# GitHub itself runs scheduled workflows only on the default branch, so a schedule event is accepted; a manual
# dispatch must name the default branch as its ref; every other event is refused. The environment's deployment
# branch policy (set by bootstrap) is the boundary that withholds the App key from any other ref; this guard is
# defence in depth with a readable message.
#
# Env: OKF_EVENT (github.event_name), OKF_REF (github.ref), OKF_DEFAULT_BRANCH (the default branch's name; the
# workflows pass `github.event.repository.default_branch || github.ref_name`, so a scheduled run never sees it empty).
# Exit 0 admitted, 1 refused.
set -euo pipefail

event="${OKF_EVENT:-}"
ref="${OKF_REF:-}"
default_branch="${OKF_DEFAULT_BRANCH:-}"

case "$event" in
    schedule)
        exit 0
        ;;
    workflow_dispatch)
        if [ -z "$default_branch" ] || [ "$ref" != "refs/heads/$default_branch" ]; then
            printf '::error::this workflow runs only on the default branch (%s)\n' "$(printf '%s' "${default_branch:-unknown}" | tr -d '\r\n' | head -c 200)"
            exit 1
        fi
        exit 0
        ;;
    *)
        printf '::error::this workflow runs only on a schedule or a manual dispatch on the default branch\n'
        exit 1
        ;;
esac
