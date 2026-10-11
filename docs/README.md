# docs

How this repo's infrastructure and the mailer work, and the procedures a
person runs against them. Decision records and the product plan are in the
[insolvia repo's `docs/`](https://github.com/insolvia-ai/insolvia/tree/main/docs).

| Document | Kind | What it covers |
|---|---|---|
| [`reference/terraform.md`](reference/terraform.md) | reference | The six roots, state keys, cross-layer and cross-repo lookups, human account access, apply order |
| [`reference/email.md`](reference/email.md) | reference | Mail for `insolvia.ai`: Google Workspace receives, SES sends; every DNS record and why |
| [`runbooks/aws-bootstrap.md`](runbooks/aws-bootstrap.md) | runbook | Standing the account up from nothing, across both repos |
| [`runbooks/state-migration.md`](runbooks/state-migration.md) | runbook | The 2026-10-11 cutover: moving the live mailer's state out of insolvia's roots |
| [`runbooks/auth-state-migration.md`](runbooks/auth-state-migration.md) | runbook | Moving auth (the Cognito pools and clients) out of insolvia's roots: staging, prod, each developer machine |
| [`runbooks/ses-production-access.md`](runbooks/ses-production-access.md) | runbook | Getting SES out of the sandbox: checklist, request text, after the decision |
| [`runbooks/iam-mfa-rotation.md`](runbooks/iam-mfa-rotation.md) | runbook | Rotating a human IAM user's MFA device (a console procedure, not Terraform) |

Service-level documents live with the service:
[`services/mailer/docs/onboarding.md`](../services/mailer/docs/onboarding.md)
(registering a caller) and
[`services/mailer/docs/operations.md`](../services/mailer/docs/operations.md)
(alarms, DLQs, the kill switch).
