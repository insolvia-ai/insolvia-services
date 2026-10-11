# AWS & GitHub bootstrap

One-time setup so CI in **both** Insolvia repositories can deploy to AWS with
**no long-lived keys**: this one (account-wide infrastructure, the mailer) and
[insolvia-ai/insolvia](https://github.com/insolvia-ai/insolvia) (the app and
its stacks). Insolvia runs in its **own dedicated AWS account**
(`521762924626`). Resources are namespaced by the `insolvia` project +
environment.

> **Status (2026-07-23): bootstrap is complete and deploys are live.**
> `insolvia.ai` is registered, Gandi delegates to Route53 hosted zone
> `Z01038711J6IZ68FD6ZDW`, the state bucket exists, `infra/envs/shared` is
> applied, and the `*.insolvia.ai` ACM certificate is `ISSUED`. The account
> was bootstrapped from the single insolvia repo; on 2026-10-11 the
> account-wide roots and the mailer moved here, so this runbook now describes
> standing the account up again **across both repos**. Work the steps in
> order; **step 3 (importing the hosted zone) is not optional** — skipping it
> breaks certificate validation in a way that is hard to diagnose.
>
> Moving the *existing* account from one repo to two is a different, one-off
> procedure: [`state-migration.md`](state-migration.md).

## 0. Prerequisites

- AWS CLI configured with credentials that can create S3/IAM/Route53/ACM in
  the Insolvia account.
- `terraform` `>= 1.10` (native S3 state locking — `use_lockfile`), `tflint`,
  Docker. `scripts/dev-setup.sh` installs the first two and checks for Docker.
- Admin on **both** GitHub repositories, `insolvia-ai/insolvia-services` and
  `insolvia-ai/insolvia` (secrets, environments, rulesets).
- Checkouts of both. Steps marked **(insolvia)** run in the insolvia checkout;
  everything else runs here.

### Running Terraform locally — export credentials first

A working `aws` CLI is **not** enough for Terraform: the failure looks like
having no credentials at all, and it is easy to misdiagnose. The mechanism,
the failure modes and the fix for each belong to the **`insolvia-aws-auth`
skill** — read it rather than improvising. The one line every manual apply
below needs, in the same shell:

```bash
eval "$(aws configure export-credentials --format env)"
```

### The ci-trust anchor

`infra/envs/ci-trust` owns the GitHub OIDC provider, the
`insolvia-shared-deploy-role` deploy role (assumed by CI in **both** repos),
that role's permissions policy, and the staging seed role (assumed by
insolvia's CI alone). It is **applied only by a human admin — never by CI —
and that is the point**: the role's own policy denies it `iam:PutRolePolicy`
on itself, so a privilege change cannot take effect from merged code alone.
There is deliberately **no `ci-trust-*.yml` workflow** in either repo.

Why the self-deny exists is
[`../reference/terraform.md`](../reference/terraform.md#deployment-order).
Changing the role's permissions — including the `AccessDenied`-on-a-new-action
symptom that means you need to — belongs to the
**`insolvia-deploy-role-permissions`** skill. The apply itself is one of the
only legitimate local applies:

```bash
scripts/apply-ci-trust.sh
```

### Human IAM users

The admin user this runbook is executed *as* is itself codified, in
`infra/envs/account-access` — also human-applied, and in a fresh account it is
the one root that must be stood up by whoever holds the root credentials,
since there is no admin user yet to run anything else. It is otherwise outside
the apply order: nothing depends on it. See
[`../reference/terraform.md`](../reference/terraform.md#human-account-access)
for what it does and does not model, and
[`iam-mfa-rotation.md`](iam-mfa-rotation.md) for MFA, which is not a Terraform
resource on purpose.

```bash
scripts/apply-account-access.sh
```

## 1. Terraform state bucket — the first action in the entire plan

Every `backend.tf` in both repos points at this bucket, so `terraform init`
cannot run anywhere until it exists.

```bash
aws s3api create-bucket --bucket insolvia-shared-terraform-state-us-east-1 --region us-east-1
aws s3api put-bucket-versioning --bucket insolvia-shared-terraform-state-us-east-1 \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket insolvia-shared-terraform-state-us-east-1 \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket insolvia-shared-terraform-state-us-east-1 \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

State keys: `insolvia/{ci-trust,account-access,shared}/…` and
`insolvia-services/{staging,prod}/…` (this repo), `insolvia/{staging,prod}/…`
and `insolvia/dev/…` (the insolvia repo).
[`terraform.md`](../reference/terraform.md#roots-and-state) has the table.

## 2. GitHub OIDC provider (created by `ci-trust`)

The account has no GitHub OIDC provider yet — so `infra/envs/ci-trust`
**creates** it (step 4). There is exactly one such provider per account.
Confirm it is absent before first apply (empty list is expected):

```bash
aws iam list-open-id-connect-providers
```

If you later consolidate into an account that already has the provider,
switch the `aws_iam_openid_connect_provider.github` resource back to a `data`
source.

**Check the repository ids too.** The org enforces immutable OIDC subject
claims, so the trust policy pins each repo's *numeric id*
(`github_immutable_sub_prefix` and `github_services_immutable_sub_prefix` in
`infra/envs/ci-trust/variables.tf`). If either repository was created anew,
read its prefix and update the default before applying:

```bash
gh api repos/insolvia-ai/insolvia/actions/oidc/customization/sub --jq .sub_claim_prefix
gh api repos/insolvia-ai/insolvia-services/actions/oidc/customization/sub --jq .sub_claim_prefix
```

## 3. ⚠️ Import the existing hosted zone — BEFORE any apply on `shared`

The hosted zone for `insolvia.ai` (`Z01038711J6IZ68FD6ZDW`) already exists,
holds only its NS + SOA records, and is the zone Gandi delegates to — but it
was created outside Terraform, and with no state bucket there was never a
state file.

`infra/envs/shared/main.tf` declares `resource "aws_route53_zone" "main"`.
Applied against empty state, that creates a **second** hosted zone for
`insolvia.ai`. Route53 permits duplicate zones and gives the new one different
nameservers, so:

1. Gandi still delegates to the *original* zone — the Terraform-managed zone
   is authoritative for nothing.
2. ACM DNS-validation records land in the new, unreferenced zone, so
   validation never completes.
3. `aws_acm_certificate_validation` hangs until timeout and surfaces as a
   certificate error that points nowhere near the real cause.
4. You pay for both zones.

Import instead of recreating — this keeps Gandi's delegation valid, with no
registrar change:

```bash
terraform -chdir=infra/envs/shared init
terraform -chdir=infra/envs/shared import aws_route53_zone.main Z01038711J6IZ68FD6ZDW
terraform -chdir=infra/envs/shared plan   # MUST NOT propose creating a hosted zone
```

**Do not skip the plan check.** A plan that proposes creating an
`aws_route53_zone` means the import did not take — stop and fix it before
applying.

## 4. Apply the trust anchor, then shared infra

Apply `ci-trust` first, because `shared` — and everything after it, in both
repos — is applied *as* the deploy role `ci-trust` creates. Leave
`staging_user_pool_arn` empty on this first apply: the staging pool does not
exist yet (step 11 comes back for it).

```bash
scripts/apply-ci-trust.sh
terraform -chdir=infra/envs/ci-trust output github_actions_role_arn
```

The first `shared` apply is local too, because the zone import above exists
only in state no CI run has applied against yet:

```bash
terraform -chdir=infra/envs/shared apply   # adopts the imported zone; cert, SES, every ECR repository, the fixture bucket
```

Because delegation is already in place, DNS validation should resolve and the
certificate should reach `ISSUED` without any registrar work. Every later
`shared` apply is this repo's release pipeline.

## 5. Wire both GitHub repos

The deploy role's ARN is a repository-level secret in **each** repo. (This
repo's `release.yml` `record` job runs without an `environment:`, so an
environment-scoped secret would read as empty there.)

```bash
for repo in insolvia-ai/insolvia-services insolvia-ai/insolvia; do
  gh secret set AWS_ROLE_ARN --repo "$repo" \
    --body "arn:aws:iam::521762924626:role/insolvia-shared-deploy-role"
done
```

**This repo** needs three GitHub environments — `insolvia-shared`
(`shared-infra-deploy.yml`), `insolvia-staging` (`mailer-staging.yml`) and
`insolvia-production` (the release's `promote` gate and `mailer-prod.yml`;
give it a required reviewer and restrict it to `main`) — and the
`protect-main` ruleset with the required checks the
**`insolvia-branch-protection`** skill lists.

**(insolvia)** sets up its own environments, secrets and ruleset; its
`CLAUDE.md` and `scripts/README.md` describe them.

## 6. Confirm delegation and the certificate

`insolvia.ai` is registered and Gandi already points at the imported zone.
Verify the registrar's nameservers still match the zone Terraform now manages:

```bash
terraform -chdir=infra/envs/shared output route53_name_servers
dig +short NS insolvia.ai
```

Until the ACM cert reports `ISSUED`, every environment-level plan in both
repos fails — each looks the cert up with `statuses = ["ISSUED"]` — so there
is nothing to switch on; the ordering itself is the gate.

## 7. Cognito email service-linked role — before any pool sends through SES

One-time, account-wide, human-run. The first Cognito pool with
`email_configuration` in DEVELOPER mode (insolvia's `modules/auth`, #210)
needs `AWSServiceRoleForAmazonCognitoIdpEmailService` to exist, and the CI
deploy role deliberately cannot create service-linked roles for Cognito (its
`iam:CreateServiceLinkedRole` grant covers API Gateway only) — so a staging
apply that carries the first DEVELOPER-mode pool fails without this:

```bash
aws iam create-service-linked-role --aws-service-name email.cognito-idp.amazonaws.com
```

Idempotent in effect: a second run fails with `InvalidInput` naming the role
as already taken, which is the confirmation. Only the Cognito service itself
can assume it. *Done for account `521762924626` on 2026-08-10.*

## 8. Auth — the user pools, before anything of insolvia's

insolvia's env roots find their user pool and app clients **by name** (its
`modules/auth`), so they cannot plan until the pool exists. The pool is
`module.auth` in this repo's `staging` and `prod` roots — but those roots also
hold the mailer, which looks up insolvia's API role and fails the plan until
step 9 has created it. Break the circle with a **targeted** first apply of
auth alone, from a human admin's machine, once per environment. It is the one
bootstrap-only exception to "staging and prod apply in CI", for the same
reason `shared`'s first apply in step 4 was local:

```bash
terraform -chdir=infra/envs/staging init
terraform -chdir=infra/envs/staging apply -target=module.auth   # the pool, its domains, the app clients
terraform -chdir=infra/envs/prod init
terraform -chdir=infra/envs/prod apply -target=module.auth
```

Read each plan: it should create one pool, the domain(s) and the clients,
and nothing of the mailer's. Staging's custom domain (`staging-auth`) needs
the apex to resolve, and Cognito takes 15–20 minutes to provision it. Until
insolvia's prod marketing site is up (step 9), the apex has no A record, and
this apply fails on that resource with "Was not able to resolve a DNS A record
for the parent domain". If so, re-run it after step 9. Everything else will
already exist.

Step 7's service-linked role must exist first, because both pools send
through SES.

## 9. The app's environments **(insolvia)**

In the insolvia checkout: seed the first images its Image-package Lambdas
need (`scripts/bootstrap-ecr-images.sh <env> …` — the repositories already
exist, from step 4), then apply its `staging` root through its release.
Its `scripts/README.md` and `infra/README.md` own the detail. `prod` follows
behind that repo's approval.

The mailer comes next, and needs this first: its roots look up insolvia's
`insolvia-<env>-api-role` and fail the plan until it exists. From here on
those roots plan whole, auth included, and their workflows apply them.

## 10. The mailer's environments

Once per environment, staging first. The header of
`.github/workflows/mailer-staging.yml` (and of `infra/modules/mailer/main.tf`)
is the authority; in short:

```bash
repo="$(terraform -chdir=infra/envs/shared output -json ecr_repository_urls | jq -r .mailer)"
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "${repo%%/*}"
docker build --target lambda -t "$repo:staging" services/mailer && docker push "$repo:staging"
gh workflow run mailer-staging.yml --repo insolvia-ai/insolvia-services -f bootstrap=true
```

For prod, push the same image as `$repo:prod` and dispatch `mailer-prod.yml`
with `bootstrap=true` and the `sha` staging just released. **`bootstrap: true`
is for an empty account only** — it disables the guard that stops an apply
from creating a second mailer next to a live one.

insolvia's API already points at the mailer: its roots construct
`MAILER_API_URL` from the same hostname, so nothing on that side waits on this
step. The mailer's invoke grant on insolvia's API role is created here, so
sends start working once this apply lands.

## 11. Close the loop on `ci-trust`

Now that the staging Cognito pool exists (step 8), set `staging_user_pool_arn`
in `infra/envs/ci-trust/variables.tf` (`terraform -chdir=infra/envs/staging
output -raw auth_user_pool_arn` in this repo), merge, and run
`scripts/apply-ci-trust.sh` again. Until then the staging seed role holds no
Cognito grant and insolvia's seed step fails with `AccessDenied`.

## Order of operations

1 (state bucket) → 2 (confirm no OIDC provider; check repo ids) → **3 (import
the hosted zone)** → 4 (`ci-trust`, then `shared`) → 5 (secrets, environments,
rulesets in both repos) → 6 (verify delegation + cert) → 7 (Cognito SLR) →
**8 (auth, targeted, here)** → 9 (insolvia's environments) → 10 (the
mailer's, which also brings auth under its normal workflow) → 11 (`ci-trust`
again, with the staging pool).
