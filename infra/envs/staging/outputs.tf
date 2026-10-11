# Names kept from the insolvia root's mailer_* outputs, so the deploy
# workflows read the same keys they always did.

output "mailer_api_url" {
  description = "Staging mailer API base URL (SigV4-authenticated)."
  value       = module.mailer.api_url
}

output "mailer_ecr_repository_url" {
  description = "ECR repository the mailer deploy workflow pushes images to (shared across environments)."
  value       = module.mailer.ecr_repository_url
}

output "mailer_lambda_function_names" {
  description = "Staging mailer Lambda function names keyed by role (ingress/sender/feedback)."
  value       = module.mailer.lambda_function_names
}

output "mailer_content_bucket" {
  description = "Staging mailer content bucket (request manifests, future attachments)."
  value       = module.mailer.content_bucket
}

output "mailer_messages_table" {
  description = "Staging mailer messages DynamoDB table."
  value       = module.mailer.messages_table
}

output "mailer_suppressions_table" {
  description = "Staging mailer suppressions DynamoDB table."
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
  description = "Staging SES configuration set the mailer sends through."
  value       = module.mailer.configuration_set
}

output "mailer_alarms_topic_arn" {
  description = "SNS topic for Staging mailer alarms — subscribe by hand (Terraform manages no subscriptions)."
  value       = module.mailer.alarms_topic_arn
}
