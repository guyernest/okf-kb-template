#!/usr/bin/env python3
"""okf-triage: the deterministic first reader of an issue report (Phase 214, KTPL-02, D-16).

Runs as the single step of the `okf-triage` workflow:  python3 -I .github/okf/triage.py

The decision is made from ONE fresh `gh api repos/<r>/issues/<n>` read. The event file
(GITHUB_EVENT_PATH) supplies only the issue number, validated as digits; the body, the labels and
everything else come from that read, so a delayed or out-of-order event, a removed kind label or a
hand-applied `okf:triaged` converges on the labels the live issue implies.

What it decides, for the issue as it is now:

  * no kind label (okf:wrong-answer, okf:missing, okf:update): nothing to check. A stale
    `okf:triaged` is removed; that is the only write such an issue can cause.
  * more than one kind label, an over-long body, a required section that is missing or empty, or a
    contract heading that appears twice: INVALID. `okf:triaged` is removed when present and ONE
    sticky comment (first line: the marker) names what to fix.
  * otherwise VALID: `okf:triaged` is added when absent and every marker comment is deleted.

The comment is composed only from fixed sentences and the heading names in issue-contract.json. It
never quotes the issue: a hostile body creates no file and emits no workflow command, because the
body is only ever parsed here, never passed to a shell, an expression or the log.

The form contract (labels and headings) lives in issue-contract.json beside this file; it is the one
source the forms test, the workflow's label list, the agent gate and the issue-creating tool read.

    triage.py                               reconcile the live issue (needs GH_TOKEN, OKF_REPO, GITHUB_EVENT_PATH)
    triage.py --decide-only                 same read, print the decision JSON, write nothing
    triage.py --decide-only --issue-json F  read {"body": ..., "labels": [...]} from F, print the
                                            decision JSON, call nothing at all (the agent gate runs
                                            this on the frozen body)

Decision JSON keys: kind, valid, reason, missing, duplicates, add_labels, remove_labels, comment,
comment_mode (upsert | delete | none). Exit status: 0 done (an invalid issue is a normal outcome),
1 a GitHub call failed, 2 bad input or configuration.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.parse

PREFIX = "okf-triage"
MAX_BODY_CHARS = 65536
NO_RESPONSE = "_No response_"
BOT_LOGIN = "github-actions[bot]"
ISSUE_NUMBER = re.compile(r"^[1-9][0-9]{0,9}$")
REPO_NAME = re.compile(r"^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$")
GH_TIMEOUT_SECONDS = 60
HEADING_TRAILING = " \t\r"
DEFAULT_CONTRACT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "issue-contract.json")

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2


class UsageError(Exception):
    """Bad input or configuration (exit 2)."""


class GhError(Exception):
    """A `gh api` call failed (exit 1). The message never carries issue text."""


# ------------------------------------------------------------------ contract


def load_contract(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        raise UsageError(f"cannot read the contract {os.path.basename(path)}: {type(exc).__name__}") from exc
    kinds = data.get("kinds") if isinstance(data, dict) else None
    ok = (
        isinstance(data, dict)
        and data.get("schema_version") == 1
        and isinstance(data.get("triaged_label"), str)
        and isinstance(data.get("marker"), str)
        and data["marker"].strip()
        and isinstance(kinds, dict)
        and kinds
    )
    if ok:
        for cfg in kinds.values():
            ok = ok and isinstance(cfg, dict) and isinstance(cfg.get("label"), str)
            for key in ("required", "optional"):
                items = cfg.get(key) if isinstance(cfg, dict) else None
                ok = ok and isinstance(items, list) and all(isinstance(i, str) and i for i in items)
    if not ok:
        raise UsageError("the contract is not schema_version 1 with triaged_label, marker and kinds")
    return data


# ------------------------------------------------------------------ parsing


def has_content(value):
    """True when the value holds at least one visible character (zero-width marks do not count)."""
    return any(ch.isprintable() and not ch.isspace() for ch in value)


def parse_sections(body, headings):
    """Split a rendered form body into {heading: value} for THIS kind's contract headings only.

    A section starts at a line that is exactly `### <heading>` (trailing spaces, tabs and CR
    removed) and runs to the next such line, so any other `###` line stays inside the value. A
    heading carrying a zero-width or bidi mark is a different string and does not match. Returns
    (values, duplicates): the value of the first occurrence, and the headings that occur twice.
    """
    wanted = {"### " + h: h for h in headings}
    chunks = []  # [heading, [lines]]
    for line in body.replace("\r\n", "\n").split("\n"):
        heading = wanted.get(line.rstrip(HEADING_TRAILING))
        if heading is not None:
            chunks.append([heading, []])
        elif chunks:
            chunks[-1][1].append(line)
    values = {}
    duplicates = []
    for heading, lines in chunks:
        if heading in values:
            if heading not in duplicates:
                duplicates.append(heading)
            continue
        value = "\n".join(lines).strip()
        values[heading] = "" if value == NO_RESPONSE or not has_content(value) else value
    return values, duplicates


# ------------------------------------------------------------------ the decision


def label_names(raw):
    names = []
    for item in raw if isinstance(raw, list) else []:
        name = item.get("name") if isinstance(item, dict) else item
        if isinstance(name, str):
            names.append(name)
    return names


def compose_comment(contract, reason, missing, duplicates):
    """Fixed sentences plus contract names. Nothing from the issue is ever quoted."""
    kind_labels = [cfg["label"] for cfg in contract["kinds"].values()]
    lines = [
        contract["marker"],
        "Thanks for the report. It cannot be checked yet, so it has not been marked as triaged.",
        "",
    ]
    if reason == "multiple-kinds":
        lines.append("This issue has more than one report-kind label. Keep exactly one of: " + ", ".join("`%s`" % k for k in kind_labels) + ".")
    elif reason == "body-too-large":
        lines.append(f"The issue text is longer than {MAX_BODY_CHARS:,} characters. Please shorten it and attach long material as a file.")
    else:
        if missing:
            lines.append("These required sections are missing or empty:")
            lines.extend("- " + name for name in missing)
        if missing and duplicates:
            lines.append("")
        if duplicates:
            lines.append("These sections appear more than once. Keep one of each:")
            lines.extend("- " + name for name in duplicates)
    lines += ["", "Please edit the issue to fix this. It is checked again automatically after every edit."]
    return "\n".join(lines)


def decide(issue, contract):
    """The decision for an issue as it is NOW: {"body": str|None, "labels": [...]}."""
    triaged = contract["triaged_label"]
    labels = label_names(issue.get("labels"))
    present = [name for name, cfg in contract["kinds"].items() if cfg["label"] in labels]
    decision = {
        "kind": None,
        "valid": False,
        "reason": "no-kind",
        "missing": [],
        "duplicates": [],
        "add_labels": [],
        "remove_labels": [triaged] if triaged in labels else [],
        "comment": None,
        "comment_mode": "none",
    }
    if not present:
        return decision

    body = issue.get("body")
    body = body if isinstance(body, str) else ""
    if len(present) > 1:
        decision["reason"] = "multiple-kinds"
    elif len(body) > MAX_BODY_CHARS:
        decision["kind"] = present[0]
        decision["reason"] = "body-too-large"
    else:
        kind = present[0]
        cfg = contract["kinds"][kind]
        values, duplicates = parse_sections(body, cfg["required"] + cfg["optional"])
        missing = [h for h in cfg["required"] if not values.get(h)]
        decision["kind"] = kind
        decision["missing"] = missing
        decision["duplicates"] = duplicates
        decision["reason"] = "ok" if not missing and not duplicates else ("duplicate-heading" if duplicates else "missing-fields")

    if decision["reason"] == "ok":
        decision["valid"] = True
        decision["add_labels"] = [] if triaged in labels else [triaged]
        decision["remove_labels"] = []
        decision["comment_mode"] = "delete"
    else:
        decision["comment"] = compose_comment(contract, decision["reason"], decision["missing"], decision["duplicates"])
        decision["comment_mode"] = "upsert"
    return decision


# ------------------------------------------------------------------ GitHub


def gh_api(args, tolerate_404=False):
    """Run `gh api <args>` (an argument list, never a shell). Returns stdout."""
    label = " ".join(a for a in args if a.startswith("repos/") or a in ("POST", "PATCH", "DELETE"))
    try:
        proc = subprocess.run(
            ["gh", "api", *args],
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=GH_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise GhError(f"gh could not run ({type(exc).__name__})") from exc
    if proc.returncode != 0:
        if tolerate_404 and "HTTP 404" in proc.stderr:
            return ""
        raise GhError(f"gh api {label} failed (exit {proc.returncode})")
    return proc.stdout


def parse_json_stream(text):
    """Every JSON value in `text`, one after another (compact or pretty, as `gh --jq` prints)."""
    decoder = json.JSONDecoder()
    out = []
    pos = 0
    while True:
        while pos < len(text) and text[pos].isspace():
            pos += 1
        if pos >= len(text):
            return out
        try:
            value, pos = decoder.raw_decode(text, pos)
        except ValueError as exc:
            raise GhError("a gh api response was not JSON") from exc
        out.append(value)


def fetch_issue(repo, number):
    try:
        issue = json.loads(gh_api([f"repos/{repo}/issues/{number}"]))
    except ValueError as exc:
        raise GhError("the issue response was not JSON") from exc
    if not isinstance(issue, dict):
        raise GhError("the issue response was not an object")
    return issue


def marker_comments(repo, number, marker):
    """The bot's marker comments on the issue, oldest first. A user's copy of the marker is ignored."""
    out = gh_api(
        ["--paginate", f"repos/{repo}/issues/{number}/comments", "--jq", ".[] | {id, login: .user.login, body, created_at}"]
    )
    found = []
    for obj in parse_json_stream(out):
        if not isinstance(obj, dict) or obj.get("login") != BOT_LOGIN:
            continue
        body, cid = obj.get("body"), obj.get("id")
        if isinstance(body, str) and marker in body and isinstance(cid, int) and not isinstance(cid, bool):
            found.append((str(obj.get("created_at") or ""), cid, body))
    found.sort()
    return found


def normalized(text):
    return text.replace("\r\n", "\n").strip()


def apply_decision(decision, repo, number, contract):
    for label in decision["add_labels"]:
        gh_api(["-X", "POST", f"repos/{repo}/issues/{number}/labels", "-f", f"labels[]={label}"])
    for label in decision["remove_labels"]:
        gh_api(["-X", "DELETE", f"repos/{repo}/issues/{number}/labels/{urllib.parse.quote(label, safe='')}"], tolerate_404=True)
    mode = decision["comment_mode"]
    if mode == "none":
        return
    existing = marker_comments(repo, number, contract["marker"])
    if mode == "delete":
        for _created, cid, _body in existing:
            gh_api(["-X", "DELETE", f"repos/{repo}/issues/comments/{cid}"], tolerate_404=True)
        return
    text = decision["comment"]
    if not existing:
        gh_api(["-X", "POST", f"repos/{repo}/issues/{number}/comments", "-f", f"body={text}"])
        return
    _created, keep_id, keep_body = existing[0]
    if normalized(keep_body) != normalized(text):
        gh_api(["-X", "PATCH", f"repos/{repo}/issues/comments/{keep_id}", "-f", f"body={text}"])
    for _created, cid, _body in existing[1:]:
        gh_api(["-X", "DELETE", f"repos/{repo}/issues/comments/{cid}"], tolerate_404=True)


# ------------------------------------------------------------------ entry


def issue_number_from_event():
    path = os.environ.get("GITHUB_EVENT_PATH", "")
    if not path:
        raise UsageError("GITHUB_EVENT_PATH is not set")
    try:
        with open(path, encoding="utf-8") as fh:
            event = json.load(fh)
        number = event["issue"]["number"]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise UsageError("the event file has no issue number") from exc
    number = str(number) if isinstance(number, int) and not isinstance(number, bool) else ""
    if not ISSUE_NUMBER.match(number):
        raise UsageError("the issue number is not a plain positive integer")
    return number


def read_repo():
    repo = os.environ.get("OKF_REPO", "")
    if not REPO_NAME.match(repo):
        raise UsageError("OKF_REPO is not an owner/name repository")
    return repo


def read_issue_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            issue = json.load(fh)
    except (OSError, ValueError) as exc:
        raise UsageError(f"cannot read the issue file: {type(exc).__name__}") from exc
    if not isinstance(issue, dict):
        raise UsageError("the issue file is not a JSON object")
    return issue


def main(argv=None):
    parser = argparse.ArgumentParser(prog=PREFIX, description="triage one issue against the form contract")
    parser.add_argument("--decide-only", action="store_true", help="print the decision JSON and write nothing")
    parser.add_argument("--issue-json", metavar="FILE", help="with --decide-only: read the issue from FILE, call nothing")
    parser.add_argument("--contract", metavar="FILE", default=DEFAULT_CONTRACT, help="the issue contract (default: beside this script)")
    args = parser.parse_args(argv)
    try:
        if args.issue_json and not args.decide_only:
            raise UsageError("--issue-json is only valid with --decide-only")
        contract = load_contract(args.contract)
        if args.issue_json:
            print(json.dumps(decide(read_issue_json(args.issue_json), contract), sort_keys=True))
            return EXIT_OK
        repo = read_repo()
        number = issue_number_from_event()
        issue = fetch_issue(repo, number)
        if "pull_request" in issue:
            print(f"{PREFIX}: #{number} is a pull request; nothing to triage")
            return EXIT_OK
        decision = decide(issue, contract)
        if args.decide_only:
            print(json.dumps(decision, sort_keys=True))
            return EXIT_OK
        apply_decision(decision, repo, number, contract)
    except UsageError as exc:
        sys.stderr.write(f"{PREFIX}: {exc}\n")
        return EXIT_USAGE
    except GhError as exc:
        sys.stderr.write(f"{PREFIX}: {exc}\n")
        return EXIT_FAILED
    kind = decision["kind"] or "none"
    print(f"{PREFIX}: #{number} kind={kind} valid={'yes' if decision['valid'] else 'no'} reason={decision['reason']}")
    for label in decision["add_labels"]:
        print(f"{PREFIX}: added {label}")
    for label in decision["remove_labels"]:
        print(f"{PREFIX}: removed {label}")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
