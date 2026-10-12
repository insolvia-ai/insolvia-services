terraform {
  backend "s3" {
    bucket = "insolvia-shared-terraform-state-us-east-1"
    # The shared development pool's own key. NOT insolvia/dev/…: that prefix
    # holds the insolvia repo's per-machine roots (and its orphan sweeper
    # matches it).
    key     = "insolvia-services/dev/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true

    use_lockfile = true
  }
}
