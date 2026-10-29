#!/usr/bin/env bash
# One-time setup for a project generated from django-template.
#
# Reads .env. For each step (GitHub repo, ECR, RDS, EB app, EB test env, EB prod env,
# EB env vars), prints what it will do and prompts [y/N] before executing.
#
# Idempotent: every step checks whether the resource already exists.
# Refuses to run if .env contains placeholder strings.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Copy .env.example to .env and fill in values first." >&2
  exit 2
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 2; }
}
for cmd in aws eb gh python3 git curl; do require_cmd "$cmd"; done

refuse_placeholders() {
  local placeholders=(
    "REPLACE_ME_GENERATE_LOCAL_KEY"
  )
  for p in "${placeholders[@]}"; do
    if grep -qF "$p" .env; then
      echo "ERROR: .env still contains placeholder '$p'. Fill in real values first." >&2
      exit 2
    fi
  done
}
refuse_placeholders

confirm() {
  local prompt="$1"
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

step() {
  echo
  echo "===== $1 ====="
}

# Defaults pulled from .env, with safe fallbacks.
: "${AWS_REGION:=us-west-2}"
: "${EB_APP_NAME:=django-template-app}"
: "${EB_ENV_TEST:=django-template-test}"
: "${EB_ENV_PROD:=django-template-prod}"
: "${ECR_REPO_NAME:=$EB_APP_NAME}"
: "${RDS_INSTANCE_ID:=django-template-db}"
: "${RDS_DB_NAME:=django_template}"
: "${RDS_MASTER_USERNAME:=djangoapp}"
: "${RDS_INSTANCE_CLASS:=db.t3.micro}"
: "${RDS_ALLOCATED_STORAGE:=20}"
EB_PLATFORM="Docker running on 64bit Amazon Linux 2023"

# -----------------------------------------------------------------------------
# Step 1: GitHub repo
# -----------------------------------------------------------------------------

step "1/6 GitHub repository"
if [[ -z "${GH_REPO_NAME:-}" ]]; then
  echo "GH_REPO_NAME is empty in .env — skipping GitHub setup."
else
  GH_OWNER="$(gh api user --jq .login)"
  GH_FULL="$GH_OWNER/$GH_REPO_NAME"
  if gh repo view "$GH_FULL" >/dev/null 2>&1; then
    echo "Repo $GH_FULL already exists. Skipping create."
  else
    echo "Will create private GitHub repo: $GH_FULL"
    if confirm "Create it now?"; then
      gh repo create "$GH_FULL" --private --source=. --remote=origin --push=false
    fi
  fi
fi

# -----------------------------------------------------------------------------
# Step 2: AWS identity check
# -----------------------------------------------------------------------------

step "2/6 AWS identity"
aws sts get-caller-identity --region "$AWS_REGION" --output table

# -----------------------------------------------------------------------------
# Step 3: ECR repo
# -----------------------------------------------------------------------------

step "3/6 ECR repository: $ECR_REPO_NAME"
if aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "ECR repo $ECR_REPO_NAME already exists."
else
  echo "Will create ECR repo: $ECR_REPO_NAME"
  if confirm "Create it now?"; then
    aws ecr create-repository --repository-name "$ECR_REPO_NAME" --region "$AWS_REGION" >/dev/null
  fi
fi
# shellcheck disable=SC2034  # unused; kept as-is
ECR_URI="$(aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" --query 'repositories[0].repositoryUri' --output text 2>/dev/null || echo "")"

# -----------------------------------------------------------------------------
# Step 4: RDS PostgreSQL
# -----------------------------------------------------------------------------

step "4/6 RDS PostgreSQL: $RDS_INSTANCE_ID"
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
    if [[ -z "${RDS_MASTER_PASSWORD:-}" ]]; then
      RDS_MASTER_PASSWORD="$(python3 -c "import secrets,string; a=string.ascii_letters+string.digits+'_+-'; print('AppDB-'+''.join(secrets.choice(a) for _ in range(32)))")"
      echo "Generated RDS_MASTER_PASSWORD. Saving to .env."
      if grep -q '^RDS_MASTER_PASSWORD=' .env; then
        python3 -c "
import re,sys
p=open('.env').read()
p=re.sub(r'^RDS_MASTER_PASSWORD=.*$', 'RDS_MASTER_PASSWORD=$RDS_MASTER_PASSWORD', p, flags=re.M)
open('.env','w').write(p)
"
      else
        echo "RDS_MASTER_PASSWORD=$RDS_MASTER_PASSWORD" >> .env
      fi
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
RDS_ENDPOINT="$(aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" --region "$AWS_REGION" --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || echo "")"
RDS_PORT="$(aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" --region "$AWS_REGION" --query 'DBInstances[0].Endpoint.Port' --output text 2>/dev/null || echo "5432")"
if [[ -n "$RDS_ENDPOINT" && -n "${RDS_MASTER_PASSWORD:-}" ]]; then
  DATABASE_URL="postgresql://${RDS_MASTER_USERNAME}:${RDS_MASTER_PASSWORD}@${RDS_ENDPOINT}:${RDS_PORT}/${RDS_DB_NAME}"
else
  DATABASE_URL=""
fi

# -----------------------------------------------------------------------------
# Step 5: Elastic Beanstalk app + two environments
# -----------------------------------------------------------------------------

step "5/6 Elastic Beanstalk app: $EB_APP_NAME (envs: $EB_ENV_TEST, $EB_ENV_PROD)"
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

create_env_if_missing() {
  local env_name="$1"
  local count
  count="$(aws elasticbeanstalk describe-environments \
    --application-name "$EB_APP_NAME" \
    --environment-names "$env_name" \
    --region "$AWS_REGION" \
    --query "length(Environments[?Status!='Terminated'])" \
    --output text)"
  if [[ "$count" == "0" ]]; then
    echo "Will create EB environment: $env_name"
    if confirm "Create it now? (takes ~5 minutes)"; then
      sync_eb_config
      eb create "$env_name" \
        --region "$AWS_REGION" \
        --instance_type t3.small \
        --elb-type application \
        --platform "$EB_PLATFORM"
    fi
  else
    echo "EB env $env_name already exists."
  fi
}
create_env_if_missing "$EB_ENV_TEST"
create_env_if_missing "$EB_ENV_PROD"

# -----------------------------------------------------------------------------
# Step 6: Push EB env vars to both environments
# -----------------------------------------------------------------------------

step "6/6 EB environment variables"
if [[ -z "$DATABASE_URL" ]]; then
  echo "DATABASE_URL not derivable yet (RDS still provisioning?). Skipping env var push."
else
  if [[ -z "${DJANGO_SECRET_KEY:-}" || "$DJANGO_SECRET_KEY" == *REPLACE* ]]; then
    DJANGO_SECRET_KEY="$(python3 -c "import secrets; print(secrets.token_urlsafe(50))")"
    echo "Generated DJANGO_SECRET_KEY (not persisted to .env to avoid local/prod drift)."
  fi
  push_env_vars() {
    local env_name="$1"
    local cname
    cname="$(aws elasticbeanstalk describe-environments \
      --application-name "$EB_APP_NAME" \
      --environment-names "$env_name" \
      --region "$AWS_REGION" \
      --query "Environments[?Status!='Terminated'] | [0].CNAME" --output text)"
    if [[ "$cname" == "None" || -z "$cname" ]]; then
      echo "No CNAME for $env_name yet; skipping."
      return
    fi
    echo "Will push env vars to $env_name (CNAME: $cname)"
    if ! confirm "Push now?"; then return; fi
    aws elasticbeanstalk update-environment \
      --region "$AWS_REGION" \
      --application-name "$EB_APP_NAME" \
      --environment-name "$env_name" \
      --option-settings \
        "Namespace=aws:elasticbeanstalk:application:environment,OptionName=DATABASE_URL,Value=$DATABASE_URL" \
        "Namespace=aws:elasticbeanstalk:application:environment,OptionName=DJANGO_SECRET_KEY,Value=$DJANGO_SECRET_KEY" \
        "Namespace=aws:elasticbeanstalk:application:environment,OptionName=DJANGO_DEBUG,Value=False" \
        "Namespace=aws:elasticbeanstalk:application:environment,OptionName=DJANGO_ALLOWED_HOSTS,Value=$cname" \
        "Namespace=aws:elasticbeanstalk:application:environment,OptionName=CSRF_TRUSTED_ORIGINS,Value=https://$cname,http://$cname" \
        "Namespace=aws:elasticbeanstalk:application:environment,OptionName=SOCIAL_AUTH_REDIRECT_IS_HTTPS,Value=True" \
        "Namespace=aws:elasticbeanstalk:application:environment,OptionName=SOCIAL_AUTH_GLOBUS_REDIRECT_URI,Value=https://$cname/complete/globus/" \
        "Namespace=aws:elasticbeanstalk:application:environment,OptionName=GLOBUS_CLIENT_ID,Value=${GLOBUS_CLIENT_ID:-}" \
        "Namespace=aws:elasticbeanstalk:application:environment,OptionName=GLOBUS_CLIENT_SECRET,Value=${GLOBUS_CLIENT_SECRET:-}" \
        "Namespace=aws:elasticbeanstalk:application:environment,OptionName=GLOBUS_ALLOWED_IDENTITIES,Value=${GLOBUS_ALLOWED_IDENTITIES:-}" \
        "Namespace=aws:elasticbeanstalk:application:environment,OptionName=GLOBUS_ALLOWED_GROUP,Value=${GLOBUS_ALLOWED_GROUP:-}" \
        "Namespace=aws:elasticbeanstalk:application:environment,OptionName=NRP_API_KEY,Value=${NRP_API_KEY:-}" \
        "Namespace=aws:elasticbeanstalk:application:environment,OptionName=NRP_GATEWAY_BASE_URL,Value=${NRP_GATEWAY_BASE_URL:-https://llm.nrp-nautilus.io/}" \
        "Namespace=aws:elasticbeanstalk:application:environment,OptionName=NRP_DEFAULT_MODEL,Value=${NRP_DEFAULT_MODEL:-meta-llama/Meta-Llama-3.1-70B-Instruct}" \
      >/dev/null
  }
  push_env_vars "$EB_ENV_TEST"
  push_env_vars "$EB_ENV_PROD"
fi

echo
echo "Setup done. Next steps:"
echo "  1. Register Globus callback URLs (see docs/globus_setup.md) for each EB CNAME."
echo "  2. Deploy:  scripts/deploy.sh test       # or: scripts/deploy.sh prod"
echo "  3. Git push: git add . && git commit -m 'initial' && git push -u origin main"
