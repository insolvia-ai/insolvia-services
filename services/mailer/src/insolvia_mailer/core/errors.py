class MailerError(Exception):
    """Base class for expected Mailer failures."""


class ValidationError(MailerError):
    """A caller supplied an invalid request."""


class AuthorizationError(MailerError):
    """The authenticated caller is not registered for the service route."""


class ConflictError(MailerError):
    """An idempotency key was reused with different content."""


class RetryableError(MailerError):
    """The operation may succeed when retried."""


class AttachmentBlockedError(MailerError):
    """An attachment failed a terminal safety check."""


class RecipientNotAllowedError(MailerError):
    """A recipient is outside this environment's allowlist (core/recipients.py).

    Carries only what may be logged: a reason category and a count. The
    message the caller sees is fixed text — never the address."""

    def __init__(
        self,
        *,
        reason: str,
        refused_count: int,
        service_id: str,
        application_message_id: str,
    ) -> None:
        super().__init__("recipient is not allowed in this environment")
        self.reason = reason
        self.refused_count = refused_count
        self.service_id = service_id
        self.application_message_id = application_message_id
