# Issue contract

The label and heading contract for reports about this knowledge base. The machine-readable source is
[`issue-contract.json`](issue-contract.json); this page explains it. The three issue forms in
`.github/ISSUE_TEMPLATE/`, the `okf-triage` workflow (`triage.py`), the agent's input gate and any tool
that creates a report through the API all read the same contract.

## The three kinds

A report is exactly one of three kinds. The kind is the issue's **kind label**, and the form applies it
when the report is opened.

| Kind | Label | Form |
|---|---|---|
| Wrong answer | `okf:wrong-answer` | `wrong-answer.yml` |
| Missing knowledge | `okf:missing` | `missing-knowledge.yml` |
| Update | `okf:update` | `update.yml` |

### Wrong answer (`okf:wrong-answer`)

Required: `Question you asked`, `Answer you received`, `What the answer should say`.
Optional: `How you know (sources)`, `Documents the answer cited`, `Supporting files`,
`Anything else (attach files here too)`.

### Missing knowledge (`okf:missing`)

Required: `Question you asked`, `What is missing`.
Optional: `Where the knowledge lives (sources)`, `Supporting files`,
`Anything else (attach files here too)`.

### Update (`okf:update`)

Required: `Document to update`, `What changed`, `Source of the change`.
Optional: `Effective date`, `Supporting files`, `Anything else (attach files here too)`.

## How a report is read

GitHub renders each form field into the issue body as `### <heading>` on its own line, a blank line,
then the value. A field left empty is rendered as `_No response_`. Triage reads the body the same way:

- A section starts only at a line that is exactly `### ` followed by one of **this kind's** headings
  (trailing spaces removed). Any other `###` line, including a heading of another kind, stays part of
  the value it appears in.
- A value that is empty, `_No response_`, or only invisible characters counts as empty.
- Every required heading must appear once with a non-empty value. A heading that appears twice makes
  the report invalid. A body longer than 65,536 characters is invalid. An issue with more than one kind
  label is invalid.
- Windows line endings are accepted. A heading that carries a zero-width or direction-control
  character is a different heading and does not match.

## Labels and who may apply them

- `okf:triaged` is applied **only by the triage workflow**, and only to a report whose body satisfies
  this contract. Triage reads the live issue on every run, so a label applied or removed by hand is
  corrected the next time the issue changes: an invalid report loses it, and so does an issue with no
  kind label.
- `agent:propose` starts the agent. It is a **maintainer-only** trigger: no form, reporter, workflow or
  tool may add it, and a tool that creates reports through the API must never add it either.
- A tool that creates a report through the API must send the same headings as the form for its kind
  and carry exactly one kind label. The API never shows the form, so triage is what checks it.

## What triage does

Triage never quotes the report. For an invalid one it removes `okf:triaged` if present and keeps a
single comment that starts with `<!-- okf-triage:v1 -->` and names only the sections to fix. For a valid
one it adds `okf:triaged` if absent and deletes that comment. An issue with no kind label is left alone,
except that a stale `okf:triaged` is removed.
