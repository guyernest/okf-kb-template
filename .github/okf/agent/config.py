#!/usr/bin/env python3
"""okf-agent caps reader: .okf/agent.toml, validated, before any value becomes a job output (D-04).

Runs as the `Read the caps` step of the okf-agent `gate` job:  python3 -I .github/okf/agent/config.py

The file is read from the DEFAULT branch checkout (the workflow runs from there), never from a pull
request. A missing file means every default. Anything else that is not exactly the documented shape is
refused: an unknown key or table, a wrong type (a boolean is not a number), a value outside its fixed
range, a model name outside its pattern, an extension outside the readable set. A refusal prints one
sentence naming the key (never its value), writes `reason=config-invalid` to GITHUB_OUTPUT and exits 1;
no output and no caps file is written then.

On success it writes to GITHUB_OUTPUT: model, max-turns, timeout-minutes, max-budget-usd, and writes the
attachment caps as JSON to $RUNNER_TEMP/okf-gate/attachment-caps.json for the snapshot step.

Needs Python 3.11 or newer (tomllib); older Python is refused with a sentence that says so.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

try:
    import tomllib
except ImportError:  # pragma: no cover - only on Python older than 3.11
    tomllib = None

PREFIX = "okf-agent config"
SCHEMA_VERSION = 1
DEFAULT_CONFIG = os.path.join(".okf", "agent.toml")
MODEL_PATTERN = re.compile(r"^[a-z0-9][a-z0-9.-]{2,63}$")
EXTENSIONS = (".txt", ".md", ".csv", ".json", ".log", ".tsv", ".yaml", ".yml")

DEFAULT_AGENT = {"model": "claude-opus-5-5", "max_turns": 30, "timeout_minutes": 20, "max_budget_usd": 5}
DEFAULT_ATTACHMENTS = {
    "max_files": 10,
    "max_file_bytes": 10485760,
    "max_total_bytes": 26214400,
    "readable_extensions": [".txt", ".md", ".csv", ".json", ".log"],
}
# key -> (minimum, maximum), inclusive
INT_RANGES = {
    "max_turns": (1, 100),
    "timeout_minutes": (5, 60),
    "max_files": (0, 20),
    "max_file_bytes": (1, 26214400),
    "max_total_bytes": (1, 52428800),
}
BUDGET_RANGE = (0.5, 100)


class ConfigError(Exception):
    """The file is not acceptable; the message names a key, never a value."""


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def table(data, name, allowed):
    section = data.get(name, {})
    if not isinstance(section, dict):
        raise ConfigError(f"[{name}] must be a table")
    for key in section:
        if key not in allowed:
            raise ConfigError(f"[{name}] has an unknown key `{key}`")
    return section


def whole(section, name, key, default):
    value = section.get(key, default)
    low, high = INT_RANGES[key]
    if not isinstance(value, int) or isinstance(value, bool) or not low <= value <= high:
        raise ConfigError(f"[{name}] `{key}` must be a whole number from {low} to {high}")
    return value


def validate(data):
    """(agent values, attachment values), every one checked."""
    if not isinstance(data, dict):
        raise ConfigError("the file is not a table")
    if data.get("schema_version") != SCHEMA_VERSION or isinstance(data.get("schema_version"), bool):
        raise ConfigError(f"`schema_version` must be {SCHEMA_VERSION}")
    for key in data:
        if key not in ("schema_version", "agent", "attachments"):
            raise ConfigError(f"unknown key or table `{key}`")

    section = table(data, "agent", DEFAULT_AGENT)
    model = section.get("model", DEFAULT_AGENT["model"])
    if not isinstance(model, str) or not MODEL_PATTERN.match(model):
        raise ConfigError("[agent] `model` must be lowercase letters, digits, dots and hyphens, 3 to 64 characters")
    budget = section.get("max_budget_usd", DEFAULT_AGENT["max_budget_usd"])
    if not is_number(budget) or not BUDGET_RANGE[0] <= budget <= BUDGET_RANGE[1]:
        raise ConfigError(f"[agent] `max_budget_usd` must be a number from {BUDGET_RANGE[0]} to {BUDGET_RANGE[1]}")
    agent = {
        "model": model,
        "max_turns": whole(section, "agent", "max_turns", DEFAULT_AGENT["max_turns"]),
        "timeout_minutes": whole(section, "agent", "timeout_minutes", DEFAULT_AGENT["timeout_minutes"]),
        "max_budget_usd": budget,
    }

    section = table(data, "attachments", DEFAULT_ATTACHMENTS)
    extensions = section.get("readable_extensions", DEFAULT_ATTACHMENTS["readable_extensions"])
    if not isinstance(extensions, list) or not all(isinstance(e, str) and e in EXTENSIONS for e in extensions):
        raise ConfigError("[attachments] `readable_extensions` must be a list within " + " ".join(EXTENSIONS))
    attachments = {
        "max_files": whole(section, "attachments", "max_files", DEFAULT_ATTACHMENTS["max_files"]),
        "max_file_bytes": whole(section, "attachments", "max_file_bytes", DEFAULT_ATTACHMENTS["max_file_bytes"]),
        "max_total_bytes": whole(section, "attachments", "max_total_bytes", DEFAULT_ATTACHMENTS["max_total_bytes"]),
        "readable_extensions": list(dict.fromkeys(extensions)),
    }
    return agent, attachments


def load(path):
    if tomllib is None:
        raise ConfigError("Python 3.11 or newer is needed to read .okf/agent.toml (tomllib is missing)")
    if not os.path.exists(path):
        return {"schema_version": SCHEMA_VERSION}
    try:
        with open(path, "rb") as fh:
            return tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise ConfigError(f"the file could not be read as TOML ({type(exc).__name__})") from exc


def budget_text(value):
    """The budget as a plain decimal: 5 for 5.0, 7.5 for 7.5."""
    return str(int(value)) if float(value).is_integer() else repr(float(value))


def write_output(key, value):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(f"{key}={value}\n")


def main(argv=None):
    parser = argparse.ArgumentParser(prog=PREFIX, description="read and validate .okf/agent.toml")
    parser.add_argument("--config", default=DEFAULT_CONFIG, metavar="FILE", help="the caps file (default: .okf/agent.toml)")
    parser.add_argument("--caps-out", metavar="FILE", help="where to write the attachment caps (default: $RUNNER_TEMP/okf-gate/attachment-caps.json)")
    args = parser.parse_args(argv)
    caps_path = args.caps_out or os.path.join(os.environ.get("RUNNER_TEMP", ""), "okf-gate", "attachment-caps.json")
    try:
        agent, attachments = validate(load(args.config))
    except ConfigError as exc:
        write_output("reason", "config-invalid")
        sys.stderr.write(f"{PREFIX}: {exc}\n")
        return 1
    os.makedirs(os.path.dirname(caps_path), exist_ok=True)
    with open(caps_path, "w", encoding="utf-8") as fh:
        json.dump(attachments, fh, indent=2, sort_keys=True)
        fh.write("\n")
    write_output("model", agent["model"])
    write_output("max-turns", agent["max_turns"])
    write_output("timeout-minutes", agent["timeout_minutes"])
    write_output("max-budget-usd", budget_text(agent["max_budget_usd"]))
    print(f"{PREFIX}: caps read (max_turns {agent['max_turns']}, timeout {agent['timeout_minutes']} min)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
