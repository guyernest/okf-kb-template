#!/usr/bin/env python3
"""Phase 214 (KTPL-04; D-05; threat T-214-23): the provenance gate for documents the agent added or changed.

    python3 -I provenance.py --date YYYY-MM-DD --issue-url URL [--profile] PATH...

For each PATH (a Markdown document, read as UTF-8) the frontmatter block between the first two `---` lines is
parsed. The document passes only when

  * the top-level `verified:` list holds the item {by: agent:okf-agent, at: <run date>}, and
  * unless --profile is given (the default branch has `.okf/profile.json`, so the issue URL is not a source),
    the top-level `sources:` list holds an item whose `resource` is the issue URL.

The same text in the body, in another key, or in the other list does not count. Standard library only.

Output: one line `<reason>\\t<path>` per refused document (reasons: no-frontmatter, unreadable,
verified-entry-missing, source-missing). Exit 0 when every document passes, 1 when any is refused, 2 on a
usage error.
"""

import re
import sys

AGENT_ID = "agent:okf-agent"
KEY_LINE = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):(.*)$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")


def frontmatter_lines(text):
    """The lines strictly between the first two `---` lines, or None when there is no such block."""
    lines = [line.rstrip("\r") for line in text.split("\n")]
    if not lines or lines[0] != "---":
        return None
    for i in range(1, len(lines)):
        if lines[i] == "---":
            return lines[1:i]
    return None


def top_level_block(lines, key):
    """(inline remainder, block lines) of a top-level `key:`; None when the key is absent."""
    for i, line in enumerate(lines):
        m = KEY_LINE.match(line)
        if m and m.group(1) == key:
            block = []
            for follower in lines[i + 1 :]:
                if KEY_LINE.match(follower):
                    break
                block.append(follower)
            return m.group(2).strip(), block
    return None


def unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def split_flow(text):
    """Split flow-collection text on commas at depth 0, outside quotes."""
    parts, depth, quote, current = [], 0, "", []
    for ch in text:
        if quote:
            current.append(ch)
            if ch == quote:
                quote = ""
            continue
        if ch in "\"'":
            quote = ch
            current.append(ch)
        elif ch in "{[":
            depth += 1
            current.append(ch)
        elif ch in "}]":
            depth -= 1
            current.append(ch)
        elif ch == "," and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(ch)
    tail = "".join(current)
    if tail.strip():
        parts.append(tail)
    return [p.strip() for p in parts if p.strip()]


def split_pair(text):
    """`key: value` split at the first colon that is followed by a space or ends the text."""
    m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_-]*)\s*:(?:\s+(.*)|\s*)$", text, re.S)
    if not m:
        return None
    return m.group(1), unquote(m.group(2) or "")


def parse_item(text):
    """One list item as a dict of strings; a plain scalar is {"_scalar": value}."""
    text = text.strip()
    if text.startswith("{"):
        end = text.rfind("}")
        if end < 0:
            return {}
        item = {}
        for part in split_flow(text[1:end]):
            pair = split_pair(part)
            if pair:
                item[pair[0]] = pair[1]
        return item
    item = {}
    pairs = 0
    for line in text.split("\n"):
        pair = split_pair(line)
        if pair:
            item[pair[0]] = pair[1]
            pairs += 1
    if pairs:
        return item
    return {"_scalar": unquote(text)}


def list_items(inline, block):
    """The items of a top-level list: a flow sequence on the key's line, or a block sequence below it."""
    if inline.startswith("["):
        text = inline + "\n" + "\n".join(block)
        end = text.rfind("]")
        if end < 0:
            return []
        return [parse_item(p) for p in split_flow(text[1:end])]
    if inline:
        return []
    items, current, indent = [], None, None
    for line in block:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = re.match(r"^(\s*)-(?:\s+(.*)|\s*)$", line)
        if m and (indent is None or len(m.group(1)) <= indent):
            if current is not None:
                items.append(parse_item(current))
            indent = len(m.group(1))
            current = m.group(2) or ""
        elif current is not None:
            current += "\n" + line.strip()
    if current is not None:
        items.append(parse_item(current))
    return items


def check_document(path, date, issue_url, profile):
    """The refusal reason for one document, or None when it passes."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError):
        return "unreadable"
    lines = frontmatter_lines(text)
    if lines is None:
        return "no-frontmatter"
    verified = top_level_block(lines, "verified")
    items = list_items(*verified) if verified else []
    if not any(i.get("by") == AGENT_ID and i.get("at") == date for i in items):
        return "verified-entry-missing"
    if not profile:
        sources = top_level_block(lines, "sources")
        items = list_items(*sources) if sources else []
        if not any(i.get("resource") == issue_url for i in items):
            return "source-missing"
    return None


def main(argv):
    date = issue_url = None
    profile = False
    paths = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--date" and i + 1 < len(argv):
            date = argv[i + 1]
            i += 2
        elif arg == "--issue-url" and i + 1 < len(argv):
            issue_url = argv[i + 1]
            i += 2
        elif arg == "--profile":
            profile = True
            i += 1
        elif arg == "--":
            paths.extend(argv[i + 1 :])
            break
        elif arg.startswith("--"):
            sys.stderr.write("provenance: unknown option\n")
            return 2
        else:
            paths.append(arg)
            i += 1
    if not date or not DATE_RE.match(date) or not issue_url or not paths:
        sys.stderr.write("usage: provenance.py --date YYYY-MM-DD --issue-url URL [--profile] PATH...\n")
        return 2
    refused = 0
    for path in paths:
        reason = check_document(path, date, issue_url, profile)
        if reason:
            refused += 1
            print(f"{reason}\t{path}")
    return 1 if refused else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
