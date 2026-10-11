---
name: insolvia-deploy
description: >-
  How insolvia-services ships shared infrastructure and the mailer — and the
  rule that deploys happen in CI, never from your CLI. Use this whenever a
  task is about deploying, shipping, releasing, or "applying" infrastructure
  or the mailer to staging or prod: "deploy to prod", "ship the mailer",
  "apply the terraform", "apply shared", "push a new version live", "run
  terraform apply", "update the lambda", "release". Read it BEFORE running any
  `terraform apply`, `docker push` to ECR, `aws lambda update-function-code`,
  or `aws`/`gh` deploy command against staging or prod — those are CI's job,
  and doing them by hand bypasses the OIDC deploy role and the environment
  gates. Also read it before passing `bootstrap: true` to a mailer workflow.
---

# Deploying insolvia-services

**Deploys run in GitHub Actions, triggered by git — not from anyone's CLI.**
The only credential that touches staging/prod AWS is the CI OIDC deploy role,
which this repo and the insolvia repo share. This skill covers this repo's
pipeline; the app, its API and its stacks ship from the
[insolvia repo](https://github.com/insolvia-ai/insolvia), whose own
`insolvia-deploy` skill covers them.

## The pipeline

One workflow, `release.yml`, owns the whole path to production:

```
changes → shared → staging (mailer) → record → promote (approval) → prod (mailer)
```

1. **Merge to `main`.** `changes` diffs against the last commit staging
   released green (so a leg an earlier run lost is retried), then:
   - **`shared`** — `shared-infra-deploy.yml` applies `infra/envs/shared`,
     if it or `modules/{email,dev_fixtures}` changed. Ungated, ahead of the
     gate: both repos' environments consume it.
   - **`staging`** — `mailer-staging.yml` applies `infra/envs/staging`,
     builds and pushes `sha-<commit>` + the `staging` marker, points the three
     Lambdas at it, and smoke-tests (an unsigned request must get a 403).
   - **`record`** — makes sure the mailer has a `sha-<commit>` tag even when
     this push did not change it, then stamps the commit status
     `insolvia-services/staging-release`.
2. **The run parks at `promote`**, waiting on the `insolvia-production`
   environment's required reviewer.
3. **Approve it in the GitHub UI** ("Review deployments" on the run). `prod`
   — `mailer-prod.yml` — applies `infra/envs/prod` and **promotes**: it
   resolves the commit's `sha-<commit>` tag to a digest and deploys that
   image. It never rebuilds.

So the deploy procedure is: **open a PR, get it merged, approve the pending
release run when you want prod to have it.** Not approving is fine — a newer
green staging run cancels older pending ones, so an unapproved run ending
`cancelled` is normal, not a failure.

| Target | Trigger |
|---|---|
| **shared infra** | automatic on merge, first leg of `release.yml`; `shared-infra-deploy.yml` stays dispatchable out of band |
| **staging mailer** | automatic on merge, `release.yml`'s staging leg; `mailer-staging.yml` is dispatchable for one out-of-band deploy |
| **prod mailer** | approving the `promote` gate of a green `release.yml` run |
| **prod mailer, out of band** | dispatch `mailer-prod.yml` with `sha=<commit>` — it refuses a commit without a green `insolvia-services/staging-release` status (`.github/actions/verified-commit`) and asks for the production approval itself. Also how to roll back: dispatch it with an older green `sha`. |

**Two pipelines, one account.** insolvia's `release.yml` deploys the app's
stacks; this one deploys shared and the mailer. Neither waits on the other at
deploy time, and each stamps its own commit status (`insolvia/staging-release`
there, `insolvia-services/staging-release` here), so neither can promote on
the other's evidence. The orderings that *do* cross the boundary — a new
container repository releasing here before insolvia uses it, the mailer
needing insolvia's API role — are root `CLAUDE.md` § "Two repositories".

## The empty-state guard — and `bootstrap: true`

`mailer-staging.yml` and `mailer-prod.yml` refuse to apply when their root's
state holds no `module.mailer`. **Do not pass `bootstrap: true` to get past
that.** Empty state with a live mailer means its state has not been moved out
of the insolvia repo yet
([`docs/runbooks/state-migration.md`](../../../docs/runbooks/state-migration.md)),
and an apply would create a second mailer that collides on every fixed name.
`bootstrap: true` is for a genuinely empty account, following
[`docs/runbooks/aws-bootstrap.md`](../../../docs/runbooks/aws-bootstrap.md).

## The rule

**Do not deploy or apply against staging or prod from the CLI.** Never run,
against shared, staging or prod:

- `terraform apply` in `infra/envs/shared`, `infra/envs/staging` or
  `infra/envs/prod`
- `docker push` to `insolvia-shared-mailer` (or any `insolvia-shared-*`
  repository), or `aws lambda update-function-code` on a mailer Lambda
- `terraform state mv`/`rm`/`push` against any of this repo's states

To *see* what a risky change would do, a local read-only `terraform plan`
under your own admin credentials is fine (`infra/CLAUDE.md` says when it is
worth it); applying stays CI's.

## The only local applies that are legitimate

All three are human-run, each through its own guarded script:

- **The `ci-trust` anchor** — `scripts/apply-ci-trust.sh`, because CI cannot
  apply its own permissions (`insolvia-deploy-role-permissions` skill). It
  serves both repos: an IAM `AccessDenied` in an insolvia deploy is fixed
  here too.
- **`account-access`** — `scripts/apply-account-access.sh`, when the people
  change. CI holds no IAM user/group permissions at all.
- **The state moves out of insolvia** — `scripts/migrate-module-state.sh`,
  once per environment, only inside
  [`docs/runbooks/state-migration.md`](../../../docs/runbooks/state-migration.md)
  (the mailer) or
  [`docs/runbooks/auth-state-migration.md`](../../../docs/runbooks/auth-state-migration.md)
  (auth), which freeze the release pipelines around them. They move state;
  they create and destroy nothing. `--rehearse` is read-only and always fine.
- **A developer's own Cognito pool** — `infra/envs/dev`, per machine, applied
  by `scripts/dev-aws-auth.sh` (normally run by insolvia's
  `scripts/dev-aws-setup.sh`). Never CI, never shared.

The mailer still has no per-developer AWS environment — its local loop is
Docker + Mailpit (`services/mailer/scripts/dev-up.sh`). The rest of the
per-machine stack (`infra/envs/dev`, `scripts/dev-aws-*`) is the insolvia
repo's.

Everything else is a merge, an approval, or a dispatch — never a hand-run
apply.
