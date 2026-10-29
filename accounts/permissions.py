"""Globus OAuth pipeline step that enforces the identity/group allowlist."""
import logging

from django.conf import settings
from social_core.exceptions import AuthForbidden

logger = logging.getLogger("audit")


def _identity_uuid(response):
    return (response or {}).get("sub") or (response or {}).get("preferred_username")


def _group_uuids(response):
    identity_set = (response or {}).get("identity_set") or []
    return {entry.get("identity_id") for entry in identity_set if entry.get("identity_id")}


def enforce_globus_allowlist(strategy, details, response, *args, **kwargs):
    """Reject Globus logins that don't match GLOBUS_ALLOWED_IDENTITIES or GLOBUS_ALLOWED_GROUP.

    Runs after `auth_allowed`. The default Globus backend's group check uses
    SOCIAL_AUTH_GLOBUS_ALLOWED_GROUPS, which we also configure. This pipeline
    step additionally enforces the identity-UUID allowlist and logs every
    accept/reject to the audit logger.
    """
    identity = _identity_uuid(response)
    allowed_identities = set(settings.GLOBUS_ALLOWED_IDENTITIES or [])
    allowed_group = settings.GLOBUS_ALLOWED_GROUP

    if identity and identity in allowed_identities:
        logger.info("globus_login_allowed identity=%s reason=identity_allowlist", identity)
        return None

    if allowed_group:
        groups = _group_uuids(response)
        if allowed_group in groups:
            logger.info(
                "globus_login_allowed identity=%s reason=group_allowlist group=%s",
                identity, allowed_group,
            )
            return None

    logger.warning(
        "globus_login_denied identity=%s allowed_identities=%d allowed_group=%s",
        identity, len(allowed_identities), bool(allowed_group),
    )
    raise AuthForbidden(strategy.backend)
