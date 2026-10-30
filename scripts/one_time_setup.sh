#!/usr/bin/env bash
# One-time AWS setup for ONE environment:  scripts/one_time_setup.sh {test|prod}
#
# Reads .env. For each step (ECR, RDS, EB app + environment, HTTPS, environment variables),
# prints what it will do and prompts [y/N] before creating anything.
#
# - Test and prod get separate ECR repositories and RDS instances (names in scripts/lib/aws_env.sh).
# - HTTPS: with CUSTOM_DOMAIN_<ENV> set, an ACM certificate on the load balancer; otherwise a
#   CloudFront distribution, which gives HTTPS on a default *.cloudfront.net address (AWS will not
#   issue certificates for *.elasticbeanstalk.com names).
# - Idempotent: every step checks whether the resource already exists. Rerun after a partial run,
#   or to refresh environment variables after editing .env.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=scripts/lib/aws_env.sh
source scripts/lib/aws_env.sh "${1:-}"

for cmd in aws eb python3 curl; do require_cmd "$cmd"; done

if grep -qF "REPLACE_ME_GENERATE_LOCAL_KEY" .env; then
  echo "ERROR: .env still contains placeholder 'REPLACE_ME_GENERATE_LOCAL_KEY'. Fill in real values first." >&2
  exit 2
fi

: "${RDS_INSTANCE_CLASS:=db.t3.micro}"
: "${RDS_ALLOCATED_STORAGE:=20}"
: "${EB_INSTANCE_TYPE:=t3.small}"
EB_PLATFORM="Docker running on 64bit Amazon Linux 2023"

step() {
  echo
  echo "===== $1 ====="
}

# Write NAME=value into .env, replacing an existing line.
save_to_env() {
  python3 - "$1" "$2" <<'PY'
import re
import sys

name, value = sys.argv[1:3]
path = ".env"
text = open(path).read()
line = f"{name}={value}"
if re.search(rf"^{re.escape(name)}=", text, flags=re.M):
    text = re.sub(rf"^{re.escape(name)}=.*$", lambda _m: line, text, flags=re.M)
else:
    text = text.rstrip("\n") + "\n" + line + "\n"
open(path, "w").write(text)
PY
}

echo "Target: $TARGET  (EB app $EB_APP_NAME, environment $EB_ENV, region $AWS_REGION)"

# -----------------------------------------------------------------------------
step "1/6 AWS identity"
# -----------------------------------------------------------------------------
aws sts get-caller-identity --region "$AWS_REGION" --output table

# -----------------------------------------------------------------------------
step "2/6 ECR repository: $ECR_REPO_NAME"
# -----------------------------------------------------------------------------
if aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "ECR repo $ECR_REPO_NAME already exists."
else
  echo "Will create ECR repo: $ECR_REPO_NAME"
  if confirm "Create it now?"; then
    aws ecr create-repository --repository-name "$ECR_REPO_NAME" --region "$AWS_REGION" >/dev/null
  fi
fi

# -----------------------------------------------------------------------------
step "3/6 RDS PostgreSQL: $RDS_INSTANCE_ID"
# -----------------------------------------------------------------------------
if aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "RDS instance $RDS_INSTANCE_ID already exists."
else
  # The instance gets a public endpoint (so scripts/deploy.sh can run `migrate` from this
  # machine), but its security group only admits port 5432 from the default VPC (the EB
  # instances) and from this machine's current public IP. deploy.sh offers to add your new
  # IP if it changes.
  VPC_ID="$(aws ec2 describe-vpcs --region "$AWS_REGION" --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)"
  if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
    echo "ERROR: no default VPC in $AWS_REGION. Create one (aws ec2 create-default-vpc) and rerun." >&2
    exit 2
  fi
  VPC_CIDR="$(aws ec2 describe-vpcs --region "$AWS_REGION" --vpc-ids "$VPC_ID" --query 'Vpcs[0].CidrBlock' --output text)"
  MY_IP="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
  RDS_SG_NAME="${RDS_INSTANCE_ID}-sg"
  echo "Will create RDS PostgreSQL instance: $RDS_INSTANCE_ID ($RDS_INSTANCE_CLASS, ${RDS_ALLOCATED_STORAGE}GB, database $RDS_DB_NAME)"
  echo "  security group $RDS_SG_NAME: port 5432 from $VPC_CIDR (EB instances) and $MY_IP/32 (this machine) only"
  if confirm "Create it now? (takes ~10 minutes)"; then
    if [[ -z "$RDS_MASTER_PASSWORD" ]]; then
      RDS_MASTER_PASSWORD="$(python3 -c "import secrets,string; a=string.ascii_letters+string.digits+'_+-'; print('AppDB-'+''.join(secrets.choice(a) for _ in range(32)))")"
      save_to_env "RDS_MASTER_PASSWORD_${ENV_UPPER}" "$RDS_MASTER_PASSWORD"
      echo "Generated RDS_MASTER_PASSWORD_${ENV_UPPER} and saved it to .env."
    fi
    RDS_SG_ID="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$RDS_SG_NAME" \
      --query 'SecurityGroups[0].GroupId' --output text)"
    if [[ "$RDS_SG_ID" == "None" || -z "$RDS_SG_ID" ]]; then
      RDS_SG_ID="$(aws ec2 create-security-group --region "$AWS_REGION" --vpc-id "$VPC_ID" \
        --group-name "$RDS_SG_NAME" --description "PostgreSQL access for $RDS_INSTANCE_ID" \
        --query GroupId --output text)"
      for cidr in "$VPC_CIDR" "$MY_IP/32"; do
        aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$RDS_SG_ID" \
          --protocol tcp --port 5432 --cidr "$cidr" >/dev/null
      done
    fi
    aws rds create-db-instance \
      --region "$AWS_REGION" \
      --db-instance-identifier "$RDS_INSTANCE_ID" \
      --db-instance-class "$RDS_INSTANCE_CLASS" \
      --engine postgres --engine-version 16 \
      --db-name "$RDS_DB_NAME" \
      --master-username "$RDS_MASTER_USERNAME" \
      --master-user-password "$RDS_MASTER_PASSWORD" \
      --allocated-storage "$RDS_ALLOCATED_STORAGE" \
      --storage-type gp3 --backup-retention-period 7 \
      --vpc-security-group-ids "$RDS_SG_ID" \
      --publicly-accessible >/dev/null
    aws rds wait db-instance-available --db-instance-identifier "$RDS_INSTANCE_ID" --region "$AWS_REGION"
  fi
fi

# -----------------------------------------------------------------------------
step "4/6 Elastic Beanstalk: app $EB_APP_NAME, environment $EB_ENV"
# -----------------------------------------------------------------------------
if [[ "$(aws elasticbeanstalk describe-applications --application-names "$EB_APP_NAME" --region "$AWS_REGION" --query 'length(Applications)' --output text)" == "0" ]]; then
  echo "Will create EB application: $EB_APP_NAME"
  if confirm "Create it now?"; then
    aws elasticbeanstalk create-application --application-name "$EB_APP_NAME" --region "$AWS_REGION" >/dev/null
  fi
fi

# `eb create` takes the application name from .elasticbeanstalk/config.yml, not a flag,
# so write .env's EB_APP_NAME / AWS_REGION / platform into it first.
sync_eb_config() {
  python3 - "$EB_APP_NAME" "$AWS_REGION" "$EB_PLATFORM" <<'PY'
import re, sys
values = dict(zip(("application_name", "default_region", "default_platform"), sys.argv[1:]))
path = ".elasticbeanstalk/config.yml"
text = open(path).read()
for key, value in values.items():
    text = re.sub(rf"^(  {key}:).*$", lambda m, v=value: f"{m.group(1)} {v}", text, flags=re.M)
open(path, "w").write(text)
PY
}

env_count="$(aws elasticbeanstalk describe-environments \
  --application-name "$EB_APP_NAME" \
  --environment-names "$EB_ENV" \
  --region "$AWS_REGION" \
  --query "length(Environments[?Status!='Terminated'])" \
  --output text)"
if [[ "$env_count" == "0" ]]; then
  if [[ "$EB_SINGLE_INSTANCE" == "true" ]]; then shape="single $EB_INSTANCE_TYPE instance"; else shape="load-balanced $EB_INSTANCE_TYPE"; fi
  echo "Will create EB environment: $EB_ENV ($shape)"
  if confirm "Create it now? (takes ~5 minutes)"; then
    sync_eb_config
    create_cmd=(eb create "$EB_ENV" --region "$AWS_REGION" --instance_type "$EB_INSTANCE_TYPE" --platform "$EB_PLATFORM")
    if [[ "$EB_SINGLE_INSTANCE" == "true" ]]; then create_cmd+=(--single); else create_cmd+=(--elb-type application); fi
    "${create_cmd[@]}"
  fi
else
  echo "EB env $EB_ENV already exists."
fi

EB_CNAME="$(aws elasticbeanstalk describe-environments \
  --application-name "$EB_APP_NAME" \
  --environment-names "$EB_ENV" \
  --region "$AWS_REGION" \
  --query "Environments[?Status!='Terminated'] | [0].CNAME" --output text)"
if [[ "$EB_CNAME" == "None" || -z "$EB_CNAME" ]]; then
  echo "No CNAME for $EB_ENV yet; rerun this script once the environment exists."
  exit 0
fi

# -----------------------------------------------------------------------------
step "5/6 HTTPS"
# -----------------------------------------------------------------------------
PUBLIC_HOST=""
USE_CLOUDFRONT=false
if [[ -n "$CUSTOM_DOMAIN" ]]; then
  if [[ "$EB_SINGLE_INSTANCE" == "true" ]]; then
    echo "ERROR: CUSTOM_DOMAIN_${ENV_UPPER} needs a load-balanced environment for its certificate." >&2
    echo "Set EB_SINGLE_INSTANCE_${ENV_UPPER}=false (a new environment), or clear the domain to use CloudFront." >&2
    exit 2
  fi
  PUBLIC_HOST="$CUSTOM_DOMAIN"
  CERT_ARN="$(aws acm list-certificates --region "$AWS_REGION" \
    --certificate-statuses PENDING_VALIDATION ISSUED \
    --query "CertificateSummaryList[?DomainName=='${CUSTOM_DOMAIN}'].CertificateArn | [0]" --output text)"
  if [[ "$CERT_ARN" == "None" || -z "$CERT_ARN" ]]; then
    echo "Will request an ACM certificate for $CUSTOM_DOMAIN (DNS validation)."
    if confirm "Request it now?"; then
      CERT_ARN="$(aws acm request-certificate --region "$AWS_REGION" --domain-name "$CUSTOM_DOMAIN" \
        --validation-method DNS --query CertificateArn --output text)"
      sleep 10  # the validation record takes a moment to appear
    fi
  fi
  if [[ -n "$CERT_ARN" && "$CERT_ARN" != "None" ]]; then
    CERT_STATUS="$(aws acm describe-certificate --region "$AWS_REGION" --certificate-arn "$CERT_ARN" --query 'Certificate.Status' --output text)"
    if [[ "$CERT_STATUS" != "ISSUED" ]]; then
      RECORD="$(aws acm describe-certificate --region "$AWS_REGION" --certificate-arn "$CERT_ARN" \
        --query 'Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Type,Value]' --output text)"
      read -r REC_NAME REC_TYPE REC_VALUE <<<"$RECORD"
      if [[ -n "${ROUTE53_ZONE_NAME:-}" ]]; then
        ZONE_ID="$(aws route53 list-hosted-zones-by-name --dns-name "$ROUTE53_ZONE_NAME" \
          --query "HostedZones[?Name=='${ROUTE53_ZONE_NAME%.}.'].Id | [0]" --output text)"
        ZONE_ID="${ZONE_ID#/hostedzone/}"
        echo "Will add the validation record to Route 53 zone $ROUTE53_ZONE_NAME: $REC_NAME $REC_TYPE $REC_VALUE"
        if [[ "$ZONE_ID" != "None" && -n "$ZONE_ID" ]] && confirm "Add it now?"; then
          aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch \
            "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$REC_NAME\",\"Type\":\"$REC_TYPE\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"$REC_VALUE\"}]}}]}" >/dev/null
        fi
      else
        echo "Add this DNS record at your DNS provider to validate the certificate:"
        echo "  $REC_NAME $REC_TYPE $REC_VALUE"
      fi
      echo "Certificate is $CERT_STATUS. Rerun this script once it is ISSUED to attach it."
    else
      echo "Will attach certificate $CERT_ARN to $EB_ENV's load balancer (HTTPS on port 443)."
      if confirm "Attach it now?"; then
        aws elasticbeanstalk update-environment --region "$AWS_REGION" \
          --application-name "$EB_APP_NAME" --environment-name "$EB_ENV" \
          --option-settings \
            Namespace=aws:elbv2:listener:443,OptionName=ListenerEnabled,Value=true \
            Namespace=aws:elbv2:listener:443,OptionName=Protocol,Value=HTTPS \
            Namespace=aws:elbv2:listener:443,OptionName=SSLCertificateArns,Value="$CERT_ARN" >/dev/null
        aws elasticbeanstalk wait environment-updated --region "$AWS_REGION" \
          --application-name "$EB_APP_NAME" --environment-names "$EB_ENV" ||
          echo "WARNING: timed out waiting for the update; check EB events, it may still complete."
      fi
      echo "Point $CUSTOM_DOMAIN at the environment: a CNAME (or Route 53 alias) to $EB_CNAME."
    fi
  fi
else
  USE_CLOUDFRONT=true
  CLOUDFRONT_COMMENT="${EB_APP_NAME}/${EB_ENV}"
  CLOUDFRONT_ID="$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Comment=='${CLOUDFRONT_COMMENT}'].Id | [0]" --output text)"
  if [[ "$CLOUDFRONT_ID" == "None" || -z "$CLOUDFRONT_ID" ]]; then
    echo "No CUSTOM_DOMAIN_${ENV_UPPER}: will create a CloudFront distribution in front of $EB_CNAME"
    echo "  (HTTPS on a default *.cloudfront.net address; caching disabled, so every request reaches Django)."
    if confirm "Create it now?"; then
      CLOUDFRONT_CONFIG="$(mktemp)"
      python3 - "$CLOUDFRONT_CONFIG" "$EB_CNAME" "$CLOUDFRONT_COMMENT" <<'PY'
import json
import sys
import time

path, origin, comment = sys.argv[1:4]
methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
config = {
    "CallerReference": f"{comment}-{int(time.time())}",
    "Comment": comment,
    "Enabled": True,
    "PriceClass": "PriceClass_100",
    "Origins": {
        "Quantity": 1,
        "Items": [{
            "Id": "eb",
            "DomainName": origin,
            "CustomOriginConfig": {
                "HTTPPort": 80,
                "HTTPSPort": 443,
                "OriginProtocolPolicy": "http-only",
                "OriginReadTimeout": 60,
            },
        }],
    },
    "DefaultCacheBehavior": {
        "TargetOriginId": "eb",
        "ViewerProtocolPolicy": "redirect-to-https",
        "AllowedMethods": {
            "Quantity": len(methods),
            "Items": methods,
            "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]},
        },
        "Compress": True,
        # Managed CachingDisabled and AllViewerAndCloudFrontHeaders-2022-06 policies:
        # every request reaches Django with its Host, cookies and CloudFront-Forwarded-Proto.
        "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
        "OriginRequestPolicyId": "33f36d7e-f396-46d9-90e0-52428a34d9dc",
    },
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(config, fh)
PY
      CLOUDFRONT_ID="$(aws cloudfront create-distribution \
        --distribution-config "file://$CLOUDFRONT_CONFIG" --query 'Distribution.Id' --output text)"
      rm -f "$CLOUDFRONT_CONFIG"
    fi
  else
    echo "CloudFront distribution $CLOUDFRONT_ID already exists."
  fi
  if [[ -n "$CLOUDFRONT_ID" && "$CLOUDFRONT_ID" != "None" ]]; then
    PUBLIC_HOST="$(aws cloudfront get-distribution --id "$CLOUDFRONT_ID" --query 'Distribution.DomainName' --output text)"
  fi
fi
if [[ -z "$PUBLIC_HOST" ]]; then
  echo "No HTTPS address yet; environment variables will use the bare EB address for now."
  PUBLIC_HOST="$EB_CNAME"
fi

# -----------------------------------------------------------------------------
step "6/6 EB environment variables for $EB_ENV"
# -----------------------------------------------------------------------------
RDS_ENDPOINT="$(aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" --region "$AWS_REGION" --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || echo "")"
RDS_PORT="$(aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" --region "$AWS_REGION" --query 'DBInstances[0].Endpoint.Port' --output text 2>/dev/null || echo "5432")"
DATABASE_URL="$(eb_env_var DATABASE_URL)"
if [[ -n "$RDS_ENDPOINT" && "$RDS_ENDPOINT" != "None" && -n "$RDS_MASTER_PASSWORD" ]]; then
  DATABASE_URL="postgresql://${RDS_MASTER_USERNAME}:${RDS_MASTER_PASSWORD}@${RDS_ENDPOINT}:${RDS_PORT}/${RDS_DB_NAME}"
fi
if [[ -z "$DATABASE_URL" ]]; then
  echo "DATABASE_URL not derivable yet (RDS still provisioning, or RDS_MASTER_PASSWORD_${ENV_UPPER} missing from .env). Skipping."
  exit 0
fi

# Keep the environment's existing secret key so a rerun does not sign everyone out.
DJANGO_SECRET_KEY="$(eb_env_var DJANGO_SECRET_KEY)"
if [[ -z "$DJANGO_SECRET_KEY" ]]; then
  DJANGO_SECRET_KEY="$(python3 -c "import secrets; print(secrets.token_urlsafe(50))")"
  echo "Generated a DJANGO_SECRET_KEY for $EB_ENV (stored only in EB, not in .env)."
fi

ALLOWED_HOSTS="$PUBLIC_HOST"
[[ "$PUBLIC_HOST" != "$EB_CNAME" ]] && ALLOWED_HOSTS="$PUBLIC_HOST,$EB_CNAME"
REDIRECT_URI="https://${PUBLIC_HOST}/complete/globus/"
env_pairs=(
  "DATABASE_URL=$DATABASE_URL"
  "DJANGO_SECRET_KEY=$DJANGO_SECRET_KEY"
  "DJANGO_DEBUG=False"
  "DJANGO_ALLOWED_HOSTS=$ALLOWED_HOSTS"
  "CSRF_TRUSTED_ORIGINS=https://$PUBLIC_HOST"
  "SOCIAL_AUTH_REDIRECT_IS_HTTPS=True"
  "SOCIAL_AUTH_GLOBUS_REDIRECT_URI=$REDIRECT_URI"
  "GLOBUS_CLIENT_ID=${GLOBUS_CLIENT_ID:-}"
  "GLOBUS_CLIENT_SECRET=${GLOBUS_CLIENT_SECRET:-}"
  "GLOBUS_ALLOWED_IDENTITIES=${GLOBUS_ALLOWED_IDENTITIES:-}"
  "GLOBUS_ALLOWED_GROUP=${GLOBUS_ALLOWED_GROUP:-}"
  "NRP_API_KEY=${NRP_API_KEY:-}"
  "NRP_GATEWAY_BASE_URL=${NRP_GATEWAY_BASE_URL:-https://llm.nrp-nautilus.io/}"
  "NRP_DEFAULT_MODEL=${NRP_DEFAULT_MODEL:-meta-llama/Meta-Llama-3.1-70B-Instruct}"
)
if [[ "$USE_CLOUDFRONT" == "true" ]]; then
  env_pairs+=("SECURE_PROXY_SSL_HEADER_NAME=HTTP_CLOUDFRONT_FORWARDED_PROTO")
fi

echo "Will push environment variables to $EB_ENV (public address https://$PUBLIC_HOST)"
if confirm "Push now?"; then
  # A JSON file, not CLI shorthand: values such as DJANGO_ALLOWED_HOSTS contain commas.
  OPTIONS_FILE="$(mktemp)"
  python3 - "$OPTIONS_FILE" "${env_pairs[@]}" <<'PY'
import json
import sys

path, *pairs = sys.argv[1:]
settings = []
for pair in pairs:
    key, value = pair.split("=", 1)
    settings.append({
        "Namespace": "aws:elasticbeanstalk:application:environment",
        "OptionName": key,
        "Value": value,
    })
with open(path, "w", encoding="utf-8") as fh:
    json.dump(settings, fh)
PY
  aws elasticbeanstalk update-environment --region "$AWS_REGION" \
    --application-name "$EB_APP_NAME" --environment-name "$EB_ENV" \
    --option-settings "file://$OPTIONS_FILE" >/dev/null
  rm -f "$OPTIONS_FILE"
  aws elasticbeanstalk wait environment-updated --region "$AWS_REGION" \
    --application-name "$EB_APP_NAME" --environment-names "$EB_ENV" ||
    echo "WARNING: timed out waiting for the update; check EB events, it may still complete."
fi

echo
echo "Setup done for $TARGET. Next steps:"
echo "  1. Add this redirect URI to your Globus app (docs/globus_setup.md):"
echo "       $REDIRECT_URI"
echo "  2. Deploy:  scripts/deploy.sh $TARGET"
echo "  3. Open:    https://$PUBLIC_HOST/  (a new CloudFront address takes several minutes to go live)"
