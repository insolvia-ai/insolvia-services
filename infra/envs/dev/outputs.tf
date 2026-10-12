# For humans. The insolvia repo reads the SSM contract
# (/insolvia/dev/auth/*, modules/auth/contract.tf), never these.

output "auth_user_pool_id" {
  description = "The shared development Cognito user pool ID."
  value       = module.auth.user_pool_id
}

output "auth_domain" {
  description = "The shared development pool's sign-in hostname."
  value       = module.auth.domain
}

output "auth_mcp_client_ids_by_harness" {
  description = "MCP harness app client IDs on the shared development pool, keyed by harness."
  value       = module.auth.mcp_client_ids_by_harness
}
