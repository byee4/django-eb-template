import json

from django.contrib.auth.decorators import login_required
from django.http import HttpResponseBadRequest, StreamingHttpResponse
from django.shortcuts import render
from django.views.decorators.csrf import csrf_protect
from django.views.decorators.http import require_POST

from .services import get_or_create_cache_salt, stream_chat


@login_required
def index(request):
    return render(request, "chat/chat.html")


@login_required
@require_POST
@csrf_protect
def message(request):
    try:
        payload = json.loads(request.body or "{}")
    except json.JSONDecodeError:
        return HttpResponseBadRequest("invalid JSON")

    user_message = (payload.get("message") or "").strip()
    if not user_message:
        return HttpResponseBadRequest("missing 'message'")

    history = payload.get("history") or []
    cache_salt = get_or_create_cache_salt(request.session)
    response = StreamingHttpResponse(
        stream_chat(user_message, history, cache_salt=cache_salt),
        content_type="text/event-stream",
    )
    response["Cache-Control"] = "no-cache"
    response["X-Accel-Buffering"] = "no"
    return response
