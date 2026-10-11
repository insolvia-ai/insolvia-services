from __future__ import annotations

from dataclasses import dataclass
from typing import cast

from flask import current_app

from insolvia_mailer.core.config import ServiceConfig
from insolvia_mailer.core.errors import AuthorizationError
from insolvia_mailer.core.ports import (
    AttachmentReceiver,
    MailerStore,
    RequestAuthorizer,
)
from insolvia_mailer.core.recipients import REFUSE_ALL, RecipientPolicy


@dataclass(frozen=True)
class ApiDependencies:
    services: dict[str, ServiceConfig]
    store: MailerStore
    authorizer: RequestAuthorizer
    attachment_receiver: AttachmentReceiver | None = None
    # Defaults to refusing every recipient: a composition that forgets to
    # pass the environment's policy sends nothing rather than anything.
    recipient_policy: RecipientPolicy = REFUSE_ALL


def dependencies() -> ApiDependencies:
    return cast("ApiDependencies", current_app.extensions["mailer_dependencies"])


def authorized_service(service_id: str) -> ServiceConfig:
    configured = dependencies()
    service = configured.services.get(service_id)
    if not service:
        raise AuthorizationError("service route is not registered")
    configured.authorizer.authorize(service)
    return service
