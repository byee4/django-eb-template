from types import SimpleNamespace

import pytest
from social_core.exceptions import AuthForbidden

from accounts.permissions import enforce_globus_allowlist


def _strategy():
    return SimpleNamespace(backend=SimpleNamespace(name="globus"))


def test_allowlist_accepts_matching_identity(settings):
    settings.GLOBUS_ALLOWED_IDENTITIES = ["abc-123"]
    settings.GLOBUS_ALLOWED_GROUP = ""
    result = enforce_globus_allowlist(_strategy(), {}, {"sub": "abc-123"})
    assert result is None


def test_allowlist_rejects_unknown_identity_with_no_group(settings):
    settings.GLOBUS_ALLOWED_IDENTITIES = ["abc-123"]
    settings.GLOBUS_ALLOWED_GROUP = ""
    with pytest.raises(AuthForbidden):
        enforce_globus_allowlist(_strategy(), {}, {"sub": "someone-else"})


def test_allowlist_accepts_group_member(settings):
    settings.GLOBUS_ALLOWED_IDENTITIES = []
    settings.GLOBUS_ALLOWED_GROUP = "group-uuid"
    response = {
        "sub": "user-uuid",
        "identity_set": [{"identity_id": "group-uuid"}, {"identity_id": "other"}],
    }
    assert enforce_globus_allowlist(_strategy(), {}, response) is None


def test_allowlist_rejects_non_member(settings):
    settings.GLOBUS_ALLOWED_IDENTITIES = []
    settings.GLOBUS_ALLOWED_GROUP = "group-uuid"
    response = {"sub": "user-uuid", "identity_set": [{"identity_id": "other"}]}
    with pytest.raises(AuthForbidden):
        enforce_globus_allowlist(_strategy(), {}, response)


def test_empty_allowlist_rejects_everyone(settings):
    settings.GLOBUS_ALLOWED_IDENTITIES = []
    settings.GLOBUS_ALLOWED_GROUP = ""
    response = {"sub": "user-uuid", "identity_set": [{"identity_id": "any-group"}]}
    with pytest.raises(AuthForbidden):
        enforce_globus_allowlist(_strategy(), {}, response)


# --- Globus OAuth recovery middleware ------------------------------------------------------


def _recovery(rf, path, exception):
    from django.contrib.sessions.backends.signed_cookies import SessionStore

    from accounts.middleware import GlobusOAuthRecoveryMiddleware

    request = rf.get(path)
    request.session = SessionStore()
    request.user = SimpleNamespace(is_authenticated=False)
    return GlobusOAuthRecoveryMiddleware(lambda r: None).process_exception(request, exception)


def test_lost_oauth_state_on_callback_returns_retry_message(rf):
    from social_core.exceptions import AuthStateMissing

    missing = AuthStateMissing(None, "state")  # type: ignore[arg-type]
    response = _recovery(rf, "/complete/globus/", missing)
    assert response.status_code == 400
    assert b"/login/globus/" in response.content


def test_globus_5xx_on_callback_restarts_login(rf):
    from requests import Response
    from requests.exceptions import HTTPError

    upstream = Response()
    upstream.status_code = 502
    response = _recovery(rf, "/complete/globus/", HTTPError(response=upstream))
    assert response.status_code == 302
    assert response.url == "/login/globus/?oauth_retry=1"


def test_other_errors_are_left_alone(rf):
    assert _recovery(rf, "/", ValueError("boom")) is None
