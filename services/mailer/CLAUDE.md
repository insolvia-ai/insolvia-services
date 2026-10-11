# services/mailer — agent rules

Shared outbound-email platform (apps own their templates and copy). Human docs:
[`README.md`](README.md). Run with `scripts/dev-up.sh` (Mailpit).

- **Layered `core / api / adapters / entrypoints`**; `tests/unit/test_architecture.py`
  enforces the direction (`core` depends on nothing else; `api` only on `core`).
- **Caller identity, sender, configuration set, and status routing come from the
  registered service — never the request body.** A caller cannot spoof who it is
  or where feedback goes by setting a field.
- **S3 object keys and internal SQS messages are implementation details** — not
  part of the API contract.
- **The production API is IAM-authenticated (SigV4)** — the only application
  ingress.
- **Never write message bodies, recipients, subjects, filenames, or upload URLs
  to logs or DynamoDB.**
- **Local Mailpit must never relay externally.**
- **The recipient allowlist fails closed.** A missing or malformed
  `MAILER_RECIPIENT_POLICY_JSON` refuses every recipient; only an explicit
  `{"mode": "unrestricted"}` allows all, and Terraform lets only prod say so.
  Never add a code path that defaults to unrestricted, and never put a
  refused address in an error message or log line — `core/recipients.py`
  owns the format, README § "Recipient allowlist" the per-environment values.
- **The one caller lives in another repository** (insolvia's `services/api`,
  registered as `insolvia_api`). No PR can change both sides at once, so a
  change to `contracts/` or to a route must stay backward-compatible until the
  insolvia side has shipped against it — and a new allowed category lands
  here (`local.insolvia_api_service` in `infra/modules/mailer/main.tf`, plus
  `docker-compose.yml`'s development registry) *before* the API sends it.
