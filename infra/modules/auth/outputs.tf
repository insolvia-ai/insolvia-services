# These outputs are this ROOT's view, and what the env roots here republish
# as auth_* outputs (for humans, and for the ci-trust seed role's pool ARN).
# The insolvia repo does NOT read them — it reads the SSM contract
# (contract.tf), and keeps auth_* outputs of the same names for its own
# deploy workflows.

output "user_pool_id" {
  description = "Cognito user pool ID."
  value       = aws_cognito_user_pool.main.id
}

output "user_pool_arn" {
  description = "Cognito user pool ARN (for a future API Gateway/JWT authorizer)."
  value       = aws_cognito_user_pool.main.arn
}

output "web_client_id" {
  description = "App client ID for the web SPA (authorization-code + PKCE)."
  value       = aws_cognito_user_pool_client.web.id
}

# The client portal's app client (ADR 0023) — DISJOINT from web_client_id,
# and that disjointness is the audience check between the staff and client
# principal classes. insolvia publishes it as
# /insolvia/<env>/api/auth-portal-client-id (its deploy workflow derives
# AUTH_PORTAL_CLIENT_ID from it).
output "portal_client_id" {
  description = "App client ID for the client portal (authorization-code + PKCE, memory-only sessions)."
  value       = aws_cognito_user_pool_client.portal.id
}

# The one hostname consumers should ever use: insolvia's app builds its
# /oauth2 URLs from it and its E2E asserts the redirect landed on it (both
# through insolvia's own auth_domain output, which derives the same value).
#
# Prefers the custom domain where one exists, which is what makes the cutover a
# rebuild rather than a code change — the prefix domain keeps serving until the
# app's next deploy picks this up.
output "domain" {
  description = "Hostname serving /oauth2/authorize, /oauth2/token and the sign-in pages — the custom domain where configured, otherwise the Cognito prefix domain."
  value       = local.domain
}

# The prefix domain specifically, which keeps serving after a custom domain is
# added. Exposed so the cutover is observable — during it the two differ, and
# afterwards this is what you would remove.
output "prefix_domain" {
  description = "Cognito-provided prefix hostname. Always present; equals `domain` when no custom domain is configured."
  value       = "${aws_cognito_user_pool_domain.main.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"
}

# What insolvia's API and MCP service verify tokens against (its JWKS lives
# at <issuer>/.well-known/jwks.json).
output "issuer_url" {
  description = "OIDC issuer URL the API will validate access/ID tokens against."
  value       = "https://cognito-idp.${data.aws_region.current.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
}

# The MCP service's client-id allowlist (#261), derived from the registered
# harness clients so registering a harness IS adding it to the allowlist —
# insolvia publishes the same set (from the mcp-client-ids contract parameter) as
# /insolvia/<env>/mcp/auth-client-ids and its deploy workflow derives
# AUTH_CLIENT_IDS from it. A map too, for anything
# that needs to name one harness's client (the E2E, a directory listing).
output "mcp_client_ids" {
  description = "Comma-joinable list of MCP harness app client IDs — the MCP service's token allowlist."
  value       = [for client in aws_cognito_user_pool_client.mcp : client.id]
}

output "mcp_client_ids_by_harness" {
  description = "MCP harness app client IDs, keyed by harness (claude, inspector...)."
  value       = { for harness, client in aws_cognito_user_pool_client.mcp : harness => client.id }
}
