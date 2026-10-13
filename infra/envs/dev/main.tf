# The shared development pool: ONE Cognito pool every developer machine signs
# in against, applied by CI like staging and prod (insolvia ADR 0026).
#
# Everything else in development is per machine — the insolvia repo's
# infra/envs/dev holds each machine's tables, queues and buckets, under its own
# state key — and stays that way. Only the identities are shared. That is the
# shape humbugg arrived at for the same pool, and for the reason that will
# reach insolvia the day sign-in federates (Google, Facebook, …): every
# identity provider's console holds an exact list of redirect URIs, and a
# per-machine pool means a per-machine hosted domain, which means every new
# machine is a console edit at every provider before its developer can sign
# in. One pool is one domain is one URI, registered once.
#
# It also keeps the repositories apart. A per-machine pool has to be applied
# from the developer's machine, which would make the insolvia repo's local
# setup drive this repository; a shared one is applied here, by this repo's
# release, and insolvia's per-machine root only READS it — through the SSM
# contract (modules/auth/contract.tf), exactly as staging and prod do.
#
# What sharing costs: accounts are shared. A test person seeded from one
# machine exists for every machine, with whatever password the last seed set.
# Per-machine tables still hold per-machine data. And nothing per machine may
# delete pool users — they are not one machine's to delete.
#
# The sign-in page's style (the managed-login branding of the two app clients)
# is part of the module, as on staging and prod — adopted from the insolvia
# repo's retiring infra/envs/dev-shared by the import blocks at the bottom.

locals {
  environment = "dev"
  common_tags = {
    Project     = "insolvia"
    Environment = local.environment
    ManagedBy   = "terraform"
  }
}

data "aws_route53_zone" "main" {
  name = var.domain_name
}

# The account's one wildcard cert (*.insolvia.ai, infra/envs/shared), which
# covers dev-auth exactly as it covers staging-auth: one label.
data "aws_acm_certificate" "wildcard" {
  domain      = "*.${var.domain_name}"
  statuses    = ["ISSUED"]
  most_recent = true
}

# The same module staging and prod instantiate. Pool insolvia-dev-users.
# Registers only the localhost origin every machine serves the app on
# (`npx expo start --web --port 3000` in insolvia — pinned because Cognito
# callback URLs are exact-match), which is identical on every machine and so is
# part of why one pool works. No SES sender: Cognito's default sender delivers
# to any address, with no sandbox in the way.
module "auth" {
  source = "../../modules/auth"

  project     = "insolvia"
  environment = local.environment

  web_origins = ["http://localhost:3000"]

  # Sign-in on our own domain: dev-auth.insolvia.ai, beside the prefix domain
  # (insolvia-dev-auth.auth.us-east-1.amazoncognito.com, which keeps serving).
  # Once ruled out for dev — a per-machine pool would have meant a quarter-hour
  # of Cognito-managed CloudFront and a Route53 record PER MACHINE — and
  # possible now that dev is one shared pool: it is one domain, created once.
  # What it buys: dev takes the same custom-domain path staging and prod do,
  # and a federated identity provider (the day there is one) registers a
  # redirect URI we own, https://dev-auth.insolvia.ai/oauth2/idpresponse.
  #
  # Same dependency as staging's: Cognito refuses a custom domain unless the
  # PARENT (the apex, insolvia.ai) resolves, which it does only while insolvia's
  # prod marketing distribution is enabled. Verify with `dig +short insolvia.ai A`.
  #
  # The first apply blocks 15-20 minutes while Cognito provisions its own
  # CloudFront distribution. insolvia's app picks the hostname up by itself:
  # the contract's `domain` parameter prefers the custom domain.
  custom_domain   = var.auth_subdomain
  certificate_arn = data.aws_acm_certificate.wildcard.arn
  hosted_zone_id  = data.aws_route53_zone.main.zone_id

  # The MCP inspector's loopback-callback client (#261): connecting
  # `npx @modelcontextprotocol/inspector` to insolvia's locally running
  # services/mcp is the local check for MCP work.
  mcp_inspector_client = true

  # Test accounts only.
  deletion_protection = false

  tags = local.common_tags
}

# ── Adopting the sign-in page's style (2026-10-12) ──────────────
# The managed-login branding of this pool's two app clients moved here from
# the insolvia repo's infra/envs/dev-shared (insolvia ADR 0026, amended): it is
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
  id = "us-east-1_Om3HJ6JUk,e028c193-c92b-4aa5-ba6a-e58b42e6f405"
}

import {
  to = module.auth.aws_cognito_managed_login_branding.portal
  id = "us-east-1_Om3HJ6JUk,e62c48cc-92f0-4cb7-b627-51d27c9b35e3"
}
