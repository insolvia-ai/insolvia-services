variable "aws_region" {
  description = "Default AWS region."
  type        = string
  default     = "us-east-1"
}

variable "github_repo" {
  description = <<-EOT
    owner/name of the APP repo (insolvia), allowed to assume the deploy role.
    Must match the canonical case GitHub emits in the OIDC `sub` claim (the
    IAM condition is case-sensitive) — i.e. the org's exact login casing.
  EOT
  type        = string
  default     = "insolvia-ai/insolvia"
}

variable "github_immutable_sub_prefix" {
  description = <<-EOT
    The org enforces GitHub's IMMUTABLE OIDC subject claims, so the `sub` is
    built from numeric ids — `repo:<org>@<org_id>/<repo>@<repo_id>` — not the
    mutable `owner/name`. This is the immutable prefix (everything before the
    trailing `:<job-context>`), read from
    `gh api repos/<owner>/<repo>/actions/oidc/customization/sub .sub_claim_prefix`.

    It is pinned to the repo's numeric id ON PURPOSE (that is the security value
    of immutable subjects): if the repository is ever deleted and recreated it
    gets a NEW id and this must be updated, or `AssumeRoleWithWebIdentity` fails
    with "Not authorized". org_id=305033818, repo_id=1312821833.
  EOT
  type        = string
  default     = "repo:insolvia-ai@305033818/insolvia@1312821833"
}

variable "github_services_repo" {
  description = <<-EOT
    owner/name of THIS repo (insolvia-services), allowed to assume the deploy
    role alongside var.github_repo. Same case-sensitivity rule as that one.
  EOT
  type        = string
  default     = "insolvia-ai/insolvia-services"
}

variable "github_services_immutable_sub_prefix" {
  description = <<-EOT
    The immutable OIDC subject prefix for var.github_services_repo — the same
    construction as github_immutable_sub_prefix, read from
    `gh api repos/insolvia-ai/insolvia-services/actions/oidc/customization/sub .sub_claim_prefix`.
    org_id=305033818, repo_id=1414426760. Recreating the repository changes
    the id; update this and re-apply by hand, or CI here stops assuming the
    role ("Not authorized").
  EOT
  type        = string
  default     = "repo:insolvia-ai@305033818/insolvia-services@1414426760"
}
