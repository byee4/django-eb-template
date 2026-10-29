#!/usr/bin/env bash
# One-click deploy. Usage: scripts/deploy.sh {test|prod}
#
# Builds/pushes image to ECR, runs migrations against the target RDS,
# packages Dockerrun.aws.json + .ebextensions, uploads as an EB application version.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TARGET="${1:-}"
if [[ "$TARGET" != "test" && "$TARGET" != "prod" ]]; then
  echo "Usage: $0 {test|prod}" >&2
  exit 2
fi

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Run scripts/one_time_setup.sh first." >&2
  exit 2
fi
set -a
# shellcheck disable=SC1091
source .env
set +a

for cmd in aws docker zip unzip python3 curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 2; }
done
docker info >/dev/null 2>&1 || { echo "Docker daemon not reachable. Start Docker Desktop." >&2; exit 2; }

: "${AWS_REGION:=us-west-2}"
: "${EB_APP_NAME:=django-template-app}"
EB_ENV="$(if [[ "$TARGET" == "test" ]]; then echo "${EB_ENV_TEST:-django-template-test}"; else echo "${EB_ENV_PROD:-django-template-prod}"; fi)"
: "${ECR_REPO_NAME:=$EB_APP_NAME}"
: "${RDS_INSTANCE_ID:=django-template-db}"

ECR_URI="$(aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" --query 'repositories[0].repositoryUri' --output text)"
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d-%H%M%S)}"
VERSION_LABEL="${VERSION_LABEL:-app-${IMAGE_TAG}}"

echo "Target environment: $EB_ENV"
read -r -p "Deploy commit $(git rev-parse --short HEAD 2>/dev/null || echo unknown) to $EB_ENV? [y/N] " reply
[[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo "[1/5] ECR login"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "${ECR_URI%/*}"

echo "[2/5] Build + push $ECR_URI:$IMAGE_TAG"
# EB runs x86_64 (t3) instances; without --platform, Apple Silicon builds arm64 images.
docker build --platform linux/amd64 -t "$ECR_URI:$IMAGE_TAG" .
docker push "$ECR_URI:$IMAGE_TAG"

echo "[3/5] Run migrations against $EB_ENV's RDS"
DATABASE_URL="$(aws elasticbeanstalk describe-configuration-settings \
  --region "$AWS_REGION" \
  --application-name "$EB_APP_NAME" \
  --environment-name "$EB_ENV" \
  --query "ConfigurationSettings[0].OptionSettings[?Namespace=='aws:elasticbeanstalk:application:environment' && OptionName=='DATABASE_URL'].Value | [0]" \
  --output text)"
if [[ "$DATABASE_URL" == "None" || -z "$DATABASE_URL" ]]; then
  echo "ERROR: DATABASE_URL not set on $EB_ENV." >&2
  exit 2
fi
# migrate runs from this machine. one_time_setup.sh's RDS security group only admits the
# VPC and the IP you ran setup from, so check this machine's current IP is allowed.
RDS_SG_ID="$(aws rds describe-db-instances --region "$AWS_REGION" --db-instance-identifier "$RDS_INSTANCE_ID" \
  --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text)"
MY_IP="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
if [[ "$(aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$RDS_SG_ID" \
  --filters "Name=ip-permission.cidr,Values=$MY_IP/32" --query 'length(SecurityGroups)' --output text)" == "0" ]]; then
  echo "This machine's IP ($MY_IP) is not allowed into $RDS_INSTANCE_ID's security group ($RDS_SG_ID)."
  read -r -p "Allow $MY_IP/32 on port 5432 now? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted: migrate cannot reach RDS from here." >&2; exit 2; }
  aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$RDS_SG_ID" \
    --protocol tcp --port 5432 --cidr "$MY_IP/32" >/dev/null
fi
if [[ ! -x .deploy-venv/bin/python ]]; then
  python3 -m venv .deploy-venv
  .deploy-venv/bin/pip install --upgrade pip >/dev/null
  .deploy-venv/bin/pip install -r requirements.txt >/dev/null
fi
DATABASE_URL="$DATABASE_URL" DJANGO_DEBUG=False .deploy-venv/bin/python manage.py migrate --noinput

echo "[4/5] Package application version"
PACKAGE_DIR="$(mktemp -d)"
PACKAGE_PATH="$(mktemp -t deploy-XXXXXX.zip)"
rm -f "$PACKAGE_PATH"
cat > "$PACKAGE_DIR/Dockerrun.aws.json" <<JSON
{
  "AWSEBDockerrunVersion": "1",
  "Image": { "Name": "$ECR_URI:$IMAGE_TAG", "Update": "true" },
  "Ports": [ { "ContainerPort": 8000, "HostPort": 80 } ],
  "Logging": "/var/log/django-template"
}
JSON
cp -R .ebextensions "$PACKAGE_DIR/.ebextensions"
[[ -d .platform ]] && cp -R .platform "$PACKAGE_DIR/.platform"
( cd "$PACKAGE_DIR" && zip -qr "$PACKAGE_PATH" . )
unzip -t "$PACKAGE_PATH" >/dev/null

echo "[5/5] Upload + deploy version $VERSION_LABEL"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
S3_BUCKET="${AWS_EB_BUCKET:-elasticbeanstalk-${AWS_REGION}-${AWS_ACCOUNT_ID}}"
S3_KEY="application-versions/${EB_APP_NAME}/${VERSION_LABEL}.zip"
aws s3 cp "$PACKAGE_PATH" "s3://${S3_BUCKET}/${S3_KEY}" >/dev/null
aws elasticbeanstalk create-application-version \
  --region "$AWS_REGION" \
  --application-name "$EB_APP_NAME" \
  --version-label "$VERSION_LABEL" \
  --source-bundle "S3Bucket=${S3_BUCKET},S3Key=${S3_KEY}" >/dev/null
aws elasticbeanstalk update-environment \
  --region "$AWS_REGION" \
  --application-name "$EB_APP_NAME" \
  --environment-name "$EB_ENV" \
  --version-label "$VERSION_LABEL" >/dev/null
aws elasticbeanstalk wait environment-updated \
  --region "$AWS_REGION" \
  --application-name "$EB_APP_NAME" \
  --environment-names "$EB_ENV"

rm -rf "$PACKAGE_DIR" "$PACKAGE_PATH"
echo "Deploy complete: $EB_ENV @ $VERSION_LABEL"
