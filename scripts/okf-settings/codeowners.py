#!/usr/bin/env python3
"""Last-match CODEOWNERS evaluation for okf-doctor.sh (Phase 214, KTPL-01, D-14).

GitHub applies the LAST rule of a CODEOWNERS file that matches a path, so a later rule with no owner
silently removes the code-owner review an earlier line promised. This script reads a CODEOWNERS text on
stdin and answers, for a probe file under each protected path, which rule wins and whether it names a
real owner.

    python3 -I codeowners.py coverage      one line per protected probe path:
                                               ok <path>
                                               drift <path>: <reason>
                                               cannot-read <path>: <reason>
    python3 -I codeowners.py placeholder   one line: `ok placeholder`, or
                                               drift placeholder: line <n> still names @OKF_MAINTAINERS

Stdlib only. Patterns are gitignore style as GitHub reads them: a leading `/` anchors to the root, a
pattern with a `/` in the middle is anchored, a pattern with no `/` (a trailing one does not count)
matches at any depth, a trailing `/` matches a directory and everything under it, `*` does not cross a
`/`, `**` does. Anything the script cannot evaluate faithfully (character classes, `?`, `!`, escapes)
makes every probe `cannot-read`: an exotic pattern can never produce a false `ok`.

Free text from the file is never echoed, only line numbers.
"""

import re
import sys

PROBES = (".github/x", ".github/workflows/x.yml", ".okf/x", ".claude/x", "scripts/x")
PLACEHOLDER = "@okf_maintainers"
OWNER_RE = re.compile(
    r"^(@[A-Za-z0-9][A-Za-z0-9-]*(/[A-Za-z0-9_.-]+)?|[^@\s/]+@[^@\s/]+\.[^@\s/]+)$"
)
UNSUPPORTED = set("[]!?\\")


class Rule:
    def __init__(self, line_no, pattern, owners):
        self.line_no = line_no
        self.pattern = pattern
        self.owners = owners
        self.regex = None
        self.dir_only = False
        self.supported = self._compile(pattern)

    def _compile(self, pattern):
        if any(c in UNSUPPORTED for c in pattern):
            return False
        self.dir_only = pattern.endswith("/")
        stripped = pattern.rstrip("/")
        if not stripped:
            return False
        anchored = "/" in stripped
        segments = [s for s in stripped.split("/") if s != ""]
        if not segments:
            return False
        parts = []
        for index, segment in enumerate(segments):
            last = index == len(segments) - 1
            if segment == "**":
                parts.append(".+" if last else "(?:[^/]+/)*")
            else:
                body = "[^/]*".join(re.escape(piece) for piece in re.split(r"\*+", segment))
                parts.append(body + ("" if last else "/"))
        prefix = "" if anchored else "(?:.*/)?"
        self.regex = re.compile(prefix + "".join(parts))
        return True

    def matches(self, path):
        pieces = path.split("/")
        for count in range(1, len(pieces) + 1):
            is_dir = count < len(pieces)
            if self.dir_only and not is_dir:
                continue
            if self.regex.fullmatch("/".join(pieces[:count])):
                return True
        return False


def parse(text):
    rules = []
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        line = re.split(r"\s#", line, maxsplit=1)[0]
        tokens = line.split()
        if not tokens:
            continue
        rules.append(Rule(number, tokens[0], tokens[1:]))
    return rules


def real_owners(rule):
    return [o for o in rule.owners if OWNER_RE.match(o) and o.lower() != PLACEHOLDER]


def coverage(rules):
    unsupported = [r for r in rules if not r.supported]
    for probe in PROBES:
        if unsupported:
            print(
                "cannot-read %s: the pattern on line %d is not one this evaluation can resolve"
                % (probe, unsupported[0].line_no)
            )
            continue
        winner = None
        for rule in rules:
            if rule.matches(probe):
                winner = rule
        if winner is None:
            print("drift %s: no CODEOWNERS rule covers it" % probe)
        elif real_owners(winner):
            print("ok %s" % probe)
        elif any(o.lower() == PLACEHOLDER for o in winner.owners):
            print(
                "drift %s: the last matching rule (line %d) names only the placeholder @OKF_MAINTAINERS"
                % (probe, winner.line_no)
            )
        else:
            print(
                "drift %s: the last matching rule (line %d) names no owner"
                % (probe, winner.line_no)
            )


def placeholder(rules):
    for rule in rules:
        if any(o.lower() == PLACEHOLDER for o in rule.owners):
            print("drift placeholder: line %d still names @OKF_MAINTAINERS" % rule.line_no)
            return
    print("ok placeholder")


def main(argv):
    if len(argv) != 2 or argv[1] not in ("coverage", "placeholder"):
        sys.stderr.write("usage: codeowners.py coverage|placeholder < CODEOWNERS\n")
        return 2
    rules = parse(sys.stdin.read())
    if argv[1] == "coverage":
        coverage(rules)
    else:
        placeholder(rules)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
