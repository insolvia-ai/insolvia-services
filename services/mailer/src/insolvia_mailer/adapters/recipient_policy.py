"""Reads the environment's recipient policy — one loader for both runtimes.

MAILER_RECIPIENT_POLICY_JSON is the same variable in the AWS Lambdas
(rendered by infra/modules/mailer) and the local Docker stack
(docker-compose.yml); core/recipients.py owns its format.
"""

from __future__ import annotations

import logging
import os

from insolvia_mailer.core.recipients import RecipientPolicy, parse_recipient_policy

logger = logging.getLogger(__name__)

ENVIRONMENT_VARIABLE = "MAILER_RECIPIENT_POLICY_JSON"


def load_recipient_policy() -> RecipientPolicy:
    """Unset or unreadable refuses every recipient rather than raising (see
    parse_recipient_policy), so the reason is logged once here, at startup,
    where an operator will look for it. Counts only — never the entries."""
    policy = parse_recipient_policy(os.environ.get(ENVIRONMENT_VARIABLE))
    log = logger.warning if policy.misconfiguration else logger.info
    log("mailer.recipient_policy %s", policy.describe)
    return policy
