"""Production settings fail closed, and HTTPS detection works behind CloudFront."""

import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def load_settings(**env):
    """Import config.settings in a fresh interpreter with only the given environment."""
    clean = {k: v for k, v in os.environ.items() if not k.startswith(("DJANGO_", "SECURE_"))}
    return subprocess.run(
        [sys.executable, "-c", "import config.settings"],
        cwd=ROOT,
        env={**clean, "DJANGO_SETTINGS_MODULE": "config.settings", **env},
        capture_output=True,
        text=True,
        check=False,
    )


@pytest.mark.parametrize(
    ("env", "message"),
    [
        # Passed explicitly: a generated project's .env would otherwise supply a real key.
        (
            {"DJANGO_DEBUG": "False", "DJANGO_SECRET_KEY": "django-insecure-local-template-key-change-me"},
            "DJANGO_SECRET_KEY must be set",
        ),
        (
            {"DJANGO_DEBUG": "False", "DJANGO_SECRET_KEY": "x" * 50, "DJANGO_ALLOWED_HOSTS": "*"},
            "must not include '*'",
        ),
    ],
)
def test_production_refuses_unsafe_settings(env, message):
    result = load_settings(**env)
    assert result.returncode != 0
    assert message in result.stderr


def test_production_starts_with_real_settings():
    result = load_settings(
        DJANGO_DEBUG="False", DJANGO_SECRET_KEY="x" * 50, DJANGO_ALLOWED_HOSTS="example.org"
    )
    assert result.returncode == 0, result.stderr


def test_globus_allowlist_has_no_built_in_ids():
    """A public template must not let the template author into every project made from it."""
    clean = {k: v for k, v in os.environ.items() if not k.startswith("GLOBUS_ALLOWED")}
    code = (
        "import dotenv; dotenv.load_dotenv = lambda *a, **k: None\n"  # ignore a project's .env
        "import config.settings as s; print(s.GLOBUS_ALLOWED_IDENTITIES, repr(s.GLOBUS_ALLOWED_GROUP))"
    )
    result = subprocess.run(
        [sys.executable, "-c", code], cwd=ROOT, env=clean, capture_output=True, text=True, check=True
    )
    assert result.stdout.strip() == "[] ''"


def test_cloudfront_proto_header_marks_request_secure(rf, settings):
    settings.SECURE_PROXY_SSL_HEADER = ("HTTP_CLOUDFRONT_FORWARDED_PROTO", "https")
    request = rf.get("/", HTTP_CLOUDFRONT_FORWARDED_PROTO="https", HTTP_X_FORWARDED_PROTO="http")
    assert request.is_secure()


def test_default_file_storage_is_configured(settings):
    assert "default" in settings.STORAGES
