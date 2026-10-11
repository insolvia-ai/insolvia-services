#!/usr/bin/env bash
#
# ONE-OFF STATE SURGERY: move one module's resources out of an insolvia env
# root's Terraform state into the insolvia-services env root of the same
# environment, every address unchanged. No AWS resource is created, changed or
# destroyed — only state files are rewritten. Run by a human, from a runbook:
#
#   docs/runbooks/state-migration.md       — the mailer (2026-10-11, done)
#   docs/runbooks/auth-state-migration.md  — auth (Cognito)
#
#   scripts/migrate-module-state.sh <staging|prod|dev> --module <module.name> \
#     --insolvia-dir <path> [--keep <type.name>]... [--rehearse]
#
#   scripts/migrate-module-state.sh staging --module module.auth --insolvia-dir ../insolvia \
#     --keep aws_cognito_managed_login_branding.web --keep aws_cognito_managed_login_branding.portal \
#     --keep aws_iam_role_policy.api_invite --keep aws_iam_role_policy.admin_invite
#
# --module    the module address that moves (module.mailer, module.auth). It
#             must have the SAME address in both roots — that is what makes
#             this a move and not a destroy-and-create.
# --keep      a resource INSIDE the module that stays behind in insolvia's
#             state, at its unchanged address (type.name, no instance key;
#             repeatable). For a module that splits — auth leaves its
#             branding and its role grants with the consumer. Without --keep,
#             every managed resource in the module moves.
# --insolvia-dir
#             a checkout of the insolvia repo AT THE PR that stops declaring
#             what moves. The plan this script runs there is the proof that
#             insolvia's next apply will not touch it.
#
# --rehearse  READ-ONLY dry run of the whole thing: pull both states, move
#             between local copies, and plan BOTH roots against those copies
#             (a temporary *_override.tf points each root at a local
#             backend), applying every check below — then delete the copies
#             and the overrides. Nothing is pushed and no state is locked; no
#             prompt is asked (each question is printed instead). Run it
#             before the real thing, and for prod again right before prod.
#
# `dev` moves THIS MACHINE's per-machine roots (keys
# insolvia/dev/<account>/<machine-id>/… → insolvia-services/dev/<account>/<machine-id>/…),
# with the machine identity the insolvia repo's scripts/dev-aws-common.sh
# derives from ~/.config/insolvia/machine-id. Each developer runs it once, on
# their own machine.
#
# WHY A SCRIPT A HUMAN RUNS, AND NOT A WORKFLOW. Everything else that writes
# staging/prod state runs in CI. This does not: it needs BOTH repositories
# checked out at specific commits side by side; it runs inside a window a
# human opens (both release pipelines frozen) and closes (two merges, in
# order); and it runs a handful of times, ever. It changes no resource, so it
# is in the category `terraform state` surgery always was: an admin
# operation, with the admin's own credentials and a backup in hand.
#
# WHAT IT DOES
#   1. credentials (a human admin, never the deploy role) + preconditions:
#      insolvia's state holds the module; this root's state holds NONE of the
#      addresses that move (it may hold other things — the mailer, say)
#   2. pulls both states into a private backup directory
#   3. `terraform state mv` between LOCAL copies, in a scratch dir
#   4. pushes both back
#   5. verifies with two plans:
#        • this root: no create, destroy or replace ANYWHERE; in-place updates
#          are shown and kept only on a human's yes
#        • insolvia: NO change at all to any address under the module — moved
#          or kept, including a `removed`-block "forget"; anything else
#          pending there is shown and kept only on a human's yes
#   6. on any verification failure or a "no": restores both states from the
#      backup and exits 1
#
# Backups land in ~/.local/state/insolvia/state-migration/<env>-<module>-<timestamp>/
# (mode 700). They are full state files holding resource attributes from BOTH
# roots, so they stay on this machine and are never committed or uploaded. The
# bucket is versioned as well; that is the second copy.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUCKET="insolvia-shared-terraform-state-us-east-1"

log()  { printf '\033[1;34m[migrate]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { die "Usage: $0 <staging|prod|dev> --module <module.name> --insolvia-dir <path> [--keep <type.name>]... [--rehearse]"; }

ENV="${1:-}"; shift || true
INSOLVIA_DIR=""
MODULE=""
KEEP=()
REHEARSE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --insolvia-dir) INSOLVIA_DIR="${2:-}"; shift ;;
    --module) MODULE="${2:-}"; shift ;;
    --keep) KEEP+=("${2:-}"); shift ;;
    --rehearse) REHEARSE=1 ;;
    *) usage ;;
  esac
  shift
done
[[ "$ENV" == staging || "$ENV" == prod || "$ENV" == dev ]] || usage
[[ -n "$INSOLVIA_DIR" ]] || usage
# A root-level module call only: module.<name>. Nested addresses and
# resources outside a module are not what this was written or tested for.
[[ "$MODULE" =~ ^module\.[a-z0-9_]+$ ]] || die "--module must look like module.<name> (got '${MODULE}')."
for k in ${KEEP[@]+"${KEEP[@]}"}; do
  [[ "$k" =~ ^[a-z0-9_]+\.[a-z0-9_]+$ ]] || die "--keep takes <type>.<name> with no module prefix or instance key (got '$k')."
done
INSOLVIA_DIR="$(cd "$INSOLVIA_DIR" && pwd)"
MODULE_NAME="${MODULE#module.}"

NEW_DIR="$REPO_ROOT/infra/envs/$ENV"
OLD_DIR="$INSOLVIA_DIR/infra/envs/$ENV"
[[ -d "$OLD_DIR" ]] || die "$OLD_DIR does not exist — is --insolvia-dir an insolvia checkout?"
[[ -d "$NEW_DIR" ]] || die "$NEW_DIR does not exist — is this checkout at the PR that adds $MODULE here?"

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

# ── Where each state lives ─────────────────────────────────────────
# staging/prod: the keys are in each root's backend.tf. dev: neither root
# carries a key — both are per machine and injected at init — so derive them,
# and the variables a dev plan needs, from the machine identity exactly as
# insolvia's scripts/dev-aws-common.sh does.
OLD_INIT=(); NEW_INIT=(); PLAN_VARS=()
if [[ "$ENV" == dev ]]; then
  id_file="${XDG_CONFIG_HOME:-$HOME/.config}/insolvia/machine-id"
  [[ -f "$id_file" ]] || die "No machine id at $id_file — this machine has no dev environment to move."
  machine_id="$(tr -d '[:space:]' < "$id_file" | tr '[:upper:]' '[:lower:]')"
  [[ "$machine_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die "Invalid machine id in $id_file."
  machine_short_id="$(printf '%s' "$machine_id" | tr -d '-' | cut -c1-12)"
  OLD_KEY="insolvia/dev/$account/$machine_id/terraform.tfstate"
  NEW_KEY="insolvia-services/dev/$account/$machine_id/terraform.tfstate"
  OLD_INIT=(-reconfigure "-backend-config=key=$OLD_KEY")
  NEW_INIT=(-reconfigure "-backend-config=key=$NEW_KEY")
  PLAN_VARS=(
    "-var=aws_region=${AWS_REGION:-us-east-1}"
    "-var=aws_principal_arn=$caller"
    "-var=machine_id=$machine_id"
    "-var=machine_short_id=$machine_short_id"
    "-var=machine_name=$(hostname -s 2>/dev/null || hostname)"
  )
  log "Machine $machine_short_id: $OLD_KEY → $NEW_KEY"
else
  NEW_KEY="insolvia-services/$ENV/terraform.tfstate"
  grep -q "key *= *\"$NEW_KEY\"" "$NEW_DIR/backend.tf" || die "$NEW_DIR/backend.tf does not use key $NEW_KEY — refusing to guess where the state goes."
fi

# ── Preconditions ──────────────────────────────────────────────────
# Without --keep, the whole module leaves insolvia, so its code must no longer
# declare it — otherwise insolvia's next apply would recreate what moved. With
# --keep the call stays (the consumer half), and the source plan below is what
# proves the moved addresses are no longer declared.
if [[ ${#KEEP[@]} -eq 0 ]] && grep -qE "^module \"$MODULE_NAME\"" "$OLD_DIR"/*.tf; then
  die "$OLD_DIR still declares module \"$MODULE_NAME\". Check out the insolvia PR that removes it."
fi

log "init both roots"
# Output kept on failure: under `set -e` a silent init failure ends the script
# with nothing on screen to say why.
init_root() {
  local dir="$1" out; shift
  out="$(terraform -chdir="$dir" init -input=false -no-color "$@" 2>&1)" || { printf '%s\n' "$out" >&2; die "init failed in $dir"; }
}
init_root "$NEW_DIR" ${NEW_INIT[@]+"${NEW_INIT[@]}"}
init_root "$OLD_DIR" ${OLD_INIT[@]+"${OLD_INIT[@]}"}

# The managed resources, as resource-level addresses (no instance keys, so a
# for_each or count moves as one), under $MODULE in a state file, minus --keep.
to_move() {
  jq -r --arg m "$MODULE" '.resources[]? | select(.mode == "managed" and .module == $m)
    | "\(.type).\(.name)"' "$1" | sort -u | while read -r r; do
    local kept=0
    for k in ${KEEP[@]+"${KEEP[@]}"}; do [[ "$r" == "$k" ]] && kept=1; done
    [[ $kept == 1 ]] || printf '%s.%s\n' "$MODULE" "$r"
  done
}

WORK="$(mktemp -d)"; chmod 700 "$WORK"
OVERRIDE="migrate_rehearsal_override.tf"
cleanup() {
  # A rehearsal leaves both roots pointed at a local backend; put them back,
  # or the next command in either root would read the deleted copies.
  if [[ -f "$NEW_DIR/$OVERRIDE" || -f "$OLD_DIR/$OVERRIDE" ]]; then
    rm -f "$NEW_DIR/$OVERRIDE" "$OLD_DIR/$OVERRIDE"
    terraform -chdir="$NEW_DIR" init -reconfigure -input=false ${NEW_INIT[@]+"${NEW_INIT[@]}"} >/dev/null 2>&1 || warn "re-init of $NEW_DIR failed; run terraform init -reconfigure there."
    terraform -chdir="$OLD_DIR" init -reconfigure -input=false ${OLD_INIT[@]+"${OLD_INIT[@]}"} >/dev/null 2>&1 || warn "re-init of $OLD_DIR failed; run terraform init -reconfigure there."
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
if [[ $REHEARSE == 1 ]]; then
  # Copies live only in the scratch dir, deleted on exit.
  BACKUP="$WORK/pulled"
  warn "REHEARSAL — read-only. Nothing will be pushed; the copies are deleted on exit."
else
  BACKUP="$HOME/.local/state/insolvia/state-migration/$ENV-$MODULE_NAME-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$BACKUP"; chmod 700 "$BACKUP"

terraform -chdir="$OLD_DIR" state pull > "$BACKUP/insolvia.tfstate"
[[ -s "$BACKUP/insolvia.tfstate" ]] || die "insolvia/$ENV has no state — nothing to move."
# An "empty destination" — no state object at the key yet — is the case the
# mailer's first move and every developer machine's dev move start from.
# Decided by the OBJECT, not by what `state pull` prints: depending on the
# Terraform version that is nothing, or an empty state with a fresh lineage
# that was never written anywhere. Recorded so the restore knows whether to
# push the old state back or delete the key.
NEW_WAS_EMPTY=0
aws s3api head-object --bucket "$BUCKET" --key "$NEW_KEY" >/dev/null 2>&1 || NEW_WAS_EMPTY=1
if [[ $NEW_WAS_EMPTY == 1 ]]; then
  : > "$BACKUP/insolvia-services.tfstate"
else
  terraform -chdir="$NEW_DIR" state pull > "$BACKUP/insolvia-services.tfstate" || die "could not read insolvia-services/$ENV state — nothing changed."
  [[ -s "$BACKUP/insolvia-services.tfstate" ]] || die "s3://$BUCKET/$NEW_KEY exists but state pull returned nothing — refusing to guess. Nothing changed."
fi
ok "Pulled both states into $BACKUP"

moving="$(to_move "$BACKUP/insolvia.tfstate")"
[[ -n "$moving" ]] || die "insolvia/$ENV state holds nothing under $MODULE to move (after --keep) — nothing changed."
if [[ $NEW_WAS_EMPTY == 0 ]]; then
  clash="$(jq -r --arg m "$MODULE" '.resources[]? | select(.module == $m) | "\(.module).\(.type).\(.name)"' "$BACKUP/insolvia-services.tfstate" | sort -u)"
  [[ -z "$clash" ]] || { printf '%s\n' "$clash" >&2; die "insolvia-services/$ENV already holds resources under $MODULE — has this already run? Nothing changed."; }
fi
instances="$(jq --arg m "$MODULE" '[.resources[]? | select(.mode == "managed" and .module == $m) | .instances[]] | length' "$BACKUP/insolvia.tfstate")"

echo
log "Moving insolvia/$ENV → insolvia-services/$ENV:"
printf '%s\n' "$moving" | sed 's/^/    /'
for k in ${KEEP[@]+"${KEEP[@]}"}; do printf '    (stays in insolvia: %s.%s)\n' "$MODULE" "$k"; done
if [[ $NEW_WAS_EMPTY == 1 ]]; then
  log "insolvia-services/$ENV has no state yet; it will be created."
else
  log "insolvia-services/$ENV already holds $(jq '[.resources[]? | select(.mode == "managed")] | length' "$BACKUP/insolvia-services.tfstate") resource blocks; they are not touched."
fi
if [[ $REHEARSE == 0 ]]; then
  warn "Both repositories' release pipelines must be DISABLED for this window (see the runbook)."
  read -r -p "Proceed? [y/N] " reply
  [[ "$reply" == [yY] ]] || die "aborted — nothing changed"
fi

restore() {
  warn "Restoring both states from $BACKUP"
  terraform -chdir="$OLD_DIR" state push -force "$BACKUP/insolvia.tfstate"
  if [[ $NEW_WAS_EMPTY == 1 ]]; then
    aws s3 rm "s3://$BUCKET/$NEW_KEY" >/dev/null
  else
    terraform -chdir="$NEW_DIR" state push -force "$BACKUP/insolvia-services.tfstate"
  fi
  warn "Restored: both states are back to what they were before this run."
}

# A failed check: the real run restores both states and stops; a rehearsal
# records it and carries on, so one run reports every problem.
FAILED=0
fail() {
  if [[ $REHEARSE == 1 ]]; then
    warn "REHEARSAL: the real run would RESTORE and stop here — $*"
    FAILED=1
  else
    restore
    die "$* — restored."
  fi
}
# A question for the human. In a rehearsal it is printed, not asked.
ask() {
  if [[ $REHEARSE == 1 ]]; then
    warn "REHEARSAL: the real run would ask: $1"
    return 0
  fi
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" == [yY] ]]
}

# ── Move ───────────────────────────────────────────────────────────
# In a scratch directory with no configuration, so `-state`/`-state-out`
# address local files and no backend is involved. Moving into a copy of the
# destination keeps its lineage and bumps its serial, so the push below is an
# ordinary one.
cp "$BACKUP/insolvia.tfstate" "$WORK/old.tfstate"
[[ $NEW_WAS_EMPTY == 1 ]] || cp "$BACKUP/insolvia-services.tfstate" "$WORK/new.tfstate"
while read -r addr; do
  (cd "$WORK" && terraform state mv -lock=false \
    -state=old.tfstate -state-out=new.tfstate "$addr" "$addr" >/dev/null)
done <<<"$moving"

left="$(to_move "$WORK/old.tfstate")"
[[ -z "$left" ]] || die "Still in the source copy after mv: $left — nothing pushed."
landed="$(jq --arg m "$MODULE" '[.resources[]? | select(.mode == "managed" and .module == $m) | .instances[]] | length' "$WORK/new.tfstate")"
kept_n="$(jq --arg m "$MODULE" '[.resources[]? | select(.mode == "managed" and .module == $m) | .instances[]] | length' "$WORK/old.tfstate")"
[[ $((landed + kept_n)) == "$instances" ]] || die "Instance count does not add up ($landed moved + $kept_n kept != $instances) — nothing pushed."
ok "Moved $landed instances locally ($kept_n kept in insolvia)"

if [[ $REHEARSE == 1 ]]; then
  # Point each root at its local copy instead of pushing. -reconfigure never
  # copies state between backends, in either direction.
  [[ -f "$WORK/new.tfstate" ]] || die "no destination copy was written — nothing to plan."
  printf 'terraform {\n  backend "local" {\n    path = "%s"\n  }\n}\n' "$WORK/new.tfstate" > "$NEW_DIR/$OVERRIDE"
  printf 'terraform {\n  backend "local" {\n    path = "%s"\n  }\n}\n' "$WORK/old.tfstate" > "$OLD_DIR/$OVERRIDE"
  init_root "$NEW_DIR" -reconfigure
  init_root "$OLD_DIR" -reconfigure
  ok "Both roots now plan against the local copies"
else
  terraform -chdir="$NEW_DIR" state push "$WORK/new.tfstate" || die "Pushing the new state failed — nothing else changed."
  if ! terraform -chdir="$OLD_DIR" state push "$WORK/old.tfstate"; then
    if [[ $NEW_WAS_EMPTY == 1 ]]; then
      aws s3 rm "s3://$BUCKET/$NEW_KEY" >/dev/null
    else
      terraform -chdir="$NEW_DIR" state push -force "$BACKUP/insolvia-services.tfstate"
    fi
    die "Pushing insolvia's trimmed state failed; put insolvia-services/$ENV back. insolvia/$ENV is untouched."
  fi
  ok "Pushed both states"
fi

# ── Verify ─────────────────────────────────────────────────────────
# Resource changes, not the exit code: a move can leave this root's OUTPUTS
# to be written (they belonged to insolvia's root), so -detailed-exitcode
# would read that as a diff. Outputs are written by the first CI apply.
log "plan insolvia-services/$ENV — must create, destroy and replace nothing"
set +e
terraform -chdir="$NEW_DIR" plan -input=false -lock=false -no-color ${PLAN_VARS[@]+"${PLAN_VARS[@]}"} -out="$WORK/new.tfplan" >"$WORK/new-plan.txt" 2>&1
code=$?
set -e
if [[ $code != 0 ]]; then
  cat "$WORK/new-plan.txt" >&2
  fail "insolvia-services/$ENV plan failed (exit $code)"
  echo '{}' > "$WORK/new-plan.json"
else
  terraform -chdir="$NEW_DIR" show -json "$WORK/new.tfplan" > "$WORK/new-plan.json"
fi
# A create, delete or replace means the move did not land the way it should
# (a resource missed, an address that does not line up, an input that differs
# between the two roots) — always refused. For auth this is the line that
# matters most: a replaced pool is every account gone and every subject
# insolvia keys a row on orphaned; a replaced client is a new id every
# consumer verifies against. No human yes overrides it.
bad="$(jq -r '[.resource_changes[]?
  | select((.change.actions | index("create")) or (.change.actions | index("delete")) or (.change.actions | index("forget")))
  | "\(.change.actions | join("+"))  \(.address)"] | .[]' "$WORK/new-plan.json")"
if [[ -n "$bad" ]]; then
  printf '%s\n' "$bad" >&2
  fail "insolvia-services/$ENV would create, destroy or replace resources after the move"
fi
# IN-PLACE UPDATES are code on insolvia's main that this environment has not
# applied yet (prod lags main until a release is approved). They would have
# applied on insolvia's next promotion; now they apply on this repo's. Shown,
# and kept only on a human's yes.
updates="$(jq -r '[.resource_changes[]? | select(.change.actions == ["update"])
  | "update  \(.address)"] | .[]' "$WORK/new-plan.json")"
if [[ -n "$updates" ]]; then
  warn "insolvia-services/$ENV plans IN-PLACE UPDATES after the move — no create, destroy or replace:"
  printf '%s\n' "$updates" | sed 's/^/    /' >&2
  warn "These are changes on insolvia's main that $ENV has not applied yet, not caused by the"
  warn "move. The full diff: terraform -chdir=$NEW_DIR show $WORK/new.tfplan (in another"
  warn "terminal, before answering). They apply on this repo's next $ENV release."
  ask "Keep the move with these pending updates?" || fail "declined"
  ok "insolvia-services/$ENV: only the in-place updates above"
elif [[ -z "$bad" && $code == 0 ]]; then
  ok "insolvia-services/$ENV: no resource changes"
fi

log "plan insolvia/$ENV (the PR's code) — must not touch anything under $MODULE"
set +e
terraform -chdir="$OLD_DIR" plan -input=false -lock=false -no-color ${PLAN_VARS[@]+"${PLAN_VARS[@]}"} -out="$WORK/old.tfplan" >"$WORK/old-plan.txt" 2>&1
code=$?
set -e
if [[ $code != 0 ]]; then
  cat "$WORK/old-plan.txt" >&2
  fail "insolvia/$ENV plan failed (exit $code)"
  echo '{}' > "$WORK/old-plan.json"
else
  terraform -chdir="$OLD_DIR" show -json "$WORK/old.tfplan" > "$WORK/old-plan.json"
fi
# What the move itself could break is the MODULE: any planned change to an
# address under it — a moved one (insolvia's code no longer declares it; a
# `removed` block would show "forget"), or a kept one (whose inputs should be
# the same values, now found by name) — is the move going wrong. Always
# refused.
bad="$(jq -r --arg p "$MODULE." '[.resource_changes[]?
  | select(.address | startswith($p))
  | select(.change.actions != ["no-op"] and .change.actions != ["read"])
  | "\(.change.actions | join("+"))  \(.address)"] | .[]' "$WORK/old-plan.json")"
if [[ -n "$bad" ]]; then
  printf '%s\n' "$bad" >&2
  fail "insolvia/$ENV would change resources under $MODULE. If they are a kept resource's pending change from main (prod lagging), release that first and run this again"
fi
# Everything ELSE in insolvia's plan is that environment lagging insolvia's
# main. Those changes would apply on insolvia's next release with or without
# this move, so they are shown — destroys and replaces called out — and kept
# only on a human's yes.
other="$(jq -r '[.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])
  | "\(.change.actions | join("+"))  \(.address)"] | .[]' "$WORK/old-plan.json")"
if [[ -n "$other" ]]; then
  warn "insolvia/$ENV has OTHER pending changes — not under $MODULE, not caused by this move;"
  warn "commits on insolvia's main that $ENV has not applied yet:"
  printf '%s\n' "$other" | sed 's/^/    /' >&2
  if printf '%s\n' "$other" | grep -q 'delete'; then
    warn "Some of them DESTROY or REPLACE a resource (the lines with 'delete'). They"
    warn "will happen on insolvia's next $ENV release regardless of this move; read them."
  fi
  warn "Full diff: terraform -chdir=$OLD_DIR show $WORK/old.tfplan (another terminal)."
  ask "Keep the move?" || fail "declined"
fi
[[ -n "$bad" || $code != 0 ]] || ok "insolvia/$ENV: nothing under $MODULE changes"

echo
if [[ $REHEARSE == 1 ]]; then
  # The two plans, kept as text for the record (they hold no state, only the
  # change summary and resource attributes a plan prints).
  for side in new old; do
    printf '\n── %s plan summary ──\n' "$([[ $side == new ]] && echo "insolvia-services/$ENV" || echo "insolvia/$ENV")"
    grep -E '^(Plan:|No changes\.|Changes to Outputs:|  [+~-] [a-z_]+ +=|  # .* (will|must) be )' "$WORK/$side-plan.txt" || true
  done
  echo
  [[ $FAILED == 0 ]] || die "REHEARSAL FAILED — the real run would have restored both states. Nothing was pushed."
  ok "REHEARSAL PASSED for $MODULE ($ENV): the real run would keep the move. Nothing was pushed; the copies are deleted."
else
  ok "Migrated $MODULE: insolvia/$ENV → insolvia-services/$ENV. Backup kept at $BACKUP."
  ok "Next: the runbook's step after this one."
fi
