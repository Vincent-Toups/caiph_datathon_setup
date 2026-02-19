#!/usr/bin/env bash
set -euo pipefail

# One-click deploy script:
# - Zips and uploads the datathon_container build context to S3
# - Ensures env.txt exists and uploads it to S3
# - Generates minimal Terraform variables (overridable via env)
# - Runs teardown first by default (use --no-teardown to skip)
# - Runs terraform init/apply
# - Prints next steps and key outputs

# Configurable via environment variables:
#   INSTANCE_COUNT (default: 1)
#   INSTANCE_TYPE  (default: t3.medium)
#   DOMAIN_NAME    (default: from Terraform default)
#   SSH_KEY_NAME   (optional; if unset, auto-select first EC2 key pair)
#   ENABLE_CADDY   (default: false)
#   AWS_DEFAULT_REGION (default: from aws config or us-east-1)
#   ALLOW_CIDRS    (comma-separated). If set, overrides auto-detected IP.
#
# Flags:
#   --teardown     Run teardown before deploy (default)
#   --no-teardown  Skip teardown before deploy

INSTANCE_COUNT=${INSTANCE_COUNT:-1}
INSTANCE_TYPE=${INSTANCE_TYPE:-t3.medium}
DOMAIN_NAME=${DOMAIN_NAME:-}
ENABLE_CADDY=${ENABLE_CADDY:-false}
RUN_TEARDOWN=true

for arg in "$@"; do
  case "$arg" in
    --teardown)
      RUN_TEARDOWN=true
      ;;
    --no-teardown)
      RUN_TEARDOWN=false
      ;;
    *)
      echo "[ERROR] Unknown argument: $arg" >&2
      echo "Usage: $0 [--teardown|--no-teardown]" >&2
      exit 1
      ;;
  esac
done

if ! command -v aws >/dev/null 2>&1; then
  echo "[ERROR] aws CLI not found in PATH" >&2
  exit 1
fi
if ! command -v terraform >/dev/null 2>&1; then
  echo "[ERROR] terraform not found in PATH" >&2
  exit 1
fi

# Resolve region
if [[ -z "${AWS_DEFAULT_REGION:-}" ]]; then
  AWS_DEFAULT_REGION=$(aws configure get region || true)
  AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}
  export AWS_DEFAULT_REGION
fi
echo "[INFO] Using region: $AWS_DEFAULT_REGION"

if [[ "$RUN_TEARDOWN" == "true" ]]; then
  if [[ -x ./teardown.sh ]]; then
    echo "[INFO] Running teardown before deploy"
    ./teardown.sh
  else
    echo "[WARN] teardown.sh not found or not executable; skipping pre-deploy teardown"
  fi
fi

# Account and bucket
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="podman-build-context-${ACCOUNT_ID}-${AWS_DEFAULT_REGION}"
ZIP_KEY="build-context.zip"

# Resolve SSH key pair name (required for SSH access)
SSH_KEY_NAME_RESOLVED="${SSH_KEY_NAME:-}"
if [[ -z "$SSH_KEY_NAME_RESOLVED" ]]; then
  SSH_KEY_NAME_RESOLVED=$(aws ec2 describe-key-pairs \
    --region "$AWS_DEFAULT_REGION" \
    --query 'sort_by(KeyPairs,&KeyName)[0].KeyName' \
    --output text 2>/dev/null || true)
  if [[ -z "$SSH_KEY_NAME_RESOLVED" || "$SSH_KEY_NAME_RESOLVED" == "None" ]]; then
    echo "[ERROR] No EC2 key pairs found in region $AWS_DEFAULT_REGION." >&2
    echo "[ERROR] Create one key pair first, or export SSH_KEY_NAME before running deploy." >&2
    exit 1
  fi
  echo "[INFO] Auto-selected SSH key pair: $SSH_KEY_NAME_RESOLVED"
else
  if ! aws ec2 describe-key-pairs --region "$AWS_DEFAULT_REGION" --key-names "$SSH_KEY_NAME_RESOLVED" >/dev/null 2>&1; then
    echo "[ERROR] SSH key pair '$SSH_KEY_NAME_RESOLVED' was not found in region $AWS_DEFAULT_REGION." >&2
    exit 1
  fi
  echo "[INFO] Using SSH key pair from SSH_KEY_NAME: $SSH_KEY_NAME_RESOLVED"
fi

if [[ -f container-image.tgz ]]; then
  echo "[INFO] Uploading prebuilt image archive to s3://$BUCKET/container-image.tar.gz"
  ./upload_image.sh ./container-image.tgz
else
  echo "[WARN] container-image.tgz not found in repo root."
  echo "[WARN] Build it first: ./datathon_container/build_and_export.sh"
  echo "[ERROR] Aborting deploy to avoid instances without an image." >&2
  exit 1
fi

# Create a minimal auto tfvars for this run
TFVARS_FILE="auto.generated.tfvars"
{
  echo "instance_count = ${INSTANCE_COUNT}"
  echo "instance_type  = \"${INSTANCE_TYPE}\""
  echo "root_volume_size_gb = 64"
  echo "ssh_key_name   = \"${SSH_KEY_NAME_RESOLVED}\""
  echo "ports = [22, 8888, 3000]"
  echo "enable_caddy = ${ENABLE_CADDY}"
  if [[ -n "$DOMAIN_NAME" ]]; then
    echo "domain_name    = \"${DOMAIN_NAME}\""
  fi
} > "$TFVARS_FILE"

# Optionally override inbound allowlist
if [[ -n "${ALLOW_CIDRS:-}" ]]; then
  echo "[INFO] Overriding inbound CIDRs with: $ALLOW_CIDRS"
  # transform comma-separated to HCL list
  IFS=',' read -r -a CIDRS <<< "$ALLOW_CIDRS"
  echo "auto_allow_caller_ip = false" >> "$TFVARS_FILE"
  printf 'allow_cidrs = [\n' >> "$TFVARS_FILE"
  for c in "${CIDRS[@]}"; do
    c_trim=$(echo "$c" | xargs)
    printf '  "%s",\n' "$c_trim" >> "$TFVARS_FILE"
  done
  printf ']\n' >> "$TFVARS_FILE"
fi

echo "[INFO] Generated tfvars file: $TFVARS_FILE"
echo "----------------------------------------"
cat "$TFVARS_FILE"
echo "----------------------------------------"

echo "[INFO] Running terraform init"
terraform init -input=false

echo "[INFO] Applying Terraform"
terraform apply -auto-approve -input=false -var-file="$TFVARS_FILE"

echo "[INFO] Terraform apply complete. Key outputs:"
terraform output instance_public_ips || true
terraform output subdomain_fqdns || true
echo

# Determine domain file name (fallback to default domain)
DOMAIN_OUTPUT=$(terraform output -raw subdomain_fqdns 2>/dev/null | head -n1 || true)
DOMAIN_FROM_VAR=${DOMAIN_NAME:-caiphdatathon.live}
DNS_FILE="namecheap_dns_${DOMAIN_FROM_VAR}.txt"

if [[ -f "$DNS_FILE" ]]; then
  echo "[INFO] DNS and token helper file generated: $DNS_FILE"
  echo "----------------------------------------"
  sed -n '1,80p' "$DNS_FILE" || true
  echo "... (truncated)"
  echo "----------------------------------------"
else
  echo "[WARN] Expected DNS helper file $DNS_FILE not found."
fi

echo "[NEXT] Test via IP ports: http://<instance_ip>:8888 and http://<instance_ip>:3000"
echo "[NEXT] SSH: ssh -i /path/to/private-key ubuntu@<instance_ip>"
echo "[NEXT] If enabling Caddy later, use ENABLE_CADDY=true and configure DNS/routing as needed."
