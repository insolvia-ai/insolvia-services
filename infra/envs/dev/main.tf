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
# The managed-login BRANDING of this pool's two app clients is the insolvia
# repo's (its infra/envs/dev-shared, applied by its scripts/dev-aws-setup.sh),
# for the reason the branding is insolvia's everywhere: it is generated from
# insolvia's brand. Until that has applied once, this pool's sign-in page says
# "Login pages unavailable".

locals {
  environment = "dev"
  common_tags = {
    Project     = "insolvia"
    Environment = local.environment
    ManagedBy   = "terraform"
  }
}

# The same module staging and prod instantiate. Pool insolvia-dev-users,
# prefix domain insolvia-dev-auth.auth.us-east-1.amazoncognito.com — no custom
# domain (a quarter-hour of Cognito-managed CloudFront for a page only
# developers load). Registers only the localhost origin every machine serves
# the app on (`npx expo start --web --port 3000` in insolvia — pinned because
# Cognito callback URLs are exact-match), which is identical on every machine
# and so is part of why one pool works. No SES sender: Cognito's default sender
# delivers to any address, with no sandbox in the way.
module "auth" {
  source = "../../modules/auth"

  project     = "insolvia"
  environment = local.environment

  web_origins = ["http://localhost:3000"]

  # The MCP inspector's loopback-callback client (#261): connecting
  # `npx @modelcontextprotocol/inspector` to insolvia's locally running
  # services/mcp is the local check for MCP work.
  mcp_inspector_client = true

  # Test accounts only.
  deletion_protection = false

  tags = local.common_tags
}
