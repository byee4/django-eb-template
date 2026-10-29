import json

import pytest
from django.contrib.auth import get_user_model
from django.urls import reverse


@pytest.mark.django_db
def test_chat_index_requires_login(client):
    response = client.get(reverse("chat:index"))
    assert response.status_code == 302
    assert "/login/" in response["Location"]


@pytest.mark.django_db
def test_chat_message_requires_login(client):
    response = client.post(reverse("chat:message"), data="{}", content_type="application/json")
    assert response.status_code == 302


@pytest.mark.django_db
def test_chat_message_streams_text(client, settings, monkeypatch):
    settings.NRP_API_KEY = "test-key"

    def fake_stream(message, history=None, *, cache_salt=None, model=None):
        yield "data: " + json.dumps({"type": "text", "content": "hello "}) + "\n\n"
        yield "data: " + json.dumps({"type": "text", "content": "world"}) + "\n\n"
        yield "data: " + json.dumps({"type": "done"}) + "\n\n"

    monkeypatch.setattr("chat.views.stream_chat", fake_stream)

    user = get_user_model().objects.create_user(username="tester")
    client.force_login(user)

    response = client.post(
        reverse("chat:message"),
        data=json.dumps({"message": "hi"}),
        content_type="application/json",
    )
    assert response.status_code == 200
    assert response["Content-Type"].startswith("text/event-stream")
    body = b"".join(response.streaming_content).decode()
    assert "hello " in body
    assert "world" in body
    assert '"type": "done"' in body


@pytest.mark.django_db
def test_chat_message_rejects_empty(client):
    user = get_user_model().objects.create_user(username="tester2")
    client.force_login(user)
    response = client.post(
        reverse("chat:message"),
        data=json.dumps({"message": "   "}),
        content_type="application/json",
    )
    assert response.status_code == 400
