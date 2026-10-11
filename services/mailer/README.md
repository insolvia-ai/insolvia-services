# Mailer

Mailer is Insolvia's shared outbound-email platform. Applications submit
versioned HTTP requests; Mailer owns durable admission, private content
storage, queueing, SES delivery, attachments, suppression, and normalized
feedback.

Its one caller today is the Insolvia API (`insolvia_api`), which lives in a
different repository —
[insolvia-ai/insolvia](https://github.com/insolvia-ai/insolvia)'s
`services/api`. Nothing here imports that code: the caller is registered by
its IAM role name, and the contract is the JSON schemas in
[`contracts/`](contracts/).

## Production flow

1. An application role signs `POST /v1/services/<service>/messages` with AWS
   SigV4.
2. The ingress Lambda verifies that the caller role is registered for the route,
   and that the recipient is inside this environment's allowlist (below).
3. Mailer stores an internal manifest in S3 and enqueues a small SQS pointer.
4. The sender Lambda validates the content, kill switch, recipient allowlist,
   suppression state, and attachment scan results before calling SES.
5. SES events are normalized and sent to the application's status queue.

Attachments use `POST /v1/services/<service>/attachment-uploads` to obtain a
15-minute presigned `PUT`; raw attachment bytes never pass through API Gateway.

## Recipient allowlist — who an environment may mail at all

Each environment states which recipients its mailer may send to, in
`MAILER_RECIPIENT_POLICY_JSON` (format and matching rules:
[`core/recipients.py`](src/insolvia_mailer/core/recipients.py)):

| Environment | Policy | Set by |
|---|---|---|
| local (Docker + Mailpit) | unrestricted by default — Mailpit never relays, so there is no one to protect | `docker-compose.yml`; override from your shell to try another environment's list |
| staging | `insolvia.ai` only (exact domain, not subdomains), plus any exact addresses named there | `recipient_allowlist` in `infra/envs/staging/main.tf` |
| prod | unrestricted | `recipient_allowlist = null` in `infra/envs/prod/main.tf` — the module accepts null **only** for prod |

A message with any recipient outside the list is **refused whole**, at
admission, with `422 {"error": "RecipientNotAllowed", "reason": …}` — never
stored, queued or partly delivered. The sender Lambda checks again before
SES, so narrowing a list also stops what was already queued (those finish as
a `reject` status event). Either refusal logs `mailer.recipient_refused` with
a reason category and a count, never the address.

**It fails closed.** If the variable is missing, empty or malformed, the
mailer refuses *every* recipient (`reason: policy_unconfigured` /
`policy_invalid`) and says so in a startup log line,
`mailer.recipient_policy refuse-all (…)`. "Send to anyone" has to be written
out as `{"mode": "unrestricted"}`.

**Not covered:** mail Cognito sends itself (invitations with temporary
passwords, reset codes) goes straight to SES and never passes through here.

## Suppression, and who is allowed to add to it

Step 4 above refuses to send to a suppressed address. Entries reach that table
two ways:

- **Automatically**, from the SES feedback path — a permanent bounce or any
  complaint (`entrypoints/feedback_lambda.py`).
- **On request**, from a registered caller: `POST
  /v1/services/<service>/suppressions` with `reason: "unsubscribe"`
  (`contracts/suppression-request.schema.json`). This is how a person clicking
  the unsubscribe link in an email actually stops the mail.

Both write the same one-way hash to the same table, on purpose: an opt-out
stored anywhere else would need the sender to check two places, and the day
someone forgets the second check is the day an unsubscribed person gets
emailed.

**The mailer does not verify that the caller has the address owner's consent.**
It cannot — it sees a SigV4-signed request from a registered service and
nothing else. Proving the request came from the address's owner belongs to the
caller; for `insolvia_api` that proof is an HMAC token (the insolvia repo's
`services/api`, `core/unsubscribe.py`) which the mailer never sees and holds
no key for. What
bounds that split is the operation itself: the worst a compromised caller
achieves is stopping its own mail to an address — never reading the table,
never sending anything. The ingress role's IAM grant on the suppressions table
is `PutItem` and nothing else, so "cannot enumerate who unsubscribed" is
enforced and not merely intended.

A caller that wants a mail client to render its own unsubscribe button sets
`list_unsubscribe_url` on the message; the sender turns it into
`List-Unsubscribe` + `List-Unsubscribe-Post` (RFC 2369 / RFC 8058). The mailer
never mints or interprets that URL — the caller composed the body, so the
caller owns the link.

## Code boundaries

The source tree makes the runtime boundary explicit:

```text
src/insolvia_mailer/
├── core/          # contracts, validation, MIME construction, and ports
├── api/           # the single Flask application and versioned routes
├── adapters/      # AWS, in-memory, and Mailpit implementations
└── entrypoints/   # Lambda handlers and the development HTTP server
```

API Gateway and the development server both invoke the same Flask application.
Only their injected adapters differ. `core` has no framework or infrastructure
dependencies, `api` depends only on `core`, and an architecture test enforces
those dependency rules. The trust invariants that ride on this layout (caller
identity comes from the registered service, never the body; S3/SQS internals are
not part of the contract) are in [`CLAUDE.md`](CLAUDE.md).

## Development flow

```bash
./scripts/dev-setup.sh   # once: shared toolchain + .venv
./scripts/dev-up.sh      # docker compose up --build
./scripts/dev-test.sh    # ruff + mypy + pytest, as CI runs them
```

- Mailer API: <http://127.0.0.1:8026>
- Mailpit inbox: <http://127.0.0.1:8025>

The development server uses the same Flask routes and schemas without SigV4.
Product email is delivered only to Mailpit, which has no outbound relay
configured.

To run with staging's recipient allowlist instead of the unrestricted local
default:

```bash
MAILER_RECIPIENT_POLICY_JSON='{"mode":"allowlist","domains":["insolvia.ai"]}' ./scripts/dev-up.sh
```

The insolvia repo's own `scripts/dev-up.sh` starts this same stack from a
sibling `insolvia-services` checkout (or `$INSOLVIA_SERVICES_DIR`), so the
local API sends through it; without a checkout it leaves the mailer out and
the API records mail in memory.

Example:

```bash
curl -i http://127.0.0.1:8026/v1/services/insolvia_api/messages \
  -H 'content-type: application/json' \
  --data @contracts/examples/message.json
```

## Privacy and retention

- Access logs contain method, route, status, latency, and request ID only.
- DynamoDB records contain identifiers, hashes, states, and timestamps—not
  message content.
- Successfully delivered S3 content is deleted promptly.
- Abandoned, failed, and quarantined content expires after 14 days.
- Delivery metadata expires after 90 days; suppressions require explicit
  removal.

See [operations.md](docs/operations.md) for alarms and recovery.
