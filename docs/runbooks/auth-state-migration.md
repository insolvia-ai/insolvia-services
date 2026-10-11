# Cutover: auth (Cognito) leaves the insolvia repo

**Status: not yet executed.** When it has run, record the date, who ran it and
the backup directory names here. Do not delete the page.

The decision is insolvia's
[ADR 0026](https://github.com/insolvia-ai/insolvia/blob/main/docs/adr/0026-auth-is-a-shared-service.md),
which amends ADR 0025: auth is a shared service. This runbook moves the live
user pools, their hosted domains and their app clients out of insolvia's state
into this repo's. It follows the pattern of the mailer's move,
[`state-migration.md`](state-migration.md). It differs in four ways, all
covered below:

1. **The module splits.** `module.auth` exists on both sides afterwards.
   Seven resource blocks move here. Four stay in insolvia at their unchanged
   addresses: the two managed-login branding styles and the two
   `AdminCreateUser` grants. `--keep` names those four.
2. **This repo's roots are not empty.** They already hold `module.mailer`.
   The script refuses only if this side already holds something under
   `module.auth`.
3. **Prod has a precondition.** Prod's pool lacks the portal and `mcp-claude`
   clients that insolvia's main already declares. Until insolvia's prod has
   applied main, the move would plan to *create* clients here, and the
   script refuses that.
4. **Developer machines move too**, each one once, by its owner.

| Root | State key | What moves |
|---|---|---|
| staging | `insolvia/staging/…` → `insolvia-services/staging/…` | 7 blocks, 8 instances: pool, prefix + custom domain, the custom domain's alias record, app / portal / mcp[claude, inspector] clients |
| prod | `insolvia/prod/…` → `insolvia-services/prod/…` | pool, prefix domain, app / portal / mcp[claude] clients (once prod has applied main) |
| dev, per machine | `insolvia/dev/<acct>/<machine>/…` → `insolvia-services/dev/<acct>/<machine>/…` | pool, prefix domain, app / portal / mcp[claude, inspector] clients |

**Nothing in AWS is created, changed or destroyed.** Every pool keeps its id,
users and subjects. Every client keeps its id, so the SSM parameters, the
deployed app bundles and every token already issued stay valid.

## What can go wrong, and what stops it

| Ordering | Would cause | Stopped by |
|---|---|---|
| insolvia's **new** code applies before the move | it would forget the pool (no longer declared there); a forgotten pool can still be recovered | the `removed { … destroy = false }` blocks insolvia's PR adds to all three env roots; without them this would be a **destroy** |
| insolvia's **old** code applies after the move | a second pool, because the old code still declares one and the state no longer holds it. Cognito allows duplicate names, and the domain prefix collides partway through | step 2 freezes insolvia's release **and** the dispatchable `infra-staging.yml` / `infra-prod.yml` |
| this repo's **old** code (main, no `module.auth`) applies after the move | it would **destroy** the pool. Staging has no deletion protection, clients never do | step 2 freezes this repo's release **and** the dispatchable `mailer-staging.yml` / `mailer-prod.yml` |
| this repo's **new** code applies before the move | a second pool | the deploy workflows' state guard: they refuse when `module.auth` (or `module.mailer`) is missing from the state, unless someone passes `bootstrap: true` |
| any later plan destroys or replaces a pool or client | every account gone, or a new client id | the deploy workflows refuse such a plan unless a human dispatches with `allow_auth_destroy: true`; a release cannot |

The move itself is
[`scripts/migrate-module-state.sh`](../../scripts/migrate-module-state.sh),
run by a human with admin credentials, for the reasons its header gives. It
backs up both states, moves the resources between local copies, pushes both
states and verifies with two plans:

- **Here:** no create, destroy or replace anywhere. No human can override this.
- **insolvia:** nothing at all changes under `module.auth`, moved or kept.

If either plan is wrong, it **restores both states automatically**.
`--rehearse` runs all of this read-only against local copies.

## Rehearsal results so far

All runs were read-only, with copies deleted afterwards.

| Date | Env | Result |
|---|---|---|
| 2026-10-11 | staging | **PASSED.** Here: no resource changes, only seven new `auth_*` outputs. insolvia: "No changes. Your infrastructure matches the configuration." |
| 2026-10-11 | dev (one machine) | **PASSED.** Here: no resource changes, outputs only. insolvia's dev root: no changes. |
| 2026-10-11 | prod | **FAILED, as expected.** Here it would *create* `aws_cognito_user_pool_client.portal` and `.mcp["claude"]`, and update the pool in place. insolvia's lookup postcondition fails because the portal client does not exist. Promote insolvia's prod first. |

## Before you start

- **Both PRs are open and green:** insolvia's (the consumer `modules/auth`,
  the `removed` blocks, and the dev scripts calling this repo) and this
  repo's (`modules/auth`, `module.auth` in staging/prod, the `dev` root, the
  generalised script, the guards).
- **Prod has applied insolvia's main**, through a normal promotion of a
  release that includes everything up to insolvia's PR base. Check with
  step 1's prod rehearsal. If it still plans client creates here, you are
  not ready.
- Checkouts side by side: this repo **at its PR's branch**, insolvia **at its
  PR's branch**.
- `aws login` as yourself in account `521762924626` (see the
  `insolvia-aws-auth` skill).
- About 45 minutes during which nothing merges in either repo.

The `--keep` list is the same everywhere. It is written out once here:

```bash
KEEP=(--keep aws_cognito_managed_login_branding.web --keep aws_cognito_managed_login_branding.portal --keep aws_iam_role_policy.api_invite --keep aws_iam_role_policy.admin_invite)
```

## Steps

### 1. Rehearse, read-only

```bash
scripts/migrate-module-state.sh staging --module module.auth --insolvia-dir ../insolvia "${KEEP[@]}" --rehearse
scripts/migrate-module-state.sh prod    --module module.auth --insolvia-dir ../insolvia "${KEEP[@]}" --rehearse
```

Each run must end with `REHEARSAL PASSED`. This step pushes nothing and takes
no locks, so it is safe to run while the pipelines are still live.

### 2. Freeze both repositories

Freeze every workflow that can apply one of the four roots:

```bash
for wf in release.yml infra-staging.yml infra-prod.yml; do gh workflow disable "$wf" -R insolvia-ai/insolvia; done
for wf in release.yml mailer-staging.yml mailer-prod.yml; do gh workflow disable "$wf" -R insolvia-ai/insolvia-services; done
for repo in insolvia-ai/insolvia insolvia-ai/insolvia-services; do
  gh run list -R "$repo" --limit 20 --json databaseId,workflowName,status \
    --jq '.[] | select(.status != "completed") | "\(.databaseId) \(.workflowName)"'
done
```

Cancel **every** run that has not completed, including one waiting at a
`promote` gate. If an old waiting run is approved after the move, it applies
the old code (see the table above).

```bash
gh run cancel <id> -R <repo>
```

### 3. Move staging

```bash
scripts/migrate-module-state.sh staging --module module.auth --insolvia-dir ../insolvia "${KEEP[@]}"
```

It lists what moves and what stays, then asks before moving. It finishes with
`Migrated module.auth: insolvia/staging → insolvia-services/staging` and the
backup directory. A `restored` line means both states were put back and the
script stopped. Read its output, fix the cause, and run it again.

### 4. Move prod

```bash
scripts/migrate-module-state.sh prod --module module.auth --insolvia-dir ../insolvia "${KEEP[@]}"
```

You may see in-place updates on the pool here (the prod rehearsal showed
one). If so, read the diff the script points to before you answer. A create,
destroy or replace is refused and restored without asking. That includes the
client creates the rehearsal saw, which mean prod has not applied main yet.

### 5. Merge insolvia's PR, then this repo's

Both pushes start nothing, because the workflows are disabled. Merge
insolvia's first so its `main` matches its state as soon as possible.

### 6. Unfreeze this repo first

The pool lives here now, and insolvia's plan reads it by name.

```bash
for wf in release.yml mailer-staging.yml mailer-prod.yml; do gh workflow enable "$wf" -R insolvia-ai/insolvia-services; done
gh workflow run release.yml -R insolvia-ai/insolvia-services --ref main -f all=true
```

The staging leg should show both guards passing. The apply should report **no
resource changes**, only the new `auth_*` outputs, followed by the usual
mailer image deploy and smoke test. Approve `promote` and expect the same for
prod.

### 7. Unfreeze insolvia

```bash
for wf in release.yml infra-staging.yml infra-prod.yml; do gh workflow enable "$wf" -R insolvia-ai/insolvia; done
gh workflow run release.yml -R insolvia-ai/insolvia --ref main
```

The staging infra leg should show **no changes**. The `removed` blocks are
no-ops because the state no longer holds those addresses. The lookups
resolve to the same ids, so every SSM parameter, the branding and the grants
are unchanged. The app, API and MCP legs read the same `auth_*` outputs they
always did. Approve its promotion when you normally would.

### 8. Prove it

```bash
for env in staging prod; do
  aws ssm get-parameters-by-path --path "/insolvia/$env/api" \
    --query "Parameters[?contains(Name,'auth')].[Name,Value]" --output text
done
```

Each value should match what it was before step 3: the same pool id and the
same client ids. Then sign in on `staging-app.insolvia.ai` and on the
portal. The `app-staging.yml` flows tier (`auth-round-trip`,
`client-portal`) does this on every release, so a green insolvia staging
release from step 7 is the proof.

### 9. Developer machines, each one once

Each developer, on their own machine, with both checkouts at `main`:

```bash
scripts/migrate-module-state.sh dev --module module.auth --insolvia-dir ../insolvia "${KEEP[@]}" --rehearse
scripts/migrate-module-state.sh dev --module module.auth --insolvia-dir ../insolvia "${KEEP[@]}"
```

Then run insolvia's `./scripts/dev-aws-setup.sh` as usual. Until this has
run, `dev-aws-auth.sh apply` (which setup calls) refuses to create a second
pool and points here. A machine that never had a dev environment needs
nothing: setup creates its pool here directly.

### 10. Afterwards

- Once insolvia's staging and prod have each applied a release after the
  move, delete the `removed` blocks from insolvia's staging and prod roots
  in one small PR. Delete the dev root's once every developer machine has
  moved.
- Add `Terraform validate (dev)` to this repo's required checks:
  `scripts/update-ruleset.sh add "Terraform validate (dev)"`.
- Record the execution at the top of this page.
- Keep the backup directories (`~/.local/state/insolvia/state-migration/`)
  for a few weeks, then delete them.

## Rollback

**Before step 5.** Push the backups back:

```bash
B=~/.local/state/insolvia/state-migration/<env>-auth-<timestamp>
terraform -chdir=../insolvia/infra/envs/<env> state push -force "$B/insolvia.tfstate"
terraform -chdir=infra/envs/<env> state push -force "$B/insolvia-services.tfstate"
```

Then re-enable the frozen workflows. Old code with restored states is
consistent.

**After step 5.** Fix forward in whichever repo is wrong. No resource was
touched, so there is nothing to recover in AWS. Do not revert one repo's PR
on its own: insolvia's old code with the moved state creates a second pool,
and this repo's old code with the moved state destroys the real one.
