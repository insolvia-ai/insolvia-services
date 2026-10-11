#!/usr/bin/env bash
#
# This machine's Cognito pool — the per-machine infra/envs/dev root.
#
#   scripts/dev-aws-auth.sh apply   [--profile NAME] [--yes]
#   scripts/dev-aws-auth.sh destroy [--profile NAME] [--yes]
#   scripts/dev-aws-auth.sh check   [--profile NAME]
#
# You normally do not run this yourself: the insolvia repo's
# scripts/dev-aws-setup.sh runs `apply` before its own root (whose name
# lookups need the pool to exist), and its dev-aws-destroy.sh runs `destroy`
# after its own. It is runnable alone for exactly one reason — working on
# infra/modules/auth here and wanting a real pool to try it on.
#
# IDENTITY is the insolvia repo's: the persistent UUID at
# ~/.config/insolvia/machine-id, first 12 hex characters as the environment
# suffix (dev-<short-id>). This script never creates that file — insolvia's
# dev-aws-setup.sh does, on its first run — because two scripts minting it
# would be two chances to disagree about which machine this is.
#
# STATE: s3://insolvia-shared-terraform-state-us-east-1/
#        insolvia-services/dev/<account-id>/<machine-id>/terraform.tfstate
#
# If this machine's pool still lives in insolvia's dev state (set up before
# auth moved, 2026-10-11), `apply` refuses: creating here would collide on the
# pool's globally unique domain prefix. Move it instead —
#   scripts/migrate-module-state.sh dev --module module.auth --insolvia-dir <insolvia> \
#     --keep aws_cognito_managed_login_branding.web --keep aws_cognito_managed_login_branding.portal \
#     --keep aws_iam_role_policy.api_invite --keep aws_iam_role_policy.admin_invite
# (docs/runbooks/auth-state-migration.md § Developer machines).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/infra/envs/dev"
BUCKET="insolvia-shared-terraform-state-us-east-1"
ID_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/insolvia/machine-id"

log()  { printf '\033[1;34m[dev-auth]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { die "Usage: $0 <apply|destroy|check> [--profile NAME] [--yes]"; }

ACTION="${1:-}"; shift || true
[[ "$ACTION" == apply || "$ACTION" == destroy || "$ACTION" == check ]] || usage
PROFILE="${AWS_PROFILE:-default}"
AUTO_APPROVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift ;;
    --yes) AUTO_APPROVE=1 ;;
    *) usage ;;
  esac
  shift
done
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

for c in aws jq terraform; do command -v "$c" >/dev/null || die "$c is not installed."; done

[[ -f "$ID_FILE" ]] || die "No machine id at $ID_FILE. Run the insolvia repo's ./scripts/dev-aws-setup.sh, which creates it."
MACHINE_ID="$(tr -d '[:space:]' < "$ID_FILE" | tr '[:upper:]' '[:lower:]')"
[[ "$MACHINE_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die "Invalid machine id in $ID_FILE."
MACHINE_SHORT_ID="$(printf '%s' "$MACHINE_ID" | tr -d '-' | cut -c1-12)"

# Terraform's SDK cannot read an `aws login` session; resolve it into plain
# short-lived env credentials first (the insolvia-aws-auth skill).
aws --profile "$PROFILE" --region "$REGION" sts get-caller-identity >/dev/null 2>&1 ||
  die "AWS profile '$PROFILE' has no valid session. Run: aws login --profile $PROFILE"
eval "$(aws configure export-credentials --profile "$PROFILE" --format env)"
export AWS_REGION="$REGION"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
PRINCIPAL="$(aws sts get-caller-identity --query Arn --output text)"
[[ "$ACCOUNT" == 521762924626 ]] || die "Account $ACCOUNT is not Insolvia's (521762924626) — see the insolvia-aws-auth skill."

KEY="insolvia-services/dev/$ACCOUNT/$MACHINE_ID/terraform.tfstate"
LEGACY_KEY="insolvia/dev/$ACCOUNT/$MACHINE_ID/terraform.tfstate"
POOL_NAME="insolvia-dev-$MACHINE_SHORT_ID-users"
TF_VARS=(
  "-var=aws_region=$REGION"
  "-var=aws_principal_arn=$PRINCIPAL"
  "-var=machine_id=$MACHINE_ID"
  "-var=machine_short_id=$MACHINE_SHORT_ID"
  "-var=machine_name=$(hostname -s 2>/dev/null || hostname)"
)

log "Machine $MACHINE_SHORT_ID — pool $POOL_NAME — state s3://$BUCKET/$KEY"

if [[ "$ACTION" == check ]]; then
  # Read the pool by name the way insolvia's dev root does: exactly one.
  ids="$(aws cognito-idp list-user-pools --max-results 60 --query "UserPools[?Name=='$POOL_NAME'].Id" --output text)"
  n="$(wc -w <<<"$ids" | tr -d ' ')"
  [[ "$n" == 1 ]] || die "Expected exactly one pool named $POOL_NAME, found $n. Run: $0 apply"
  ok "$POOL_NAME exists ($ids)."
  exit 0
fi

terraform -chdir="$TF_DIR" init -reconfigure -input=false -backend-config="key=$KEY" >/dev/null

if [[ "$ACTION" == apply ]]; then
  # The pre-move layout: insolvia's dev state still holds this machine's pool.
  if legacy="$(aws s3 cp "s3://$BUCKET/$LEGACY_KEY" - 2>/dev/null)" &&
    jq -e '[.resources[]? | select(.module == "module.auth" and .type == "aws_cognito_user_pool")] | length > 0' <<<"$legacy" >/dev/null; then
    die "This machine's pool is still in the insolvia repo's dev state ($LEGACY_KEY). Move it rather than creating a second one — see this script's header, or docs/runbooks/auth-state-migration.md § Developer machines."
  fi
  args=(apply -input=false "${TF_VARS[@]}")
  [[ $AUTO_APPROVE == 1 ]] && args+=(-auto-approve)
  terraform -chdir="$TF_DIR" "${args[@]}"
  ok "Pool ready: $(terraform -chdir="$TF_DIR" output -raw auth_user_pool_id) ($(terraform -chdir="$TF_DIR" output -raw auth_domain))"
else
  # Never destroy a pool this machine does not own.
  if terraform -chdir="$TF_DIR" state list >/dev/null 2>&1 && [[ -n "$(terraform -chdir="$TF_DIR" state list)" ]]; then
    owner="$(terraform -chdir="$TF_DIR" output -raw machine_id 2>/dev/null || true)"
    [[ "$owner" == "$MACHINE_ID" ]] || die "State at $KEY belongs to machine '$owner', not this one ($MACHINE_ID). Refusing."
  else
    ok "No auth state for this machine — nothing to destroy."
    exit 0
  fi
  args=(destroy -input=false "${TF_VARS[@]}")
  [[ $AUTO_APPROVE == 1 ]] && args+=(-auto-approve)
  terraform -chdir="$TF_DIR" "${args[@]}"
  ok "This machine's pool is gone."
fi
