from __future__ import annotations

import logging
import queue
import threading

from insolvia_mailer.adapters.memory.store import MemoryDelivery, MemoryStore
from insolvia_mailer.core.mime import build_message
from insolvia_mailer.core.ports import MailTransport
from insolvia_mailer.core.recipients import RecipientPolicy

logger = logging.getLogger("insolvia_mailer.development")


class MemoryDeliveryWorker:
    """Drains the ephemeral queue into the configured development transport.

    Stands in for entrypoints/sender_lambda.py, so it checks suppression the
    same way the real sender does. That check is the whole reason this takes
    the store rather than just its queue: an unsubscribe that works against
    AWS but silently does nothing in the Mailpit dev loop (issue 6.5) is a
    difference you only discover in production. The recipient policy is
    checked again here for the same reason the sender Lambda re-checks it.
    """

    def __init__(
        self,
        store: MemoryStore,
        transport: MailTransport,
        recipient_policy: RecipientPolicy,
    ) -> None:
        self.store = store
        self.recipient_policy = recipient_policy
        self.deliveries: queue.Queue[MemoryDelivery] = store.deliveries
        self.transport = transport

    def start(self) -> None:
        threading.Thread(
            target=self._run,
            name="mailer-development-delivery",
            daemon=True,
        ).start()

    def _run(self) -> None:
        while True:
            delivery = self.deliveries.get()
            try:
                refusal = self.recipient_policy.refusal([delivery.request.to_address])
                if refusal:
                    logger.warning(
                        "mailer.recipient_refused service_id=%s "
                        "application_message_id=%s reason=%s refused_count=%d "
                        "stage=send",
                        delivery.service.service_id,
                        delivery.request.application_message_id,
                        *refusal,
                    )
                    continue
                if self.store.is_suppressed(delivery.request.to_address):
                    logger.info(
                        "development email suppressed service_id=%s "
                        "application_message_id=%s",
                        delivery.service.service_id,
                        delivery.request.application_message_id,
                    )
                    continue
                message = build_message(
                    delivery.service,
                    delivery.request,
                    delivery.attachments,
                )
                self.transport.send(message)
                logger.info(
                    "development email captured service_id=%s "
                    "application_message_id=%s category=%s",
                    delivery.service.service_id,
                    delivery.request.application_message_id,
                    delivery.request.category,
                )
            except Exception:
                logger.exception(
                    "development email capture failed "
                    "service_id=%s application_message_id=%s",
                    delivery.service.service_id,
                    delivery.request.application_message_id,
                )
            finally:
                self.deliveries.task_done()
