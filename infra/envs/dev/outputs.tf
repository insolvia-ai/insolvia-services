# scripts/dev-aws-auth.sh checks machine_id before it touches anything. The
# auth_* outputs are for humans: insolvia's dev root reads none of them — it
# looks the pool up by name, as its staging and prod roots do.

output "machine_id" {
  description = "Machine UUID this state belongs to — dev-aws-auth.sh refuses to act when it does not match the local machine-id file."
  value       = var.machine_id
}

output "environment" {
  description = "This machine's environment name (dev-<machine_short_id>)."
  value       = local.environment
}

output "auth_user_pool_id" {
  description = "This machine's Cognito user pool ID."
  value       = module.auth.user_pool_id
}

output "auth_domain" {
  description = "This machine's Cognito prefix hostname."
  value       = module.auth.domain
}
