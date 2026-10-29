from urllib.parse import urlencode

from django.conf import settings
from django.contrib.auth import logout as auth_logout
from django.shortcuts import redirect
from django.urls import include, path


def logout_view(request):
    """Clear local Django/social-auth state, then optionally end the Globus web session."""
    if hasattr(request, "session"):
        for key in list(request.session.keys()):
            if key.startswith("social_auth_") or "oauth" in key.lower() or "state" in key.lower():
                request.session.pop(key, None)

    auth_logout(request)
    if hasattr(request, "session"):
        request.session.flush()

    client_id = (getattr(settings, "SOCIAL_AUTH_GLOBUS_KEY", "") or "").strip()
    local_only = request.GET.get("local_only", "").lower() in {"1", "true", "yes"}
    if client_id and not local_only:
        params = {
            "client_id": client_id,
            "redirect_uri": request.build_absolute_uri("/"),
            "redirect_name": "Django Template",
        }
        response = redirect(f"https://auth.globus.org/v2/web/logout?{urlencode(params)}")
    else:
        response = redirect("/")

    for name in {settings.SESSION_COOKIE_NAME, settings.CSRF_COOKIE_NAME, "sessionid", "csrftoken"}:
        response.delete_cookie(name, path="/")
    response["Clear-Site-Data"] = "\"cookies\", \"storage\""
    return response


urlpatterns = [
    path("", include("social_django.urls", namespace="social")),
    path("logout/", logout_view, name="logout"),
    path("chat/", include("chat.urls")),
    path("", include("main.urls")),
]
