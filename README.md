# Knowledge base

This repository is a knowledge base (KB) kept as plain Markdown documents under `bundle/`. Every change to it is a pull
request that is checked by the same engine the platform uses (`okf-check`), so a document that would break the knowledge
base never reaches the default branch. People report problems with three issue forms; a maintainer can ask an agent to
propose the fix as a pull request; a person always reviews and merges it.

This README belongs to your repository: the template never overwrites it. The files the template does own (workflows,
actions, scripts, the issue forms, the rules skill and the secret-scan configuration) are listed in
`.okf/template-manifest` and are brought up to date by a weekly pull request (see "Keeping up to date").

## Create your repository from the template

1. Open the public template repository and choose **Use this template**, then **Create a new repository**. Create it in
   the organisation or account that will own the knowledge base. A private repository needs GitHub Team or Enterprise
   (or a personal Pro account): environment secrets and their branch rules are part of the security model (see
   `.github/okf/CI.md`, section 2).
2. Clone it and replace `@OKF_MAINTAINERS` in `.github/CODEOWNERS` with your maintainer user or team, and list the
   maintainers' logins in `.okf/maintainers`. Until you do, code-owner review protects nothing.
3. Edit `.okf/publish.toml` (the platform instance and region the bundle is published to). Keep `bundle_root` equal to
   the bundle directory (`bundle`).

## One-time setup, in this order

Replace `<owner>/<repo>` with your repository. You need to be an administrator of the repository.

### 1. Bootstrap the settings

```bash
bash scripts/okf-bootstrap.sh --repo <owner>/<repo> --agent-app-slug <agent-app-slug>
```

Bootstrap creates the branch ruleset (the required checks `okf-check` and `okf-secret-scan`, code-owner review, one
approval from someone other than the last pusher, no force push), the four environments (`okf-engine-seed`, `publish`,
`agent`, `okf-maintenance`, each limited to the default branch), the Actions settings, the six labels, and two
repository variables: `OKF_AGENT_BOT_LOGIN` and `OKF_MAINTENANCE_ENABLED=true`. **`OKF_MAINTENANCE_ENABLED` is what
switches on the engine seed, template sync and the weekly doctor; without it they stay off**, so nothing runs in a
repository nobody bootstrapped. Add `--dry-run` first to see what it would write. It never writes a secret.

Create the agent App first (below) so you have its slug, or run bootstrap again later with the slug.

### 2. Install the two GitHub Apps

Two Apps keep the powers apart. Create each under your organisation (Settings, Developer settings, GitHub Apps), install
it on this repository only, generate a private key, and note its client ID.

**Agent GitHub App** (opens the agent's pull requests; it can never touch a workflow file):

- Contents: read and write
- Pull requests: read and write
- Issues: read and write
- Metadata: read
- No Workflows permission

**Maintenance GitHub App** (template sync and the weekly doctor; the only credential that can write workflow files):

- Contents: read and write
- Pull requests: read and write
- Workflows: read and write
- Issues: read and write
- Administration: read
- Actions: read
- Environments: read
- Secrets: read
- Metadata: read

### 3. Place each secret in its environment

Secrets live only in environments, never at repository level. Bootstrap lists the names still missing; place each one
with `gh secret set <NAME> --env <environment> --repo <owner>/<repo>` (the value is read from the prompt, never from the
command line).

| Environment | Secrets |
| --- | --- |
| `okf-engine-seed` | `ENGINE_RELEASE_TOKEN` |
| `publish` | `OKF_PUBLISH_ROLE_ARN`, `OKF_PUBLISH_AUDIENCE` |
| `agent` | `ANTHROPIC_API_KEY`, `OKF_AGENT_APP_CLIENT_ID`, `OKF_AGENT_APP_PRIVATE_KEY` |
| `okf-maintenance` | `OKF_MAINT_APP_CLIENT_ID`, `OKF_MAINT_APP_PRIVATE_KEY` |

Create the model key (`ANTHROPIC_API_KEY`) in a **dedicated Anthropic workspace** and set a **monthly spend limit** on that
workspace. The key's spend limit is the real cost cap of the agent; the per-run caps in `.okf/agent.toml` are only a second
fence. Never use a key from a workspace that also serves other work.

### 4. Seed the engine

The pull-request check never downloads anything: it restores the engine pinned in `.okf/engine.lock` from the Actions
cache, and fails closed when the cache has no entry. Push the first commit to the default branch (or run
**okf-seed-engine** from the Actions tab) and confirm the `okf-seed-engine` and `okf-bundle-view` runs are green before
opening a pull request. `.github/okf/CI.md` explains the engine pin, bumping it and recovering from a bad cache entry.

### 5. Run the doctor, then the probe

```bash
bash scripts/okf-doctor.sh --repo <owner>/<repo>
```

Run it until it exits 0. It only reads, and it checks the controls that are in force, not only that a setting exists.
Then run **okf-agent-probe** once from the Actions tab (Run workflow, on the default branch). Keep its green run as the
proof that the agent's tool boundary and its caps hold on this repository. Run it again after setup changes and after any
template sync that changes `.github/workflows/okf-agent.yml` or the pinned version of the agent action.

### 6. Replace the starter bundle

`bundle/` holds three starter files (`index.md`, `guides/index.md` and `guides/getting-started.md`) so the first required
check is green. Replace them with your own documents. Each folder has an `index.md` with one line
`* [Title](file.md) - description` per document; the check warns about a document its index does not list.

## Reporting problems

Anyone with access can open an issue with one of three forms: **wrong answer**, **missing knowledge** or **update**. The
forms apply the labels `okf:wrong-answer`, `okf:missing` and `okf:update`; the `okf-triage` workflow adds `okf:triaged`
when a report is complete. Blank issues are turned off, because a free-form issue has no contract for triage to check.
`.github/okf/ISSUE-CONTRACT.md` describes the headings each form carries.

The six labels are:

| Label | Meaning |
| --- | --- |
| `okf:wrong-answer` | A knowledge-base answer was wrong or outdated |
| `okf:missing` | Knowledge the knowledge base does not have yet |
| `okf:update` | A document needs to change |
| `okf:triaged` | Triage found the report complete (set by `okf-triage`, never by hand) |
| `agent:propose` | Maintainer-only trigger: runs the agent on this issue |
| `okf:drift` | Repository settings drift found by the weekly `okf-doctor` |

## The agent

A maintainer starts the agent by adding the label **`agent:propose`** to a triaged issue. Only a collaborator with write
access can do that, and the workflow checks it live when it runs, not when the label was set. A reporter, a form or a
workflow can never add that label.

- The agent reads a frozen copy of the issue (and its small readable attachments), not the live issue.
- It proposes **one pull request** on the branch `agent/issue-<n>`, changing documents under the bundle root.
- It cannot merge, approve, publish, add a human review stamp, delete or rename documents, or change anything outside
  the bundle root. It has no git and no network tool. A person reviews and merges the pull request, exactly as for any
  other change.
- Its limits (turns, time, budget, attachment sizes) are in `.okf/agent.toml`; changing them needs a code-owner review.
- Optional hardening: add required reviewers to the `agent` environment so each run waits for an explicit approval.

### Data handling

The text of an issue and its readable attachments are **sent to the model provider** (Anthropic) when the agent runs.
Do not put secrets or personal data in issues. On private repositories the agent may not be able to fetch an attachment;
it then works from the issue text alone. If your data must stay in your own region or account, discuss the provider
choice with your platform operator before enabling the agent.

## Keeping up to date

- **Template sync.** Weekly, `okf-template-sync` opens or updates ONE pull request from the branch `okf-template-sync`
  that brings every template-owned file (the ones `.okf/template-manifest` lists) to the newest template tag. When the
  engine pin moves it also seeds the new pin and re-runs its own check, so the pull request turns green by itself. It
  never approves or merges. Review it like any other pull request, and run **okf-agent-probe** again when it changes
  `.github/workflows/okf-agent.yml`.
- **Template-owned files are overwritten.** The issue forms (`.github/ISSUE_TEMPLATE/`) and the secret-scan configuration
  (`.okf/gitleaks.toml` and `.okf/gitleaks.lock`) belong to the template. A local edit is replaced by the next sync, so
  change them through a template release instead. Your bundle, this README, `.okf/maintainers`, `.okf/publish.toml`,
  `.okf/agent.toml` and the owners in `.github/CODEOWNERS` are yours and are never touched.
- **Weekly doctor.** `okf-doctor` reads the repository settings back and keeps exactly one open issue labelled
  `okf:drift` while anything has drifted. Fix the drift (or run `bash scripts/okf-doctor.sh --repo <owner>/<repo>`
  yourself); the issue closes on the next clean run.

## Review rule: add a second maintainer

The ruleset requires one approval from a code owner who is **not the last pusher**. A repository where a single account
has write access therefore cannot merge anything: the one maintainer cannot approve their own push. Add a second code
owner (a person or a team) before you need to merge, and keep that in mind when the agent opens its first pull request.

## More

- [`.github/okf/CI.md`](.github/okf/CI.md) - the CI runbook: what every workflow does, the settings, engine pin, publishing
  and troubleshooting.
- [`.github/okf/ISSUE-CONTRACT.md`](.github/okf/ISSUE-CONTRACT.md) - the labels and headings of the issue forms.
- [`.claude/skills/okf-kb-rules/`](.claude/skills/okf-kb-rules/SKILL.md) - the rules skill the agent (and Claude Code in
  this repository) follows when writing documents.
