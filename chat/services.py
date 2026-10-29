"""Chat service: streaming LLM calls against an OpenAI-compatible NRP Nautilus gateway.

Adapted from yeolab_search/publications/chat_service.py (minimal port: no tool use,
no per-session cache salt — those are added back in app-specific extensions).
"""
import base64
import json
import logging
import secrets

from django.conf import settings

logger = logging.getLogger("chat")

SYSTEM_PROMPT = (
    "You are a helpful assistant for this Django application. "
    "Answer concisely. If you don't know, say so honestly."
)
NRP_GATEWAY_UNAVAILABLE = (
    "The NRP Nautilus gateway is currently unreachable or the model is loading. "
    "Please try again in a few moments."
)


def generate_cache_salt() -> str:
    """Per-session base64 salt for the shared NRP server token (256 bits)."""
    return base64.b64encode(secrets.token_bytes(32)).decode("ascii")


def get_or_create_cache_salt(session) -> str:
    salt = session.get("nrp_cache_salt")
    if not salt:
        salt = generate_cache_salt()
        session["nrp_cache_salt"] = salt
        session.save()
    return salt


def stream_chat(user_message, conversation_history=None, *, cache_salt=None, model=None):
    """Yield SSE-formatted strings for a chat response.

    Uses the NRP_API_KEY configured server-side; requires per-session cache_salt
    to prevent cross-user prompt-cache leakage.
    """
    if not settings.NRP_API_KEY:
        yield _sse({"type": "error", "message": "NRP_API_KEY is not configured on the server."})
        return
    if not cache_salt:
        yield _sse({"type": "error", "message": "Missing per-session cache_salt."})
        return

    try:
        import openai as openai_module
        from openai import OpenAI
    except ImportError:
        yield _sse({"type": "error", "message": "openai package not installed. Run: pip install openai"})
        return

    messages = list(conversation_history or [])
    messages.append({"role": "user", "content": user_message})

    client = OpenAI(api_key=settings.NRP_API_KEY, base_url=settings.NRP_GATEWAY_BASE_URL)
    request = dict(
        model=model or settings.NRP_DEFAULT_MODEL,
        messages=[{"role": "system", "content": SYSTEM_PROMPT}, *messages],
        stream=True,
        extra_body={"cache_salt": cache_salt},
    )

    try:
        for chunk in client.chat.completions.create(**request):
            if not chunk.choices:
                continue
            delta = chunk.choices[0].delta
            if delta.content:
                yield _sse({"type": "text", "content": delta.content})
        yield _sse({"type": "done"})
    except openai_module.AuthenticationError:
        yield _sse({"type": "error", "message": "Invalid NRP token. Check NRP_API_KEY."})
    except (openai_module.APIConnectionError, openai_module.APITimeoutError) as exc:
        yield _sse({"type": "error", "message": f"{NRP_GATEWAY_UNAVAILABLE} ({exc.__class__.__name__})"})
    except openai_module.APIStatusError as exc:
        if getattr(exc, "status_code", None) == 503:
            yield _sse({"type": "error", "message": NRP_GATEWAY_UNAVAILABLE})
        else:
            yield _sse({"type": "error", "message": f"NRP API error: {exc}"})
    except openai_module.RateLimitError:
        yield _sse({"type": "error", "message": "NRP rate limit exceeded. Please wait and try again."})
    except Exception as exc:
        logger.exception("chat error")
        yield _sse({"type": "error", "message": f"Unexpected error: {exc}"})


def _sse(data) -> str:
    return f"data: {json.dumps(data, default=str)}\n\n"
