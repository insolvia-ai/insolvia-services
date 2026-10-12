# insolvia-services

Insolvia's account-wide AWS infrastructure, the mailer — the
transactional-email service the Insolvia app's API sends through — and auth,
the Cognito user pools the app signs people in with.

This repository was cut from
[insolvia-ai/insolvia](https://github.com/insolvia-ai/insolvia) on
2026-10-11. The reasoning is insolvia's
[ADR 0025](https://github.com/insolvia-ai/insolvia/blob/main/docs/adr/0025-shared-infra-and-mailer-move-to-insolvia-services.md);
`git log` for these files before that date is in the insolvia repo.

## What is here, and what is not

| Here | In the [insolvia repo](https://github.com/insolvia-ai/insolvia) |
|---|---|
| `infra/envs/shared` — the `insolvia.ai` zone, the wildcard certificate, the SES domain identity and mail DNS, **every** service's container repository, the seed-fixture bucket | The app, the marketing site, the staff admin portal |
| `infra/envs/ci-trust` — the GitHub OIDC provider and the one deploy role both repos use | The app's backend: `services/api`, `admin`, `mcp`, `filing`, `insolvia_core` |
| `infra/envs/account-access` — the human IAM users and groups | Every app stack: `infra/envs/dev`, `staging`, `prod` |
| `services/mailer`, and its staging/prod stacks in `infra/envs/staging` and `infra/envs/prod` | Decision records (`docs/adr/`), the product plan, seeds and fixtures |
| `infra/modules/auth` — the Cognito user pools, hosted domains and app clients, in `staging`, `prod` and one shared `dev` root ([ADR 0026](https://github.com/insolvia-ai/insolvia/blob/main/docs/adr/0026-auth-is-a-shared-service.md)) | The sign-in page's branding and the API's invite grants (insolvia's `modules/auth`, which reads the pool's SSM contract) |

The two repos deploy into one AWS account and find each other's resources by
name — never by reading each other's Terraform state. The rules that follow
from that are in [`CLAUDE.md`](CLAUDE.md#two-repositories).

## Layout

```
services/mailer/   the mailer (Python on Lambda; Mailpit locally)
infra/             Terraform — six roots, four modules; see infra/README.md
.github/           CI: PR gates, the release pipeline, shared actions
scripts/           toolchain setup and the human-run Terraform applies
docs/              reference and runbooks; see docs/README.md
```

## Running the mailer locally

You need Docker. Nothing local touches AWS.

```bash
services/mailer/scripts/dev-setup.sh   # toolchain (Homebrew) + services/mailer/.venv
services/mailer/scripts/dev-up.sh      # the mailer dev server + Mailpit
```

- Mailer API: <http://127.0.0.1:8026>
- Mailpit (every message it "sends"): <http://127.0.0.1:8025>

Mailpit has no outbound relay, so nothing sent locally can reach a real
inbox. `services/mailer/scripts/dev-test.sh` runs the same lint, type check
and tests as CI; `dev-down.sh` stops the stack. More in
[`services/mailer/README.md`](services/mailer/README.md).

Working on the app? The insolvia repo's `scripts/dev-up.sh` finds a checkout
of this repo next to it (`../insolvia-services`, or `$INSOLVIA_SERVICES_DIR`)
and brings the mailer up alongside the API.

## How deploys work

Everything deploys from GitHub Actions; nobody applies staging or prod from a
laptop.

1. **Merge to `main`.** `release.yml` applies `infra/envs/shared` if it
   changed, then deploys the mailer to staging (its Terraform root, a fresh
   image, a smoke test), then marks the commit staging-green.
2. **Approve the run's `promote` gate** when you want production to have it.
   The production leg applies `infra/envs/prod` and promotes the exact image
   staging ran — it never rebuilds.

Two roots are applied by a person instead, on purpose: `ci-trust` (the deploy
role cannot change its own permissions) and `account-access` (CI cannot create
IAM users at all). See [`infra/README.md`](infra/README.md).

**The 2026-10-11 cutover.** Until the mailer's live resources have been moved
out of the insolvia repo's Terraform state, this repo's staging and prod
deploys refuse to run (they would create a second mailer). The procedure is
[`docs/runbooks/state-migration.md`](docs/runbooks/state-migration.md).
