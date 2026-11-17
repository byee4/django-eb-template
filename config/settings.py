"""Django settings for the template project.

Local dev uses SQLite. Production uses PostgreSQL via DATABASE_URL.
Globus OAuth provides authentication; access is restricted to identities/groups
listed in GLOBUS_ALLOWED_IDENTITIES / GLOBUS_ALLOWED_GROUP.
"""
import os
from pathlib import Path

import dj_database_url
from django.core.exceptions import ImproperlyConfigured
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent

if (BASE_DIR / ".env").is_file():
    load_dotenv(BASE_DIR / ".env")


def env_bool(name: str, default: bool) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.lower() in {"1", "true", "yes", "on"}


def env_list(name: str, default: str = "") -> list[str]:
    return [item.strip() for item in os.environ.get(name, default).split(",") if item.strip()]


INSECURE_DEFAULT_KEY = "django-insecure-local-template-key-change-me"
SECRET_KEY = os.environ.get("DJANGO_SECRET_KEY", INSECURE_DEFAULT_KEY)
DEBUG = env_bool("DJANGO_DEBUG", True)
ALLOWED_HOSTS = env_list("DJANGO_ALLOWED_HOSTS", "localhost,127.0.0.1")

# Production fails closed: refuse to start with a development secret or wildcard hosts.
if not DEBUG:
    if SECRET_KEY in {INSECURE_DEFAULT_KEY, "REPLACE_ME_GENERATE_LOCAL_KEY"}:
        raise ImproperlyConfigured("DJANGO_SECRET_KEY must be set when DJANGO_DEBUG=False.")
    if "*" in ALLOWED_HOSTS:
        raise ImproperlyConfigured("DJANGO_ALLOWED_HOSTS must not include '*' when DJANGO_DEBUG=False.")

INSTALLED_APPS = [
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "social_django",
    "globus_portal_framework",
    "accounts",
    "main",
    "chat",
]

MIDDLEWARE = [
    "main.middleware.HealthCheckMiddleware",  # first: load balancers send an IP as the Host
    "django.middleware.security.SecurityMiddleware",
    "whitenoise.middleware.WhiteNoiseMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
    "social_django.middleware.SocialAuthExceptionMiddleware",
    "globus_portal_framework.middleware.ExpiredTokenMiddleware",
    "globus_portal_framework.middleware.GlobusAuthExceptionMiddleware",
    "accounts.middleware.GlobusOAuthRecoveryMiddleware",
    "accounts.middleware.AuditLogMiddleware",
]

ROOT_URLCONF = "config.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
                "social_django.context_processors.backends",
                "social_django.context_processors.login_redirect",
                "globus_portal_framework.context_processors.globals",
            ],
        },
    },
]

WSGI_APPLICATION = "config.wsgi.application"

DATABASE_URL = os.environ.get("DATABASE_URL", "").strip()
if DATABASE_URL:
    DATABASES = {"default": dj_database_url.parse(DATABASE_URL, conn_max_age=600)}
    DATABASES["default"]["CONN_HEALTH_CHECKS"] = True
else:
    DATABASES = {
        "default": {
            "ENGINE": "django.db.backends.sqlite3",
            "NAME": str(BASE_DIR / "db.sqlite3"),
        }
    }

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

LANGUAGE_CODE = "en-us"
TIME_ZONE = os.environ.get("TIME_ZONE", "America/Los_Angeles")
USE_I18N = True
USE_TZ = True

STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
STATICFILES_DIRS = [BASE_DIR / "static"]
_STATIC_BACKEND = (
    "django.contrib.staticfiles.storage.StaticFilesStorage"
    if DEBUG
    else "whitenoise.storage.CompressedManifestStaticFilesStorage"
)
STORAGES = {
    "default": {"BACKEND": "django.core.files.storage.FileSystemStorage"},
    "staticfiles": {"BACKEND": _STATIC_BACKEND},
}
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# --- Globus auth ------------------------------------------------------------
AUTHENTICATION_BACKENDS = [
    "social_core.backends.globus.GlobusOpenIdConnect",
    "globus_portal_framework.auth.GlobusOpenIdConnect",
    "django.contrib.auth.backends.ModelBackend",
]

SOCIAL_AUTH_GLOBUS_KEY = os.environ.get("GLOBUS_CLIENT_ID", "").strip()
SOCIAL_AUTH_GLOBUS_SECRET = os.environ.get("GLOBUS_CLIENT_SECRET", "").strip()
SOCIAL_AUTH_GLOBUS_SCOPE = [
    "openid",
    "profile",
    "email",
    "urn:globus:auth:scope:groups.api.globus.org:view_my_groups_and_memberships",
]
SOCIAL_AUTH_GLOBUS_IGNORE_DEFAULT_SCOPE = True
SOCIAL_AUTH_GLOBUS_SESSIONS = True
SOCIAL_AUTH_REDIRECT_IS_HTTPS = env_bool("SOCIAL_AUTH_REDIRECT_IS_HTTPS", not DEBUG)
SOCIAL_AUTH_GLOBUS_REDIRECT_URI = os.environ.get("SOCIAL_AUTH_GLOBUS_REDIRECT_URI", "").strip()

# No built-in defaults: with both empty, nobody can log in until the owner sets them.
GLOBUS_ALLOWED_IDENTITIES = env_list("GLOBUS_ALLOWED_IDENTITIES")
GLOBUS_ALLOWED_GROUP = os.environ.get("GLOBUS_ALLOWED_GROUP", "").strip()
SOCIAL_AUTH_GLOBUS_ALLOWED_GROUPS = (
    [{"name": "App Members", "uuid": GLOBUS_ALLOWED_GROUP}] if GLOBUS_ALLOWED_GROUP else []
)

SOCIAL_AUTH_PIPELINE = (
    "social_core.pipeline.social_auth.social_details",
    "social_core.pipeline.social_auth.social_uid",
    "social_core.pipeline.social_auth.auth_allowed",
    "accounts.permissions.enforce_globus_allowlist",
    "social_core.pipeline.social_auth.social_user",
    "social_core.pipeline.user.get_username",
    "social_core.pipeline.user.create_user",
    "social_core.pipeline.social_auth.associate_user",
    "social_core.pipeline.social_auth.load_extra_data",
    "social_core.pipeline.user.user_details",
)

LOGIN_URL = "/login/globus/"
LOGIN_REDIRECT_URL = "/"
LOGOUT_REDIRECT_URL = "/"

CSRF_TRUSTED_ORIGINS = env_list("CSRF_TRUSTED_ORIGINS")
# Behind CloudFront (the default HTTPS front door when there is no custom domain) the origin sees
# plain HTTP, so X-Forwarded-Proto says "http". one_time_setup.sh then sets
# SECURE_PROXY_SSL_HEADER_NAME=HTTP_CLOUDFRONT_FORWARDED_PROTO so Django trusts CloudFront instead.
SECURE_PROXY_SSL_HEADER = (
    os.environ.get("SECURE_PROXY_SSL_HEADER_NAME", "HTTP_X_FORWARDED_PROTO"),
    "https",
)
USE_X_FORWARDED_PORT = True
SESSION_COOKIE_SAMESITE = os.environ.get("SESSION_COOKIE_SAMESITE", "Lax")
CSRF_COOKIE_SAMESITE = os.environ.get("CSRF_COOKIE_SAMESITE", "Lax")

if not DEBUG:
    SECURE_SSL_REDIRECT = env_bool("SECURE_SSL_REDIRECT", True)
    SECURE_REDIRECT_EXEMPT = [r"^healthz/$"]
    SECURE_HSTS_SECONDS = int(os.environ.get("SECURE_HSTS_SECONDS", "31536000"))
    SECURE_HSTS_INCLUDE_SUBDOMAINS = env_bool("SECURE_HSTS_INCLUDE_SUBDOMAINS", True)
    SECURE_HSTS_PRELOAD = env_bool("SECURE_HSTS_PRELOAD", True)
    SESSION_COOKIE_SECURE = env_bool("SESSION_COOKIE_SECURE", True)
    CSRF_COOKIE_SECURE = env_bool("CSRF_COOKIE_SECURE", True)

# --- NRP chat ---------------------------------------------------------------
NRP_API_KEY = os.environ.get("NRP_API_KEY", "").strip()
NRP_GATEWAY_BASE_URL = os.environ.get("NRP_GATEWAY_BASE_URL", "https://llm.nrp-nautilus.io/").strip()
NRP_DEFAULT_MODEL = os.environ.get("NRP_DEFAULT_MODEL", "meta-llama/Meta-Llama-3.1-70B-Instruct").strip()

# --- Logging ----------------------------------------------------------------
# Audit trail: every authenticated mutating request is logged with user + path.
LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "audit": {"format": "[%(asctime)s] %(name)s %(levelname)s %(message)s"},
    },
    "handlers": {
        "console": {"class": "logging.StreamHandler", "formatter": "audit"},
    },
    "loggers": {
        "audit": {"handlers": ["console"], "level": "INFO", "propagate": False},
        "chat": {"handlers": ["console"], "level": "INFO", "propagate": False},
    },
    "root": {"handlers": ["console"], "level": "WARNING"},
}
