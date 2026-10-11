#!/usr/bin/env bash
#
# Add or remove a required status check on the `protect-main` ruleset.
#
#   scripts/update-ruleset.sh show
#   scripts/update-ruleset.sh add "Terraform validate (shared)"
#   scripts/update-ruleset.sh remove "Terraform validate (shared)"
#
# There is no `gh ruleset edit` (the CLI is read-only), so this goes through
# `gh api`. It reads the whole ruleset, edits it, and PUTs the whole thing back
# — because PUT /repos/{owner}/{repo}/rulesets/{id} REPLACES the arrays you
# send. A payload carrying only the new check deletes every other rule on
# `main`, and the REST docs don't warn you.
#
# The check name must match the workflow job's `name:` exactly; a typo is
# accepted and then parks every PR on "waiting for status to be reported".
# The insolvia-branch-protection skill (.claude/skills/) lists the valid names.
#
# WHICH REPOSITORY. This script exists in both the insolvia repo and this one,
# and each has its own `protect-main`. The default is THIS repo,
# insolvia-ai/insolvia-services, hard-coded rather than read from
# `gh repo view`: that resolves through the checkout's git remote, and a
# checkout whose remote points somewhere else (a fork, a mirror, a copy with
# no remote yet) would silently edit the wrong ruleset. Override with
# INSOLVIA_REPO=owner/name.
#
set -euo pipefail

REPO="${INSOLVIA_REPO:-insolvia-ai/insolvia-services}"
RULESET="protect-main"

die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }

command -v gh >/dev/null || die "gh CLI not installed."
command -v jq >/dev/null || die "jq not installed."

action="${1:-show}"
context="${2:-}"

# By name, never a hard-coded id: a ruleset recreated in the UI comes back with
# a new one (which is why 18947945 appears in older notes and 404s today).
id="$(gh api "/repos/$REPO/rulesets" --jq "map(select(.name == \"$RULESET\")) | .[0].id // empty")"
[[ -n "$id" ]] || die "No ruleset named '$RULESET' on $REPO."

checks() {
  gh api "/repos/$REPO/rulesets/$id" \
    --jq '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context'
}

case "$action" in
  show)
    echo "$RULESET (id $id) on $REPO — required checks:"
    checks | sed 's/^/  /'
    exit 0 ;;
  add|remove) [[ -n "$context" ]] || die "Usage: $0 $action \"<check name>\"" ;;
  *) die "Usage: $0 [show|add|remove] [\"<check name>\"]" ;;
esac

# The two `edit` programs are jq, not shell: `$i` and `$c` are jq variables
# and must reach jq unexpanded, hence single quotes.
if [[ "$action" == add ]]; then
  # shellcheck disable=SC2016
  edit='(.rules | map(.type) | index("required_status_checks")) as $i
        | if $i == null then
            .rules += [{type: "required_status_checks", parameters: {
              strict_required_status_checks_policy: false,
              do_not_enforce_on_create: false,
              required_status_checks: [{context: $c}]}}]
          else
            .rules[$i].parameters.required_status_checks |=
              (. + [{context: $c}] | unique_by(.context))
          end'
else
  # shellcheck disable=SC2016
  edit='.rules |= map(if .type == "required_status_checks" then
          .parameters.required_status_checks |= map(select(.context != $c))
        else . end)'
fi

# The projection matters: a live GET also returns id/source/_links/timestamps,
# which PUT rejects. These six fields are what it accepts.
payload="$(gh api "/repos/$REPO/rulesets/$id" \
  | jq --arg c "$context" "$edit | {name, target, enforcement, bypass_actors, conditions, rules}")"

# Sorted on both sides: `unique_by` reorders the list, and that reordering is
# not a change worth showing — or worth PUTting.
echo "$RULESET (id $id) on $REPO"
diff --label before <(checks | sort) --label after \
  <(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context' <<<"$payload" | sort) \
  && { ok "Already the case — nothing to do."; exit 0; }

read -r -p "Apply to $REPO? [y/N] " reply
[[ "$reply" == [yY]* ]] || { echo "Aborted."; exit 1; }

gh api --method PUT "/repos/$REPO/rulesets/$id" --input - <<<"$payload" >/dev/null
ok "Done. Rollback: gh api /repos/$REPO/rulesets/$id/history"
