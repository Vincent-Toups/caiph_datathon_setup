#!/usr/bin/env bash
set -euo pipefail

err() { echo "[ERROR] $*" >&2; }
info() { echo "[INFO] $*"; }

usage() {
  cat <<'EOF'
Usage: ./fix.sh [--team <number|color>] [--cmd "<remote command>"] [--key <pem_path>]

Defaults:
  --cmd "sudo systemctl restart caddy && sudo systemctl status caddy --no-pager -l | head -n 20 && sudo ss -ltnp | egrep ':80|:443' || true"
  --key auto-detect: ./ws.pem, then ./sshkey

Examples:
  ./fix.sh
  ./fix.sh --team 1
  ./fix.sh --team blue
  ./fix.sh --cmd "sudo systemctl restart caddy"
EOF
}

TEAM_INPUT=""
REMOTE_CMD='sudo systemctl restart caddy && sudo systemctl status caddy --no-pager -l | head -n 20 && sudo ss -ltnp | egrep ":80|:443" || true'
KEY_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team)
      TEAM_INPUT="${2:-}"
      [[ -n "$TEAM_INPUT" ]] || { err "--team requires a value"; exit 2; }
      shift
      ;;
    --cmd)
      REMOTE_CMD="${2:-}"
      [[ -n "$REMOTE_CMD" ]] || { err "--cmd requires a value"; exit 2; }
      shift
      ;;
    --key)
      KEY_PATH="${2:-}"
      [[ -n "$KEY_PATH" ]] || { err "--key requires a value"; exit 2; }
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
  shift
done

command -v terraform >/dev/null 2>&1 || { err "terraform not found in PATH"; exit 1; }
command -v jq >/dev/null 2>&1 || { err "jq not found in PATH"; exit 1; }
command -v ssh >/dev/null 2>&1 || { err "ssh not found in PATH"; exit 1; }

if [[ -z "$KEY_PATH" ]]; then
  if [[ -f ./ws.pem ]]; then
    KEY_PATH="./ws.pem"
  elif [[ -f ./sshkey ]]; then
    KEY_PATH="./sshkey"
  else
    err "No SSH key found. Provide --key <pem_path>."
    exit 1
  fi
fi
[[ -f "$KEY_PATH" ]] || { err "SSH key file not found: $KEY_PATH"; exit 1; }
chmod 600 "$KEY_PATH" >/dev/null 2>&1 || true

mapfile -t IPS < <(terraform output -json instance_public_ips 2>/dev/null | jq -r '.[]')
[[ ${#IPS[@]} -gt 0 ]] || { err "No instance_public_ips found. Run terraform apply first."; exit 1; }

COLORS=()
if terraform output -json subdomain_fqdns >/dev/null 2>&1; then
  mapfile -t COLORS < <(terraform output -json subdomain_fqdns | jq -r '.[] | split(".")[0] | ascii_downcase')
fi

TARGET_INDEXES=()
if [[ -z "$TEAM_INPUT" ]]; then
  for i in "${!IPS[@]}"; do TARGET_INDEXES+=("$i"); done
else
  if [[ "$TEAM_INPUT" =~ ^[0-9]+$ ]]; then
    idx=$((TEAM_INPUT - 1))
    (( idx >= 0 && idx < ${#IPS[@]} )) || { err "team number out of range 1..${#IPS[@]}"; exit 1; }
    TARGET_INDEXES=("$idx")
  else
    team_lc=$(echo "$TEAM_INPUT" | tr '[:upper:]' '[:lower:]')
    team_lc="${team_lc%%.*}"
    found=-1
    for i in "${!COLORS[@]}"; do
      if [[ "${COLORS[$i]}" == "$team_lc" ]]; then
        found="$i"
        break
      fi
    done
    (( found >= 0 )) || { err "Unknown team color: $TEAM_INPUT"; exit 1; }
    TARGET_INDEXES=("$found")
  fi
fi

info "Using SSH key: $KEY_PATH"
info "Remote command: $REMOTE_CMD"
echo

fail_count=0
for idx in "${TARGET_INDEXES[@]}"; do
  ip="${IPS[$idx]}"
  team=$((idx + 1))
  color="n/a"
  if [[ $idx -lt ${#COLORS[@]} ]]; then
    color="${COLORS[$idx]}"
  fi

  info "team${team} (${color}) -> ${ip}"
  if ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -i "$KEY_PATH" ubuntu@"$ip" "$REMOTE_CMD"; then
    info "team${team} (${color}) OK"
  else
    err "team${team} (${color}) FAILED"
    fail_count=$((fail_count + 1))
  fi
  echo
done

if (( fail_count > 0 )); then
  err "Completed with ${fail_count} failure(s)."
  exit 1
fi

info "Completed successfully."
