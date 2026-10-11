import json

import pytest


@pytest.fixture(autouse=True)
def local_registry(monkeypatch):
    monkeypatch.setenv(
        "MAILER_DEVELOPMENT_SERVICES_JSON",
        json.dumps(
            {
                "insolvia_api": {
                    "sender_name": "Insolvia",
                    "sender_address": "no-reply@insolvia.ai",
                    "allowed_categories": ["welcome", "email_verification"],
                    "allowed_message_classes": ["transactional"],
                }
            }
        ),
    )


@pytest.fixture(autouse=True)
def unrestricted_recipients(monkeypatch):
    # Production code refuses every recipient when this is unset (fail
    # closed), so tests that are not about the allowlist state the local
    # default explicitly — the same value docker-compose.yml supplies.
    monkeypatch.setenv("MAILER_RECIPIENT_POLICY_JSON", '{"mode": "unrestricted"}')
