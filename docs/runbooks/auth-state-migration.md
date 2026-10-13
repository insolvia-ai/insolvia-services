# Cutover: auth (Cognito) leaves the insolvia repo

**Later the same day:** the two branding styles that this move left in
insolvia moved here too (insolvia ADR 0026, amendment) — by `import` blocks
in this repo and `removed { destroy = false }` there, not by this script.

**Status: executed 2026-10-12** by the maintainer (andreas.savva), staging and
prod. Backups, on the machine that ran it:
`~/.local/state/insolvia/state-migration/staging-auth-20261012T161532Z` and
`prod-auth-20261012T161058Z`. Both moves passed the script's two verification
plans (prod's kept two pending in-place mailer Lambda updates from #3, on a
yes). Afterwards insolvia-services' release applied staging (0 changed) and
prod (the 2 mailer updates), and insolvia's release applied staging with "No
changes" and passed its integration and e2e sign-in tiers.

What did not go to plan, for whoever runs a move like this next:
- **insolvia-services#2 (the first design) was merged before any move.** Its
  release stopped at the state guard, so nothing was created. The guard is
  the reason that was harmless; keep it.
- **Staging was moved, rolled back with the backups, and moved again.** The
  rollback restored both states together, so they stayed consistent
  throughout. The rule it confirmed: never push only one of the two backups.
- **The first prod attempt was refused and restored** because prod had not
  been promoted yet. The check worked as designed; promote first.

The decision is insolvia's
[ADR 0026](https://github.com/insolvia-ai/insolvia/blob/main/docs/adr/0026-auth-is-a-shared-service.md),
which amends ADR 0025: auth is a shared service. This runbook moves the live
staging and prod user pools, their hosted domains, their app clients and
their **SSM contract parameters** out of insolvia's state into this repo's.
It also stands up the **shared development pool**, which replaces every
per-machine one. It follows the pattern of the mailer's move,
[`state-migration.md`](state-migration.md), and differs from it in five ways:

1. **The module splits.** `module.auth` exists on both sides afterwards.
   What moves here: the pool, its domains, the alias record, the clients and
   the contract parameters. What stays in insolvia, at unchanged addresses:
   the two managed-login branding styles and the two `AdminCreateUser`
   grants. `--keep` names those four.
2. **This repo's roots are not empty.** They already hold `module.mailer`.
   The script refuses only if this side already holds something under
   `module.auth`.
3. **There is a prep PR.** insolvia reads the pool through
   `/insolvia/<env>/auth/*` SSM parameters. Those parameters must exist
   before the move, so that the move's verification plan of insolvia can
   read them. So insolvia's **current** `module.auth` publishes them first, in
   a small PR released ahead of the cutover. They then travel with the module
   like everything else, with the same addresses
   (`module.auth.aws_ssm_parameter.contract["<key>"]`) and no recreate.
4. **Prod has a precondition.** Prod's pool lacks the portal and `mcp-claude`
   clients that insolvia's main already declares. Until insolvia's prod has
   applied main (and the prep PR), the move would plan to *create* resources
   here, and the script refuses that.
5. **Dev does not move. It is replaced.** Development gets one shared pool,
   created fresh here (§ Shared dev pool). Each machine's old per-machine
   pool is destroyed by its owner's next `dev-aws-setup.sh`, and the
   developer reseeds.

| Root | State key | What moves |
|---|---|---|
| staging | `insolvia/staging/…` → `insolvia-services/staging/…` | 8 blocks, 15 instances: pool, prefix + custom domain, the custom domain's alias record, app / portal / mcp[claude, inspector] clients, the 7 contract parameters |
| prod | `insolvia/prod/…` → `insolvia-services/prod/…` | pool, prefix domain, app / portal / mcp[claude] clients, the 7 contract parameters (once prod has applied main and the prep PR) |
| dev | nothing moves | the shared pool is created new at `insolvia-services/dev/terraform.tfstate` |

**For staging and prod, nothing in AWS is created, changed or destroyed.**
Every pool keeps its id, users and subjects. Every client keeps its id, so
the API's SSM configuration, the deployed app bundles and every token already
issued stay valid.

## What can go wrong, and what stops it

| Ordering | Would cause | Stopped by |
|---|---|---|
| insolvia's **new** code applies before the move | it would forget the pool and its parameters (no longer declared there). A forget can be recovered; insolvia's next plan then still reads the parameters, which still exist | the `removed { … destroy = false }` blocks insolvia's PR adds to its staging and prod roots. Without them this would be a **destroy** |
| insolvia's **old** code applies after the move | a second pool, because the old code still declares one and the state no longer holds it. Cognito allows duplicate names, and the domain prefix collides partway through | step 2 freezes insolvia's release **and** the dispatchable `infra-staging.yml` / `infra-prod.yml` |
| this repo's **old** code (main, no `module.auth`) applies after the move | it would **destroy** the pool. Staging has no deletion protection, clients never do | step 2 freezes this repo's release **and** the dispatchable `mailer-staging.yml` / `mailer-prod.yml` |
| this repo's **new** code applies before the move | a second pool, whose contract parameters collide with the live ones | the deploy workflows' state guard: they refuse when `module.auth` (or `module.mailer`) is missing from the state, unless someone passes `bootstrap: true` |
| any later plan destroys or replaces a pool or client | every account gone, or a new client id | the deploy workflows refuse such a plan unless a human dispatches with `allow_auth_destroy: true`; a release cannot. `apply-dev-auth.sh` refuses the same for dev |

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

| Date | Env | Design rehearsed | Result |
|---|---|---|---|
| 2026-10-11 | staging | the first design (insolvia looked the pool up by name) | **PASSED.** Here: no resource changes, only the `auth_*` outputs. insolvia: "No changes. Your infrastructure matches the configuration." Re-run after merging insolvia's main (#451): same |
| 2026-10-11 | prod | the first design | **FAILED, as expected.** Here it would *create* `client.portal` and `client.mcp["claude"]`. Promote insolvia's prod first |
| 2026-10-12 | staging | **this design (SSM contract)**, after the prep PR (insolvia#453) released to staging | **PASSED.** 8 blocks / 15 instances moved (the 7 contract parameters with them), 4 kept in insolvia. Here: no resource changes, only the `auth_*` outputs. insolvia (#452's code): "No changes. Your infrastructure matches the configuration." |

## Before you start

- **The prep PR has merged, and its release has applied staging** (prod as
  well, before step 4). Check:
  `aws ssm get-parameters-by-path --path /insolvia/staging/auth --query 'Parameters[].Name'`
  must list seven parameters.
- **Both cutover PRs are open and green.** insolvia's: the consumer
  `modules/auth`, the `auth_contract` reader, `removed` blocks, the
  `dev-shared` root. This repo's: `modules/auth` with `contract.tf`,
  `module.auth` in staging/prod/dev, the guards, the script.
- **Prod has applied insolvia's main**, through a normal promotion. Check
  with step 1's prod rehearsal: if it still plans creates here, you are not
  ready.
- Checkouts side by side: this repo **at its PR's branch**, insolvia **at its
  PR's branch**.
- `aws login` as yourself in account `521762924626` (see the
  `insolvia-aws-auth` skill).
- About 45 minutes during which nothing merges in either repo.

The `--keep` list is the same for both environments. It is written out once
here:

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
no locks, so it is safe while the pipelines are live. Record the result in
the table above.

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
the old code.

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

You may see in-place updates on the pool here. If so, read the diff the
script points to before you answer. A create, destroy or replace is refused
and restored without asking.

### 5. Merge insolvia's PR, then this repo's

Both pushes start nothing, because the workflows are disabled. Merge
insolvia's first so its `main` matches its state as soon as possible.

### 6. Unfreeze this repo first

The pool and its parameters live here now.

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
no-ops because the state no longer holds those addresses, and the contract
reads return the same ids. Approve its promotion when you normally would.

### 8. Prove it

```bash
for env in staging prod; do
  aws ssm get-parameters-by-path --path "/insolvia/$env/api" \
    --query "Parameters[?contains(Name,'auth')].[Name,Value]" --output text
done
```

Each value should match what it was before step 3. Then sign in on
`staging-app.insolvia.ai` and on the portal. The `app-staging.yml` flows
tier (`auth-round-trip`, `client-portal`) does this on every release, so a
green insolvia staging release from step 7 is the proof.

### 9. Shared dev pool

Run this once, from this repo at `main` (after step 5):

```bash
scripts/apply-dev-auth.sh
```

It creates `insolvia-dev-users` (sign-in on `dev-auth.insolvia.ai`, beside the
prefix domain `insolvia-dev-auth`; the custom domain blocks the first apply for
15–20 minutes and needs `dig +short insolvia.ai A` to resolve), its
clients and the `/insolvia/dev/auth/*` parameters. It refuses any plan that
destroys or replaces a pool or client.

Then each developer, on their own machine, with insolvia at `main`:

```bash
./scripts/dev-aws-setup.sh   # brands the shared pool (infra/envs/dev-shared), then DESTROYS this machine's old per-machine pool
./scripts/dev-aws-seed.sh    # your dev account, now in the shared pool, plus your firm in this machine's tables
```

The destroy is expected and its plan says so: `insolvia-dev-<machine-id>-users`,
its domain, its clients and its branding. Its test accounts go with it, and
`dev-aws-seed.sh` recreates yours. Firm rows keyed on the old subjects are
reseeded too: `dev-aws-reset.sh` first if you want the tables clean.

### 10. Afterwards

- Once insolvia's staging and prod have each applied a release after the
  move, delete the `removed` blocks from insolvia's staging and prod roots in
  one small PR.
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
