#!/usr/bin/env bash
set -euo pipefail

# tmp.sh — Check if your current public IP can reach an EC2 instance
# - Looks up an instance by Name tag (e.g., teamnode-0) or by InstanceId
# - Shows inbound security group rules and whether your IP matches any CIDR
# - Performs quick HTTP reachability checks on common ports
#
# Usage:
#   ./tmp.sh <instance-name-or-id> [port1 port2 ...]
#     - Default ports: 8888 3000 80 443
#
# Examples:
#   ./tmp.sh teamnode-0
#   ./tmp.sh i-0123456789abcdef0 80 443

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <instance-name-or-id> [ports...]" >&2
  exit 2
fi

TARGET="$1"; shift || true
if [[ $# -gt 0 ]]; then
  PORTS=("$@")
else
  PORTS=(8888 3000 80 443)
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] '$1' not found in PATH" >&2; exit 1; }; }
need aws
need curl

# Region resolution
if [[ -z "${AWS_DEFAULT_REGION:-}" ]]; then
  AWS_DEFAULT_REGION=$(aws configure get region || true)
  AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}
  export AWS_DEFAULT_REGION
fi

# Helper: IPv4 to int
ip2int() {
  local IFS=.
  read -r a b c d <<< "$1"
  echo $(( (a<<24) + (b<<16) + (c<<8) + d ))
}

# Helper: does CIDR contain IP (both IPv4)
cidr_contains_ip() {
  local cidr="$1" ip="$2"
  local net prefix base ipi
  IFS=/ read -r base prefix <<< "$cidr"
  [[ -z "$prefix" ]] && prefix=32
  net=$(ip2int "$base")
  ipi=$(ip2int "$ip")
  # mask: top 'prefix' bits set
  local mask=$(( 0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF ))
  (( (net & mask) == (ipi & mask) )) && return 0 || return 1
}

# Resolve instance details
if [[ "$TARGET" =~ ^i-[a-f0-9]+$ ]]; then
  QUERY='Reservations[0].Instances[0]'
  DESC=$(aws ec2 describe-instances --instance-ids "$TARGET" --query "$QUERY" --output json || true)
else
  QUERY='Reservations[0].Instances[0]'
  DESC=$(aws ec2 describe-instances --filters Name=tag:Name,Values="$TARGET" --query "$QUERY" --output json || true)
fi

if [[ -z "$DESC" || "$DESC" == "null" ]]; then
  echo "[ERROR] Instance not found for target: $TARGET" >&2
  exit 1
fi

# Extract fields with minimal jq (fallback to awk if jq missing)
if command -v jq >/dev/null 2>&1; then
  IID=$(echo "$DESC" | jq -r '.InstanceId')
  NAME=$(echo "$DESC" | jq -r '.Tags[]? | select(.Key=="Name") | .Value' | head -n1)
  PUBIP=$(echo "$DESC" | jq -r '.PublicIpAddress // ""')
  readarray -t SGIDS < <(echo "$DESC" | jq -r '.SecurityGroups[].GroupId')
else
  IID=$(echo "$DESC" | awk -F'"' '/InstanceId/ {print $4; exit}')
  NAME=$(echo "$DESC" | awk -F'"' '/"Key": "Name"/ {getline; getline; print $4; exit}')
  PUBIP=$(echo "$DESC" | awk -F'"' '/PublicIpAddress/ {print $4; exit}')
  SGIDS=($(echo "$DESC" | awk -F'"' '/GroupId/ {print $4}'))
fi

MYIP=$(curl -fsSL https://checkip.amazonaws.com | xargs || true)

echo "Instance: ${NAME:-<no-name>} (${IID})"
echo "Public IP: ${PUBIP:-<none>}"
echo "Security Groups: ${SGIDS[*]:-<none>}"
echo "Your IP: ${MYIP:-<unknown>}"

if [[ -z "${PUBIP:-}" ]]; then
  echo "[WARN] Instance has no public IP; reachability tests will be skipped."
fi

# Describe SG inbound rules
if [[ ${#SGIDS[@]} -gt 0 ]]; then
  SGJSON=$(aws ec2 describe-security-groups --group-ids "${SGIDS[@]}" --output json)
else
  SGJSON='{}'
fi

echo
echo "Inbound rules (port from-to, proto, CIDRs):"
if command -v jq >/dev/null 2>&1; then
  echo "$SGJSON" | jq -r '.SecurityGroups[]? | .IpPermissions[]? | "- " + ( .FromPort|tostring // "-" ) + ":" + ( .ToPort|tostring // "-" ) + ", " + (.IpProtocol // "-") + ", " + ( [.IpRanges[]?.CidrIp] | join(" ") )'
else
  echo "$SGJSON" | awk -F'"' '/FromPort|ToPort|IpProtocol|CidrIp/ {print $0}'
fi

# Evaluate allow for each requested port
echo
echo "Allow check per port for your IP:"
ALLOW_ANY=0
for p in "${PORTS[@]}"; do
  # Validate port is a number
  if ! [[ "$p" =~ ^[0-9]+$ ]]; then
    echo "  port '$p' is invalid; skipping"
    continue
  fi
  PORT_ALLOWED="no"
  if command -v jq >/dev/null 2>&1; then
    mapfile -t CIDRS < <(echo "$SGJSON" | jq -r --argjson port "$p" '.SecurityGroups[]?.IpPermissions[]? | select(.IpProtocol=="tcp" and .FromPort<= $port and .ToPort>= $port) | .IpRanges[]?.CidrIp')
  else
    CIDRS=($(echo "$SGJSON" | awk -v p="$p" '/"FromPort":/ {from=$2} /"ToPort":/ {to=$2} /"IpProtocol":/ {proto=$2} /"CidrIp":/ {gsub(/"|,/,"",$2); if(proto=="tcp" && from<=p && to>=p) print $2}'))
  fi

  for c in "${CIDRS[@]:-}"; do
    [[ -z "$MYIP" ]] && continue
    if [[ "$c" == "0.0.0.0/0" ]]; then PORT_ALLOWED="yes"; break; fi
    if cidr_contains_ip "$c" "$MYIP"; then PORT_ALLOWED="yes"; break; fi
  done
  echo "  port $p -> $PORT_ALLOWED"
  [[ "$PORT_ALLOWED" == "yes" ]] && ALLOW_ANY=1 || true
done

# Reachability tests (best-effort)
if [[ -n "${PUBIP:-}" ]]; then
  echo
  echo "Reachability tests to http://$PUBIP:(ports)..."
  for p in "${PORTS[@]}"; do
    code=$(curl -m 5 -sS -o /dev/null -w '%{http_code}' "http://$PUBIP:$p" || echo "ERR")
    echo "  http://$PUBIP:$p -> $code"
  done
  code=$(curl -k -m 5 -sS -o /dev/null -w '%{http_code}' "https://$PUBIP" || echo "ERR")
  echo "  https://$PUBIP (443) -> $code"
fi

echo
if [[ $ALLOW_ANY -eq 1 ]]; then
  echo "Summary: Your IP appears allowed for at least one requested port."
else
  echo "Summary: Your IP does NOT appear allowed for the requested ports. Consider re-applying with updated allowlist."
fi
