#!/usr/bin/env bash
set -euo pipefail

# inspect.sh — Instance status + optional SSH log collection
# - Prints EC2 status checks and recent console output
# - Optionally enables SSH (opens port 22, attaches first key pair) via Terraform
# - If SSH is reachable, collects on-instance logs (bootstrap + podman) to debug/<ts>/
#
# Usage:
#   ./inspect.sh <instance-name-or-id> [enable-ssh]
#
# Examples:
#   ./inspect.sh teamnode-0
#   ./inspect.sh i-0123456789abcdef0 enable-ssh

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <instance-name-or-id> [enable-ssh]" >&2
  exit 2
fi

TARGET="$1"
DO_ENABLE_SSH=${2:-}

need() { command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] '$1' not found" >&2; exit 1; }; }
need aws
need terraform
need curl
need sed

# Region resolution
if [[ -z "${AWS_DEFAULT_REGION:-}" ]]; then
  AWS_DEFAULT_REGION=$(aws configure get region || true)
  AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}
  export AWS_DEFAULT_REGION
fi

# Resolve instance by ID or Name
resolve_instance() {
  local tgt="$1"
  local q='Reservations[0].Instances[0]'
  local desc
  if [[ "$tgt" =~ ^i-[a-f0-9]+$ ]]; then
    desc=$(aws ec2 describe-instances --instance-ids "$tgt" --query "$q" --output json || true)
  else
    desc=$(aws ec2 describe-instances --filters Name=tag:Name,Values="$tgt" --query "$q" --output json || true)
  fi
  [[ -z "$desc" || "$desc" == "null" ]] && { echo "[ERROR] Instance not found: $tgt" >&2; exit 1; }
  IID=$(echo "$desc" | sed -n 's/.*"InstanceId" *: *"\([^"]*\)".*/\1/p' | head -n1)
  NAME=$(echo "$desc" | sed -n 's/.*"Key" *: *"Name".*"Value" *: *"\([^"]*\)".*/\1/p' | head -n1)
  PUBIP=$(echo "$desc" | sed -n 's/.*"PublicIpAddress" *: *"\([^"]*\)".*/\1/p' | head -n1)
  echo "$IID" "$NAME" "$PUBIP"
}

read IID NAME PUBIP < <(resolve_instance "$TARGET")

echo "Instance: ${NAME:-<no-name>} ($IID)"
echo "Public IP: ${PUBIP:-<none>}"

echo
echo "[1/4] EC2 status checks:"
aws ec2 describe-instance-status --include-all-instances --instance-ids "$IID" \
  --query "InstanceStatuses[].{ID:InstanceId,State:InstanceState.Name,System:SystemStatus.Status,Instance:InstanceStatus.Status}" \
  --output table || true

echo
echo "[2/4] Recent console output (last 200 lines):"
aws ec2 get-console-output --instance-id "$IID" --latest --output text 2>/dev/null | tail -n 200 || echo "<no console output>"

echo
echo "[3/4] TCP probe to common ports (direct to public IP)"
if [[ -n "${PUBIP:-}" ]]; then
  for p in 8888 3000 80 443; do
    echo -n "port $p -> "
    (echo >/dev/tcp/$PUBIP/$p) >/dev/null 2>&1 && echo "open" || echo "closed/filtered"
  done
else
  echo "Instance has no public IP."
fi

# Optionally enable SSH and collect logs
if [[ "$DO_ENABLE_SSH" == "enable-ssh" ]]; then
  echo
  echo "[4/4] Enabling SSH (opens port 22, attaches first EC2 key), then collecting logs"
  KEY_NAME=$(aws ec2 describe-key-pairs --query 'KeyPairs[0].KeyName' --output text)
  if [[ -z "$KEY_NAME" || "$KEY_NAME" == "None" ]]; then
    echo "[ERROR] No EC2 key pairs found in region $AWS_DEFAULT_REGION" >&2
    exit 1
  fi
  echo "Using EC2 key pair: $KEY_NAME"

  APPLY_ARGS=(
    -auto-approve
    -var "ssh_key_name=${KEY_NAME}"
    -var 'ports=[22,80,443,8888,3000]'
  )
  TFVARS_FILE="auto.generated.tfvars"
  if [[ -f "$TFVARS_FILE" ]]; then
    APPLY_ARGS+=( -var-file="$TFVARS_FILE" )
  fi
  terraform apply "${APPLY_ARGS[@]}"

  # Refresh IP
  PUBIP=$(aws ec2 describe-instances --instance-ids "$IID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  echo "Public IP (post-apply): $PUBIP"

  KEY_PATH=${KEY_PATH:-sshkey}
  if [[ ! -f "$KEY_PATH" ]]; then
    echo "[WARN] Private key file '$KEY_PATH' not found. Ensure it matches EC2 key '$KEY_NAME'" >&2
  else
    chmod 600 "$KEY_PATH" || true
  fi

  echo "Waiting for SSH..."
  for i in {1..60}; do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i "$KEY_PATH" ubuntu@"$PUBIP" 'echo ok' >/dev/null 2>&1; then
      echo "SSH is ready. Collecting logs."
      break
    fi
    sleep 5
    [[ $i -eq 60 ]] && echo "[WARN] SSH not ready yet; skipping log collection" && exit 0
  done

  TS=$(date +%Y%m%d-%H%M%S)
  OUTDIR="debug/inspect-${TS}-${IID}"
  mkdir -p "$OUTDIR"

  ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ubuntu@"$PUBIP" \
    'sudo tail -n 400 /var/log/datathon-setup.log || true' > "$OUTDIR/datathon-setup.log" 2>&1 || true

  ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ubuntu@"$PUBIP" \
    'sudo journalctl -t datathon-setup -n 400 --no-pager || true' > "$OUTDIR/journal-datathon-setup.txt" 2>&1 || true

  ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ubuntu@"$PUBIP" \
    'sudo systemctl status caddy --no-pager || true' > "$OUTDIR/caddy-status.txt" 2>&1 || true

  ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ubuntu@"$PUBIP" \
    'sudo podman ps -a && echo && for n in jupyter opencode; do echo "--- logs: $n ---"; sudo podman logs --tail 200 "$n" || true; echo; done' \
    > "$OUTDIR/podman.txt" 2>&1 || true

  ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ubuntu@"$PUBIP" \
    "sudo ss -ltnp | egrep ':(8888|3000|80|443)\\b' || true" > "$OUTDIR/listeners.txt" 2>&1 || true

  echo "Logs saved under: $OUTDIR"
fi

