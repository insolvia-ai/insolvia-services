terraform {
  backend "s3" {
    bucket = "insolvia-shared-terraform-state-us-east-1"
    # Its own key, NOT insolvia/prod/terraform.tfstate. That key belongs to the
    # insolvia repo's prod root (the app's stacks). The mailer's resources were
    # moved out of it into this one by docs/runbooks/state-migration.md, with
    # their addresses unchanged (module.mailer.*), so nothing was recreated.
    key     = "insolvia-services/prod/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true

    # Native S3 state locking (Terraform >= 1.10), same as every other root.
    use_lockfile = true
  }
}
