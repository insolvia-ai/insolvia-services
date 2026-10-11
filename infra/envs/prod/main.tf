# Production — the shared services this repo runs for the environment:
#   • the mailer       -> ${var.mailer_subdomain}
#   • auth (Cognito)   -> the pool, its hosted domain(s) and the app clients
#
# The app's stacks for this environment (web hosting, API, case stores, …) are
# the insolvia repo's infra/envs/prod — a separate root with its own state.
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
  environment = "prod"
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
  ecr_repository_url         = data.aws_ecr_repository.mailer.repository_url
  image_tag                  = local.environment
  tags                       = local.common_tags
}

# ── Auth (Cognito) ──────────────────────────────────────────────
# Insolvia's identity service for production, moved from the insolvia repo's
# root of the same name on 2026-10-11 (insolvia ADR 0026). Its address is
# module.auth, exactly as it was there, so the state moved and nothing was
# recreated (docs/runbooks/auth-state-migration.md). Every input below is the
# value insolvia passed, unchanged.
#
# Production registers ONLY the real app origin — no localhost dev callbacks
# (those live on staging), so nothing running on a laptop can complete a prod
# sign-in.
module "auth" {
  source = "../../modules/auth"

  project     = "insolvia"
  environment = local.environment

  web_origins = ["https://${var.app_subdomain}"]

  # No custom auth domain YET. It is staged behind staging on purpose —
  # staging-auth.insolvia.ai proves the module against a real pool first, and
  # the prod apply is 15-20 minutes of Cognito provisioning its own CloudFront
  # distribution. Enable by setting these, once staging's has been seen working:
  #
  #   custom_domain   = "auth.${var.domain_name}"
  #   certificate_arn = data.aws_acm_certificate.wildcard.arn
  #   hosted_zone_id  = data.aws_route53_zone.main.zone_id
  #
  # insolvia's app picks the new hostname up by itself: its auth_domain output
  # prefers the pool's custom domain wherever one exists.

  # THE POINT OF THE VARIABLE. This pool holds the real attorney accounts;
  # deleting it deletes every one of them, and with them every subject
  # insolvia keys a row on. A destroy has to be two applies: flip this off,
  # then destroy, with a plan diff at each step.
  deletion_protection = true

  # Branded sender ON, ahead of SES production access (#211) — chosen, not
  # discovered: recipients on the verified domain deliver; onboarding a REAL
  # firm before #211 lands would mean their invite silently never arrives,
  # which is why #211 is a hard prerequisite on the provisioning checklist.
  ses_source_arn = local.ses_identity_arn

  tags = local.common_tags
}
