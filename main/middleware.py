"""Answer load-balancer health checks before Django validates the Host header.

An application load balancer's health check sends the instance's private IP as the Host header,
which is not in ALLOWED_HOSTS, so the check would get a 400 and mark the instance unhealthy.
"""
from .views import healthz


class HealthCheckMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        if request.path == "/healthz/":
            return healthz(request)
        return self.get_response(request)
