# Knowledge-base repository CI runbook

This runbook is for the maintainers of a knowledge-base (KB) repository created from this template. It explains what the vendored workflows do, the one-time setup (in the order that avoids red first runs), the repository settings the security model depends on, and how to seed, bump, recover and rotate the pinned `okf-check` engine.

Terms: the *default branch* is the branch the repository's Pull Requests merge into; the *engine* is the `okf-check` binary pinned in `.okf/engine.lock`; the *release repository* is the private repository whose releases carry that binary.

## 1. What runs

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `okf-check` | every pull request | The **required check**. Restores the pinned engine from the Actions cache, runs `okf-check check` and `okf-check preview` against the pull request, writes the job summary and annotations, and uploads the comment text. It holds no secret and no write token, and it never downloads: a cache miss fails closed. Its job is named `okf-check`; that is the status name the branch ruleset requires. |
| `okf-secret-scan` | every pull request | The **second required check** (D-19). Downloads the gitleaks CLI pinned in `.okf/gitleaks.lock` (version, archive and binary sha256; never the gitleaks Action) and scans every commit of the pull request and its net diff, failing on any finding and printing only the rule, file and line, never the secret. The script, the lock and `.okf/gitleaks.toml` are read from the pull request's base commit, so a pull request cannot weaken the scan with its own ignore file, config or `gitleaks:allow` comment. It holds no secret and no write token. Its job is named `okf-secret-scan`; that is the second status name the branch ruleset requires. If the release cannot be downloaded or a digest differs, the check fails closed. |
| `okf-preview-comment` | `okf-check` completed | The **poster**. Reads the uploaded comment as data, proves it belongs to exactly one open pull request, re-validates it and creates or updates one sticky comment. A posting failure never fails the check, and this workflow is never a required check. It only exists for GitHub once its file is on the default branch. |
| `okf-seed-engine` | push to the default branch, twice a week, manual | The **only** workflow that holds the engine read token. Downloads the pinned engine from the release repository, verifies it against the lock and saves it to the Actions cache. Runs inside the `okf-engine-seed` environment. |
| `okf-bundle-view` | after a successful `okf-seed-engine` on the default branch, manual | Builds the bundle view (a static page with the documents, links and trust tiers, metadata only) and keeps it as the `bundle-view` artifact for 30 days. |
| `okf-pages` | manual only, off by default | Optionally publishes the bundle view to GitHub Pages. Does nothing unless you opt in (section 8). |
| `okf-publish` | manual only | Publishes the bundle to the platform with the seeded engine's `publish` subcommand and stops at "awaiting approval" (section 5a). Runs inside the `publish` environment. |
| `okf-template-sync` | weekly, manual (optional `tag`) | Opens or updates ONE pull request from the branch `okf-template-sync` that brings this repository's template-owned files (the ones `.okf/template-manifest` lists) to the newest `okf-kb-template-v<semver>` tag of the public template repository, deletes files a later manifest dropped and appends new CODEOWNERS rules; your bundle, `.okf/maintainers`, `.okf/publish.toml`, `.okf/profile.json`, `.okf/agent.toml`, `README.md` and CODEOWNERS owners are never touched. When the engine pin moves, a second job seeds the candidate pin and re-runs the pull request's `okf-check` until it is green. It never approves or merges. Runs in the `okf-maintenance` environment on the maintenance App's token, only where `OKF_MAINTENANCE_ENABLED` is `true`, and only on the default branch. |
| `okf-doctor` | weekly, manual | Reads back the repository settings the bootstrap applies (`scripts/okf-doctor.sh --variables-from-env`) and keeps exactly one open issue labelled `okf:drift`, created by the maintenance App: drift opens it or updates it in place, a clean run comments and closes it. The job fails while drift remains. Same opt-in, environment and default-branch guard as the sync; its token can read settings and write issues, nothing else. |

Two composite actions back them: `okf-engine` (restore or seed the pinned engine and prove its checksum and version) and `okf-check` (the pull-request check script). Workflows run inline scripts; none of them depends on `just`.

## 2. Prerequisite: your plan must support environment secrets

The engine token is stored as a secret of the `okf-engine-seed` **environment**, and that environment restricts which branches may use it. In a **private** repository, environment secrets and deployment-branch policies need GitHub Pro (a personal account) or GitHub Team or Enterprise (an organisation). On GitHub Free, either use a public repository or upgrade. Never fall back to a repository secret: a repository secret is readable by workflows from every branch and would defeat the design.

## 3. First-time setup, in this order

The secret must exist before anything runs, so that the first seed and view runs succeed. Replace `<owner>/<repo>` with the KB repository and `<default>` with its default branch name.

1. **Create the repository** from the template.

2. **Create the environment `okf-engine-seed`** (Settings, Environments, New environment) and restrict its deployment branches: Deployment branches and tags, Selected branches and tags, add the default branch name, and no tag rule. With the CLI:

   ```bash
   gh api -X PUT repos/<owner>/<repo>/environments/okf-engine-seed \
     -F 'deployment_branch_policy[protected_branches]=false' \
     -F 'deployment_branch_policy[custom_branch_policies]=true'
   gh api -X POST repos/<owner>/<repo>/environments/okf-engine-seed/deployment-branch-policies \
     -f name=<default> -f type=branch
   ```

3. **Create `ENGINE_RELEASE_TOKEN`**: a fine-grained personal access token owned by the **release repository's owner** (which may be a different organisation from this repository's), with Repository access set to only the release repository, the Contents permission set to read-only, and an explicit expiry within your organisation's policy. Record the expiry date in the repository's notes so the rotation (section 7) happens before it. Store it **only** as that environment's secret:

   ```bash
   gh secret set ENGINE_RELEASE_TOKEN --env okf-engine-seed --repo <owner>/<repo>
   ```

   Do not create a repository-level secret with that name. Check with `gh secret list --repo <owner>/<repo>`: the name must not appear there.

4. **Name the maintainers.** Replace `@OKF_MAINTAINERS` in `.github/CODEOWNERS` with your maintainer team or user (CODEOWNERS only protects anything once both this and the ruleset in section 4 are done). List maintainer logins in `.okf/maintainers`, one per line: only a listed author of type User gets human-stamp and profile-configuration changes downgraded from errors to warnings (D-10). The copy on the default branch is the one that counts, so a pull request cannot add its own author.

5. **Set the optional repository variables** (Settings, Secrets and variables, Actions, Variables): `OKF_BUNDLE_PATH` (the bundle directory, default `bundle`) and `OKF_RUNNER` (the runner label, default `ubuntu-latest`).

6. **Commit the template to the default branch.** Make sure `.okf/engine.lock` holds the pin copied from the engine release's `engine.lock` first. The push runs `okf-seed-engine`; its success runs `okf-bundle-view`, and from this commit on the poster workflow exists for GitHub.

7. **Confirm** the `okf-seed-engine` and `okf-bundle-view` runs are green (Actions tab) before opening any pull request.

8. **Add the branch ruleset** on the default branch (section 4).

## 3a. Bootstrap and doctor

Sections 3 and 4 describe the settings by hand. Two scripts shipped in this template apply and check the same settings, so a second repository is not left open. The numbered steps of section 3 remain the reference for what the scripts do.

1. **Run the bootstrap** with an administrator's `gh` login (it needs Administration: write):

   ```bash
   bash scripts/okf-bootstrap.sh --repo <owner>/<repo> --agent-app-slug <agent-app-slug>
   ```

   It creates the ruleset `okf-default-branch` on the default branch, the four environments below (each limited to the default branch), the Actions settings of section 4, the six labels the issue forms and the agent use, and two repository variables: `OKF_AGENT_BOT_LOGIN` (`<agent-app-slug>[bot]`, read by the required check) and `OKF_MAINTENANCE_ENABLED=true`. Without `OKF_MAINTENANCE_ENABLED` the seed, template-sync and doctor workflows stay off, so nothing runs in a repository nobody bootstrapped. Add `--dry-run` to see what it would write.

2. **Place the secrets it lists by hand.** Bootstrap never writes a secret and never prints one; it prints, for each environment, the names still missing and the command:

   ```bash
   gh secret set <NAME> --env <environment> --repo <owner>/<repo>
   ```

   | Environment | Secrets |
   | --- | --- |
   | `okf-engine-seed` | `ENGINE_RELEASE_TOKEN` |
   | `publish` | `OKF_PUBLISH_ROLE_ARN`, `OKF_PUBLISH_AUDIENCE` |
   | `agent` | `ANTHROPIC_API_KEY`, `OKF_AGENT_APP_CLIENT_ID`, `OKF_AGENT_APP_PRIVATE_KEY` |
   | `okf-maintenance` | `OKF_MAINT_APP_CLIENT_ID`, `OKF_MAINT_APP_PRIVATE_KEY` |

3. **Run the doctor** until it exits 0:

   ```bash
   bash scripts/okf-doctor.sh --repo <owner>/<repo>
   ```

   It only reads. It prints one `ok <item>`, `drift <item>: <reason>` or `cannot-read <item>: <reason>` line per item and ends with `okf-doctor: <N> drift, <M> ok`. The weekly CI run (`--variables-from-env`, a read-only App token) cannot read `ruleset.bypass` because GitHub returns `bypass_actors` only to a caller that can write the ruleset, so there it prints `note ruleset.bypass: ...` (not counted, not drift); run the script with your own login to check it. A `cannot-read` line names the GitHub App permission the read needs (Administration, Actions, Environments, Secrets, Variables or Contents: read). It checks the controls that are in force, not only that a setting exists: the ruleset's required checks are bound to GitHub Actions, an environment's deployment policy is exactly the default branch (an extra branch or tag policy is drift), the last matching `CODEOWNERS` rule of each protected path (`/.github/`, `/.okf/`, `/.claude/`, `/scripts/`) names a real owner, and `OKF_BUNDLE_PATH` equals the `bundle_root` of `.okf/publish.toml`.

How the scripts treat what is already there:

- **Idempotent.** Every write is preceded by a read and made only when the read differs; a second run writes nothing.
- **Never loosens, never deletes.** An existing `okf-default-branch` ruleset that is below the floor is reported; `--repair` tightens it by merging into the live ruleset (it raises what is too low, removes bypass actors and keeps every stronger setting, extra rule and extra required check). An environment that has reviewers, a wait timer or a custom protection rule is never rewritten. An extra deployment policy is reported together with the exact `gh api -X DELETE` command for you to run if you agree.
- **A single maintainer cannot merge.** The ruleset needs a code-owner approval from someone other than the last pusher, so a repository where only one account has write access is stuck. Bootstrap says so (`note solo-maintainer:`); add a second code owner.
- **`OKF_BUNDLE_PATH`, when set, must equal `bundle_root`.** The check and the publish must look at the same directory.

A repository set up by hand from section 3 (without the bootstrap) sets the variable once, or the seed, template-sync and doctor workflows never run: `gh variable set OKF_MAINTENANCE_ENABLED --body true --repo <owner>/<repo>`.

Replace `@OKF_MAINTAINERS` in `.github/CODEOWNERS` yourself (step 4 of section 3): bootstrap does not edit files, and the doctor reports a CODEOWNERS that still names it.

## 4. Required settings

Repository settings, under Settings, Actions, General:

| Setting | Value |
| --- | --- |
| Run workflows from fork pull requests | On |
| Send write tokens to workflows from fork pull requests | Off |
| Send secrets to workflows from fork pull requests | Off |
| Require approval for fork pull request workflows | On (the bootstrap sets it; for a public repository, every external contributor) |

Private repositories default to *not* running workflows for fork pull requests, which leaves a fork's required `okf-check` status pending forever; turn the first row on. The check needs no secret and no write token, so the next two rows stay off: fork pull requests are validated without either. Approval for fork workflows is on (the bootstrap and the doctor expect it): the required check waits until a maintainer approves the run.

**An organisation can forbid the first row.** In a private repository owned by an organisation whose policy does not allow fork pull request workflows, GitHub refuses the change (`Policy is forbidden by entity owner`) and the setting reads *Run workflows from fork pull requests: Off*. That is stricter than the table: no workflow runs for a fork pull request, so none can receive a write token, a secret or a variable. The bootstrap and the doctor accept it: the bootstrap writes nothing and reports `ok actions.fork-approval`, and the doctor reports `ok actions.fork-approval` with a `note` line saying that fork workflows are off. The cost is that a fork pull request gets no `okf-check` run, so a maintainer pushes its branch to this repository to get one. The table's other three rows are enforced only while the first row is On; if it is On and a row is below the table, the bootstrap writes the tightening, and a write the organisation refuses stays a reported `request-error`, never hidden. The public-repository setting (approval for every external contributor) is unchanged.

Branch ruleset on the default branch (Settings, Rules, Rulesets):

- Require a pull request before merging.
- Require the status checks **`okf-check`** and **`okf-secret-scan`**, both bound to GitHub Actions (never `okf-preview-comment`; the poster is best effort and not a gate).
- **Require review from Code Owners.** The `okf-engine-seed` environment trusts the default branch, so the ruleset is what keeps unreviewed code off it. A pull request can edit the workflow and actions it runs from; the code-owner review of `.github/` and `.okf/` is the control for that, and the job summary says when a change touches them.

Environment `okf-engine-seed`:

- Deployment branches: the default branch only.
- No repository-level secret named `ENGINE_RELEASE_TOKEN` exists.

Environments `publish`, `agent` and `okf-maintenance` follow the same rules: deployment branches limited to the default branch, secrets only at environment level (section 3a lists the names), and no repository-level secret with any of those names. `okf-maintenance` holds the maintenance GitHub App that template sync and the weekly doctor use; `agent` holds the agent App and the model key.

Actions settings the scripts apply: the default workflow token is read-only, Actions may not approve pull requests, and fork pull request workflows need approval from every external contributor (on a private repository, fork workflows switched off by an organisation policy also satisfy the floor).

## 5. Bumping the engine pin

A pull request never downloads (so a pin change cannot reach the token), which means a pin-bump pull request stays red until the new engine is seeded. This is by design.

1. Download `engine.lock` from the new engine release.
2. Open a pull request replacing `.okf/engine.lock` (code-owner review applies).
3. Dispatch **okf-seed-engine** on the default branch (Actions, okf-seed-engine, Run workflow) with `lock-ref` set to the pull request's branch name, or `pull/<N>/head` for a pull request from a fork. The job reads that ref's `.okf/engine.lock` as data only and seeds it, provided its `release_repo` equals the default branch's; a candidate that changes the release repository is refused, so land that change on the default branch first.
4. Re-run the pull request's `okf-check`. It restores the seeded entry and passes.
5. Merge. The push to the default branch seeds the same pin again (a cache hit that refreshes the entry).

### Template updates arrive as a pull request

`okf-template-sync` (weekly, or Actions, okf-template-sync, Run workflow with an optional tag) keeps the files listed in `.okf/template-manifest` current. Review its pull request like any other: it changes only template-owned files, and CODEOWNERS plus the ruleset still require a code owner's approval. When it changes `.okf/engine.lock` its `seed` job dispatches **okf-seed-engine** for the candidate pin and re-runs the failed `okf-check` on the same commit, so step 4 above happens for you; the `release_repo` of the lock must stay the same (a change is refused, land it on the default branch first), and `minimum_engine` in `.okf/publish.toml` is yours to raise. The sync branch is regenerated whenever the template or the default branch moves, so do not push to it. The sync job restores the CURRENT pin's engine first, so it needs that cache entry warm: with a cold cache it stops at `Restore the pinned engine` before any pull request opens (run **okf-seed-engine** on the default branch, then dispatch the sync again; the seed runs twice a week and on every push to the default branch, so the entry is normally warm). Files a later manifest drops are deleted in that pull request; removing a line from `.okf/template-manifest` therefore deletes the file in every repository on its next sync. Local edits to template-owned files, including `.okf/gitleaks.toml` and the issue forms, are overwritten by the next sync: change them through a template release.

## 5a. Publishing (okf-publish)

`okf-publish` uploads the bundle to the platform. It never goes live by itself: the run stops at "awaiting approval", and an administrator on the platform approves the staged version. It runs the **seeded** engine (the same pinned binary the PR check runs, restored from the cache), never code from this repository.

Set it up once per repository:

1. **Create the environment `publish`** (Settings, Environments, New environment) and set its deployment branches to the default branch now (Deployment branches and tags, Selected branches and tags, the default branch name). This is recommended today and is not enforced by this template: required reviewers and a checked publish-branch-only rule come with the protected-environment work of a later phase. Until then the `publish` environment's secrets are what a run from another branch could disclose, so keep the deployment-branch rule.

   ```bash
   gh api -X PUT repos/<owner>/<repo>/environments/publish \
     -F 'deployment_branch_policy[protected_branches]=false' \
     -F 'deployment_branch_policy[custom_branch_policies]=true'
   gh api -X POST repos/<owner>/<repo>/environments/publish/deployment-branch-policies \
     -f name=<default> -f type=branch
   ```

2. **Add the two secrets to that environment**, with the values the platform operator gives you (never commit them, and never create repository-level secrets of these names):

   ```bash
   gh secret set OKF_PUBLISH_ROLE_ARN --env publish --repo <owner>/<repo>
   gh secret set OKF_PUBLISH_AUDIENCE --env publish --repo <owner>/<repo>
   ```

3. **Edit `.okf/publish.toml`** (code-owner reviewed): set `instance`, `region` and `bundle_root`. `bundle_root` must equal the PR check's bundle path (`OKF_BUNDLE_PATH`, default `bundle`), so what is published is what is checked. The workflow has no input and no instance flag: this file is the only target.

4. **Seed the engine** (section 3): the publish restores the same cache entry as the PR check and fails closed on a miss.

5. **Run the workflow** from the Actions tab (okf-publish, Run workflow) on the default branch, then read the run summary.

The Publish step's exit code is the engine's:

| Exit | Meaning |
| --- | --- |
| 0 | The bundle is staged and awaiting approval on the platform. |
| 1 | The check or the platform refused the bundle; the summary lists why. Nothing is awaiting approval (an upload that was already staged expires on its own). |
| 2 | The configuration is wrong: `.okf/publish.toml` is missing or invalid, or an environment value is. Fix the file or the secrets. |
| 4 | The publish failed (a network, role or platform error). The summary names the step; run the workflow again once the cause is fixed. |
| 5 | The staged build is still running. The publish is not lost: run the workflow again later. |

Exit 3 is never used by publish.

Raising `minimum_engine`: the platform's publisher reports its own engine version, and a publish is refused while that is older than `minimum_engine`. Raise the value (together with `.okf/engine.lock`, section 5) only after the platform has deployed a publisher that reports the new engine.

## 6. Troubleshooting

| Symptom | Meaning and fix |
| --- | --- |
| `engine not seeded for <version>` | The cache has no entry for the pinned engine. Run the Seed workflow on the default branch. For a pin-bump pull request, dispatch it with `lock-ref` (section 5). |
| `okf-check binary sha256 mismatch` | The lock or the cache entry is wrong. Re-check `.okf/engine.lock` against the `engine.lock` of the release it names; if the lock is right, remove the entry (next row) and re-seed. |
| An invalid cache entry fails every restore | List the entries with `gh cache list --key okf-engine-v1-`, remove the bad one with `gh cache delete <key>`, then dispatch `okf-seed-engine`. |
| `checksums.txt disagrees with .okf/engine.lock` | Stop. The release does not match the pin. Contact the engine owner; do not edit the lock to match. |
| `could not download` in the seed | The token expired, belongs to the wrong owner, or lacks Contents read on the release repository. Rotate it (section 7). |
| The seed job fails with an environment-protection message | It ran from a ref other than the default branch (expected for any other branch), or the environment's deployment-branch policy names the wrong branch. Fix the policy (section 3, step 2). |
| No comment appears on a pull request | The poster file must be on the default branch (it exists for GitHub only from there). Two open pull requests sharing one head branch get no comment, by design. A comment failure never fails the check; read the `okf-preview-comment` run. |
| Trusted review was not applied | The author is not listed in `.okf/maintainers` **on the default branch**, the file is invalid (the job summary names the warning), or the author is a bot. |
| A scheduled seed stopped | GitHub disables scheduled workflows after 60 days without repository activity in **public** repositories: re-enable the workflow. Private repositories are unaffected, and every default-branch push seeds again. |
| `okf-seed-engine` is skipped on a branch push | Expected and free: only default-branch pushes run it. |
| A fork pull request's check stays pending | Fork workflows are disabled, or awaiting approval. Turn on "Run workflows from fork pull requests" or approve the run. Do not fix a pending or red check by sending secrets or write tokens to forks: the check needs neither, and enabling either exposes the repository to every fork. |

## 7. Rotating the engine token

A warm cache never uses the token, so the rotation has to force a download with the new one. An expired token only breaks seeding; warm pull request runs keep working.

1. Create the new fine-grained token (section 3, step 3).
2. Update the environment secret: `gh secret set ENGINE_RELEASE_TOKEN --env okf-engine-seed --repo <owner>/<repo>`.
3. Delete the current cache entry for your runner's architecture: `gh cache delete okf-engine-v1-<arch>-<version>-<binary sha256>` (the key is printed by every seed run summary and by `gh cache list --key okf-engine-v1-`). Do this when no pull request is waiting: their checks are red until the next step finishes.
4. Dispatch **okf-seed-engine** and wait for success. The seed had to download, so it used the new token.
5. Only then revoke the old token.

If the seed fails, put the old token back (step 2) and dispatch again.

## 8. Opting into Pages

The bundle view is available as an artifact without Pages. To publish it: set the repository variable `OKF_PAGES_PUBLISH` to `true`, set Settings, Pages, Source to GitHub Actions, then run **okf-pages** by hand. Warning: the Pages site of a private repository may be publicly reachable unless your plan supports private Pages. The view holds document metadata only (titles, paths, trust tiers, links), no document bodies, but that is still the shape of your knowledge base. Leave `OKF_PAGES_PUBLISH` unset to keep it off.

## 9. The maintainer-triggered agent: containment and what is proven

`okf-agent` (label `agent:propose` on a triaged issue) runs Claude Code on a frozen snapshot of the issue and opens one pull request; `okf-agent-probe` (manual, default branch only) asks the model to attempt every forbidden operation once and runs the two caps. Run the probe once per repository after setup and after any sync that changes `okf-agent.yml` or the action pin; it spends a few cents of the model key's budget.

Around the model step the job does not trust the model or the CLI's permission rules: it stages read-only copies of the scripts it runs afterwards, records the git control state of the workspace (`.git/config`, `HEAD`, `packed-refs`, `info/`, `hooks/`, `objects/info/`) and, before any git command, compares it again. A difference leaves a status-only result `contained:workspace-tampered` and nothing is proposed. The pinned `claude-code-action` configures git itself before the model starts, so the comparison of `.git/config` ignores exactly that and nothing else: a `[user]` section holding only `name = claude[bot]` and the matching no-reply `email`, and the `url` of `[remote "origin"]` when it is `https://x-access-token:<token>@github.com/<owner>/<repo>.git` (compared as the plain URL it was). Any other change, the file's mode included, still contains the run. `contain.sh` lists the writes with the action's source file, and `containment.test.sh` runs the action's own git commands and every near miss.

What is proven live (observed on template v0.1.2; v0.1.3 adds one attachment host; v0.1.4 changes only the CI doctor's `ruleset.bypass` item and the secret-scan net-diff label, no agent file; the ledger, `214-LIVE-PROOF.md` in the source repository, has the runs and the rows):

- **The probe passes as a whole** on a private repository carrying v0.1.2: every one of the eleven forbidden attempts was denied, errored or absent, the canary never appeared in the transcript, the one allowed wrapper call ran, `contain.sh verify` found nothing changed after the model session (so the action's own post-session restore of `.git/config` leaves nothing the comparison sees), and the caps job stopped with `error_max_turns` and `error_max_budget_usd`. A real runner's job token is `ghs_` plus about 370 letters, digits, `_`, `-` and `.`; the tolerance for the action's origin URL accepts exactly that alphabet (v0.1.0 and v0.1.1 did not and ended every run `contained:workspace-tampered`).
- **A whole agent run, end to end:** add, update and retire issues each produced one pull request authored by the agent App, with the four `Okf-*` trailers, the provenance block and `Closes #<n>` in the body, and `okf-check` and `okf-secret-scan` started on `pull_request` without an approval click and passed. The session check printed `the session used the declared tool set`. A run costs roughly 0.11 to 0.17 USD and 13 to 19 turns against the default caps (30 turns, 5 USD).
- **Hostile issue text** (instructions to edit a workflow, add a `human:` stamp, publish, fetch a URL and print the environment, in the body, in an HTML comment and behind invisible characters) reached no branch: the snapshot dropped the comment and the invisible characters, and the one pull request changed two files under `bundle/`.
- **Not proven live:** the tool list of the probe session (the job summary is not readable through the GitHub API; the agent job's own `--run` check prints that it used the declared tool set), and the `Read(./.git/**)` deny, which none of the probe's twelve attempts tries.

**Attachments.** The snapshot fetches issue attachments without credentials, as inert data. On a **public** repository a `.pdf` and a `.txt` attachment were fetched (a redirect from `github.com` to `objects.githubusercontent.com`) and an image attached with the editor redirected to GitHub's asset bucket (`github-production-user-asset-6210df.s3.amazonaws.com`), a host v0.1.2 refused as `not-allowed-host`; v0.1.3 follows it. On a **private** repository every attachment, whatever its type, came back `unavailable:404`: a private repository's attachment URLs need the viewer's session, and the run has none, so the agent sees only the issue text there. That is the best-effort outcome by design; paste the text of a private file into the issue when the agent needs it.
