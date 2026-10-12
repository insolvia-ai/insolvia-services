variable "aws_region" {
  description = "Default AWS region."
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "Apex domain for Insolvia."
  type        = string
  default     = "insolvia.ai"
}

# Flat label, not nested: the account's one wildcard cert (*.insolvia.ai, owned
# by infra/envs/shared) covers exactly one label — dev-auth, like staging-auth.
variable "auth_subdomain" {
  description = "Custom hostname the shared development pool's managed login serves."
  type        = string
  default     = "dev-auth.insolvia.ai"
}
