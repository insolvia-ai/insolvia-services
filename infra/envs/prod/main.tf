# Production mailer:
#   • mailer API -> ${var.mailer_subdomain}
#
# The mailer is the only stack this root owns. The app's stacks for this
# environment (web hosting, API, auth, case stores, …) are the insolvia repo's
# infra/envs/prod — a separate root with its own state. This root reaches
# across to it in exactly two places, both BY NAME, never by remote state
# (docs/reference/terraform.md: cross-layer references are data sources):
#
#   1. The API Lambda's execution role (data.aws_iam_role.api below) — the
#      mailer's one registered caller. If insolvia has not applied this
#      environment yet, the lookup fails the plan outright, which is the
#      honest answer: there is no caller to allow.
#   2. The mailer URL travels the other way WITHOUT a reference: insolvia's
#      root constructs it from the same hostname and writes it into the API's
#      SSM namespace itself.
#
# Shared resources (zone, wildcard cert, the mailer's container repository)
# come from infra/envs/shared, in this repo, also by name.

locals {
  environment = "prod"
  common_tags = {
    Project     = "insolvia"
    Environment = local.environment
    ManagedBy   = "terraform"
  }
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
# recipient_allowlist = null: production mails its real users, so no
# restriction — the module accepts null only when environment = "prod".
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
  recipient_allowlist        = null
  ecr_repository_url         = data.aws_ecr_repository.mailer.repository_url
  image_tag                  = local.environment
  tags                       = local.common_tags
}
