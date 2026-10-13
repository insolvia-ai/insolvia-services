# insolvia-services — agent guide

Insolvia's **account-wide AWS infrastructure** (Terraform: `shared`,
`ci-trust`, `account-access`), the **mailer** — the transactional-email
platform the app's API sends through — and **auth**, the Cognito user pools
the app signs people in with (insolvia's
[ADR 0026](https://github.com/insolvia-ai/insolvia/blob/main/docs/adr/0026-auth-is-a-shared-service.md)). Lifted out of
[insolvia-ai/insolvia](https://github.com/insolvia-ai/insolvia) on 2026-10-11;
the decision and its reasoning are insolvia's
[ADR 0025](https://github.com/insolvia-ai/insolvia/blob/main/docs/adr/0025-shared-infra-and-mailer-move-to-insolvia-services.md).

**This file is a catalog.** It says where things live and what to open before
touching them. Detail lives in the linked file, not here.

**Always (before you look anything up):**
- This repo is **public** — never commit secrets, credentials, real mailbox
  addresses, or customer/case data.
- Never commit to `main` — work on a branch (`claude/<name>-<id>`) and open a
  PR. *(A `PreToolUse` hook enforces this.)*
- **Three environments, every time: local, staging, prod.** Say what a change
  does on a developer's machine and do that too. Here "local" means the
  mailer's Docker stack (`services/mailer/scripts/dev-up.sh`, Mailpit) and an
  offline `terraform validate` of every root you touched — there is no `dev`
  root in this repo; insolvia owns `infra/envs/dev`.
- **Everything must be testable locally**, unless there is a reason good
  enough to write down. When something genuinely cannot be (a human-applied
  root, a real SES identity), say so in the PR and give the nearest local
  approximation.
- **Deploys run in CI, never from your CLI** — `insolvia-deploy` skill. The
  exceptions are human-run and named there.

## The map

```
services/mailer/   the mailer: SigV4 HTTP API → SQS → SES, Python on Lambda (+ Mailpit locally)
infra/envs/        shared · ci-trust · account-access (account-wide) · staging · prod (mailer + auth) · dev (the shared development pool)
infra/modules/     mailer · auth (Cognito pool, domains, app clients) · email (SES identity + mail DNS) · dev_fixtures (the seed-fixture bucket)
.github/           release.yml (shared → mailer staging → promote → mailer prod) · PR gates · actions
scripts/           dev-setup.sh · apply-dev-auth.sh · apply-ci-trust.sh · apply-account-access.sh · update-ruleset.sh · migrate-module-state.sh
docs/              reference/ · runbooks/ — index in docs/README.md
```

Each area with rules of its own has a `CLAUDE.md` (auto-loads when you work
there; read it before editing) and a `README.md` for humans: `infra/`,
`services/mailer/`, `docs/`. One owner per fact — link, never restate.

## Two repositories

**What lives where.** This repo: the account-wide layer, the mailer and auth. The
[insolvia repo](https://github.com/insolvia-ai/insolvia): the app, the
marketing site, the admin portal, and the app's backend (`services/api`,
`admin`, `mcp`, `filing`, `insolvia_core`), with every app stack in its own
`infra/envs/{dev,staging,prod}`. Both deploy into one AWS account
(`521762924626`), one state bucket, under **one deploy role** that trusts both
repos — each repo's state keys and workflows are what keep them apart.

**They reach each other by name, never by state** — no
`terraform_remote_state`, no shared code. Four names cross the boundary, and
each is an ordering rule:

| Name | Owned by | Read by | So… |
|---|---|---|---|
| zone `insolvia.ai`, cert `*.insolvia.ai`, `insolvia-shared-<service>` ECR repos | this repo's `infra/envs/shared` | insolvia's env roots, via `data` lookups | A **new insolvia service's ECR repository is added here first**, and must merge *and release* before the insolvia PR that deploys it — that PR's plan fails until it exists. |
| `insolvia-<env>-api-role` | insolvia's `modules/api_service` | this repo's `infra/envs/{staging,prod}` (`data "aws_iam_role" "api"`), which also attach the mailer's invoke policy *onto* it | The mailer cannot plan in an environment where insolvia's API has never applied; renaming the role there breaks this plan here (loudly, by design); replacing it drops the invoke grant until the mailer re-applies. |
| the mailer's hostname (`staging-mailer-api.insolvia.ai`, `mailer-api.insolvia.ai`) | this repo (`mailer_subdomain`) | insolvia, which **constructs** `MAILER_API_URL` from the same hostname | Changing a mailer hostname is a two-repo change: here, then insolvia's API configuration. |
| the auth contract: SSM `/insolvia/<env>/auth/*` (pool id/ARN, web and portal client ids, sign-in domain, issuer, MCP client ids) | this repo's `modules/auth` (`contract.tf`), in `infra/envs/{dev,staging,prod}` | insolvia's `modules/auth_contract` (`data "aws_ssm_parameter"`); its `modules/auth` also owns its roles' **invite grants** (the sign-in page's **style** is this repo's, `modules/auth/branding.tf`) | This root applies **before** insolvia's (its reads need the parameters; a missing one fails insolvia's plan by name). A new client or key insolvia must read is added here first and released before the insolvia PR that reads it. A pool or client is **never** recreated — see `modules/auth/main.tf`. |

The trust anchor is here too: an `AccessDenied` in **either** repo's deploy
is fixed by a PR to `infra/envs/ci-trust` in this repo plus a human apply.

## Catalog — need this? read that

| When you're… | Open |
|---|---|
| working in `infra/` or `services/mailer/` | that directory's `CLAUDE.md` |
| deploying, releasing, "applying the terraform" | `insolvia-deploy` skill |
| hitting AWS credential errors, or an account other than `521762924626` | `insolvia-aws-auth` skill |
| any GitHub write (`gh pr create`, `git push`, …) or a GitHub 403 | `insolvia-github-auth` skill — read the `GitHub:` line the SessionStart hook put in your context |
| changing the CI deploy role's IAM, or an IAM `AccessDenied` in any deploy | `insolvia-deploy-role-permissions` skill |
| naming or renaming any AWS resource | `insolvia-aws-naming` skill |
| changing required PR checks on `main` | `insolvia-branch-protection` skill |
| opening a PR / writing its description | `insolvia-pr-description` skill |
| the Terraform model: roots, state keys, cross-repo lookups, apply order | [`docs/reference/terraform.md`](docs/reference/terraform.md) |
| mail DNS, SES, Google Workspace | [`docs/reference/email.md`](docs/reference/email.md) |
| standing up a fresh account (spans both repos) | [`docs/runbooks/aws-bootstrap.md`](docs/runbooks/aws-bootstrap.md) |
| the 2026-10-11 cutover: moving the mailer's state out of insolvia | [`docs/runbooks/state-migration.md`](docs/runbooks/state-migration.md) — run `scripts/migrate-module-state.sh` only from a runbook |
| moving auth's state out of insolvia (staging, prod) | [`docs/runbooks/auth-state-migration.md`](docs/runbooks/auth-state-migration.md) |
| the shared development pool (`infra/envs/dev`) | `scripts/apply-dev-auth.sh` — human-run, when its configuration changes; developers only read it |
| the Cognito sign-in page's look — colours, logo, tab icon | `infra/modules/auth/branding.tf` and the four files beside it (checked in, hand-maintained until the design system renders them; insolvia ADR 0026 amendment). A re-brand in insolvia needs a matching change here — nothing checks the two against each other yet |
| adding/removing a human IAM user, or rotating MFA | [`infra/envs/account-access/`](infra/envs/account-access/main.tf) · [`docs/runbooks/iam-mfa-rotation.md`](docs/runbooks/iam-mfa-rotation.md) |
| SES production access | [`docs/runbooks/ses-production-access.md`](docs/runbooks/ses-production-access.md) |
| registering a new mailer caller | [`services/mailer/docs/onboarding.md`](services/mailer/docs/onboarding.md) |
| mailer alarms, DLQs, the kill switch | [`services/mailer/docs/operations.md`](services/mailer/docs/operations.md) |
| the app, the API, case data, the app's stacks, or `infra/envs/dev` | **not here** — the [insolvia repo](https://github.com/insolvia-ai/insolvia) and its [`CLAUDE.md`](https://github.com/insolvia-ai/insolvia/blob/main/CLAUDE.md) |
| an ADR (any decision record) | **not here** — insolvia's [`docs/adr/`](https://github.com/insolvia-ai/insolvia/tree/main/docs/adr); this repo has none of its own yet |

## Verifying a change locally

There is no pre-commit or pre-push hook here; CI is the gate, and these are
what it runs.

```bash
services/mailer/scripts/dev-test.sh                      # ruff, mypy, pytest
terraform fmt -check -recursive infra
terraform -chdir=infra/envs/<root> init -backend=false && terraform -chdir=infra/envs/<root> validate
tflint --init && tflint --chdir=infra/envs/<root> --recursive
actionlint .github/workflows/*.yml
bash .github/scripts/release-diff-base.test.sh
shellcheck scripts/*.sh services/mailer/scripts/*.sh
```
