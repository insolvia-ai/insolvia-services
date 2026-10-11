# infra

Terraform for Insolvia's account-wide AWS resources and the mailer's stacks.
The app's own stacks are in the
[insolvia repo's `infra/`](https://github.com/insolvia-ai/insolvia/tree/main/infra).
[`../docs/reference/terraform.md`](../docs/reference/terraform.md) is the
model; [`../docs/runbooks/aws-bootstrap.md`](../docs/runbooks/aws-bootstrap.md)
stands it up in a fresh account.

```
envs/ci-trust/        OIDC provider + insolvia-shared-deploy-role (both repos deploy with it) + the staging seed role — human-applied only
envs/account-access/  human IAM users + groups + their attached policies — human-applied; CI has no IAM user/group permissions at all
envs/shared/          zone insolvia.ai, *.insolvia.ai cert, SES identity + mail DNS, every service's ECR repository, the seed-fixture bucket
envs/staging/         the staging mailer (staging-mailer-api.insolvia.ai)
envs/prod/            the production mailer (mailer-api.insolvia.ai)
modules/              mailer · email · dev_fixtures
```

| Root | State key in `s3://insolvia-shared-terraform-state-us-east-1` | Applied by |
|---|---|---|
| `ci-trust` | `insolvia/ci-trust/terraform.tfstate` | a human — `scripts/apply-ci-trust.sh` |
| `account-access` | `insolvia/account-access/terraform.tfstate` | a human — `scripts/apply-account-access.sh` |
| `shared` | `insolvia/shared/terraform.tfstate` | CI — the first leg of `release.yml` |
| `staging` | `insolvia-services/staging/terraform.tfstate` | CI — `mailer-staging.yml`, on merge |
| `prod` | `insolvia-services/prod/terraform.tfstate` | CI — `mailer-prod.yml`, after the release's approval |

The three account-wide roots kept the keys they had in the insolvia repo —
moving them was a code move, not a state move. `staging` and `prod` are new,
mailer-only roots; the `insolvia/staging` and `insolvia/prod` keys belong to
the insolvia repo's app stacks.

## Apply order

`ci-trust` (human) → `shared` → `staging` / `prod` here → then the insolvia
repo's roots, which look up `shared`'s zone, cert and repositories by name.
The mailer roots in turn need insolvia's API to exist in that environment
(they look up its execution role), so in a fresh account the two repos
interleave — [`aws-bootstrap.md`](../docs/runbooks/aws-bootstrap.md) has the
sequence. `account-access` sits outside the order: nothing depends on it, so
apply it when the people change. Rotating an MFA device is not an apply —
[`iam-mfa-rotation.md`](../docs/runbooks/iam-mfa-rotation.md).

DNS is live and deploys are real. Never `destroy` `shared`: both repos'
environments depend on its zone, certificate and repositories.

## The empty-state guard

`mailer-staging.yml` and `mailer-prod.yml` refuse to apply when their root's
state holds no `module.mailer`. Empty state means either a fresh account
(dispatch with `bootstrap: true`) or that the mailer's state has not yet been
moved out of the insolvia repo
([`state-migration.md`](../docs/runbooks/state-migration.md)), in which case
an apply would build a second mailer beside the live one.

## No `dev` root

The mailer runs locally under Docker with Mailpit and needs no AWS
(`services/mailer/scripts/dev-up.sh`), so nobody deploys it per machine. The
per-developer AWS environment is the insolvia repo's `infra/envs/dev`.

## Checking a change offline

```bash
terraform fmt -check -recursive infra
terraform -chdir=infra/envs/<root> init -backend=false
terraform -chdir=infra/envs/<root> validate
tflint --init && tflint --chdir=infra/envs/<root> --recursive
```

That is what `infra-pr.yml` runs, once per root. It cannot show what a change
would *do* to real state; [`CLAUDE.md`](CLAUDE.md) says when that matters and
how to see it.
