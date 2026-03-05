#!/usr/bin/env bash
set -euo pipefail

err() { echo "[ERROR] $*" >&2; }

if [[ $# -ne 1 ]]; then
  err "Usage: $0 <team_number|team_color>"
  err "Examples: $0 1   |   $0 blue"
  exit 1
fi

TEAM_INPUT="$1"
TEAM_INPUT_LC=$(echo "$TEAM_INPUT" | tr '[:upper:]' '[:lower:]')

if ! command -v terraform >/dev/null 2>&1; then
  err "terraform not found in PATH"
  exit 1
fi

PEM="./ws.pem"
if [[ ! -f "$PEM" ]]; then
  err "PEM file not found: $PEM"
  exit 1
fi

IPS=()
if terraform output -json instance_public_ips >/dev/null 2>&1; then
  mapfile -t IPS < <(terraform output -json instance_public_ips | jq -r '.[]')
else
  err "terraform output 'instance_public_ips' not found. Run terraform apply first."
  exit 1
fi

if [[ ${#IPS[@]} -eq 0 ]]; then
  err "No instance IPs found in terraform output."
  exit 1
fi

# Resolve input to index: numeric team number OR team color.
INDEX=-1
TEAM_LABEL=""

if [[ "$TEAM_INPUT" =~ ^[0-9]+$ ]]; then
  TEAM_NUM="$TEAM_INPUT"
  INDEX=$((TEAM_NUM - 1))
  if (( INDEX < 0 || INDEX >= ${#IPS[@]} )); then
    err "team_number out of range. Available teams: 1..${#IPS[@]}"
    exit 1
  fi
else
  # If user passed FQDN, keep only the leftmost label.
  TEAM_COLOR="$TEAM_INPUT_LC"
  TEAM_COLOR="${TEAM_COLOR%%.*}"

  COLORS=()
  if terraform output -json subdomain_fqdns >/dev/null 2>&1; then
    mapfile -t COLORS < <(terraform output -json subdomain_fqdns | jq -r '.[] | split(".")[0] | ascii_downcase')
  elif [[ -f team-colors.txt ]]; then
    mapfile -t COLORS < <(sed '/^[[:space:]]*$/d' team-colors.txt | tr '[:upper:]' '[:lower:]')
  fi

  if [[ ${#COLORS[@]} -eq 0 ]]; then
    err "Could not resolve team color (no subdomain/team color list found). Use a team number 1..${#IPS[@]}."
    exit 1
  fi

  for i in "${!COLORS[@]}"; do
    if [[ "${COLORS[$i]}" == "$TEAM_COLOR" ]]; then
      INDEX=$i
      TEAM_NUM=$((i + 1))
      TEAM_LABEL="${COLORS[$i]}"
      break
    fi
  done

  if (( INDEX < 0 )); then
    err "Unknown team color: $TEAM_INPUT"
    err "Available colors: ${COLORS[*]}"
    exit 1
  fi
fi

IP="${IPS[$INDEX]}"
if [[ -n "$TEAM_LABEL" ]]; then
  echo "[INFO] SSH to team $TEAM_NUM ($TEAM_LABEL) at $IP"
else
  echo "[INFO] SSH to team $TEAM_NUM at $IP"
fi

chmod 600 "$PEM" >/dev/null 2>&1 || true
exec ssh -i "$PEM" -o StrictHostKeyChecking=accept-new ubuntu@"$IP"
