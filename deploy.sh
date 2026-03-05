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
#   INSTANCE_COUNT (default: number of colors in team-colors.txt, fallback 1)
#   INSTANCE_TYPE  (default: t3.medium)
#   DOMAIN_NAME    (default: from Terraform default)
#   SSH_KEY_NAME   (optional; if unset, auto-select first EC2 key pair)
#   AWS_DEFAULT_REGION (default: from aws config or us-east-1)
#   ALLOW_CIDRS    (comma-separated). If set, used as final (post-TLS) CIDRs.
#   TLS_ALLOW_CIDRS (comma-separated). If set, used for ports 80/443 in final phase.
#                   Default is 0.0.0.0/0 so Let's Encrypt renewal and public HTTPS work.
#   TLS_WAIT_TIMEOUT_SEC (default: 1800)
#   TLS_WAIT_INTERVAL_SEC (default: 15)
#
# Flags:
#   --teardown           Run teardown before deploy (default)
#   --no-teardown        Skip teardown before deploy
#   --team-count <num>   Override instance count for this run
#   --create-data-volumes  Create any missing persistent workspace volumes
#   --force-uploads      Force image and dataset uploads even if unchanged

DEFAULT_INSTANCE_COUNT=1
if [[ -f team-colors.txt ]]; then
  COLOR_COUNT=$(awk 'NF{print}' team-colors.txt | wc -l | xargs)
  if [[ "$COLOR_COUNT" =~ ^[0-9]+$ && "$COLOR_COUNT" -gt 0 ]]; then
    DEFAULT_INSTANCE_COUNT="$COLOR_COUNT"
  fi
fi
INSTANCE_COUNT=${INSTANCE_COUNT:-$DEFAULT_INSTANCE_COUNT}
INSTANCE_TYPE=${INSTANCE_TYPE:-t3.medium}
DOMAIN_NAME=${DOMAIN_NAME:-}
DATASET_ARCHIVE="data_sets.tgz"
CODE_ARCHIVE="code.tgz"
DATASETS_DIR="${DATASETS_DIR:-datasets}"
CODE_DIR="${CODE_DIR:-code}"
RUN_TEARDOWN=true
CREATE_DATA_VOLUMES=true
FORCE_UPLOADS=false
TLS_WAIT_TIMEOUT_SEC=${TLS_WAIT_TIMEOUT_SEC:-1800}
TLS_WAIT_INTERVAL_SEC=${TLS_WAIT_INTERVAL_SEC:-15}

TEAM_COUNT_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --teardown)
      RUN_TEARDOWN=true
      ;;
    --no-teardown)
      RUN_TEARDOWN=false
      ;;
    --team-count)
      if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "[ERROR] --team-count requires a number" >&2
        echo "Usage: $0 [--teardown|--no-teardown] [--team-count N] [--create-data-volumes] [--force-uploads]" >&2
        exit 1
      fi
      TEAM_COUNT_OVERRIDE="$2"
      shift
      ;;
    --create-data-volumes)
      CREATE_DATA_VOLUMES=true
      ;;
    --force-uploads)
      FORCE_UPLOADS=true
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      echo "Usage: $0 [--teardown|--no-teardown] [--team-count N] [--create-data-volumes] [--force-uploads]" >&2
      exit 1
      ;;
  esac
  shift
done

if [[ -n "$TEAM_COUNT_OVERRIDE" ]]; then
  if ! [[ "$TEAM_COUNT_OVERRIDE" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] --team-count must be a positive integer" >&2
    exit 1
  fi
  INSTANCE_COUNT="$TEAM_COUNT_OVERRIDE"
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "[ERROR] aws CLI not found in PATH" >&2
  exit 1
fi
if ! command -v terraform >/dev/null 2>&1; then
  echo "[ERROR] terraform not found in PATH" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "[ERROR] jq not found in PATH" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "[ERROR] curl not found in PATH" >&2
  exit 1
fi
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  echo "[ERROR] Need sha256sum or shasum in PATH" >&2
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

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

to_hcl_list_from_csv() {
  local csv="$1"
  local out=""
  IFS=',' read -r -a items <<< "$csv"
  for raw in "${items[@]}"; do
    item=$(echo "$raw" | xargs)
    [[ -n "$item" ]] || continue
    if [[ -n "$out" ]]; then
      out="${out},"
    fi
    out="${out}\"${item}\""
  done
  echo "$out"
}

generate_tfvars() {
  local file="$1"
  local cidrs_csv="$2"
  local tls_cidrs_csv="$3"
  local ports_hcl
  local cidrs_hcl
  local tls_cidrs_hcl
  ports_hcl=$(IFS=,; echo "${PORTS[*]}")
  cidrs_hcl=$(to_hcl_list_from_csv "$cidrs_csv")
  tls_cidrs_hcl=$(to_hcl_list_from_csv "$tls_cidrs_csv")

  {
    echo "instance_count = ${INSTANCE_COUNT}"
    echo "instance_type  = \"${INSTANCE_TYPE}\""
    echo "root_volume_size_gb = 64"
    echo "create_data_volumes = ${CREATE_DATA_VOLUMES}"
    echo "env_hash = \"${ENV_HASH}\""
    echo "ssh_key_name   = \"${SSH_KEY_NAME_RESOLVED}\""
    echo "ports = [${ports_hcl}]"
    if [[ -n "$DOMAIN_NAME" ]]; then
      echo "domain_name    = \"${DOMAIN_NAME}\""
    fi
    echo "auto_allow_caller_ip = false"
    echo "allow_cidrs = [${cidrs_hcl}]"
    echo "tls_allow_cidrs = [${tls_cidrs_hcl}]"
  } > "$file"
}

# Determine whether we need to create any missing data volumes
NAME_PREFIX="teamnode"
EXPECTED_VOLUME_NAMES=()
for ((i=0; i<INSTANCE_COUNT; i++)); do
  EXPECTED_VOLUME_NAMES+=("${NAME_PREFIX}-data-${i}")
done

if [[ "$CREATE_DATA_VOLUMES" != "true" && ${#EXPECTED_VOLUME_NAMES[@]} -gt 0 ]]; then
  VOLUME_NAME_FILTER=$(IFS=,; echo "${EXPECTED_VOLUME_NAMES[*]}")
  EXISTING_COUNT=$(aws ec2 describe-volumes \
    --region "$AWS_DEFAULT_REGION" \
    --filters "Name=tag:Name,Values=$VOLUME_NAME_FILTER" \
    --query "length(Volumes[].VolumeId)" \
    --output text 2>/dev/null || echo "0")
  if [[ "$EXISTING_COUNT" -lt "$INSTANCE_COUNT" ]]; then
    echo "[INFO] Detected missing data volumes ($EXISTING_COUNT/$INSTANCE_COUNT present); enabling creation"
    CREATE_DATA_VOLUMES=true
  else
    echo "[INFO] All data volumes present ($EXISTING_COUNT/$INSTANCE_COUNT); leaving them unchanged"
  fi
fi

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
  if [[ "$FORCE_UPLOADS" == "true" ]]; then
    ./upload_image.sh --force ./container-image.tgz
  else
    ./upload_image.sh ./container-image.tgz
  fi
else
  echo "[WARN] container-image.tgz not found in repo root."
  echo "[WARN] Build it first: ./datathon_container/build_and_export.sh"
  echo "[ERROR] Aborting deploy to avoid instances without an image." >&2
  exit 1
fi

# Prepare datasets archive if missing
if [[ ! -f "$DATASET_ARCHIVE" ]]; then
  if [[ -d "$DATASETS_DIR" ]]; then
    echo "[INFO] Creating datasets archive from ./$DATASETS_DIR"
    tar -czf "$DATASET_ARCHIVE" -C "$DATASETS_DIR" .
  else
    echo "[ERROR] Dataset archive not found ($DATASET_ARCHIVE) and datasets dir missing ($DATASETS_DIR)" >&2
    exit 1
  fi
fi

# Prepare code archive if missing
if [[ ! -f "$CODE_ARCHIVE" ]]; then
  if [[ -d "$CODE_DIR" ]]; then
    echo "[INFO] Creating code archive from ./$CODE_DIR"
    tar -czf "$CODE_ARCHIVE" -C "$CODE_DIR" .
  else
    echo "[ERROR] Code archive not found ($CODE_ARCHIVE) and code dir missing ($CODE_DIR)" >&2
    exit 1
  fi
fi

# Upload datasets archive (required)
echo "[INFO] Uploading datasets archive to s3://$BUCKET/data_sets.tar.gz"
if [[ "$FORCE_UPLOADS" == "true" ]]; then
  ./upload_datasets.sh --force "$DATASET_ARCHIVE"
else
  ./upload_datasets.sh "$DATASET_ARCHIVE"
fi

# Upload code archive (required)
echo "[INFO] Uploading code archive to s3://$BUCKET/code.tar.gz"
if [[ "$FORCE_UPLOADS" == "true" ]]; then
  ./upload_code.sh --force "$CODE_ARCHIVE"
else
  ./upload_code.sh "$CODE_ARCHIVE"
fi

if [[ ! -f env.txt ]]; then
  echo "[ERROR] env.txt not found in repo root." >&2
  exit 1
fi
ENV_HASH=$(sha256_of env.txt)
echo "[INFO] env.txt hash: $ENV_HASH"

PORTS=(22 8888 3000 80 443)
CALLER_IP=$(curl -fsSL https://checkip.amazonaws.com | tr -d '\r\n')
CALLER_CIDR="${CALLER_IP}/32"
FINAL_ALLOW_CIDRS="${ALLOW_CIDRS:-$CALLER_CIDR}"
FINAL_TLS_ALLOW_CIDRS="${TLS_ALLOW_CIDRS:-0.0.0.0/0}"
PERMISSIVE_ALLOW_CIDRS="0.0.0.0/0"
echo "[INFO] Caller public IP detected: ${CALLER_IP}"
echo "[INFO] Final app/SSH allow CIDRs (ports 22,3000,8888): ${FINAL_ALLOW_CIDRS}"
echo "[INFO] Final TLS allow CIDRs (ports 80,443): ${FINAL_TLS_ALLOW_CIDRS}"
echo "[INFO] Deploy phases:"
echo "       Phase 1/2 -> permissive ingress for bootstrap + ACME issuance"
echo "       Phase 2/2 -> final policy: app/SSH restricted, TLS set to configured TLS CIDRs"

TFVARS_PHASE1="auto.generated.phase1.tfvars"
TFVARS_PHASE2="auto.generated.tfvars"
generate_tfvars "$TFVARS_PHASE1" "$PERMISSIVE_ALLOW_CIDRS" "$PERMISSIVE_ALLOW_CIDRS"
generate_tfvars "$TFVARS_PHASE2" "$FINAL_ALLOW_CIDRS" "$FINAL_TLS_ALLOW_CIDRS"

echo "[INFO] Generated phase 1 tfvars file: $TFVARS_PHASE1"
echo "----------------------------------------"
cat "$TFVARS_PHASE1"
echo "----------------------------------------"
echo "[INFO] Generated phase 2 tfvars file: $TFVARS_PHASE2"
echo "----------------------------------------"
cat "$TFVARS_PHASE2"
echo "----------------------------------------"

echo "[INFO] Running terraform init"
terraform init -input=false

echo "[INFO] Applying Terraform (phase 1/2: permissive ingress for bootstrap + ACME)"
terraform apply -auto-approve -input=false -var-file="$TFVARS_PHASE1"

echo "[INFO] Phase 1 apply complete. Key outputs:"
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

if [[ -f ./namecheap_sync_dns.py ]]; then
  if [[ -n "${NAMECHEAP_API_USER:-}" && -n "${NAMECHEAP_API_KEY:-}" ]]; then
    echo "[INFO] Syncing Namecheap DNS from terraform outputs"
    ./namecheap_sync_dns.py || echo "[WARN] Namecheap DNS sync failed"
  else
    echo "[INFO] Namecheap DNS sync skipped (missing NAMECHEAP_API_USER/NAMECHEAP_API_KEY)"
  fi
fi

if [[ -f team-colors.txt ]]; then
  mapfile -t COLORS < <(awk 'NF{print}' team-colors.txt)
else
  COLORS=()
fi
IPS=()
if terraform output -json instance_public_ips >/dev/null 2>&1; then
  mapfile -t IPS < <(terraform output -json instance_public_ips | jq -r '.[]')
fi
DOMAIN_PRINT="${DOMAIN_NAME:-caiphdatathon.live}"
if [[ ${#COLORS[@]} -gt 0 && ${#IPS[@]} -gt 0 ]]; then
  echo "[INFO] Service URLs (by team color)"
  count=${#COLORS[@]}
  if [[ ${#IPS[@]} -lt $count ]]; then count=${#IPS[@]}; fi
  for ((i=0; i<count; i++)); do
    name=$(echo "${COLORS[$i]}" | tr '[:upper:]' '[:lower:]')
    echo "  https://${name}.${DOMAIN_PRINT}/"
    echo "  https://${name}.${DOMAIN_PRINT}/jupyter"
  done
fi

FQDNS=()
if terraform output -json subdomain_fqdns >/dev/null 2>&1; then
  mapfile -t FQDNS < <(terraform output -json subdomain_fqdns | jq -r '.[]')
fi

if [[ ${#FQDNS[@]} -eq 0 ]]; then
  echo "[ERROR] No subdomain_fqdns found; cannot verify TLS issuance." >&2
  exit 1
fi

echo "[INFO] Waiting for HTTPS/TLS readiness on all team FQDNs (timeout ${TLS_WAIT_TIMEOUT_SEC}s)"
WAIT_START=$(date +%s)
while true; do
  READY=true
  now=$(date +%s)
  elapsed=$((now - WAIT_START))
  if (( elapsed > TLS_WAIT_TIMEOUT_SEC )); then
    echo "[ERROR] Timed out waiting for TLS readiness after ${TLS_WAIT_TIMEOUT_SEC}s." >&2
    echo "[ERROR] Leaving permissive ingress in place so issuance can continue." >&2
    exit 1
  fi

  for fqdn in "${FQDNS[@]}"; do
    dns_a=$(getent ahostsv4 "$fqdn" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd "," -)
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 4 --max-time 8 "https://${fqdn}/" || true)
    [[ -n "$code" ]] || code="000"
    if [[ "$code" == "000" ]]; then
      READY=false
      echo "[WAIT] ${fqdn} https=${code} dns=${dns_a:--} elapsed=${elapsed}s"
    else
      echo "[OK]   ${fqdn} https=${code} dns=${dns_a:--}"
    fi
  done

  if [[ "$READY" == "true" ]]; then
    break
  fi
  sleep "$TLS_WAIT_INTERVAL_SEC"
done

echo "[INFO] TLS ready across all team FQDNs. Applying Terraform (phase 2/2: final ingress policy)"
echo "[INFO] Phase 2 target: app/SSH -> ${FINAL_ALLOW_CIDRS} | TLS -> ${FINAL_TLS_ALLOW_CIDRS}"
terraform apply -auto-approve -input=false -var-file="$TFVARS_PHASE2"

echo "[INFO] Phase 2 apply complete. Key outputs:"
terraform output instance_public_ips || true
terraform output subdomain_fqdns || true
echo
if [[ -x ./info.sh ]]; then
  echo "[INFO] Running info.sh"
  ./info.sh || true
  echo
fi

echo "[NEXT] Test via IP ports: http://<instance_ip>:8888 and http://<instance_ip>:3000"
echo "[NEXT] SSH: ssh -i /path/to/private-key ubuntu@<instance_ip>"
echo "[NEXT] Caddy is enabled by default; app ingress tightened to: ${FINAL_ALLOW_CIDRS}"
echo "[NEXT] TLS ingress on ports 80/443 set to: ${FINAL_TLS_ALLOW_CIDRS}"
