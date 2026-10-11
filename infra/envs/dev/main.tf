# Per-developer-machine auth: this machine's Cognito pool, for the insolvia
# repo's local development.
#
# One instance PER DEVELOPER MACHINE, never shared, never touched by CI — the
# shape of the insolvia repo's infra/envs/dev, of which this is the auth half
# since auth moved here (insolvia ADR 0026). Every name carries the machine's
# short id (environment `dev-<machine_short_id>`), every machine keeps its own
# state key (backend.tf), and it is applied and destroyed only by
# scripts/dev-aws-auth.sh with the developer's own credentials.
#
# WHY A DEV ROOT HERE AT ALL, when the mailer has none: the mailer has a local
# stand-in (Docker + Mailpit) and Cognito does not — local sign-in needs a
# real pool. Keeping that pool in insolvia's dev root would mean either a copy
# of modules/auth there (two truths that drift) or insolvia applying this
# repo's module by git ref, which ADR 0025 already rejected for the mailer.
# Here, insolvia's dev root looks this pool up BY NAME exactly as its staging
# and prod roots look theirs up, so a developer's machine exercises the
# cross-repo contract itself, not an approximation of it.
#
# Developers do not run this directly: insolvia's scripts/dev-aws-setup.sh
# finds this checkout (its scripts/services-checkout.sh) and runs
# scripts/dev-aws-auth.sh apply before its own root, which needs the pool to
# exist to plan.

locals {
  # dev-<machine_short_id>, the ENV segment of insolvia-<env>-<component> —
  # identical to insolvia's dev root, so this pool is
  # insolvia-dev-<short-id>-users and the names line up across both roots.
  environment = "dev-${var.machine_short_id}"

  common_tags = {
    Project     = "insolvia"
    Environment = local.environment
    ManagedBy   = "terraform"
    # Ownership breadcrumbs: enough to find the human behind an orphaned
    # resource, without the UUID ever landing in git.
    DeveloperMachineId = var.machine_id
    DeveloperPrincipal = var.aws_principal_arn
    MachineName        = var.machine_name
  }
}

# The same module staging and prod instantiate. The hosted-domain prefix it
# derives (insolvia-dev-<machine_short_id>-auth) is GLOBALLY unique across all
# of AWS — the short id is what makes a per-developer pool creatable at all.
# Registers only the localhost web origin staging also registers for dev
# (`npx expo start --web --port 3000` in insolvia — the port is pinned to
# match, since Cognito callback URLs are exact-match). No custom domain (a
# quarter-hour per machine, see the module's variables) and no SES sender
# (Cognito's default sender is the right answer here: no sandbox in the way).
#
# Address module.auth, as it was in insolvia's dev root: an existing machine's
# pool moves here by `scripts/migrate-module-state.sh dev`, keeping its users.
module "auth" {
  source = "../../modules/auth"

  project     = "insolvia"
  environment = local.environment

  web_origins = ["http://localhost:3000"]

  # The MCP inspector's loopback-callback client (#261): connecting
  # `npx @modelcontextprotocol/inspector` to insolvia's locally running
  # services/mcp against THIS machine's pool is the local check for MCP work.
  mcp_inspector_client = true

  # Throwaway test accounts on a throwaway pool.
  deletion_protection = false

  tags = local.common_tags
}
