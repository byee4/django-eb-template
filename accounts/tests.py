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


def test_default_seed_identity_is_allowed(settings):
    settings.GLOBUS_ALLOWED_IDENTITIES = ["0ab2be39-35fe-432b-a620-2ed86db7999d"]
    settings.GLOBUS_ALLOWED_GROUP = "f0c3d900-18af-11f1-8e43-0affecd7d007"
    assert enforce_globus_allowlist(_strategy(), {}, {"sub": "0ab2be39-35fe-432b-a620-2ed86db7999d"}) is None
