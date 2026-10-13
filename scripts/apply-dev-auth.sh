#!/usr/bin/env bash
#
# Apply infra/envs/dev — the SHARED development Cognito pool every developer
# machine signs in against (insolvia ADR 0026).
#
# HUMAN-APPLIED, like ci-trust and account-access, but for a different reason:
# not privilege, just proportion. The pool's configuration changes about as
# often as staging's callback URLs do — almost never — and a CI leg would be a
# workflow, a job and a required check to apply it. Run this when
# infra/envs/dev or modules/auth changes in a way dev should see, after the
# change has merged. (humbugg applies its shared dev pool from developer
# machines for the same reason.)
#
# Developers who only work on the insolvia app never run this: their machine's
# insolvia/infra/envs/dev READS the pool through SSM (/insolvia/dev/auth/*).
# If the pool has never been applied, that plan fails naming the missing
# parameter — which is the signal to run this once.
#
# What it does: credential hygiene → init → plan → refuse a destroy or replace
# of the pool or a client → show you the plan → apply after you confirm.
#
#   scripts/apply-dev-auth.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/infra/envs/dev"

log()  { printf '\033[1;34m[dev-auth]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null || die "aws CLI not installed."
command -v terraform >/dev/null || die "terraform not installed."
command -v jq >/dev/null || die "jq not installed."

# ── Credentials ────────────────────────────────────────────────────
# Same handling as scripts/apply-ci-trust.sh (the insolvia-aws-auth skill).
log "Checking AWS session"
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
    warn "Ignoring stale AWS_* environment credentials; using the profile instead."
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
  fi
  aws sts get-caller-identity >/dev/null 2>&1 || die "AWS session is expired or absent. Run 'aws login' and try again."
fi
eval "$(aws configure export-credentials --format env)"
account="$(aws sts get-caller-identity --query Account --output text)"
[[ "$account" == 521762924626 ]] || die "Account $account is not Insolvia's (521762924626) — see the insolvia-aws-auth skill."
ok "Authenticated as $(aws sts get-caller-identity --query Arn --output text)"

# ── Plan ───────────────────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log "init + plan  ($TF_DIR)"
terraform -chdir="$TF_DIR" init -input=false >/dev/null
terraform -chdir="$TF_DIR" plan -input=false -out="$WORK/dev.tfplan"

# The pool holds every developer's seeded identities, and every machine's firm
# rows are keyed on their subjects; a new client is a new id in every
# machine's configuration. Same rule as the staging/prod workflows: a destroy
# or replace of either is refused here, not left to a skim of the plan.
hits="$(terraform -chdir="$TF_DIR" show -json "$WORK/dev.tfplan" | jq -r '
  [.resource_changes[]?
   | select(.type == "aws_cognito_user_pool" or .type == "aws_cognito_user_pool_client")
   | select(.change.actions | index("delete"))
   | "\(.change.actions | join("+"))  \(.address)"] | .[]')"
if [[ -n "$hits" ]]; then
  printf '%s\n' "$hits" >&2
  die "This plan destroys or replaces a user pool or app client. Not applied. If that is genuinely intended, apply it by hand with terraform, deliberately."
fi

echo
warn "Review the plan above. A first apply in a fresh account creates"
warn "insolvia-dev-users, its prefix domain, dev-auth.insolvia.ai (15-20 minutes:"
warn "Cognito provisions CloudFront), its clients, their sign-in page styles and"
warn "the /insolvia/dev/auth/* parameters. After that, expect in-place updates only."
read -r -p "Apply this plan? [y/N] " reply
[[ "$reply" == [yY] ]] || die "aborted — nothing applied"

# ── Apply ──────────────────────────────────────────────────────────
terraform -chdir="$TF_DIR" apply -input=false "$WORK/dev.tfplan"
ok "Shared dev pool applied: $(terraform -chdir="$TF_DIR" output -raw auth_user_pool_id) ($(terraform -chdir="$TF_DIR" output -raw auth_domain))."
