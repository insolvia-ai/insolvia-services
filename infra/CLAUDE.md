# infra — agent rules

Account-wide AWS infrastructure plus the mailer's stacks. Human overview:
[`README.md`](README.md). Deep model:
[`docs/reference/terraform.md`](../docs/reference/terraform.md); fresh-account
bootstrap: [`docs/runbooks/aws-bootstrap.md`](../docs/runbooks/aws-bootstrap.md).
Applies touch AWS — read the `insolvia-aws-auth` skill first if credentials
aren't working.

- **Six roots, and only `shared`, `staging` and `prod` are CI-applied.**
  `ci-trust` and `account-access` are human-applied by design (below);
  `dev` is per developer machine, applied only by `scripts/dev-aws-auth.sh`
  with the developer's own credentials. `staging` and `prod` hold **the
  mailer and auth** (`module.mailer`, `module.auth`); every app stack for
  those environments is the insolvia repo's root of the same name, with its
  own state key. `dev` holds **auth alone** — a developer's own pool, which
  insolvia's `infra/envs/dev` looks up by name; the mailer still has no dev
  root (its local loop is Docker + Mailpit).
- **Terraform `>= 1.10`** (native S3 state locking via `use_lockfile`; no
  DynamoDB lock table), AWS provider `~> 6.37` in every root. The floor is the
  insolvia repo's, kept identical so both repos run one provider line against
  one account: it was set by resources in insolvia's modules (managed-login
  branding, `case_store`'s index `key_schema` and two data-loss fixes up to
  6.37.0). Raise it here when insolvia raises it, or when a root here starts
  depending on something newer. **Region `us-east-1` everywhere** (CloudFront
  ACM requirement).
- **Each root's `.terraform.lock.hcl` is committed** — the constraint is the
  floor, the lock is the exact provider build every machine and CI run
  installs. To move to a newer provider, regenerate the lock for **both**
  platforms and commit the diff:
  `terraform -chdir=infra/envs/<root> providers lock -platform=linux_amd64 -platform=darwin_arm64`
  (linux_amd64 is CI, darwin_arm64 is developer machines). Never take the lock
  a plain `terraform init -upgrade` writes: it records only the current
  platform, so the other one fails checksum verification at init. If init
  reports a lock/constraint conflict, fix the lock with that command — don't
  delete the file.
- **Naming `insolvia-<env>-<component>-<identifier>`** — environment SECOND,
  component named for what it *serves*. **Read the `insolvia-aws-naming` skill
  before creating or renaming any AWS resource.** Tags `{ Project =
  "insolvia", Environment, ManagedBy = "terraform" }`. Sensitive vars
  `sensitive = true`, never committed — commit `terraform.tfvars.example`,
  never real `*.tfvars`. **`shared` is an environment, not an exemption**:
  `insolvia-shared-mailer`, `insolvia-shared-deploy-role`.
- **A rename is not just a rename — `envs/ci-trust` fences the deploy role by
  ARN pattern, and two of those patterns are controls.** A component fence is
  a MID-STRING wildcard (`alias/insolvia-*-cases`); missing one does not fail
  the apply — `DenyCaseDataDecryption` and `DenyAuditLogErasure` silently stop
  matching. Most fenced families are the insolvia repo's resources, so **a
  rename there can need a `ci-trust` change here**, applied by a human
  *before* insolvia's apply.
- **Cross-layer and cross-repo references are by name, never by state.** No
  `terraform_remote_state`, anywhere, in either repo. `shared`'s resources are
  found with `data` lookups (zone, `statuses = ["ISSUED"]` cert,
  `data "aws_ecr_repository"`); the mailer roots find insolvia's API role
  with `data "aws_iam_role"`. Root `CLAUDE.md` § "Two repositories" owns the
  three names that cross and the ordering each imposes.
- **Container repositories are shared across environments, one per service,
  in `envs/shared` — for both repos' services.** Adding one for an insolvia
  service is a PR *here* that must merge and release before insolvia's PR
  that deploys it. One-repo-per-env is deliberately rejected (prod promotes
  the digest staging validated); the note in `envs/shared/main.tf` owns why.
- **Structure:** `modules/<concern>/{main,variables,outputs}.tf`,
  `envs/<root>/{main,variables,providers,backend,outputs}.tf`. State bucket
  `insolvia-shared-terraform-state-us-east-1`, `encrypt = true`, keys in
  [`README.md`](README.md). The bucket is created by hand (bootstrap runbook),
  not by Terraform — a root cannot create its own backend. **Never reuse a
  key**: `insolvia/<env>/…` is the insolvia repo's namespace for app stacks;
  this repo's environment roots are `insolvia-services/<env>/…`. Each
  environment is its own `envs/<root>/` dir — **never** Terraform workspaces.
- **The `ci-trust` root** (OIDC provider + `insolvia-shared-deploy-role` + its
  policy + the staging seed role) is applied by a **human, never CI**
  (`DenySelfPrivilegeEscalation`) — `scripts/apply-ci-trust.sh`; skill
  `insolvia-deploy-role-permissions`. The deploy role trusts **both** repos;
  the seed role trusts insolvia **only** (it writes app data).
- **The `account-access` root** holds the **human** IAM users and groups —
  `scripts/apply-account-access.sh`, human-applied. CI cannot apply it: the
  deploy role has no `iam:*User*`/`iam:*Group*` action at all, deliberately,
  so merged code can never mint an admin. **Do not add MFA devices, login
  profiles or access keys to it** — all three write the credential into the
  state bucket; `docs/reference/terraform.md` § "Human account access" has the
  table and `docs/runbooks/iam-mfa-rotation.md` the procedure that replaces
  them. Do not add a self-service "manage your own MFA" policy either: every
  user is in `insolvia-shared-admin-group`, so it grants nothing.
- **The GitHub org login is lowercase `insolvia-ai`.** GitHub emits the stored
  casing in the OIDC `sub`, and the IAM `StringLike` condition is
  case-sensitive. The org also enforces **immutable** subject claims, pinned
  to each repo's numeric id (`infra/envs/ci-trust/variables.tf`) — recreating
  either repository changes its id and locks its CI out until a human
  re-applies `ci-trust`.
- **Never `terraform apply` staging or prod from the CLI.** Staging applies on
  merge to `main`, prod after the release's `promote` approval. The legitimate
  local applies are the human-gated `ci-trust` and `account-access`, a
  developer's own `dev` root, and the one-off state moves
  `scripts/migrate-module-state.sh` — only as `docs/runbooks/state-migration.md`
  (mailer) or `docs/runbooks/auth-state-migration.md` (auth) directs. See the
  `insolvia-deploy` skill.
- **The empty-state guard is load-bearing.** `mailer-staging.yml` and
  `mailer-prod.yml` refuse to apply onto a state missing `module.mailer` or
  `module.auth`; `bootstrap: true` overrides it **for a fresh account only**.
  Never pass it to "unstick" a deploy: if the service is live, a missing
  module means its migration has not run, and an apply creates a second
  mailer (colliding on every fixed name) or a second user pool (Cognito
  allows duplicate names — insolvia's lookup then refuses to plan). Keep both
  at their addresses — the state moves depended on it, and a rename is a
  destroy-and-create unless a `moved` block says otherwise.
- **A user pool or app client is never destroyed or replaced by a release.**
  The same two workflows refuse a plan that deletes or replaces either; only
  a hand dispatch with `allow_auth_destroy: true` gets past, and that is for
  retiring a client on purpose. A new pool mints new subjects (every account
  gone, every row insolvia keys on a subject orphaned); a new client is a new
  id every consumer verifies. Prod's pool also has deletion protection.
  Several `aws_cognito_user_pool` arguments are ForceNew — read the plan.
- **Auth's names are a contract with insolvia.** `modules/auth/main.tf`'s
  header lists them; insolvia finds the pool and its clients by name. Pool
  configuration — callback origins (staging's `http://localhost:3000` is one
  half of a contract with insolvia's Expo dev server), custom domains, the SES
  sender, deletion protection — is set here. The clients' managed-login
  **branding** and the `AdminCreateUser` **grants** are insolvia's (ADR 0026),
  so neither appears in this repo.
- **Before a large or risky change, look at a real plan.** `infra-pr.yml`
  only validates offline (`init -backend=false`): it catches syntax and type
  errors but never shows what a change would *do*, and there is no plan-mode
  workflow here. A local `terraform plan` under a human admin's credentials is
  read-only and fine (it holds the state lock briefly, so not while a release
  is applying); apply stays CI's. Skip it for routine changes, not for a
  provider bump or anything that might replace a resource.
- **A deploy job must declare `environment:`** matching the Terraform env
  (`insolvia-shared|staging|production`) — env-scoped secrets are invisible
  otherwise and resolve to empty strings silently. Never borrow another env's
  name.
- **Account facts:** dedicated AWS account `521762924626`; domain
  `insolvia.ai`. DNS is delegated and live; deploys are real.
