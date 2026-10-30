"""Account middleware: audit trail for mutating requests, and Globus OAuth callback recovery."""
import logging

from django.contrib.auth import logout
from django.http import HttpResponseBadRequest
from django.shortcuts import redirect
from requests.exceptions import HTTPError
from social_core.exceptions import AuthStateMissing

logger = logging.getLogger("audit")

MUTATING_METHODS = {"POST", "PUT", "PATCH", "DELETE"}


class AuditLogMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        response = self.get_response(request)
        if request.method in MUTATING_METHODS and getattr(request, "user", None) and request.user.is_authenticated:
            logger.info(
                "request user=%s method=%s path=%s status=%s",
                request.user.username,
                request.method,
                request.path,
                response.status_code,
            )
        return response


class GlobusOAuthRecoveryMiddleware:
    """Turn common Globus callback failures into a clean retry instead of a 500.

    - Lost OAuth state (cookies dropped between /login/globus/ and the callback, often a scheme
      or host mismatch behind a proxy): clear the session and explain how to retry.
    - Globus token-exchange 5xx: clear the session and restart the login once.
    """

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        return self.get_response(request)

    def process_exception(self, request, exception):
        on_callback = request.path.startswith("/complete/globus/")
        if isinstance(exception, AuthStateMissing) and on_callback:
            logger.warning(
                "globus_oauth_state_missing host=%s secure=%s has_session_cookie=%s",
                request.get_host(),
                request.is_secure(),
                request.COOKIES.get("sessionid") is not None,
            )
            logout(request)
            request.session.flush()
            return HttpResponseBadRequest(
                "Login session was lost before the Globus callback completed. "
                "Clear site cookies and start again at /login/globus/."
            )
        if isinstance(exception, HTTPError) and exception.response is not None:
            logger.error("globus_token_exchange_failed status=%s", exception.response.status_code)
            if on_callback and exception.response.status_code >= 500:
                logout(request)
                request.session.flush()
                return redirect("/login/globus/?oauth_retry=1")
        return None
