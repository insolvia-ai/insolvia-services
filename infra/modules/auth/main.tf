# Cognito auth — Insolvia's identity service: one user pool per environment
# (insolvia-<env>-users), its hosted domains, and public PKCE app clients:
# the web SPA's (staff), the client portal's (debtors, ADR 0023) and one per
# MCP harness — disjoint ids, each verified by exactly the surface it serves.
# The house style is email-as-username, admin-only creation, and SRP-only
# explicit flows, on the OAuth authorization-code + PKCE flows a browser SPA
# actually needs. (ADR numbers here are the insolvia repo's docs/adr/.)
#
# MOVED HERE from the insolvia repo on 2026-10-11 (insolvia ADR 0026, amending
# 0025): auth is a shared service. The addresses are the ones it had there —
# module.auth.* — so the state moved and nothing was recreated
# (docs/runbooks/auth-state-migration.md).
#
# WHAT THIS MODULE DOES NOT OWN, and where it went. Both stayed in the insolvia
# repo's modules/auth, at their old addresses, because they are the
# CONSUMER's, not the service's:
#   • the managed-login branding styles (aws_cognito_managed_login_branding) —
#     generated from insolvia's brand by its `npm run tokens`, per app client;
#   • the AdminCreateUser grants on insolvia's API and admin Lambda roles —
#     a consumer grants its own role access to this pool, so this module never
#     needs a consumer's role name, and a fresh account has no cycle between
#     this root and insolvia's.
#
# THE SSM PARAMETERS ARE THE CONTRACT. insolvia reads /insolvia/<env>/auth/*
# (published by contract.tf) — never this module's state, and
# never the pool by name. Every MCP harness client registered here lands in
# the mcp-client-ids parameter, so adding a client here IS allowing it in
# insolvia's MCP service.
#
# NEVER RECREATE A POOL OR A CLIENT. A new pool mints new subjects, and every
# row insolvia keys on a subject (firm users, case ownership, client bindings)
# then points at nobody; a new client changes the id every consumer verifies.
# Prod carries deletion_protection. Treat a planned create, destroy or replace
# of either as a hard stop, not a review comment.
#
# A desktop or mobile client, if one is ever added, must register a CUSTOM
# SCHEME — `insolvia://auth/callback` — and NOT an RFC 8252 §7.3 loopback
# redirect (`http://127.0.0.1:<port>/callback`): the loopback pattern needs
# the app to bind an HTTP listener on 127.0.0.1, which a React Native runtime
# has no way to do without a native module, whereas a custom scheme is exactly
# what `expo-auth-session` + `app.json`'s `scheme` already produce on every
# platform, web included. Cognito accepts a custom scheme in `callback_urls`
# with no special handling.

data "aws_region" "current" {}

# The branded email bodies (#210). Inline HTML rather than templatefile():
# each is one small paragraph-block whose only variables are Cognito's own
# {username}/{####} placeholders — which must reach Cognito literally, so a
# Terraform template would spend its complexity escaping them. Copy changes
# are code-reviewed diffs here, same as everything else in this module.
#
# Kept deliberately spare: no images, no links to click. A credential email
# that trains recipients to click buttons is phishing practice; this one tells
# them what happened and what the temporary password is, and the sign-in page
# is wherever their firm already goes.
#
# AUDIENCE-NEUTRAL since ADR 0023: this one template now reaches two kinds of
# recipient — an attorney or paralegal added by their firm, and a debtor
# invited to the client portal by the law firm representing them — because
# invitation copy is a POOL setting and the portal shares this pool. "The
# platform your firm uses" was true of the first and false of the second, who
# does not have a firm; "a law firm that uses it" is true of both. Anything
# audience-specific (which firm, what to do next, where to sign in) travels in
# the second message, which the API sends through the mailer and which carries
# no secret. Diverging copy per audience is one of the recorded reasons to
# reopen ADR 0023's one-pool decision, not something to fake here.
locals {
  invite_email_message = join("", [
    "<p>Hello,</p>",
    "<p>An account has been created for you on <b>Insolvia</b>, a bankruptcy case preparation platform, at the request of a law firm that uses it.</p>",
    "<p>Your sign-in name is {username} and your temporary password is <b>{####}</b>. It expires in 7 days — when you first sign in, you will choose a password of your own.</p>",
    "<p>If you were not expecting this invitation, you can ignore this email.</p>",
    "<p>— Insolvia</p>",
  ])

  verification_email_message = join("", [
    "<p>Your Insolvia verification code is <b>{####}</b>.</p>",
    "<p>If you did not request this code, you can ignore this email — nothing changes without it.</p>",
    "<p>— Insolvia</p>",
  ])
}

# ── User pool ───────────────────────────────────────────────────

resource "aws_cognito_user_pool" "main" {
  name = "${var.project}-${var.environment}-users"

  # Self-signup is DISABLED, deliberately: Insolvia's users are attorneys and
  # their staff, provisioned by us (aws cognito-idp admin-create-user, or the
  # admin tooling that grows around it) when a firm onboards. A public
  # sign-up form on a bankruptcy-filing platform would be an invitation to
  # junk accounts, not a growth channel.
  admin_create_user_config {
    allow_admin_create_user_only = true

    # The email that delivers a new user's temporary password (#210) — the
    # first thing an invited attorney ever receives from Insolvia, replacing
    # Cognito's stock "Your username is... your temporary password is..." text.
    # Templates are independent of WHO SENDS (email_configuration below), so
    # they land on every environment immediately, default sender included.
    # Cognito requires both {username} and {####} in the message.
    invite_message_template {
      email_subject = "Welcome to Insolvia — your account is ready"
      email_message = local.invite_email_message
      # Never sent — no SMS delivery is configured anywhere — but the provider
      # transmits an empty string when the attribute is omitted and Cognito
      # rejects that ("length greater than or equal to 6"). Found by a real
      # dev apply; validate cannot see it. Must contain both placeholders.
      sms_message = "Insolvia: sign-in {username}, temporary password {####}"
    }
  }

  # The code emails: attribute verification and — the one that matters today —
  # the forgot-password code the managed login's own "Forgot your password?"
  # flow sends. Same stock-text-to-branded upgrade as the invite above.
  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "Your Insolvia verification code"
    email_message        = local.verification_email_message
  }

  # WHO SENDS (#210): unset, Cognito's default sender —
  # no-reply@verificationemail.com, capped at 50 emails/day, and the right
  # answer for dev, where the default sender delivers to any address with no
  # SES sandbox in the way. Set, mail leaves as no-reply@insolvia.ai through
  # the account's own SES identity (DEVELOPER mode). Two consequences the
  # variable's docs spell out: SES sandbox rules then apply (an invite to an
  # unverified address silently fails to deliver until production access,
  # #211), and the FIRST DEVELOPER-mode pool in the account needs the Cognito
  # email service-linked role to exist — a one-time human CLI, because the
  # deploy role deliberately cannot create service-linked roles for Cognito
  # (docs/runbooks/aws-bootstrap.md § "Cognito email
  # service-linked role").
  dynamic "email_configuration" {
    for_each = var.ses_source_arn == null ? [] : [var.ses_source_arn]
    content {
      email_sending_account = "DEVELOPER"
      from_email_address    = var.from_email_address
      source_arn            = email_configuration.value
    }
  }

  # Email is the username. auto_verified_attributes lets an admin-created
  # user's verified email drive account recovery below.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # USERNAMES ARE MATCHED CASE-INSENSITIVELY, and this block is the only way to
  # say so. Cognito's LEGACY default — what you get when this block is absent —
  # is case-SENSITIVE, which for a pool whose username IS an email address
  # means `Alice@firm.com` and `alice@firm.com` are two different accounts and
  # an attorney who types a capital on the sign-in page is told they do not
  # exist. Measured against the real staging pool rather than inferred:
  # creating `a@example.invalid` and then `A@EXAMPLE.INVALID` produced two
  # accounts, no exception, each with its own subject.
  #
  # THIS BLOCK IS IMMUTABLE. AWS accepts it only at creation, so the provider
  # marks it ForceNew — adding it REPLACES the pool and deletes every account
  # in it. That is why it was not simply set when the pool was written, and why
  # it is being set now rather than later: the cost is every account plus every
  # row keyed on a Cognito subject, and both of those only grow.
  #
  # What "every row keyed on a subject" means, because it is the half that is
  # easy to miss: a replaced pool mints NEW subs, so `firm_user` rows
  # (insolvia-<env>-firms, keyed on the subject), `case.createdBy` and every
  # case assignment would all point at identities that no longer exist. Those
  # tables are empty today. After the first firm is onboarded this stops being
  # a pool replacement and becomes a data migration.
  username_configuration {
    case_sensitive = false
  }

  # ACTIVE on prod (via the variable): deleting the pool deletes every
  # attorney account, so prod requires a two-step (flip this off, then
  # destroy) with a plan diff at each step.
  deletion_protection = var.deletion_protection ? "ACTIVE" : "INACTIVE"

  # ESSENTIALS is the default plan for new pools; pinned explicitly so a
  # future provider default change can't silently move the pool (and the
  # bill). Threat protection ("advanced security", the reference module's
  # era called it) now requires the PLUS plan at extra per-MAU cost — not
  # "cheap", so deferred until there are real accounts worth protecting.
  # ESSENTIALS already includes the modern auth baseline (token revocation,
  # refresh-token rotation below).
  user_pool_tier = "ESSENTIALS"

  # Same shape as the reference module: 12+ chars, mixed case + digits,
  # symbols not forced (length beats charset-composition rules; forcing
  # symbols mostly forces "Password1!"). The temporary password an admin
  # provisions with lives a week — onboarding is human-paced.
  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  # Optional TOTP: attorneys can (and should) enroll an authenticator app,
  # but MFA is not forced at the door while the product has no settings UI
  # to manage enrollment. No SMS MFA — it needs an SNS/SMS setup and is the
  # weaker factor anyway.
  mfa_configuration = "OPTIONAL"
  software_token_mfa_configuration {
    enabled = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  tags = var.tags
}

# ── Hosted domain ───────────────────────────────────────────────
# Cognito-provided prefix domain: insolvia-<env>.auth.<region>.amazoncognito.com
# hosts the /oauth2/authorize, /oauth2/token, and sign-in pages. A custom domain
# (auth.insolvia.ai) is still deferred — it is a separate decision from branding
# and needs a CI-role IAM change first: Cognito provisions its own CloudFront
# distribution with the CALLER's credentials, so the deploy role would need
# cloudfront:UpdateDistribution, and that grant can only be applied by a human
# (see the insolvia-deploy-role-permissions skill). Branding — the consumer's,
# not this module's — needs neither DNS nor new IAM and works on this prefix
# domain today.
#
# managed_login_version = 2 selects MANAGED LOGIN over the classic hosted UI.
# AWS calls the classic UI "a first-generation version of the managed login
# services" with "a simpler design and fewer features"; managed login is what
# carries the branding editor, dark mode, localisation, and the Terms/Privacy
# links at sign-up. It is available from the ESSENTIALS feature tier, which
# this pool is already on — no tier change, no extra cost.
#
# Two consequences worth knowing before touching this line:
#   • Switching branding version signs everyone out. AWS does not preserve
#     sessions across the switch, and it takes up to ~4 minutes to take effect.
#   • The rendered markup changes completely, so the staging E2E's hosted-UI
#     field selectors must be re-derived from the real page (insolvia's e2e/).
resource "aws_cognito_user_pool_domain" "main" {
  # insolvia-<env>-auth. The prefix is GLOBALLY unique across all of AWS, so
  # the env segment is what makes a per-developer pool creatable at all; the
  # `auth` component says what the hostname serves rather than leaving the
  # slot empty.
  domain                = "${var.project}-${var.environment}-auth"
  user_pool_id          = aws_cognito_user_pool.main.id
  managed_login_version = 2

  # NO depends_on the branding any more, and that is a real loss, so it is
  # written down. Until 2026-10-11 this resource depended on the two
  # aws_cognito_managed_login_branding styles, which made "managed login is on
  # but has nothing to render" unreachable: a client on managed login with no
  # style does not fall back to defaults, it serves "Login pages unavailable.
  # Please contact an administrator." That is exactly how staging once broke.
  #
  # The styles now belong to the CONSUMER (the insolvia repo's modules/auth,
  # beside the generator that renders them from its brand — insolvia ADR 0026),
  # and a depends_on cannot cross a repository. What is left of the guarantee:
  #   • steady state is unaffected — every live client already has its style,
  #     and nothing here touches one;
  #   • a FRESH pool (a new environment, the shared dev pool's first apply) serves the
  #     "unavailable" page between this apply and the consumer's, which in
  #     every one of those cases is an environment nobody is signed in to yet.
  #     for dev, insolvia's scripts/dev-aws-setup.sh brands the shared pool;
  #   • a REPLACED client loses its style the same way — and a planned
  #     replacement of any client here is already a hard stop (see the
  #     header), because it also changes the id every consumer verifies.
}

# ── Custom auth domain (staging, prod) ──────────────────────────
# `auth.insolvia.ai` instead of `insolvia-prod.auth.<region>.amazoncognito.com`.
# Sign-in is the one screen where an unfamiliar domain reads as phishing, and
# AWS's own guidance is that a custom domain "improves user trust ... especially
# when the root domain matches the domain that hosts your application".
#
# ADDED ALONGSIDE the prefix domain, not instead of it. A pool may hold one of
# each, and keeping both makes the cutover free: the app moves when its build
# picks up the new `domain` output, and the prefix keeps serving until then.
# Replacing would mean deleting the prefix domain first and waiting out the
# create — sign-in down for the duration.
#
# Two costs of a custom domain, both real:
#   • Create and delete each take 15-20 minutes, and Terraform blocks. Plan
#     accordingly; this is not a resource to churn.
#   • Cognito serves `/.well-known/openid-configuration` from the CUSTOM domain
#     only once one exists. Nothing here reads it — the API verifies against
#     `issuer_url`, which is the pool's own endpoint and unaffected — but an
#     OIDC client added later must point at the custom domain.
#
# The parent domain needs an A record or Cognito refuses to create this, as
# protection against hijacking a domain you do not control. `insolvia.ai`
# already has one (the marketing apex alias); an SOA record would not count.
resource "aws_cognito_user_pool_domain" "custom" {
  count = var.custom_domain == null ? 0 : 1

  domain                = var.custom_domain
  user_pool_id          = aws_cognito_user_pool.main.id
  certificate_arn       = var.certificate_arn
  managed_login_version = 2

  # The prefix domain's note on the branding order applies here unchanged.
}

# Cognito creates its own CloudFront distribution for the custom domain and
# hands back the hostname to point at. The zone id comes from the resource
# rather than the usual hard-coded CloudFront constant (Z2FDTNDATAQYW2) —
# provider 6 exposes it, and reading it beats copying a magic string.
resource "aws_route53_record" "auth" {
  count = var.custom_domain == null ? 0 : 1

  zone_id = var.hosted_zone_id
  name    = var.custom_domain
  type    = "A"

  alias {
    name                   = aws_cognito_user_pool_domain.custom[0].cloudfront_distribution
    zone_id                = aws_cognito_user_pool_domain.custom[0].cloudfront_distribution_zone_id
    evaluate_target_health = false
  }
}

# ── App client ──────────────────────────────────────────────────
# An OAuth public client (RFC 6749 §2.1): no secret, because a browser bundle
# can be unpacked and anything embedded in it read out. It uses the
# authorization-code grant; PKCE (RFC 7636) is the client's obligation —
# Cognito's authorize endpoint accepts and enforces a code_challenge when one
# is sent, but offers no server-side "require PKCE" toggle, so the app
# implementation MUST send one (`expo-auth-session` does by default).
#
# Refresh-token rotation is ENABLED: each refresh returns a new refresh token
# and retires the old one, so a stolen refresh token stops working as soon as
# the legitimate client refreshes. The 30 s grace period keeps a flaky network
# from locking the client out when a rotation response is lost in transit and
# the client retries with the "old" token.

locals {
  # The web SPA's redirect contract: the app must handle the code exchange at
  # <origin>/auth/callback and land sign-outs on the origin root. Derived
  # here, per origin, so staging's localhost dev origin gets the same paths
  # as the real one.
  #
  # Cognito matches callback URLs EXACTLY — no wildcard host, path, or port.
  # That is why the dev origin has to pin a port (see the callers), and why a
  # future native client would register `insolvia://auth/callback` as its own
  # literal entry rather than anything pattern-shaped.
  web_callback_urls = [for o in var.web_origins : "${o}/auth/callback"]
  web_logout_urls   = var.web_origins
}

# The web SPA (app.insolvia.ai / staging-app.insolvia.ai, Expo web).
resource "aws_cognito_user_pool_client" "web" {
  # Component `app`, matching the surface it signs people in to — the same
  # component modules/web_hosting uses for that SPA's bucket. It was `web`,
  # which named a tier and collided with two other resources.
  name         = "${var.project}-${var.environment}-app"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = false # public client — see the header comment

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = local.web_callback_urls
  logout_urls   = local.web_logout_urls

  # Sign-in happens on the hosted domain, so the client needs no
  # password-carrying SDK flow — SRP for completeness. Deliberately NO
  # ALLOW_USER_PASSWORD_AUTH: nothing should ever ship a raw password
  # through this client. And NO ALLOW_REFRESH_TOKEN_AUTH: with
  # refresh_token_rotation enabled (below) Cognito REJECTS it as an explicit
  # flow at CreateUserPoolClient time ("not a permitted ExplicitAuthFlow
  # when refresh token rotation is enabled") — rotation owns the refresh
  # path. Found by the first dev-env apply; validate can't see it.
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
  ]

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  # Token validities: 1 h access/ID tokens (the Cognito default, short
  # enough that revocation-by-rotation matters), 30-day refresh so an
  # attorney using the app weekly stays signed in, but an abandoned browser
  # session dies within a month.
  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  refresh_token_rotation {
    feature                    = "ENABLED"
    retry_grace_period_seconds = 30
  }
}

# ── Client portal app client (ADR 0023) ─────────────────────────
# A debtor using the client portal is a THIRD principal class — a `client` —
# signed in by THIS pool through a SECOND public PKCE client. The class is
# decided by the token's `client_id` at verification: insolvia's services/api verifies
# the web client's id on every staff route and this client's id on every
# /v1/portal/ route, so a portal token fails closed on staff routes and a
# staff token fails closed on portal routes, with no role check to forget.
# That is ADR 0016's disjoint-client-id audience check applied a second time.
# The API's copy of this id is derived from this resource via insolvia's SSM
# parameter (`/insolvia/<env>/api/auth-portal-client-id`), never hand-listed.
#
# What this client does NOT decide: which case a client may reach. That is a
# binding row in insolvia's own store (insolvia_core.clients), exactly as ADR 0009
# keeps firm membership out of the token. A pool user who holds no binding
# can sign in here and is refused by every portal route.
#
# ONE POOL, SO ONE POLICY. Password policy, MFA and the invitation copy above
# are pool settings, shared with attorneys. ADR 0023 accepts that at launch
# and names the divergence as its reason to reopen.
#
# Same redirect contract shape as the web client, under the app's `/portal`
# route group (PR 2 of ADR 0023 builds the screens): the code exchange at
# <origin>/portal/auth/callback, sign-outs landing on <origin>/portal. Exact
# match, same origins — including http://localhost:3000, which is the local
# third of "three environments": each developer's own pool gets this client
# on their next dev apply.
locals {
  portal_callback_urls = [for o in var.web_origins : "${o}/portal/auth/callback"]
  portal_logout_urls   = [for o in var.web_origins : "${o}/portal"]
}

resource "aws_cognito_user_pool_client" "portal" {
  # insolvia-<env>-portal: component named for the surface it signs people in
  # to, as `app` is for the web client above.
  name         = "${var.project}-${var.environment}-portal"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = false # public client — same argument as the web client

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = local.portal_callback_urls
  logout_urls   = local.portal_logout_urls

  # SRP only, as every client in this pool: sign-in is on the managed login
  # pages, and the integration tier signs the seeded client in over SRP
  # (services/api/tests/integration/cognito_srp.py) against THIS client.
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
  ]

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  # SHORTER THAN THE WEB CLIENT, on purpose (ADR 0023's threat model): portal
  # sessions are memory-only — ADR 0011's choice, not ADR 0007's — because a
  # debtor's device is the least controlled in the system, and the
  # questionnaire resumes server-side, so a lost session costs one sign-in.
  # The 1 h access token bounds a stolen token and a revoked binding; the
  # 1-day refresh token bounds a session left open on a shared computer.
  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 1
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  refresh_token_rotation {
    feature                    = "ENABLED"
    retry_grace_period_seconds = 30
  }
}

# ── MCP harness clients (#261) ──────────────────────────────────
# The MCP service (insolvia's services/mcp, ADR 0016) is an OAuth 2.1 resource server
# over THIS pool: the pool is the authorization server harnesses discover
# through the server's RFC 9728 protected-resource metadata, and an MCP
# session is a `sub` with firm permissions like any other caller (ADR 0009).
#
# ONE PRE-REGISTERED APP CLIENT PER HARNESS — the design's stated v1
# constraint (insolvia's docs/reference/mcp-surface.md § Identity): Cognito supports
# neither dynamic client registration nor Client ID Metadata Documents, and
# the MCP spec explicitly allows pre-registered client ids. Whether every
# harness we care about can actually complete the flow against a
# pre-registered client is 12.5's measurement; if one demands DCR, the answer
# is a registration facade in front of this pool, not a loosening here.
#
# The client set is DISJOINT from the web SPA's client, and that disjointness
# is load-bearing: Cognito access tokens carry no `aud`, so "this token was
# issued for the MCP server" is verified as "this token names one of these
# client ids" (insolvia_core.auth.verify_access_token_for_clients). The MCP
# service's allowlist is derived from these resources — never hand-listed —
# via the mcp-client-ids contract parameter (contract.tf), so
# registering a harness here IS adding it to the allowlist.
#
# Callback URLs are each harness's PUBLISHED redirect endpoints, matched
# exactly by Cognito (no wildcards):
#   • Claude (claude.ai / Claude Desktop / Claude Code's --callback-port
#     flow lands on the same hosted endpoints): the documented
#     /api/mcp/auth_callback on both claude.ai and claude.com.
#   • The MCP inspector: its web UI's loopback callback (port 6274, plus the
#     /debug variant it also registers) and the CLI/TUI variant on 6276.
#     RFC 8252 §7.3 blesses loopback redirects for native tools; the client
#     is gated off prod by var.mcp_inspector_client because a debugging tool
#     has no business holding production-capable tokens.
#   • ChatGPT is deliberately ABSENT for now: OpenAI has moved to minting a
#     per-connector unique callback URL at connector-creation time, so its
#     registration cannot be written down before the connector exists —
#     recorded as a 12.5 measurement (mcp-surface.md § Constraints from
#     harnesses), not forgotten.
#
# Token posture, answering #261's lifetime question: the SAME as the SPA —
# 1 h access tokens, 30-day rotating refresh tokens, revocation on. The
# tempting "tighter for agents" buys nothing real: authorization is resolved
# from the firm store on EVERY tool call (never cached), so a disabled user
# or a stripped permission cuts an agent off within the hour-long access
# token exactly as it cuts off the app — and a shorter refresh token would
# only force attorneys through re-auth ceremonies without shortening that
# window. Rotation is the control that matters for a long-lived harness
# credential: a stolen refresh token dies the next time the harness
# refreshes.

locals {
  mcp_harness_clients = merge(
    {
      claude = {
        callback_urls = [
          "https://claude.ai/api/mcp/auth_callback",
          "https://claude.com/api/mcp/auth_callback",
        ]
      }
    },
    var.mcp_inspector_client ? {
      inspector = {
        callback_urls = [
          "http://localhost:6274/oauth/callback",
          "http://localhost:6274/oauth/callback/debug",
          "http://127.0.0.1:6276/oauth/callback",
        ]
      }
    } : {}
  )
}

resource "aws_cognito_user_pool_client" "mcp" {
  for_each = local.mcp_harness_clients

  # insolvia-<env>-mcp-<harness>: component `mcp`, matching the surface these
  # clients sign agents in to (mcp.insolvia.ai), harness as the identifier.
  name         = "${var.project}-${var.environment}-mcp-${each.key}"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = false # public clients, PKCE — same header argument as web

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = each.value.callback_urls
  # Harnesses have no sign-out surface to land on; Cognito requires nothing
  # here, and registering none keeps /logout unusable through these clients.

  # SRP only, exactly as the web client: sign-in happens on the hosted
  # domain, and nothing should ever ship a raw password through an MCP
  # client. (The dev-pool manual-token fallback in services/mcp/README.md
  # uses the DEV environment's own seeded client, not these.)
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
  ]

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  refresh_token_rotation {
    feature                    = "ENABLED"
    retry_grace_period_seconds = 30
  }
}
