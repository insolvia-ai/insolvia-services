import json

import pytest
from insolvia_mailer.core.errors import RecipientNotAllowedError
from insolvia_mailer.core.recipients import (
    NOT_ALLOWLISTED,
    POLICY_INVALID,
    POLICY_UNCONFIGURED,
    enforce_recipient_policy,
    parse_recipient_policy,
)

STAGING = json.dumps(
    {
        "mode": "allowlist",
        "domains": ["insolvia.ai"],
        "addresses": ["named.tester@example.com"],
    }
)


def enforce(policy, *recipients):
    enforce_recipient_policy(
        policy, recipients, service_id="insolvia_api", application_message_id="m1"
    )


# ── allowed ──────────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "address",
    [
        "andreas@insolvia.ai",
        "Andreas+e2e@Insolvia.AI",
        "named.tester@example.com",
        "NAMED.TESTER@EXAMPLE.COM",
    ],
)
def test_allowlisted_domain_or_address_is_admitted(address):
    enforce(parse_recipient_policy(STAGING), address)


def test_unrestricted_admits_anyone():
    enforce(parse_recipient_policy('{"mode": "unrestricted"}'), "anyone@gmail.com")


# ── partially allowed: close to an entry, or only some recipients ────────────


@pytest.mark.parametrize(
    "address",
    [
        "someone@mail.insolvia.ai",  # a subdomain is not the domain
        "someone@insolvia.ai.example.com",  # a suffix is not the domain
        "someone@notinsolvia.ai",  # nor is a longer name ending in it
        "named.tester+x@example.com",  # an address entry is that address only
        "someone.else@example.com",  # and does not admit its domain
    ],
)
def test_near_misses_are_refused(address):
    with pytest.raises(RecipientNotAllowedError) as refused:
        enforce(parse_recipient_policy(STAGING), address)
    assert refused.value.reason == NOT_ALLOWLISTED
    assert refused.value.refused_count == 1


def test_one_disallowed_recipient_refuses_the_whole_message():
    with pytest.raises(RecipientNotAllowedError) as refused:
        enforce(
            parse_recipient_policy(STAGING),
            "andreas@insolvia.ai",
            "real.person@gmail.com",
        )
    assert refused.value.refused_count == 1


# ── refused, and the refusal never carries the address ───────────────────────


def test_refusal_names_a_category_and_count_never_the_address():
    with pytest.raises(RecipientNotAllowedError) as refused:
        enforce(parse_recipient_policy(STAGING), "real.person@gmail.com")
    error = refused.value
    assert "real.person" not in str(error)
    assert "gmail" not in str(error)
    assert (error.reason, error.refused_count) == (NOT_ALLOWLISTED, 1)
    assert error.service_id == "insolvia_api"
    assert error.application_message_id == "m1"


def test_empty_allowlist_refuses_everyone():
    with pytest.raises(RecipientNotAllowedError):
        enforce(parse_recipient_policy('{"mode": "allowlist"}'), "a@insolvia.ai")


# ── fail closed: no shape of bad config allows anything ──────────────────────


@pytest.mark.parametrize("raw", [None, "", "   "])
def test_missing_policy_refuses_everyone(raw):
    policy = parse_recipient_policy(raw)
    with pytest.raises(RecipientNotAllowedError) as refused:
        enforce(policy, "andreas@insolvia.ai")
    assert refused.value.reason == POLICY_UNCONFIGURED


@pytest.mark.parametrize(
    "raw",
    [
        "not json",
        "[]",
        "{}",
        '{"mode": "everything"}',
        '{"mode": "Unrestricted"}',
        '{"mode": "unrestricted", "domains": ["insolvia.ai"]}',
        '{"mode": "allowlist", "domains": "insolvia.ai"}',
        '{"mode": "allowlist", "domains": ["@insolvia.ai"]}',
        '{"mode": "allowlist", "domains": ["insolvia"]}',
        '{"mode": "allowlist", "addresses": ["insolvia.ai"]}',
        '{"mode": "allowlist", "addresses": ["a@b@insolvia.ai"]}',
        '{"mode": "allowlist", "domains": ["insolvia.ai"], "extra": true}',
        '{"mode": "allowlist", "domains": [null]}',
    ],
)
def test_unreadable_policy_refuses_everyone(raw):
    policy = parse_recipient_policy(raw)
    with pytest.raises(RecipientNotAllowedError) as refused:
        enforce(policy, "andreas@insolvia.ai")
    assert refused.value.reason == POLICY_INVALID


def test_policy_description_counts_entries_without_naming_them():
    described = parse_recipient_policy(STAGING).describe
    assert described == "allowlist domains=1 addresses=1"
    assert "insolvia" not in described
