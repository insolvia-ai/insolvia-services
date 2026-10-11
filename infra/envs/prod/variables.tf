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
# by infra/envs/shared) covers exactly one label.
variable "mailer_subdomain" {
  description = "Hostname the mailer API serves in this environment."
  type        = string
  default     = "mailer-api.insolvia.ai"
}

# The app's host in this environment — the mailer's content bucket allows
# browser uploads from it (CORS), and the auth module registers it as the web
# and portal clients' redirect origin. It is the insolvia repo's web_hosting
# domain; this repo only names it, so changing it is a two-repo change.
variable "app_subdomain" {
  description = "Hostname of the Insolvia web app in this environment (CORS origin, OAuth redirect origin)."
  type        = string
  default     = "app.insolvia.ai"
}
