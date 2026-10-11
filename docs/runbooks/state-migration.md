# Cutover: shared infra and the mailer leave the insolvia repo

**Status: executed on 2026-10-11** — the `insolvia-services/staging` and
`insolvia-services/prod` state objects exist from that day and both PRs have
merged. *Who ran it and the backup directory names are still to be recorded
here by the person who did.* Auth's later move follows the same pattern:
[`auth-state-migration.md`](auth-state-migration.md).

On 2026-10-11 the shared AWS infrastructure (`infra/envs/shared`, `ci-trust`,
`account-access`) and the mailer were lifted out of
[insolvia-ai/insolvia](https://github.com/insolvia-ai/insolvia) into this
repository. The *code* moves with two pull requests. The *live mailer* moves
with this runbook, because its resources sit in the state of insolvia's
`infra/envs/staging` and `infra/envs/prod` roots, and this repo's roots of the
same names start empty.

| Root | State key | What moves |
|---|---|---|
| `shared`, `ci-trust`, `account-access` | `insolvia/<root>/terraform.tfstate` — **unchanged** | Code only. Same key, same addresses: whichever repo holds the code applies it. |
| mailer, staging | `insolvia/staging/…` → `insolvia-services/staging/…` | `module.mailer` (62 resource blocks, 68 instances at the time of writing) |
| mailer, prod | `insolvia/prod/…` → `insolvia-services/prod/…` | `module.mailer` |

**Nothing in AWS is created, changed or destroyed.** Every address stays
`module.mailer.*`; only which state file holds it changes.

## Why it is shaped like this

Three ways the move could go wrong, and what stops each one:

1. **insolvia applies its new code before the move → it would destroy the live
   mailer**, because the code no longer declares `module.mailer` and the state
   still does. Stopped by the `removed { lifecycle { destroy = false } }` block
   insolvia's PR leaves in both env roots: the worst case becomes "forgotten",
   not "destroyed".
2. **insolvia applies its *old* code after the move → it would create a second
   mailer**, colliding on every fixed name. Old code still runs if a release
   was already queued, or is waiting at the production gate. Stopped by step 3,
   which freezes insolvia's release pipeline and cancels anything pending until
   the new code is on `main`.
3. **This repo applies onto empty state → the same second mailer.** Stopped by
   the empty-state guard in `mailer-staging.yml` and `mailer-prod.yml`. They
   refuse to apply unless the state already holds `module.mailer`, unless
   someone passes `bootstrap: true`, which is only for a fresh account.

The move itself was `scripts/migrate-mailer-state.sh`, since generalised into
[`scripts/migrate-module-state.sh`](../../scripts/migrate-module-state.sh)
(`--module module.mailer`, no `--keep`) for auth's move — same backup,
verification and restore behaviour.
It is run by a human with admin credentials, not a workflow, for reasons its
header gives. It backs up, moves, verifies with two plans, and **restores both
states automatically** if either plan is wrong.

It was rehearsed read-only against staging before the PRs opened. A pulled copy
of the state was moved locally, and this repo's staging root, planned against
that copy, proposed **no resource changes** across all 62 blocks. The only diff
was adding the root's `mailer_*` outputs, which the first CI apply writes.

## Before you start

- The two PRs are open and green: insolvia's (removes the code, adds the
  `removed` blocks, drops the `shared`/`mailer` release legs) and this repo's
  import.
- Checkouts side by side: this repo **at the import PR's branch**, and insolvia
  **at its PR's branch** (the script plans insolvia's code and refuses one that
  still declares `module "mailer"`).
- `aws login` as yourself in account `521762924626`. See the
  `insolvia-aws-auth` skill.
- About 30 minutes during which nothing else merges in either repo.

## Steps

### 1. Trust this repository (human ci-trust apply)

From this repo's checkout:

```bash
scripts/apply-ci-trust.sh
```

Expected plan: **one in-place update**, the assume-role policy of
`aws_iam_role.github_actions`, gaining the two `insolvia-services` subject
patterns. Nothing destroyed or replaced. Until this is applied, every workflow
here fails at "configure AWS credentials", which is harmless but red.

Do not apply `ci-trust` from an insolvia checkout from here on. Its copy of the
root lacks the new repo, and applying it would revoke the trust again. insolvia's
PR deletes that copy.

### 2. Check GitHub is set up here

```bash
gh secret list -R insolvia-ai/insolvia-services
gh api repos/insolvia-ai/insolvia-services/environments --jq '.environments[].name'
scripts/update-ruleset.sh show
```

Expect: repository secret `AWS_ROLE_ARN`; environments `insolvia-shared`,
`insolvia-staging` and `insolvia-production`, the last with a required
reviewer, and the first and last limited to `main`; a `protect-main` ruleset.

### 3. Freeze insolvia's release pipeline

```bash
gh workflow disable release.yml -R insolvia-ai/insolvia
gh run list -R insolvia-ai/insolvia --workflow release.yml --limit 10 \
  --json databaseId,status,headSha --jq '.[] | select(.status != "completed")'
```

Cancel **every** run that is not completed, **including one waiting at the
`promote` gate**. Approving an old waiting run after the move would apply the
old prod code and recreate the mailer.

```bash
gh run cancel <id> -R insolvia-ai/insolvia
```

### 4. Move staging

```bash
scripts/migrate-module-state.sh staging --module module.mailer --insolvia-dir ../insolvia
```

It prints how many `module.mailer` resources it found, asks before moving,
and finishes with `Migrated insolvia/staging → insolvia-services/staging` and
the backup directory. A `restored` line means it put both states back and
stopped. Read its output, fix the cause, and run it again.

insolvia's plan may list **other** pending changes, from commits on `main` that
staging has not applied yet. The script prints them separately. They are fine
as long as none is a destroy, and the script already refuses any destroy.

### 5. Move prod

```bash
scripts/migrate-module-state.sh prod --module module.mailer --insolvia-dir ../insolvia
```

The same check, with one difference you should expect. Prod trails insolvia's
`main` until a release is approved, so the **new** root can plan **in-place
updates** that are not caused by the move: code merged on `main` that prod never
applied. The first attempt found three: the mailer Lambdas' registry JSON gaining
`client_invitation`, from #405. The script lists such updates and asks before
keeping the move; read the diff it points to, then answer. A create, destroy or
replace is still refused and restored automatically.

### 6. Required checks on insolvia

The checks that moved would otherwise block insolvia's PR forever:

```bash
cd ../insolvia
scripts/update-ruleset.sh remove "Mailer service"
scripts/update-ruleset.sh remove "Terraform validate (shared)"
```

### 7. Merge insolvia's PR, then this repo's

insolvia first, so its `main` matches its state as soon as possible. Its push
starts no release, because release.yml is disabled. Then merge this repo's
import PR. The first run here goes:

- `shared`: no changes (same code, same state).
- `staging`: the guard passes, and the apply shows **no resource changes**, only
  the new outputs. Then image build, Lambda update and smoke test.
- `record` stamps the commit. Approve `promote` for prod: apply with outputs
  only, promote the image, smoke test.

### 8. Unfreeze insolvia

```bash
gh workflow enable release.yml -R insolvia-ai/insolvia
gh workflow run release.yml -R insolvia-ai/insolvia --ref main
```

Its staging infra leg applies the trimmed root. The `removed` blocks are no-ops
now, because the state no longer holds `module.mailer`. The SSM parameter
`/insolvia/<env>/api/mailer-api-url` keeps the same value, so it is a no-op too.
Approve its promotion when you would normally; prod is the same story.

### 9. Prove it

```bash
for host in staging-mailer-api mailer-api; do
  curl -s -o /dev/null -w "$host %{http_code}\n" -X POST \
    "https://$host.insolvia.ai/v1/services/insolvia_api/messages"
done
```

Expect `403` from both: SigV4 with no signature, which means the domain, API
Gateway and Lambda are all wired. For a real send, trigger a portal invitation
on staging and watch the message reach `delivered` in the mailer's messages
table.

### 10. Afterwards

- Once insolvia's staging **and** prod have each applied a release after the
  move, delete the two `removed` blocks in insolvia (one small PR).
- Record the execution at the top of this page.
- Keep the backup directories (`~/.local/state/insolvia/state-migration/`) for
  a few weeks, then delete them. They are full state files; the bucket's
  object versions are the second copy.

## Rollback

**Before step 7.** Run the script's restore by hand: push the backup back into
insolvia's key, then remove the new one.

```bash
terraform -chdir=../insolvia/infra/envs/<env> state push -force \
  ~/.local/state/insolvia/state-migration/<env>-<timestamp>/insolvia.tfstate
aws s3 rm s3://insolvia-shared-terraform-state-us-east-1/insolvia-services/<env>/terraform.tfstate
```

Then re-enable insolvia's release.yml **only together with** reverting its PR,
if it was merged. Old code plus restored state is consistent; new code plus
restored state is case 1 above, which the `removed` block turns into
"forgotten", not "destroyed".

**After step 7.** The cleaner path is forward: fix whatever is wrong in this
repo. The resources were never touched, so there is nothing to recover in AWS.
