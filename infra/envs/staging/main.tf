# Staging — the shared services this repo runs for the environment:
#   • the mailer       -> ${var.mailer_subdomain}
#   • auth (Cognito)   -> the pool, its hosted domain(s) and the app clients
#
# The app's stacks for this environment (web hosting, API, case stores, …) are
# the insolvia repo's infra/envs/staging — a separate root with its own state.
# The two reach each other BY NAME, never by remote state
# (docs/reference/terraform.md: cross-layer references are data sources):
#
#   1. The mailer looks up insolvia's API Lambda execution role
#      (data.aws_iam_role.api below) — its one registered caller. If insolvia
#      has not applied this environment yet, that lookup fails the plan
#      outright, which is the honest answer: there is no caller to allow.
#   2. The mailer URL travels the other way WITHOUT a reference: insolvia's
#      root constructs it from the same hostname.
#   3. insolvia finds the user pool and its app clients by NAME (its
#      modules/auth) — this root never learns anything of insolvia's for auth.
#      The names are the contract; modules/auth/main.tf lists them.
#
# Shared resources (zone, wildcard cert, the mailer's container repository)
# come from infra/envs/shared, in this repo, also by name.

data "aws_caller_identity" "current" {}

locals {
  environment = "staging"
  common_tags = {
    Project     = "insolvia"
    Environment = local.environment
    ManagedBy   = "terraform"
  }

  # The account's SES domain identity (infra/envs/shared's email module),
  # CONSTRUCTED rather than read from remote state — the same ARN modules/mailer
  # builds. The pool sends invites and reset codes through it (#210).
  ses_identity_arn = "arn:aws:ses:${var.aws_region}:${data.aws_caller_identity.current.account_id}:identity/${var.domain_name}"
}

data "aws_route53_zone" "main" {
  name = var.domain_name
}

# Regional, us-east-1 — API Gateway's regional custom domain. The same one
# wildcard cert serves every custom domain in the account.
data "aws_acm_certificate" "wildcard" {
  domain      = "*.${var.domain_name}"
  statuses    = ["ISSUED"]
  most_recent = true
}

data "aws_ecr_repository" "mailer" {
  name = "insolvia-shared-mailer"
}

# insolvia-<env>-api-role: the insolvia repo's modules/api_service names it
# "${local.name}-role" with local.name = insolvia-<env>-api. Renaming it there
# without renaming it here fails THIS plan (the lookup finds nothing) rather
# than silently allowing a role that no longer exists — which is why this is a
# data source and not a string passed straight into the module.
data "aws_iam_role" "api" {
  name = "insolvia-${local.environment}-api-role"
}

# The shared transactional-email microservice, with exactly one registered
# caller — the API Lambda. Its address is module.mailer, the same address it
# had inside insolvia's root, so the state move was a move and not a
# destroy-and-create.
#
# enable_attachment_scanning is false: no category this platform sends today
# carries attachments, so GuardDuty Malware Protection for S3 would be a real
# monthly cost with nothing to scan (see modules/mailer/variables.tf). Set
# identically in both environments — not an environment-specific decision.
#
# recipient_allowlist: staging sends through real SES, so it mails only our own
# domain — seed users, e2e accounts and hand-entered clients at any other
# address are refused with a 422 at the mailer (the caller logs and carries
# on). Add an exact address here, not a domain, to let one outside tester
# receive staging mail. This is the precondition for SES production access
# (docs/runbooks/ses-production-access.md): without it, leaving the sandbox
# would let staging mail anyone.
#
# First apply in a fresh account needs an image before the Lambdas can be
# created — see the bootstrap note at the top of modules/mailer/main.tf.
module "mailer" {
  source = "../../modules/mailer"

  project                    = "insolvia"
  environment                = local.environment
  domain_name                = var.mailer_subdomain
  hosted_zone_id             = data.aws_route53_zone.main.zone_id
  acm_certificate_arn        = data.aws_acm_certificate.wildcard.arn
  caller_role_name           = data.aws_iam_role.api.name
  sender_address             = "no-reply@insolvia.ai"
  cors_allowed_origin        = "https://${var.app_subdomain}"
  enable_attachment_scanning = false
  recipient_allowlist        = { domains = ["insolvia.ai"] }
  ecr_repository_url         = data.aws_ecr_repository.mailer.repository_url
  image_tag                  = local.environment
  tags                       = local.common_tags
}

# ── Auth (Cognito) ──────────────────────────────────────────────
# Insolvia's identity service for this environment, moved from the insolvia
# repo's root of the same name on 2026-10-11 (insolvia ADR 0026). Its address
# is module.auth, exactly as it was there, so the state moved and nothing was
# recreated (docs/runbooks/auth-state-migration.md). Every input below is the
# value insolvia passed, unchanged — a difference would show up in the move's
# verification plan, and for the pool or a client that plan refuses anything
# but no change.
#
# web_origins carries a localhost dev origin ON STAGING ONLY: Cognito callback
# URLs are exact-match (no wildcard host or port), so local web dev against
# staging auth must PIN ITS PORT — which is why insolvia's Expo dev server is
# started on 3000 (`npx expo start --web --port 3000`). That port and this
# entry are one contract, now across two repositories; changing either alone
# breaks local sign-in. Prod registers no dev origins — nothing running on a
# laptop should be able to complete a prod sign-in.
module "auth" {
  source = "../../modules/auth"

  project     = "insolvia"
  environment = local.environment

  web_origins = [
    "https://${var.app_subdomain}",
    "http://localhost:3000",
  ]

  # Sign-in on our own domain: staging-auth.insolvia.ai.
  #
  # Cognito refuses to create a custom domain unless the PARENT domain resolves
  # to an IP, and the parent of staging-auth.insolvia.ai is the apex — which
  # resolves only because insolvia's PROD marketing distribution is enabled. So
  # parking prod's marketing site would break STAGING sign-in, across two
  # repositories now. Verify with `dig +short insolvia.ai A`; reading the
  # Route53 record is not the same check (an alias to a disabled distribution
  # resolves to nothing).
  #
  # Added alongside the Cognito prefix domain, not replacing it (see the module).
  custom_domain   = var.auth_subdomain
  certificate_arn = data.aws_acm_certificate.wildcard.arn
  hosted_zone_id  = data.aws_route53_zone.main.zone_id

  # Staging pool holds only test accounts; keep it destroyable.
  deletion_protection = false

  # The MCP inspector's loopback-callback client (#261): staging is where the
  # OAuth dance is verified with an inspector. Deliberately absent from prod.
  mcp_inspector_client = true

  # Invites and reset codes leave as no-reply@insolvia.ai (#210). SES
  # sandboxed until #211: recipients on the verified insolvia.ai domain deliver,
  # external ones do not. ONE-TIME PREREQUISITE in a fresh account: the Cognito
  # email service-linked role (docs/runbooks/aws-bootstrap.md § 7).
  ses_source_arn = local.ses_identity_arn

  tags = local.common_tags
}

# ── Adopting the sign-in page's style (2026-10-12) ──────────────
# The managed-login branding of this pool's two app clients moved here from
# the insolvia repo's infra/envs/staging (insolvia ADR 0026, amended): it is
# auth's, so it lives with the pool. These blocks ADOPT the live styles
# rather than creating new ones — Cognito allows one style per client and
# rejects a second (ManagedLoginBrandingExistsException), and a create would
# have needed the old one deleted first, taking sign-in down in between. The
# insolvia side lets go with `removed { destroy = false }`; either side may
# apply first.
#
# Id format: <user pool id>,<managed login branding id>. Idempotent once
# applied; delete these blocks after this root has applied them.
import {
  to = module.auth.aws_cognito_managed_login_branding.web
  id = "us-east-1_H6iy8mjKM,3e6fe023-4e90-4736-98f9-8a92d5f80254"
}

import {
  to = module.auth.aws_cognito_managed_login_branding.portal
  id = "us-east-1_H6iy8mjKM,42e32c3e-40b7-4448-beba-0c386ea6d582"
}
