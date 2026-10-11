# Same state bucket as every other root, but NO `key` here: each developer
# machine owns its own state, injected at init time by scripts/dev-aws-auth.sh —
#
#   -backend-config="key=insolvia-services/dev/<account-id>/<machine-id>/terraform.tfstate"
#
# Under this repo's insolvia-services/ namespace, never insolvia/dev/…: that
# prefix is the insolvia repo's per-machine roots (and its orphan sweeper
# matches it). CI's offline `terraform init -backend=false` never needs the key.
terraform {
  backend "s3" {
    bucket  = "insolvia-shared-terraform-state-us-east-1"
    region  = "us-east-1"
    encrypt = true

    use_lockfile = true
  }
}
