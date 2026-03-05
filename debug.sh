#!/usr/bin/env bash
set -euo pipefail

# Collects deployment diagnostics: Terraform state/outputs, AWS resource info,
# endpoint reachability checks, S3 artifacts presence, and EC2 console logs.

TS=$(date +%Y%m%d-%H%M%S)
OUTDIR="debug/$TS"
mkdir -p "$OUTDIR"

log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*" >&2; }

command -v aws >/dev/null 2>&1 || { err "aws CLI not found"; exit 1; }
command -v terraform >/dev/null 2>&1 || { err "terraform not found"; exit 1; }

# Region and account
if [[ -z "${AWS_DEFAULT_REGION:-}" ]]; then
  AWS_DEFAULT_REGION=$(aws configure get region || true)
  AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}
  export AWS_DEFAULT_REGION
fi
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="podman-build-context-${ACCOUNT_ID}-${AWS_DEFAULT_REGION}"

log "Using region: $AWS_DEFAULT_REGION; account: $ACCOUNT_ID"
{
  echo "aws --version: $(aws --version 2>&1)"
  echo "terraform version:"; terraform -version
} > "$OUTDIR/tooling.txt" 2>&1 || true

# S3 artifacts presence
{
  echo "S3 listing for build artifacts:";
  aws s3 ls "s3://$BUCKET/build-context.zip" || true
  aws s3 ls "s3://$BUCKET/env.txt" || true
  aws s3 ls "s3://$BUCKET/container-image.tar.gz" || true
  aws s3 ls "s3://$BUCKET/data_sets.tar.gz" || true
  aws s3 ls "s3://$BUCKET/code.tar.gz" || true
} > "$OUTDIR/s3_artifacts.txt" 2>&1

# Terraform state and outputs
{
  echo "providers:"; terraform providers || true
  echo; echo "state list:"; terraform state list || true
  echo; echo "outputs:"; terraform output || true
} > "$OUTDIR/terraform_state.txt" 2>&1

# Extract instance IDs and IPs from state/outputs if available
INSTANCE_IDS=()
INSTANCE_IPS=()
FQDNS=()

if terraform state list 2>/dev/null | grep -q '^aws_instance\.node'; then
  while read -r addr; do
    id=$(terraform state show -no-color "$addr" 2>/dev/null | awk '/^id = /{print $3; exit}')
    ip=$(terraform state show -no-color "$addr" 2>/dev/null | awk '/^public_ip = /{print $3; exit}')
    [[ -n "$id" ]] && INSTANCE_IDS+=("$id")
    [[ -n "$ip" ]] && INSTANCE_IPS+=("$ip")
  done < <(terraform state list | grep '^aws_instance\.node')
fi

# Fallback: read from outputs
if [[ ${#INSTANCE_IPS[@]} -eq 0 ]]; then
  mapfile -t INSTANCE_IPS < <(terraform output -json instance_public_ips 2>/dev/null | jq -r '.[]' || true)
fi
mapfile -t FQDNS < <(terraform output -json subdomain_fqdns 2>/dev/null | jq -r '.[]' || true)

# Describe instances and security group
{
  if [[ ${#INSTANCE_IDS[@]} -gt 0 ]]; then
    echo "describe-instances by IDs:";
    aws ec2 describe-instances --instance-ids "${INSTANCE_IDS[@]}" --output json || true
  else
    echo "describe-instances by filter (Name prefix 'teamnode-*'):";
    aws ec2 describe-instances --filters Name=tag:Name,Values='teamnode-*' --output json || true
  fi
} > "$OUTDIR/ec2_describe_instances.json" 2>&1

# Fallback: parse instance IDs from describe output if Terraform-based extraction failed.
if [[ ${#INSTANCE_IDS[@]} -eq 0 && -f "$OUTDIR/ec2_describe_instances.json" ]]; then
  mapfile -t INSTANCE_IDS < <(jq -r '.Reservations[].Instances[].InstanceId // empty' "$OUTDIR/ec2_describe_instances.json" 2>/dev/null || true)
  if [[ ${#INSTANCE_IDS[@]} -eq 0 ]]; then
    mapfile -t INSTANCE_IDS < <(grep -oE '"InstanceId":\s*"i-[^"]+"' "$OUTDIR/ec2_describe_instances.json" | sed -E 's/.*"InstanceId":\s*"([^"]+)".*/\1/' || true)
  fi
fi

# Security group details (from state if present)
{
  echo "security group from state (aws_security_group.svc):";
  terraform state show -no-color aws_security_group.svc || true
} > "$OUTDIR/security_group.txt" 2>&1

# Inbound reachability tests to app ports
{
  echo "Local detected public IP:"; curl -fsSL https://checkip.amazonaws.com || true
  for ip in "${INSTANCE_IPS[@]}"; do
    echo "--- Testing $ip ---";
    for port in 8888 3000 80 443; do
      code=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://$ip:$port" 2>/dev/null || echo "ERR")
      echo "http://$ip:$port -> $code";
    done
  done
} > "$OUTDIR/reachability.txt" 2>&1

# FQDN + TLS checks (SNI-aware)
{
  echo "Local detected public IP:"
  curl -fsSL https://checkip.amazonaws.com || true
  echo
  if [[ ${#FQDNS[@]} -eq 0 ]]; then
    echo "No terraform output subdomain_fqdns found."
    exit 0
  fi

  echo -e "FQDN\tEXPECTED_IP\tDNS_A\tHTTP_CODE\tHTTPS_CODE\tTLS_NOT_AFTER\tTLS_ISSUER"
  for idx in "${!FQDNS[@]}"; do
    fqdn="${FQDNS[$idx]}"
    expected_ip=""
    if [[ $idx -lt ${#INSTANCE_IPS[@]} ]]; then
      expected_ip="${INSTANCE_IPS[$idx]}"
    fi

    dns_a=$(getent ahostsv4 "$fqdn" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd "," -)
    [[ -n "$dns_a" ]] || dns_a="-"

    http_code=$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "http://$fqdn/" 2>/dev/null || echo "ERR")
    https_code=$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "https://$fqdn/" 2>/dev/null || echo "ERR")

    tls_dates=$(timeout 10 sh -c "echo | openssl s_client -connect ${fqdn}:443 -servername ${fqdn} 2>/dev/null | openssl x509 -noout -dates -issuer" 2>/dev/null || true)
    tls_not_after=$(echo "$tls_dates" | awk -F= '/^notAfter=/{print $2; exit}')
    tls_issuer=$(echo "$tls_dates" | sed -n 's/^issuer=//p' | head -n1)
    [[ -n "$tls_not_after" ]] || tls_not_after="-"
    [[ -n "$tls_issuer" ]] || tls_issuer="-"

    echo -e "${fqdn}\t${expected_ip:--}\t${dns_a}\t${http_code}\t${https_code}\t${tls_not_after}\t${tls_issuer}"
  done
} > "$OUTDIR/tls_checks.txt" 2>&1

# Console output logs (may include cloud-init output)
if [[ ${#INSTANCE_IDS[@]} -gt 0 ]]; then
  for id in "${INSTANCE_IDS[@]}"; do
    aws ec2 get-console-output --instance-id "$id" --latest --output text > "$OUTDIR/console-${id}.log" 2>&1 || true
  done
fi

# Pull likely TLS/Caddy signals from console output logs.
{
  shopt -s nullglob
  files=("$OUTDIR"/console-*.log)
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No console logs found."
    exit 0
  fi
  for f in "${files[@]}"; do
    echo "===== $(basename "$f") ====="
    rg -i "caddy|acme|letsencrypt|certificate|tls|challenge|443|80|error|fail" "$f" || true
    echo
  done
} > "$OUTDIR/caddy_console_signals.txt" 2>&1

# Optional deeper TLS diagnostics over SSH (best-effort).
PEM="./ws.pem"
if [[ -f "$PEM" && ${#INSTANCE_IPS[@]} -gt 0 ]]; then
  mkdir -p "$OUTDIR/ssh_tls"
  chmod 600 "$PEM" >/dev/null 2>&1 || true
  for ip in "${INSTANCE_IPS[@]}"; do
    {
      echo "Instance IP: $ip"
      echo "Timestamp (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=no -i "$PEM" ubuntu@"$ip" '
        set -e
        echo "== systemctl status caddy =="
        sudo systemctl status caddy --no-pager || true
        echo
        echo "== caddy validate =="
        sudo caddy validate --config /etc/caddy/Caddyfile || true
        echo
        echo "== listeners :80/:443 =="
        sudo ss -ltnp | egrep ":80|:443" || true
        echo
        echo "== caddy journal (last 200) =="
        sudo journalctl -u caddy -n 200 --no-pager || true
      '
    } > "$OUTDIR/ssh_tls/${ip}.txt" 2>&1 || true
  done
fi

# One-file quick diagnosis summary.
{
  echo "Debug Summary"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo

  if [[ -f "$OUTDIR/tls_checks.txt" ]]; then
    dns_mismatch_count=$(awk -F'\t' '
      NR <= 1 { next }
      $1 ~ /^FQDN$/ { next }
      $2 == "-" || $3 == "-" { next }
      {
        match_found = 0
        n = split($3, arr, ",")
        for (i = 1; i <= n; i++) {
          if (arr[i] == $2) { match_found = 1; break }
        }
        if (match_found == 0) c++
      }
      END { print c+0 }
    ' "$OUTDIR/tls_checks.txt")

    https_fail_count=$(awk -F'\t' '
      NR <= 1 { next }
      $1 ~ /^FQDN$/ { next }
      $5 ~ /ERR|000/ { c++ }
      END { print c+0 }
    ' "$OUTDIR/tls_checks.txt")

    http_ok_https_fail_count=$(awk -F'\t' '
      NR <= 1 { next }
      $1 ~ /^FQDN$/ { next }
      $4 ~ /^(200|301|302|307|308)$/ && $5 ~ /ERR|000/ { c++ }
      END { print c+0 }
    ' "$OUTDIR/tls_checks.txt")

    echo "DNS mismatches (FQDN A record != expected instance IP): $dns_mismatch_count"
    echo "FQDNs with HTTPS failure: $https_fail_count"
    echo "FQDNs where HTTP works but HTTPS fails: $http_ok_https_fail_count"
    echo
  fi

  acme_conn_errors=0
  if rg -qi "acme:error:connection|Timeout during connect|likely firewall problem" "$OUTDIR/caddy_console_signals.txt" "$OUTDIR"/ssh_tls/*.txt 2>/dev/null; then
    acme_conn_errors=1
  fi

  if [[ $acme_conn_errors -eq 1 ]]; then
    echo "Likely root cause: Let's Encrypt validation cannot reach the instance on ports 80/443."
    echo "Action: ensure DNS points to current instance IPs and keep 80/443 reachable from 0.0.0.0/0 for ACME issuance/renewal."
  elif [[ -f "$OUTDIR/tls_checks.txt" ]]; then
    if [[ "${dns_mismatch_count:-0}" -gt 0 ]]; then
      echo "Likely root cause: stale or incorrect DNS records."
      echo "Action: sync Namecheap A records from terraform outputs."
    elif [[ "${http_ok_https_fail_count:-0}" -gt 0 ]]; then
      echo "Likely root cause: Caddy is reachable over HTTP but TLS is not established."
      echo "Action: inspect ssh_tls/<ip>.txt (caddy journal + validate output)."
    else
      echo "No obvious ACME firewall signature detected."
      echo "Action: inspect tls_checks.txt and ssh_tls/*.txt for per-host failures."
    fi
  fi
} > "$OUTDIR/debug_summary.txt" 2>&1

# Summarize
log "Wrote diagnostics to $OUTDIR";
echo "Files:"; ls -1 "$OUTDIR"
