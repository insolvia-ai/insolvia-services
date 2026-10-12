# Names kept from the insolvia root's mailer_* outputs, so the deploy
# workflows read the same keys they always did.

output "mailer_api_url" {
  description = "Production mailer API base URL (SigV4-authenticated)."
  value       = module.mailer.api_url
}

output "mailer_ecr_repository_url" {
  description = "ECR repository the mailer deploy workflow pushes images to (shared across environments)."
  value       = module.mailer.ecr_repository_url
}

output "mailer_lambda_function_names" {
  description = "Production mailer Lambda function names keyed by role (ingress/sender/feedback)."
  value       = module.mailer.lambda_function_names
}

output "mailer_content_bucket" {
  description = "Production mailer content bucket (request manifests, future attachments)."
  value       = module.mailer.content_bucket
}

output "mailer_messages_table" {
  description = "Production mailer messages DynamoDB table."
  value       = module.mailer.messages_table
}

output "mailer_suppressions_table" {
  description = "Production mailer suppressions DynamoDB table."
  value       = module.mailer.suppressions_table
}

output "mailer_service_registry_json" {
  description = "MAILER_SERVICE_REGISTRY_JSON — the insolvia_api tenant's config."
  value       = module.mailer.service_registry_json
}

output "mailer_api_status_queue_url" {
  description = "SQS queue insolvia_api's send-status events are published to."
  value       = module.mailer.api_status_queue_url
}

output "mailer_api_status_queue_arn" {
  description = "ARN of the above."
  value       = module.mailer.api_status_queue_arn
}

output "mailer_configuration_set" {
  description = "Production SES configuration set the mailer sends through."
  value       = module.mailer.configuration_set
}

output "mailer_alarms_topic_arn" {
  description = "SNS topic for Production mailer alarms — subscribe by hand (Terraform manages no subscriptions)."
  value       = module.mailer.alarms_topic_arn
}

# ── Auth ────────────────────────────────────────────────────────
# For humans and for this repo's own tooling — NOT for insolvia, which looks
# the same values from the SSM contract (modules/auth/contract.tf) and keeps auth_* outputs of
# the same names for its deploy workflows. The pool ARN is what ci-trust's
# staging seed role is scoped to (infra/envs/ci-trust/variables.tf).

output "auth_user_pool_id" {
  description = "Production Cognito user pool ID."
  value       = module.auth.user_pool_id
}

output "auth_user_pool_arn" {
  description = "Production Cognito user pool ARN."
  value       = module.auth.user_pool_arn
}

output "auth_web_client_id" {
  description = "Production web SPA app client ID (insolvia-<env>-app)."
  value       = module.auth.web_client_id
}

output "auth_portal_client_id" {
  description = "Production client portal app client ID (insolvia-<env>-portal)."
  value       = module.auth.portal_client_id
}

output "auth_domain" {
  description = "Production sign-in hostname — the custom domain where configured, otherwise the Cognito prefix domain."
  value       = module.auth.domain
}

output "auth_issuer_url" {
  description = "Production OIDC issuer URL tokens are verified against."
  value       = module.auth.issuer_url
}

output "auth_mcp_client_ids_by_harness" {
  description = "Production MCP harness app client IDs, keyed by harness."
  value       = module.auth.mcp_client_ids_by_harness
}
