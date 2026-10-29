#!/usr/bin/env bash
# Shared by scripts/one_time_setup.sh and scripts/deploy.sh. Source it with the target as $1:
#   source scripts/lib/aws_env.sh "$1"
# Selects test or prod (no default, so nothing touches AWS by accident), loads .env, and derives
# per-environment names. Test and prod never share an RDS instance or an ECR repository.
# shellcheck shell=bash

TARGET="${1:-}"
case "$TARGET" in
  test|prod) ;;
  *) echo "Usage: $0 {test|prod}" >&2; exit 2 ;;
esac

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Copy .env.example to .env and fill it in first." >&2
  exit 2
fi
set -a
# shellcheck disable=SC1091
source .env
set +a

ENV_UPPER="$(printf '%s' "$TARGET" | tr '[:lower:]' '[:upper:]')"

# Value of NAME_TEST or NAME_PROD from .env, for the selected target.
env_value() {
  local name="${1}_${ENV_UPPER}"
  printf '%s' "${!name:-}"
}

: "${PROJECT_SLUG:=django-template}"
: "${AWS_REGION:=us-west-2}"
: "${EB_APP_NAME:=$PROJECT_SLUG}"
: "${RDS_MASTER_USERNAME:=djangoapp}"
EB_ENV="$(env_value EB_ENV)"
EB_ENV="${EB_ENV:-${PROJECT_SLUG}-${TARGET}}"
ECR_REPO_NAME="${PROJECT_SLUG}-${TARGET}"
RDS_INSTANCE_ID="${PROJECT_SLUG}-${TARGET}-db"
RDS_DB_NAME="$(printf '%s' "$PROJECT_SLUG" | tr '-' '_')_${TARGET}"
RDS_MASTER_PASSWORD="$(env_value RDS_MASTER_PASSWORD)"
CUSTOM_DOMAIN="$(env_value CUSTOM_DOMAIN)"
EB_SINGLE_INSTANCE="$(env_value EB_SINGLE_INSTANCE)"
if [[ -z "$EB_SINGLE_INSTANCE" ]]; then
  # Test defaults to one instance (no load balancer); prod defaults to load-balanced.
  if [[ "$TARGET" == "test" ]]; then EB_SINGLE_INSTANCE=true; else EB_SINGLE_INSTANCE=false; fi
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 2; }
}

confirm() {
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# Read one of the EB environment's application variables (empty if unset or no env yet).
eb_env_var() {
  local value
  value="$(aws elasticbeanstalk describe-configuration-settings \
    --region "$AWS_REGION" \
    --application-name "$EB_APP_NAME" \
    --environment-name "$EB_ENV" \
    --query "ConfigurationSettings[0].OptionSettings[?Namespace=='aws:elasticbeanstalk:application:environment' && OptionName=='$1'].Value | [0]" \
    --output text 2>/dev/null || true)"
  [[ "$value" == "None" ]] && value=""
  printf '%s' "$value"
}
