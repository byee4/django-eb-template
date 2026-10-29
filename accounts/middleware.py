"""Audit-trail middleware: log every authenticated mutating request."""
import logging

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
