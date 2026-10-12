# The contract: what consumers read, published to SSM.
#
# The insolvia repo reads THESE PARAMETERS — never this module's state, and
# never the pool by name. It is the pattern humbugg's dev-shared stack uses
# for the same job: a missing parameter fails the consumer's plan with its own
# name in the error, the most specific failure on offer.
#
# Inside the module, not the env root, ON PURPOSE: the insolvia repo's
# modules/auth created them first, at exactly these addresses
# (module.auth.aws_ssm_parameter.contract["<key>"]), before auth moved — so
# the state move carried them along with the pool and nothing was recreated.
# The keys and the shape of each value are an interface (insolvia ADR 0026);
# insolvia's modules/auth_contract is the reader.
#
#   /<project>/<env>/auth/user-pool-id      the pool's id (API calls)
#   /<project>/<env>/auth/user-pool-arn     the pool's ARN (IAM grants)
#   /<project>/<env>/auth/client-id         insolvia-<env>-app, the web SPA
#   /<project>/<env>/auth/portal-client-id  insolvia-<env>-portal
#   /<project>/<env>/auth/domain            sign-in hostname (custom if set)
#   /<project>/<env>/auth/issuer-url        what tokens are verified against
#   /<project>/<env>/auth/mcp-client-ids    JSON {harness: client id} — the
#                                           MCP service's allowlist

locals {
  domain = (
    var.custom_domain == null
    ? "${aws_cognito_user_pool_domain.main.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"
    : var.custom_domain
  )

  contract = {
    "user-pool-id"     = aws_cognito_user_pool.main.id
    "user-pool-arn"    = aws_cognito_user_pool.main.arn
    "client-id"        = aws_cognito_user_pool_client.web.id
    "portal-client-id" = aws_cognito_user_pool_client.portal.id
    "domain"           = local.domain
    "issuer-url"       = "https://cognito-idp.${data.aws_region.current.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
    "mcp-client-ids"   = jsonencode({ for harness, client in aws_cognito_user_pool_client.mcp : harness => client.id })
  }
}

resource "aws_ssm_parameter" "contract" {
  for_each = local.contract

  name  = "/${var.project}/${var.environment}/auth/${each.key}"
  type  = "String"
  value = each.value
  tags  = var.tags
}
