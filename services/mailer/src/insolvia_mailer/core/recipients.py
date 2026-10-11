"""Per-environment recipient allowlist.

Staging sends through real SES. Until SES production access is granted the
account-wide sandbox is what keeps staging from mailing a real person; after
it, this is. Each environment states one of two policies:

    {"mode": "unrestricted"}
    {"mode": "allowlist", "domains": ["insolvia.ai"], "addresses": [...]}

and anything else — the variable missing, empty, unparseable, an unknown mode,
a malformed entry — is a policy that refuses EVERY recipient. Fail closed is
the point: the dangerous mistake is staging silently running unrestricted, so
"unrestricted" has to be said out loud and every other shape of config means
"send nothing". Terraform renders the value (infra/modules/mailer,
`recipient_allowlist`); local Docker defaults it to unrestricted because
Mailpit never relays.

Matching is exact, on purpose:

- a domain entry matches that domain only — `insolvia.ai` does not admit
  `mail.insolvia.ai`, and certainly not `insolvia.ai.example.com`;
- an address entry matches that whole address, so `someone@gmail.com` does
  not admit `someone+x@gmail.com` or anyone else at gmail.com.

Comparison is case-insensitive (domains are; local parts are in practice at
every provider this would ever name). A wider match is one more line in the
environment's list; a match that is accidentally wider is a real person
receiving staging mail.

A message is admitted only if every recipient is allowed. The contract has
one `to_address` today, so "drop the disallowed ones" and "refuse the
message" coincide — but if it ever grows cc/bcc, delivering a message to
some of its recipients is a different message from the one the caller
composed, and a silent partial send is the kind of surprise this exists to
prevent. So the whole message is refused, and the caller is told.
"""

from __future__ import annotations

import json
from collections.abc import Iterable
from dataclasses import dataclass

from insolvia_mailer.core.errors import RecipientNotAllowedError

# Why a policy refuses, as a closed set — this is what gets logged and
# returned, never the address. `not_allowlisted` is the normal case;
# the other two mean the environment's configuration is wrong.
NOT_ALLOWLISTED = "not_allowlisted"
POLICY_UNCONFIGURED = "policy_unconfigured"
POLICY_INVALID = "policy_invalid"


def _domain(address: str) -> str:
    return address.rsplit("@", 1)[-1].strip().lower().rstrip(".")


@dataclass(frozen=True)
class RecipientPolicy:
    unrestricted: bool = False
    domains: frozenset[str] = frozenset()
    addresses: frozenset[str] = frozenset()
    # Set when the configuration could not be read, so the refusal says why.
    # A policy built with no arguments refuses everything; that is the default
    # anything constructing one by hand gets.
    misconfiguration: str | None = None

    @property
    def describe(self) -> str:
        """For the startup log — counts, never the entries themselves."""
        if self.misconfiguration:
            return f"refuse-all ({self.misconfiguration})"
        if self.unrestricted:
            return "unrestricted"
        return f"allowlist domains={len(self.domains)} addresses={len(self.addresses)}"

    def allows(self, address: str) -> bool:
        if self.misconfiguration:
            return False
        if self.unrestricted:
            return True
        normalized = address.strip().lower()
        return normalized in self.addresses or _domain(normalized) in self.domains

    def refusal(self, recipients: Iterable[str]) -> tuple[str, int] | None:
        """None if every recipient may be sent to, else (reason, how many not)."""
        refused = sum(1 for address in recipients if not self.allows(address))
        if not refused:
            return None
        return (self.misconfiguration or NOT_ALLOWLISTED, refused)


REFUSE_ALL = RecipientPolicy(misconfiguration=POLICY_UNCONFIGURED)


def _entries(value: object, *, is_address: bool) -> frozenset[str] | None:
    if not isinstance(value, list):
        return None
    result: set[str] = set()
    for item in value:
        if not isinstance(item, str):
            return None
        entry = item.strip().lower()
        valid = (
            entry.count("@") == 1 and all(entry.split("@"))
            if is_address
            else "@" not in entry and "." in entry
        )
        if not valid or any(char.isspace() for char in entry):
            return None
        result.add(entry if is_address else entry.rstrip("."))
    return frozenset(result)


def parse_recipient_policy(raw: str | None) -> RecipientPolicy:
    """Never raises: an unreadable policy is a policy that refuses everything.

    Raising would take the whole API down with it — suppressions and health
    included — for a mistake whose safe reading is simply "send nothing".
    """
    if raw is None or not raw.strip():
        return REFUSE_ALL
    invalid = RecipientPolicy(misconfiguration=POLICY_INVALID)
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return invalid
    if not isinstance(parsed, dict):
        return invalid
    mode = parsed.get("mode")
    if mode == "unrestricted":
        return (
            RecipientPolicy(unrestricted=True) if set(parsed) == {"mode"} else invalid
        )
    if mode != "allowlist" or not set(parsed) <= {"mode", "domains", "addresses"}:
        return invalid
    domains = _entries(parsed.get("domains", []), is_address=False)
    addresses = _entries(parsed.get("addresses", []), is_address=True)
    if domains is None or addresses is None:
        return invalid
    return RecipientPolicy(domains=domains, addresses=addresses)


def enforce_recipient_policy(
    policy: RecipientPolicy,
    recipients: Iterable[str],
    *,
    service_id: str,
    application_message_id: str,
) -> None:
    refusal = policy.refusal(recipients)
    if refusal:
        reason, refused_count = refusal
        raise RecipientNotAllowedError(
            reason=reason,
            refused_count=refused_count,
            service_id=service_id,
            application_message_id=application_message_id,
        )
