variable "aws_region" {
  description = "AWS region for this machine's development resources."
  type        = string
  default     = "us-east-1"
}

variable "aws_principal_arn" {
  description = "Caller ARN recorded as the development resource owner (tag only)."
  type        = string
}

# The three machine variables come from the persistent per-machine UUID at
# ~/.config/insolvia/machine-id — the SAME file, and the same derivation, as
# the insolvia repo's scripts/dev-aws-common.sh. That shared identity is what
# makes this machine's pool insolvia-dev-<short-id>-users: the name insolvia's
# dev root looks up.

variable "machine_id" {
  description = "Persistent UUID generated for this OS user on this machine."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.machine_id))
    error_message = "machine_id must be a lowercase UUID."
  }
}

variable "machine_short_id" {
  description = "First 12 hexadecimal characters of machine_id, used in resource names."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-f]{12}$", var.machine_short_id))
    error_message = "machine_short_id must contain exactly 12 lowercase hexadecimal characters."
  }
}

variable "machine_name" {
  description = "Human-readable machine hostname, stored only as a resource tag."
  type        = string
}
