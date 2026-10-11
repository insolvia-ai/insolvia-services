from __future__ import annotations

from flask import Blueprint, jsonify
from flask.typing import ResponseReturnValue

from insolvia_mailer.api.dependencies import authorized_service, dependencies
from insolvia_mailer.api.request_body import json_body
from insolvia_mailer.core.models import MessageRequest
from insolvia_mailer.core.recipients import enforce_recipient_policy

blueprint = Blueprint("messages", __name__)


@blueprint.post("/v1/services/<service_id>/messages")
def submit_message(service_id: str) -> ResponseReturnValue:
    service = authorized_service(service_id)
    message = MessageRequest.from_dict(json_body(), service)
    # Before admission, so a refused message is never stored, queued or
    # deduplicated against — a retry after the allowlist widens is a fresh send.
    enforce_recipient_policy(
        dependencies().recipient_policy,
        [message.to_address],
        service_id=service.service_id,
        application_message_id=message.application_message_id,
    )
    dependencies().store.admit_message(service, message)
    return (
        jsonify(
            {
                "schema_version": 1,
                "application_message_id": message.application_message_id,
                "status": "accepted",
            }
        ),
        202,
    )
