#!/usr/bin/env bash
#
# ONE-OFF: move the live mailer's Terraform state out of the insolvia repo's
# env root (s3://…/insolvia/<env>/terraform.tfstate) into this repo's
# (s3://…/insolvia-services/<env>/terraform.tfstate), with every address
# unchanged (module.mailer.*). No AWS resource is created, changed or
# destroyed — only the two state files are rewritten.
#
#   scripts/migrate-mailer-state.sh staging --insolvia-dir ../insolvia
#   scripts/migrate-mailer-state.sh prod    --insolvia-dir ../insolvia
#
# --insolvia-dir is a checkout of the insolvia repo AT THE PR THAT REMOVES the
# mailer from its env roots — the plan this script runs there is the proof that
# insolvia's next apply will not touch the mailer. The procedure around this
# script (freezing insolvia's release pipeline first, the merge order after)
# is docs/runbooks/state-migration.md; read it before running this.
#
# WHY A SCRIPT A HUMAN RUNS, AND NOT A WORKFLOW. Everything else that writes
# staging/prod state here runs in CI. This does not, for three reasons that
# are specific to it: it needs BOTH repositories checked out at specific
# commits side by side; it has to run inside a window a human opens (insolvia's
# releases frozen) and closes (two merges, in order); and it runs exactly
# twice, ever. A workflow would also have to exist on `main` before it could
# be dispatched — i.e. after the import merge, whose first release would then
# hit the empty-state guard. It changes no resource, so it is in the same
# category as `terraform state` surgery always was: an admin operation, run
# with the admin's own credentials and a backup in hand.
#
# WHAT IT DOES
#   1. credentials (a human admin, never the deploy role) + preconditions:
#      this root's state is empty, insolvia's holds module.mailer, and the
#      insolvia checkout no longer declares module "mailer"
#   2. pulls both states into a private backup directory
#   3. `terraform state mv` between the two LOCAL copies, in a scratch dir
#   4. pushes both back
#   5. verifies: this root plans to NO changes, and insolvia's plan neither
#      touches the mailer nor destroys/replaces anything
#   6. on any verification failure: restores both from the backup and exits 1
#
# Backups land in ~/.local/state/insolvia/state-migration/<env>-<timestamp>/
# (mode 700). They are full state files — they hold resource attributes from
# BOTH roots — so they stay on this machine and are never committed or
# uploaded. The bucket is versioned as well; that is the second copy.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '\033[1;34m[migrate]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { die "Usage: $0 <staging|prod> --insolvia-dir <path to insolvia checkout>"; }

ENV="${1:-}"; shift || true
INSOLVIA_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --insolvia-dir) INSOLVIA_DIR="${2:-}"; shift ;;
    *) usage ;;
  esac
  shift
done
[[ "$ENV" == staging || "$ENV" == prod ]] || usage
[[ -n "$INSOLVIA_DIR" ]] || usage
INSOLVIA_DIR="$(cd "$INSOLVIA_DIR" && pwd)"

NEW_DIR="$REPO_ROOT/infra/envs/$ENV"
OLD_DIR="$INSOLVIA_DIR/infra/envs/$ENV"
[[ -d "$OLD_DIR" ]] || die "$OLD_DIR does not exist — is --insolvia-dir an insolvia checkout?"

command -v aws >/dev/null || die "aws CLI not installed."
command -v terraform >/dev/null || die "terraform not installed."
command -v jq >/dev/null || die "jq not installed."

# ── Credentials ────────────────────────────────────────────────────
# Same handling as scripts/apply-ci-trust.sh: Terraform's SDK cannot read the
# `aws login` session, so resolve it into env vars, clearing stale ones first.
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
caller="$(aws sts get-caller-identity --query Arn --output text)"
[[ "$account" == 521762924626 ]] || die "Account $account is not Insolvia's (521762924626) — see the insolvia-aws-auth skill."
case "$caller" in
  *:assumed-role/insolvia-shared-deploy-role/*)
    die "Run this as a human admin, not as the deploy role." ;;
esac
ok "Authenticated as $caller"

# ── Preconditions ──────────────────────────────────────────────────
if grep -qE '^module "mailer"' "$OLD_DIR"/*.tf; then
  die "$OLD_DIR still declares module \"mailer\". Check out the insolvia PR that removes it — otherwise insolvia's next apply would recreate the mailer this moves away."
fi

log "init both roots"
# Output kept on failure: under `set -e` a silent init failure ends the script
# with nothing on screen to say why.
init_root() {
  local out
  out="$(terraform -chdir="$1" init -input=false -no-color 2>&1)" || { printf '%s\n' "$out" >&2; die "init failed in $1"; }
}
init_root "$NEW_DIR"
init_root "$OLD_DIR"

# `state list` EXITS 1 on a root with no state yet ("No state file was
# found!") — which is exactly the state this root must be in. Under
# `set -o pipefail` that used to end the script right here, silently; so
# capture the listing on its own and only then count.
new_list="$(terraform -chdir="$NEW_DIR" state list 2>/dev/null || true)"
new_count="$(printf '%s' "$new_list" | grep -c . || true)"
[[ "$new_count" == 0 ]] || die "insolvia-services/$ENV state already holds $new_count resources — has this already run? Nothing changed."
old_list="$(terraform -chdir="$OLD_DIR" state list)" || die "could not list insolvia/$ENV state — nothing changed."
old_count="$(printf '%s\n' "$old_list" | grep -c '^module\.mailer\.' || true)"
[[ "$old_count" -gt 0 ]] || die "insolvia/$ENV state holds no module.mailer — nothing to move."
ok "insolvia/$ENV holds $old_count module.mailer resources; insolvia-services/$ENV is empty"

# ── Backup ─────────────────────────────────────────────────────────
BACKUP="$HOME/.local/state/insolvia/state-migration/$ENV-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP"; chmod 700 "$BACKUP"
WORK="$(mktemp -d)"; chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

terraform -chdir="$OLD_DIR" state pull > "$BACKUP/insolvia.tfstate"
ok "Backed up insolvia/$ENV state to $BACKUP/insolvia.tfstate"

restore() {
  warn "Restoring both states from $BACKUP"
  terraform -chdir="$OLD_DIR" state push -force "$BACKUP/insolvia.tfstate"
  aws s3 rm "s3://insolvia-shared-terraform-state-us-east-1/insolvia-services/$ENV/terraform.tfstate" >/dev/null
  warn "Restored: insolvia/$ENV is back to its pre-migration state; insolvia-services/$ENV is empty again."
}

echo
warn "About to move $old_count resources: insolvia/$ENV → insolvia-services/$ENV."
warn "insolvia's release pipeline must be DISABLED for this window (docs/runbooks/state-migration.md)."
read -r -p "Proceed? [y/N] " reply
[[ "$reply" == [yY] ]] || die "aborted — nothing changed"

# ── Move ───────────────────────────────────────────────────────────
# In a scratch directory with no configuration, so `-state`/`-state-out`
# address local files and no backend is involved.
cp "$BACKUP/insolvia.tfstate" "$WORK/old.tfstate"
(cd "$WORK" && terraform state mv -lock=false \
  -state=old.tfstate -state-out=new.tfstate \
  module.mailer module.mailer)

moved="$(jq '[.resources[] | select(.module // "" | startswith("module.mailer"))] | length' "$WORK/new.tfstate")"
left="$(jq '[.resources[] | select(.module // "" | startswith("module.mailer"))] | length' "$WORK/old.tfstate")"
[[ "$left" == 0 ]] || die "module.mailer still in the source copy after mv — nothing pushed."
ok "Moved $moved resource blocks locally"

terraform -chdir="$NEW_DIR" state push "$WORK/new.tfstate" || die "Pushing the new state failed — nothing else changed."
if ! terraform -chdir="$OLD_DIR" state push "$WORK/old.tfstate"; then
  aws s3 rm "s3://insolvia-shared-terraform-state-us-east-1/insolvia-services/$ENV/terraform.tfstate" >/dev/null
  die "Pushing insolvia's trimmed state failed; removed the new copy. insolvia/$ENV is untouched."
fi
ok "Pushed both states"

# ── Verify ─────────────────────────────────────────────────────────
# Resource changes, not the exit code: the moved state carries no root
# OUTPUTS (they belonged to insolvia's root), so the plan always proposes to
# add the mailer_* outputs and -detailed-exitcode would read that as a diff.
# Outputs are written by the first CI apply; they touch no resource.
log "plan insolvia-services/$ENV — must change no resource"
set +e
terraform -chdir="$NEW_DIR" plan -input=false -lock=false -out="$WORK/new.tfplan" >"$WORK/new-plan.txt" 2>&1
code=$?
set -e
if [[ $code != 0 ]]; then
  cat "$WORK/new-plan.txt" >&2
  restore
  die "insolvia-services/$ENV plan failed (exit $code) — restored."
fi
terraform -chdir="$NEW_DIR" show -json "$WORK/new.tfplan" > "$WORK/new-plan.json"
# A create, delete or replace means the move did not land the way it should
# (a resource missed, an address that does not line up) — always refused.
bad="$(jq -r '[.resource_changes[]?
  | select((.change.actions | index("create")) or (.change.actions | index("delete")))
  | "\(.change.actions | join("+"))  \(.address)"] | .[]' "$WORK/new-plan.json")"
if [[ -n "$bad" ]]; then
  printf '%s\n' "$bad" >&2
  restore
  die "insolvia-services/$ENV would create, destroy or replace resources after the move — restored."
fi
# IN-PLACE UPDATES are a different matter: they are code on insolvia's main
# that this environment has not applied yet. Prod lags main until a release is
# approved, so a prod move can legitimately see them (the first prod move did:
# #405's `client_invitation` category in the Lambdas' registry JSON, merged
# but never promoted). They would have applied on insolvia's next promotion;
# now they apply on this repo's. Shown, and kept only on a human's yes.
updates="$(jq -r '[.resource_changes[]? | select(.change.actions == ["update"])
  | "update  \(.address)"] | .[]' "$WORK/new-plan.json")"
if [[ -n "$updates" ]]; then
  warn "insolvia-services/$ENV plans IN-PLACE UPDATES after the move — no create, destroy or replace:"
  printf '%s\n' "$updates" | sed 's/^/    /' >&2
  warn "These are changes on insolvia's main that $ENV has not applied yet, not caused by the"
  warn "move. The full diff: terraform -chdir=$NEW_DIR show $WORK/new.tfplan (in another"
  warn "terminal, before answering). They apply on this repo's next $ENV release."
  read -r -p "Keep the move with these pending updates? [y/N] " reply
  if [[ "$reply" != [yY] ]]; then
    restore
    die "declined — restored."
  fi
  ok "insolvia-services/$ENV: only the in-place updates above (outputs are added by the first CI apply)"
else
  ok "insolvia-services/$ENV: no resource changes (outputs are added by the first CI apply)"
fi

log "plan insolvia/$ENV (the removal PR's code) — must not touch the mailer or destroy anything"
set +e
terraform -chdir="$OLD_DIR" plan -input=false -lock=false -out="$WORK/old.tfplan" >"$WORK/old-plan.txt" 2>&1
code=$?
set -e
if [[ $code != 0 ]]; then
  cat "$WORK/old-plan.txt" >&2
  restore
  die "insolvia/$ENV plan failed — restored."
fi
terraform -chdir="$OLD_DIR" show -json "$WORK/old.tfplan" > "$WORK/old-plan.json"
# What the move itself could break is the MAILER: insolvia's code no longer
# declares it, so any planned change to a mailer address is the move going
# wrong — always refused.
bad="$(jq -r '[.resource_changes[]?
  | select(.address | test("mailer"))
  | select(.change.actions != ["no-op"] and .change.actions != ["read"])
  | "\(.change.actions | join("+"))  \(.address)"] | .[]' "$WORK/old-plan.json")"
if [[ -n "$bad" ]]; then
  printf '%s\n' "$bad" >&2
  restore
  die "insolvia/$ENV would touch mailer resources — restored."
fi
# Everything ELSE in insolvia's plan is that environment lagging insolvia's
# main — prod had not been applied for six weeks when this first ran, and its
# plan replaced the Cognito managed-login branding (from #405). Those changes
# would apply on insolvia's next promotion with or without this move, so they
# are shown — destroys and replaces called out — and kept only on a human's yes.
other="$(jq -r '[.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])
  | "\(.change.actions | join("+"))  \(.address)"] | .[]' "$WORK/old-plan.json")"
if [[ -n "$other" ]]; then
  warn "insolvia/$ENV has OTHER pending changes — not the mailer, not caused by this move;"
  warn "commits on insolvia's main that $ENV has not applied yet:"
  printf '%s\n' "$other" | sed 's/^/    /' >&2
  if printf '%s\n' "$other" | grep -q 'delete'; then
    warn "Some of them DESTROY or REPLACE a resource (the lines with 'delete'). They"
    warn "will happen on insolvia's next $ENV release regardless of this move; read them."
  fi
  warn "Full diff: terraform -chdir=$OLD_DIR show $WORK/old.tfplan (another terminal)."
  read -r -p "Keep the move? [y/N] " reply
  if [[ "$reply" != [yY] ]]; then
    restore
    die "declined — restored."
  fi
fi
ok "insolvia/$ENV: no mailer change"

echo
ok "Migrated insolvia/$ENV → insolvia-services/$ENV. Backup kept at $BACKUP."
ok "Next: docs/runbooks/state-migration.md, the step after this one."
