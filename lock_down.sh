#!/usr/bin/env bash
set -euo pipefail

# Locks down security group ingress to the caller's IP for known ports.
# - Revokes 0.0.0.0/0 on those ports (if present)
# - Grants <caller_ip>/32 on those ports
#
# Usage:
#   ./lock_down.sh [--ip <cidr>]
#
# Example:
#   ./lock_down.sh --ip 203.0.113.45/32

err() { echo "[ERROR] $*" >&2; }
log() { echo "[INFO] $*"; }

need() { command -v "$1" >/dev/null 2>&1 || { err "'$1' not found in PATH"; exit 1; }; }
need aws
need jq

CIDR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip)
      CIDR="${2:-}"
      shift
      ;;
    *)
      err "Unknown argument: $1"
      err "Usage: $0 [--ip <cidr>]"
      exit 1
      ;;
  esac
  shift
done

if [[ -z "${AWS_DEFAULT_REGION:-}" ]]; then
  AWS_DEFAULT_REGION=$(aws configure get region || true)
  AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}
  export AWS_DEFAULT_REGION
fi

STATE_FILE="terraform.tfstate"
if [[ ! -f "$STATE_FILE" ]]; then
  err "State file not found: $STATE_FILE"
  exit 1
fi

SG_ID=$(jq -r '
  .resources[]
  | select(.mode=="managed" and .type=="aws_security_group" and .name=="svc")
  | .instances[0].attributes.id // empty
' "$STATE_FILE")

if [[ -z "$SG_ID" ]]; then
  err "Security group ID not found in state"
  exit 1
fi

if [[ -z "$CIDR" ]]; then
  IP=$(curl -fsSL https://checkip.amazonaws.com | tr -d '\r\n' || true)
  if [[ -z "$IP" ]]; then
    err "Failed to detect public IP. Use --ip <cidr>."
    exit 1
  fi
  CIDR="${IP}/32"
fi

# Read ports from auto.generated.tfvars if present; fall back to defaults.
PORTS=(22 80 443 8888 3000)
if [[ -f auto.generated.tfvars ]]; then
  if grep -qE '^ports' auto.generated.tfvars; then
    mapfile -t PORTS < <(awk '
      /^ports/ {inlist=1; next}
      inlist && /\]/ {inlist=0}
      inlist {gsub(/[,\[\]]/,""); gsub(/[ \t]/,""); if ($0!="") print $0}
    ' auto.generated.tfvars | tr -d '\r')
  fi
fi

log "Security group: $SG_ID"
log "Locking to CIDR: $CIDR"
log "Ports: ${PORTS[*]}"

for p in "${PORTS[@]}"; do
  if ! [[ "$p" =~ ^[0-9]+$ ]]; then
    log "Skipping invalid port: $p"
    continue
  fi
  aws ec2 revoke-security-group-ingress \
    --region "$AWS_DEFAULT_REGION" \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port "$p" \
    --cidr 0.0.0.0/0 >/dev/null 2>&1 || true

  aws ec2 authorize-security-group-ingress \
    --region "$AWS_DEFAULT_REGION" \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port "$p" \
    --cidr "$CIDR" >/dev/null 2>&1 || true
done

log "Done. Inbound access should now be restricted to $CIDR on ports: ${PORTS[*]}"
