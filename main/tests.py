import pytest
from django.urls import reverse


@pytest.mark.django_db
def test_home_renders(client):
    response = client.get(reverse("home"))
    assert response.status_code == 200
    assert b"Hello, world" in response.content


@pytest.mark.django_db
def test_healthz_ok(client):
    response = client.get(reverse("healthz"))
    assert response.status_code == 200
    assert response.json() == {"ok": True}
