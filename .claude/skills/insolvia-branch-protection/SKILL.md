---
name: insolvia-branch-protection
description: >-
  How to add or remove a required status check on insolvia-services' `main`
  yourself, instead of asking a human to click through repo settings. Use
  this whenever a task means changing the `protect-main` ruleset — "make the
  new workflow's check required", "add a PR check to the ruleset", "gate
  merges on Terraform validate" — or diagnosing a PR stuck on "Expected —
  waiting for status to be reported". Trigger it the moment you rename a job
  `name:` or a matrix leg in any `*-pr.yml`, because the ruleset matches checks
  by exact name and a rename silently orphans the gate. Read it BEFORE
  hand-rolling `gh api --method PUT .../rulesets/<id>`: that call REPLACES the
  arrays you send, so a partial payload deletes every other rule on `main`.
  There is no `gh ruleset edit` — don't go looking for one.
---

# Changing `main`'s required checks (insolvia-services)

**This does not need a human.** Don't ask the user to open repo settings.

```bash
scripts/update-ruleset.sh show
scripts/update-ruleset.sh add "Terraform validate (shared)"
scripts/update-ruleset.sh remove "Terraform validate (shared)"
```

It shows a before/after diff and asks before writing. It targets
`insolvia-ai/insolvia-services` unless `INSOLVIA_REPO=owner/name` says
otherwise — the insolvia repo has its own `protect-main`, its own copy of this
script, and its own list. Rollback:
`gh api /repos/insolvia-ai/insolvia-services/rulesets/<id>/history`.

## The required checks

Every PR gate here triggers on **every** PR and reports `success` quickly when
its paths are untouched (`.github/actions/changed-paths` says why a `paths:`
filter would deadlock a required check). The name is the job's `name:`,
matched **character for character**; matrix legs get a `(leg)` suffix.

| Check | Reported by |
|---|---|
| `Mailer service` | `mailer-pr.yml` |
| `Terraform validate (shared)` | `infra-pr.yml`, matrix leg `shared` |
| `Terraform validate (staging)` | `infra-pr.yml`, matrix leg `staging` |
| `Terraform validate (prod)` | `infra-pr.yml`, matrix leg `prod` |
| `Terraform validate (ci-trust)` | `infra-pr.yml`, matrix leg `ci-trust` |
| `Terraform validate (account-access)` | `infra-pr.yml`, matrix leg `account-access` |

All six are required. `ci-trust` and `account-access` are required here even
though they were optional in the insolvia repo: they are this repo's point,
and a broken trust anchor should be found at review, not at the next human
apply. **This table is the owner of the list** — update it in the same PR
that changes a workflow's job name or matrix, then run the script.

A typo doesn't error. GitHub accepts a required check nobody reports, and every
PR then parks on *"Expected — waiting for status to be reported"* forever.
Copy the name from the workflow file; don't type it from memory.

## Why the script exists rather than a `gh api` one-liner

- **`PUT /repos/{owner}/{repo}/rulesets/{id}` replaces the arrays it receives.**
  It takes `name`, `target`, `enforcement`, `bypass_actors`, `conditions`,
  `rules` — all optional — and whatever array you send wholly replaces its live
  counterpart. Send `rules` containing just your new check and `deletion`,
  `non_fast_forward` and `required_linear_history` are gone from `main`. The
  REST docs don't mention this. Hence read-modify-write, always.
- **A live `GET` is not a valid `PUT` body** — it also returns `id`, `node_id`,
  `source`, `created_at`, `_links`, `current_user_can_bypass`. Project to the
  six fields above.
- **Ids rot.** The script resolves by name, never by a hard-coded id: a
  ruleset recreated in the UI comes back with a new one.

## Gotchas

- **The ruleset must exist first.** The script edits `protect-main`; it does
  not create it. On a fresh repository, create `protect-main` once in the UI
  (target `main`), then add the checks above with the script.
- **`gh ruleset` is read-only** — `check`, `list`, `view`, nothing else (gh
  2.96). Mutations go through `gh api`.
- **`bypass_actors` is only returned to a caller with write access.** Without
  admin it reads as empty, and writing that back would silently drop every
  bypass. Check `gh auth status` first (and the `insolvia-github-auth` skill).
- **`enforcement: evaluate`** reports what *would* have been blocked without
  blocking — a way to land a new required check without stopping merges on day
  one. `disabled` turns the ruleset off entirely.
- **This isn't a deploy.** `insolvia-deploy`'s "deploys run in CI, never from
  your CLI" rule doesn't apply — this runs from your machine against the GitHub
  API, as a repo admin.
