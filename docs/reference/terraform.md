# Terraform architecture

This repo holds Insolvia's **account-wide** Terraform and the **mailer's**
stacks. The app's stacks — web hosting, the API, auth, the case and filing
stores, the job pipeline, the marketing site, and the per-developer `dev`
environment — are the insolvia repo's, documented in its own
[`docs/reference/terraform.md`](https://github.com/insolvia-ai/insolvia/blob/main/docs/reference/terraform.md).
The split happened on 2026-10-11
([ADR 0025](https://github.com/insolvia-ai/insolvia/blob/main/docs/adr/0025-shared-infra-and-mailer-move-to-insolvia-services.md)).

## Roots and state

Every root has its own isolated S3 state — never Terraform workspaces.

```
infra/
├── modules/
│   ├── mailer/          # the transactional-email service: 3 image Lambdas
│   │                    #   (ingress/sender/feedback), SigV4 HTTP API + custom
│   │                    #   domain, SQS + DLQs, S3 content bucket, DynamoDB
│   │                    #   messages + suppressions, SES configuration set,
│   │                    #   alarms, optional GuardDuty attachment scanning
│   ├── email/           # the insolvia.ai SES domain identity, DKIM, MAIL FROM,
│   │                    #   and every mail DNS record (MX, SPF, DMARC, Google)
│   └── dev_fixtures/    # the account's one seed-fixture bucket
└── envs/
    ├── ci-trust/        # GitHub OIDC provider, insolvia-shared-deploy-role
    │                    #   (trusted by both repos) + its policy, and the
    │                    #   staging seed role (trusted by insolvia alone)
    ├── account-access/  # the account's HUMAN IAM principals
    ├── shared/          # zone insolvia.ai · ACM *.insolvia.ai (+ apex SAN) ·
    │                    #   module.email · every service's ECR repository ·
    │                    #   module.dev_fixtures
    ├── staging/         # module.mailer -> staging-mailer-api.insolvia.ai
    └── prod/            # module.mailer -> mailer-api.insolvia.ai
```

| Root | State key (`s3://insolvia-shared-terraform-state-us-east-1/…`) | Owns | Applied by |
|---|---|---|---|
| ci-trust | `insolvia/ci-trust/terraform.tfstate` | The OIDC provider, the deploy role and its policy, the staging seed role | a human only (below) |
| account-access | `insolvia/account-access/terraform.tfstate` | Human IAM users, their groups, the policies attached to them | a human only; CI *cannot* (below) |
| shared | `insolvia/shared/terraform.tfstate` | Zone, wildcard cert, SES identity + mail DNS, the container repositories (`insolvia-shared-{api,admin-api,jobs,marketing,mailer,mcp,filing}`), the seed-fixture bucket `insolvia-shared-dev-fixtures-us-east-1` | CI, first leg of `release.yml` |
| staging | `insolvia-services/staging/terraform.tfstate` | The staging mailer | CI, `mailer-staging.yml` |
| prod | `insolvia-services/prod/terraform.tfstate` | The production mailer | CI, `mailer-prod.yml` behind the release's approval |

**Two key namespaces in one bucket.** `insolvia/…` is the namespace both
repos started from. The three account-wide roots kept their keys when their
code moved here, so their move was a code move, not a state move. The
insolvia repo's environment roots also stayed at `insolvia/{staging,prod}/…`
and `insolvia/dev/<account-id>/<machine-id>/…` — those keys hold the app's
stacks. This repo's environment roots are new and sit under
`insolvia-services/…`; the live mailer was moved into them, address for
address, by [`state-migration.md`](../runbooks/state-migration.md), and auth
(the Cognito pools and their app clients) by
[`auth-state-migration.md`](../runbooks/auth-state-migration.md).

**`dev` is per developer machine and holds auth alone** — that machine's
Cognito pool, at `insolvia-services/dev/<account-id>/<machine-id>/…`, applied
by `scripts/dev-aws-auth.sh` (insolvia's `scripts/dev-aws-setup.sh` runs it
before its own dev root, which looks the pool up by name). The machine
identity is insolvia's: `~/.config/insolvia/machine-id`. Auth has a dev root
and the mailer does not because the mailer has a local stand-in (Docker +
Mailpit, `services/mailer/scripts/dev-up.sh`) and Cognito has none.

## References across layers and across repos — by name, never by state

No root reads another root's state (`terraform_remote_state` appears nowhere,
in either repo). A consumer looks a resource up by its well-known name:

```hcl
data "aws_route53_zone" "main" {
  name = "insolvia.ai"
}

data "aws_acm_certificate" "wildcard" {
  domain      = "*.insolvia.ai"
  statuses    = ["ISSUED"]
  most_recent = true
}

data "aws_ecr_repository" "mailer" {
  name = "insolvia-shared-mailer"
}
```

That rule predates the split and is what made the split cheap: the boundary
between the repos was already a set of names. Four cross it:

- **`shared` → everyone.** This repo's mailer roots and the insolvia repo's
  env roots look up the zone, the cert and their container repositories.
  Both lookups hard-fail until `shared` has applied (the cert additionally
  until it is `ISSUED`).
- **insolvia → the mailer.** The mailer's roots look up
  `insolvia-<env>-api-role` (`data "aws_iam_role" "api"`), the mailer's one
  registered caller, which insolvia's `modules/api_service` creates. A data
  source rather than a typed-in name, so that a rename on the insolvia side
  fails this plan instead of silently allowing a role that no longer exists.
  The mailer also *writes onto* that role: `module.mailer` attaches the
  `insolvia-<env>-mailer-invoke` inline policy to it. If insolvia ever
  replaces the role, the grant goes with it and returns only on this repo's
  next mailer apply — re-dispatch `mailer-<env>.yml` after such a change.
- **The mailer → insolvia, with no reference at all.** insolvia's env roots
  write the mailer's URL into the API's SSM namespace, *constructed* from the
  same hostname this repo's `mailer_subdomain` serves. A hostname change is
  therefore a change in both repos.
- **Auth → insolvia.** insolvia's `modules/auth` looks up
  `insolvia-<env>-users` (`data "aws_cognito_user_pools"`, which must find
  exactly one) and its clients by name (`data "aws_cognito_user_pool_clients"`:
  `-app`, `-portal`, every `-mcp-<harness>`). It turns them into the same
  outputs, SSM parameters and `auth_*` env outputs it had when it owned the
  pool. It also owns the two things that are the consumer's: the clients'
  managed-login **branding**, generated from its brand, and the
  `AdminCreateUser` **grants** on its own roles. That is why this repo never
  needs an insolvia role name for auth, and why a fresh account's only
  cycle is the mailer's (`aws-bootstrap.md` § 8). The pool configuration and
  the names themselves are this repo's: `modules/auth/main.tf` lists the
  contract.

Root [`CLAUDE.md`](../../CLAUDE.md#two-repositories) states the ordering each
of these imposes.

## Human account access

`infra/envs/account-access/` — the account's **human** IAM principals: the
users, the groups they belong to, and the policies attached to them. Machines
are elsewhere by construction: the pipeline's identity is `ci-trust`, and
every service role is created by the env root that owns the service (in
whichever repo that is).

**CI cannot apply this root, and that is the control rather than an
oversight.** The deploy role holds no `iam:*User*` or `iam:*Group*` action
anywhere in its policy — `ServiceRoleManagement` is fenced to
`role/insolvia-*` and nothing else — so a CI apply fails on the first call. A
pipeline that could create an IAM user with `AdministratorAccess` could mint
itself an admin, which is exactly what `DenySelfPrivilegeEscalation` exists
to prevent; keeping human principals in a root CI cannot reach makes that
property structural instead of a permission someone forgot to add.

**It is separate from `ci-trust`, which is also human-applied,** for blast
radius and cadence. `ci-trust` holds the trust anchor every deploy — in both
repos — authenticates through, so a botched plan there takes both pipelines
offline. This root changes when a person joins, leaves or moves group. Two
states means a bad edit to the user map can never propose a change to the
deploy role.

Apply with `scripts/apply-account-access.sh` (credential dance → plan →
confirm).

**What it deliberately does not model**, all for the same reason — the
credential would be written to `s3://insolvia-shared-terraform-state-us-east-1`
in plaintext:

| Not modelled | Why | Where it lives instead |
|---|---|---|
| `aws_iam_virtual_mfa_device` | Exposes `base_32_string_seed` — the TOTP shared secret — as an attribute | Console enrolment: [`iam-mfa-rotation.md`](../runbooks/iam-mfa-rotation.md) |
| `aws_iam_user_login_profile` | Generated password lands in state without a PGP key, and with one you have only moved the problem to key custody | Set by the person at first sign-in |
| `aws_iam_access_key` | Writes the secret access key to state | Created out of band; rotate by create → cut over → delete |

A self-service *"manage your own MFA"* policy is also absent, and the module
header says so explicitly so it is not re-added from a search result: every
user here is in `insolvia-shared-admin-group`, so `AdministratorAccess`
already allows every MFA action (verified with
`aws iam simulate-principal-policy`). It starts doing work the day a
non-admin user exists. MFA **enforcement** (`aws:MultiFactorAuthPresent`) is
a real open gap rather than a settled decision — left out because a badly
scoped version locks the account's only human out, so it wants its own plan.

Two behaviours worth knowing before editing the user map:

- **Group membership is exclusive.** `aws_iam_user_group_membership` manages
  the full set, so a group added in the console is removed on the next apply.
- **Policy attachment is not.** There is no exclusive variant for users, so a
  policy attached by hand survives; catching that drift means reading
  `aws iam list-attached-user-policies`, not trusting the plan.

Offboarding is deliberately two applies: `aws_iam_user` carries
`prevent_destroy`, so removing someone means deleting that line and applying,
then removing them from the map and applying again. The account has one human
user and no other console path in — an accidental destroy locks everyone out
short of root recovery, and a real departure can afford a second plan.

## Container repositories (`envs/shared`)

**One repository per service, shared by every environment, for both repos'
services.** Only `insolvia-shared-mailer` holds an image this repo builds; the
others are pushed by the insolvia repo's pipelines. They live here because a
repository is an account-wide resource that must exist before any release
that pushes to it.

Prod deliberately deploys the exact image digest staging validated, which
requires one place both environments can name it. Environment isolation lives
in separate Lambdas, roles, tables and SSM namespaces — never in separate
image stores — and every image is environment-agnostic by construction.
Retention is time-based with no catch-all rule, because ECR lifecycle rules
only ever *expire* and never *protect*: a catch-all would evict the digest
prod is running once staging churned past it. The header in
`infra/envs/shared/main.tf` has the full argument.

**Adding a service in the insolvia repo starts here**: add its name to
`local.container_repositories`, merge, let the release apply `shared`, and
only then merge the insolvia PR whose roots look the repository up. The name
must stay under `insolvia-*`, which is what `ci-trust`'s ECR grant matches.

## The mailer (`modules/mailer`, `envs/staging`, `envs/prod`)

One instance per environment, at the module address `module.mailer` — the
same address it had inside insolvia's env roots, which is what let its state
move between keys without recreating anything. Keep that address.

- **Three image Lambdas from one image** (`insolvia-<env>-mailer-ingress`,
  `-sender`, `-feedback`), seeded from `insolvia-shared-mailer:<env>` and
  then rolled forward by the deploy workflow with
  `aws lambda update-function-code`; Terraform ignores `image_uri` drift. Their
  `environment` blocks stay Terraform-managed — every value is derived from
  the module's own resources.
- **An IAM-authenticated HTTP API** behind a REGIONAL custom domain, no
  CloudFront: every route requires SigV4, and the one allowed caller is
  insolvia's API role, granted `execute-api:Invoke` on its own service routes
  only.
- **SES** sends as `no-reply@insolvia.ai` through the domain identity
  `module.email` owns in `shared`; the mailer only references it.
- **Alarms** publish to `insolvia-<env>-mailer-alarms`; Terraform manages no
  subscriptions (a confirmation click, and no real addresses in a public
  repo). [`operations.md`](../../services/mailer/docs/operations.md) has the
  response to each.

**Bootstrap — image before apply.** An image Lambda cannot be created before
its image exists, and in a fresh account the repository is empty. The
sequence is in the header of `modules/mailer/main.tf` and of
`.github/workflows/mailer-staging.yml`: `shared` applied, insolvia's API
present in the environment, an image pushed as `<repo-url>:<env>`, then the
env's mailer workflow dispatched with `bootstrap: true`.

**The empty-state guard.** Both mailer workflows refuse to apply onto a state
with no `module.mailer` unless `bootstrap: true` is passed. Empty state here
means either a fresh account or a migration that has not run; in the second
case an apply would create a second mailer colliding on every fixed name, and
succeeding for the ones AWS treats as idempotent.

## Seed-fixture bucket (`modules/dev_fixtures`, in `envs/shared`)

`insolvia-shared-dev-fixtures-us-east-1`: the bytes behind the insolvia
repo's `seeds/fixtures/<version>/`, copied server-side into every dev stack
and into staging when they are seeded. Every reader and writer is in the
insolvia repo; only the bucket is here, because it is account-wide and must
be out of reach of any one environment's teardown. CI applies the bucket and
never writes to it.

## Providers

Every root pins Terraform `>= 1.10` and the AWS provider `~> 6.37`, the same
as the insolvia repo, and declares one `aws` provider in `us-east-1`. `shared`
also declares an aliased `aws.us_east_1` for the CloudFront certificate —
identical today, explicit so the certificate stays in `us-east-1` if the
default region ever moves.

Each root commits its `.terraform.lock.hcl`, with hashes for both platforms
that run Terraform here (linux_amd64 in CI, darwin_arm64 on developer
machines), so every checkout applies the same provider build against the same
state. The upgrade procedure lives in
[`infra/CLAUDE.md`](../../infra/CLAUDE.md).

## Region

**Everything is `us-east-1`.** CloudFront requires its ACM certificate there,
so the whole footprint stays there for simplicity.

## Deployment order

```
ci-trust  →  shared  →  this repo's staging / prod (mailer)
                    ↘  the insolvia repo's staging / prod (app)
```

`ci-trust` must exist first: it holds the OIDC provider and the deploy role
that CI in both repos *assumes* to apply everything else. It is
**human-applied only** — no workflow touches it — because the deploy role
cannot grant itself permissions (`DenySelfPrivilegeEscalation`). Then
`shared`, because every environment root in both repos looks up its cert
(`statuses = ["ISSUED"]`) and its container repositories, and both lookups
hard-fail until it has applied.

Between the two repos' environment roots the dependency runs one way: the
mailer looks up insolvia's API role, so in a fresh account insolvia's
environment applies before this repo's. In steady state neither waits on the
other. [`aws-bootstrap.md`](../runbooks/aws-bootstrap.md) has the full
fresh-account sequence.

Inside this repo, CI orders `shared` against the mailer:
`shared-infra-deploy.yml` has no push trigger of its own — `release.yml`
calls it (path-filtered) as the first leg of its staging stage, so a merge
that adds a shared resource plus its consumer cannot race. Across repos there
is no `needs`, so the ordering is by merge (the container-repository rule
above). The first `shared` apply in this account was preceded by a manual
`terraform import aws_route53_zone.main Z01038711J6IZ68FD6ZDW` (#13); that
import is in state.

Changing the deploy role's permissions is a `ci-trust` apply, run by a human
admin (`scripts/apply-ci-trust.sh`) — CI cannot, by the self-deny above.
Adding an IAM permission either pipeline needs is therefore never a "just
merge it" change; the `insolvia-deploy-role-permissions` skill owns the
procedure.

`account-access` is **outside this ordering entirely** — nothing depends on
it and it depends on nothing. Apply it whenever the people change; it is
never a step in standing up an environment.

## Destruction safety

Never `terraform destroy` `shared` — it holds the hosted zone, the
certificate and every container repository that both repos' environments
depend on, and the images prod is running. Tear down environments first, in
both repos.

## Conventions

- Resources: `insolvia-<env>-<component>-<identifier>` — environment SECOND
  (e.g. `insolvia-prod-mailer-feedback-dlq`). S3 buckets take a `-us-east-1`
  suffix for global uniqueness. The `insolvia-aws-naming` skill owns the full
  per-resource-type table and the component-naming rule.
- Tags: `{ Project = "insolvia", Environment = <env>, ManagedBy = "terraform" }`.
- Sensitive vars `sensitive = true`; commit `terraform.tfvars.example`, never
  real `*.tfvars`.
- The infra directory is always `infra/`, never `terraform/`.
