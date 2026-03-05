#!/usr/bin/env bash
set -euo pipefail

err() { echo "[ERROR] $*" >&2; }

if ! command -v terraform >/dev/null 2>&1; then
  err "terraform not found in PATH"
  exit 1
fi
if ! command -v aws >/dev/null 2>&1; then
  err "aws not found in PATH"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  err "jq not found in PATH"
  exit 1
fi

TAIL=false
DUMB=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tail)
      TAIL=true
      ;;
    --dumb)
      DUMB=true
      ;;
    *)
      err "Unknown argument: $1"
      echo "Usage: $0 [--tail] [--dumb]" >&2
      exit 1
      ;;
  esac
  shift
done

NAME_PREFIX="${NAME_PREFIX:-teamnode}"
if [[ -f auto.generated.tfvars ]]; then
  if grep -qE '^name_prefix' auto.generated.tfvars; then
    NAME_PREFIX=$(awk -F= '/^name_prefix/ {gsub(/[ "\t]/, "", $2); print $2}' auto.generated.tfvars)
  fi
fi
ALLOW_CIDRS_FROM_TFVARS=""
if [[ -f auto.generated.tfvars ]]; then
  if grep -qE '^allow_cidrs' auto.generated.tfvars; then
    ALLOW_CIDRS_FROM_TFVARS=$(awk '
      /^allow_cidrs/ {inlist=1; next}
      inlist && /\]/ {inlist=0}
      inlist {gsub(/[",]/,""); gsub(/[ \t]/,""); if ($0!="") print $0}
    ' auto.generated.tfvars | paste -sd "," -)
  fi
fi

if [[ -z "${AWS_DEFAULT_REGION:-}" ]]; then
  AWS_DEFAULT_REGION=$(aws configure get region || true)
  AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}
  export AWS_DEFAULT_REGION
fi

COLORS=()
if [[ -f team-colors.txt ]]; then
  mapfile -t COLORS < team-colors.txt
fi

IPS=()
if terraform output -json instance_public_ips >/dev/null 2>&1; then
  mapfile -t IPS < <(terraform output -json instance_public_ips | jq -r '.[]')
else
  err "terraform output 'instance_public_ips' not found. Run terraform apply first."
  exit 1
fi

FQDNS=()
if terraform output -json subdomain_fqdns >/dev/null 2>&1; then
  mapfile -t FQDNS < <(terraform output -json subdomain_fqdns | jq -r '.[]')
fi

if [[ ${#IPS[@]} -eq 0 ]]; then
  err "No instance IPs found in terraform output."
  exit 1
fi

TOKENS=()
if terraform output -json jupyter_tokens >/dev/null 2>&1; then
  mapfile -t TOKENS < <(terraform output -json jupyter_tokens | jq -r '.[]')
fi

echo "[INFO] EBS data volumes (by team)"
VOLUMES_JSON=$(aws ec2 describe-volumes \
  --region "$AWS_DEFAULT_REGION" \
  --filters "Name=tag:Name,Values=${NAME_PREFIX}-data-*"
)

VOLUME_COUNT=$(echo "$VOLUMES_JSON" | jq '.Volumes | length')
if [[ "$VOLUME_COUNT" -eq 0 ]]; then
  echo "[INFO] No volumes found with Name tag prefix ${NAME_PREFIX}-data-"
else
  echo "$VOLUMES_JSON" | jq -r '
    def tagval($k): (.Tags // [] | map(select(.Key==$k).Value) | .[0] // "");
    .Volumes
    | map({
        team: (tagval("TeamIndex") | tonumber? // null),
        name: tagval("Name"),
        id: .VolumeId,
        az: .AvailabilityZone,
        state: .State,
        size: .Size,
        instance_id: (.Attachments[0].InstanceId // "")
      })
    | sort_by(.team // 9999)
    | (["TEAM","NAME","VOLUME_ID","AZ","STATE","SIZE_GB","ATTACHED_INSTANCE_ID"] | @tsv),
      (.[] | [(.team|tostring), .name, .id, .az, .state, (.size|tostring), .instance_id] | @tsv)
  ' | column -t -s $'\t'
fi

echo
echo "[INFO] Direct IP URLs (per instance)"
for idx in "${!IPS[@]}"; do
  ip="${IPS[$idx]}"
  team=$((idx + 1))
  color="n/a"
  if [[ ${#COLORS[@]} -gt 0 ]]; then
    color="${COLORS[$idx]}"
  fi

  token=""
  if [[ $idx -lt ${#TOKENS[@]} ]]; then
    token="${TOKENS[$idx]}"
  fi

  jupyter_url="http://$ip:8888/jupyter/"
  if [[ -n "$token" && "$token" != "null" ]]; then
    jupyter_url="http://$ip:8888/jupyter/lab?token=$token"
  fi
  opencode_url="http://$ip:3000/"
  fqdn_jupyter_url=""
  if [[ $idx -lt ${#FQDNS[@]} ]]; then
    fqdn="${FQDNS[$idx]}"
    fqdn_jupyter_url="https://$fqdn/jupyter/"
    if [[ -n "$token" && "$token" != "null" ]]; then
      fqdn_jupyter_url="https://$fqdn/jupyter/lab?token=$token"
    fi
  fi

  printf 'team%02d %-8s JUPYTER_8888: %s\n' "$team" "$color" "$jupyter_url"
  printf 'team%02d %-8s OPENCODE_3000: %s\n' "$team" "$color" "$opencode_url"
  if [[ -n "$fqdn_jupyter_url" ]]; then
    printf 'team%02d %-8s JUPYTER_FQDN: %s\n' "$team" "$color" "$fqdn_jupyter_url"
  fi
done

dns_ipv4s() {
  local host="$1"
  getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd "," -
}

check_https_code() {
  local host="$1"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 8 "https://$host/" || true)
  [[ -n "$code" ]] && echo "$code" || echo "000"
}

check_tls_dates() {
  local host="$1"
  if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl-missing"
    return
  fi
  local out
  out=$(timeout 8 sh -c "echo | openssl s_client -connect ${host}:443 -servername ${host} 2>/dev/null | openssl x509 -noout -dates" 2>/dev/null || true)
  if [[ -z "$out" ]]; then
    echo "unavailable"
    return
  fi
  local not_after
  not_after=$(echo "$out" | awk -F= '/^notAfter=/ {print $2}')
  if [[ -z "$not_after" ]]; then
    echo "unknown"
    return
  fi
  echo "$not_after"
}

get_allow_source() {
  if [[ -n "$ALLOW_CIDRS_FROM_TFVARS" ]]; then
    echo "$ALLOW_CIDRS_FROM_TFVARS"
    return
  fi
  local ip
  ip=$(curl -s --max-time 4 https://checkip.amazonaws.com 2>/dev/null | tr -d '\r\n' || true)
  if [[ -n "$ip" ]]; then
    echo "${ip}/32"
    return
  fi
  echo "unknown"
}

cidrs_for_port() {
  local port="$1"
  local sg_id
  sg_id=$(terraform state show -no-color aws_security_group.svc 2>/dev/null | awk '/^id = /{gsub(/"/,"",$3); print $3; exit}')
  if [[ -z "$sg_id" ]]; then
    echo "$(get_allow_source)"
    return
  fi
  aws ec2 describe-security-groups --region "$AWS_DEFAULT_REGION" --group-ids "$sg_id" --output json 2>/dev/null \
    | jq -r --argjson p "$port" '
      .SecurityGroups[0].IpPermissions[]
      | select((.IpProtocol=="tcp") and (.FromPort==$p) and (.ToPort==$p))
      | .IpRanges[].CidrIp
    ' 2>/dev/null | paste -sd "," - || true
}

is_public_cidrs() {
  local cidrs="$1"
  [[ "$cidrs" == *"0.0.0.0/0"* ]]
}

PORT_8888_CIDRS=$(cidrs_for_port 8888)
PORT_3000_CIDRS=$(cidrs_for_port 3000)
PORT_80_CIDRS=$(cidrs_for_port 80)
PORT_443_CIDRS=$(cidrs_for_port 443)
[[ -n "$PORT_8888_CIDRS" ]] || PORT_8888_CIDRS="$(get_allow_source)"
[[ -n "$PORT_3000_CIDRS" ]] || PORT_3000_CIDRS="$PORT_8888_CIDRS"
[[ -n "$PORT_80_CIDRS" ]] || PORT_80_CIDRS="$(get_allow_source)"
[[ -n "$PORT_443_CIDRS" ]] || PORT_443_CIDRS="$PORT_80_CIDRS"

echo
echo "[INFO] Access scope (where you can access from)"
echo "Direct app URLs on :8888 and :3000 are reachable from: $PORT_8888_CIDRS / $PORT_3000_CIDRS"
echo "Caddy HTTP/HTTPS on :80 and :443 are reachable from: $PORT_80_CIDRS / $PORT_443_CIDRS"
if is_public_cidrs "$PORT_80_CIDRS" && is_public_cidrs "$PORT_443_CIDRS"; then
  echo "Public TLS issuance readiness: yes (80/443 are internet-reachable)."
else
  echo "Public TLS issuance readiness: no (80/443 are not open to 0.0.0.0/0)."
fi

if [[ ${#FQDNS[@]} -gt 0 ]]; then
  echo
  echo "[INFO] DNS/TLS deployment status (per FQDN)"
  printf '%s\n' "TEAM  COLOR     FQDN                              EXPECTED_IP      DNS_A              DNS_OK HTTPS TLS_NOT_AFTER"
  for idx in "${!IPS[@]}"; do
    ip="${IPS[$idx]}"
    team=$((idx + 1))
    color="n/a"
    if [[ ${#COLORS[@]} -gt 0 ]]; then
      color="${COLORS[$idx]}"
    fi
    fqdn=""
    if [[ $idx -lt ${#FQDNS[@]} ]]; then
      fqdn="${FQDNS[$idx]}"
    fi
    if [[ -z "$fqdn" ]]; then
      continue
    fi
    dns_a=$(dns_ipv4s "$fqdn")
    [[ -n "$dns_a" ]] || dns_a="-"
    dns_ok="no"
    if [[ "$dns_a" == *"$ip"* ]]; then
      dns_ok="yes"
    fi
    https_code=$(check_https_code "$fqdn")
    tls_not_after=$(check_tls_dates "$fqdn")
    printf 'team%02d %-8s %-33s %-15s %-18s %-6s %-5s %s\n' \
      "$team" "$color" "$fqdn" "$ip" "$dns_a" "$dns_ok" "$https_code" "$tls_not_after"
  done
fi

if [[ "$TAIL" == "true" ]]; then
  if ! command -v curl >/dev/null 2>&1; then
    err "curl not found in PATH (required for --tail)"
    exit 1
  fi

  check_url() {
    local url="$1"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time 4 "$url" || true)
    if [[ -z "$code" ]]; then
      code="000"
    fi
    echo "$code"
  }

  while true; do
    if [[ "$DUMB" != "true" ]]; then
      printf '\033[H\033[2J'
    fi
    echo "[INFO] Endpoint status (updated $(date))"
    echo "[INFO] Allowlisted source(s): $(get_allow_source)"
    if [[ ${#TOKENS[@]} -gt 0 ]]; then
      echo "[INFO] Jupyter tokens:"
      for idx in "${!TOKENS[@]}"; do
        team=$((idx + 1))
        color="n/a"
        if [[ ${#COLORS[@]} -gt 0 ]]; then
          color="${COLORS[$idx]}"
        fi
        printf 'team%02d %s %s\n' "$team" "$color" "${TOKENS[$idx]}"
      done
    fi
    printf '%s\n' "TEAM  COLOR     TARGET                           STATUS DETAIL"
    for idx in "${!IPS[@]}"; do
      ip="${IPS[$idx]}"
      team=$((idx + 1))
      color="n/a"
      if [[ ${#COLORS[@]} -gt 0 ]]; then
        color="${COLORS[$idx]}"
      fi
      url1="http://$ip:8888/jupyter/"
      url2="http://$ip:3000"
      code1=$(check_url "$url1")
      code2=$(check_url "$url2")
      printf 'team%02d %-8s %-32s %-6s %s\n' "$team" "$color" "$url1" "$code1" "direct-ip-jupyter"
      printf 'team%02d %-8s %-32s %-6s %s\n' "$team" "$color" "$url2" "$code2" "direct-ip"
      if [[ $idx -lt ${#FQDNS[@]} ]]; then
        fqdn="${FQDNS[$idx]}"
        dns_a=$(dns_ipv4s "$fqdn")
        [[ -n "$dns_a" ]] || dns_a="-"
        https_code=$(check_https_code "$fqdn")
        tls_not_after=$(check_tls_dates "$fqdn")
        printf 'team%02d %-8s %-32s %-6s %s\n' "$team" "$color" "https://$fqdn/" "$https_code" "dns=$dns_a tls=$tls_not_after"
      fi
    done
    sleep 5
  done
fi
