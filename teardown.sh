#!/usr/bin/env bash
set -euo pipefail

# Teardown AWS resources created by the last Terraform apply in this repo.
# Reads identifiers from terraform.tfstate and deletes in safe dependency order.
#
# Usage:
#   ./teardown.sh
#   ./teardown.sh --purge-s3
#
# Optional:
#   --purge-s3  Also remove build artifacts from
#               s3://podman-build-context-<account>-<region>

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; }

PURGE_S3=false
if [[ "${1:-}" == "--purge-s3" ]]; then
  PURGE_S3=true
elif [[ "${1:-}" != "" ]]; then
  err "Unknown argument: $1"
  err "Usage: ./teardown.sh [--purge-s3]"
  exit 1
fi

need() { command -v "$1" >/dev/null 2>&1 || { err "'$1' not found in PATH"; exit 1; }; }
need aws
need jq

STATE_FILE="terraform.tfstate"
if [[ ! -f "$STATE_FILE" ]]; then
  err "State file not found: $STATE_FILE"
  exit 1
fi

if [[ -z "${AWS_DEFAULT_REGION:-}" ]]; then
  AWS_DEFAULT_REGION=$(aws configure get region || true)
  AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}
  export AWS_DEFAULT_REGION
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="podman-build-context-${ACCOUNT_ID}-${AWS_DEFAULT_REGION}"

# Pull IDs from state.
readarray -t INSTANCE_IDS < <(jq -r '
  .resources[]
  | select(.mode=="managed" and .type=="aws_instance" and .name=="node")
  | .instances[]
  | .attributes.id
' "$STATE_FILE")

SG_ID=$(jq -r '
  .resources[]
  | select(.mode=="managed" and .type=="aws_security_group" and .name=="svc")
  | .instances[0].attributes.id // empty
' "$STATE_FILE")

ROLE_NAME=$(jq -r '
  .resources[]
  | select(.mode=="managed" and .type=="aws_iam_role" and .name=="ec2_role")
  | .instances[0].attributes.name // empty
' "$STATE_FILE")

PROFILE_NAME=$(jq -r '
  .resources[]
  | select(.mode=="managed" and .type=="aws_iam_instance_profile" and .name=="ec2_profile")
  | .instances[0].attributes.name // empty
' "$STATE_FILE")

POLICY_ARN=$(jq -r '
  .resources[]
  | select(.mode=="managed" and .type=="aws_iam_policy" and .name=="s3_read")
  | .instances[0].attributes.arn // empty
' "$STATE_FILE")

log "Region: $AWS_DEFAULT_REGION"
log "Account: $ACCOUNT_ID"

# 1) EC2 instances
if [[ ${#INSTANCE_IDS[@]} -gt 0 ]]; then
  log "Terminating instances: ${INSTANCE_IDS[*]}"
  aws ec2 terminate-instances --region "$AWS_DEFAULT_REGION" --instance-ids "${INSTANCE_IDS[@]}" >/dev/null || true
  log "Waiting for instances to terminate"
  aws ec2 wait instance-terminated --region "$AWS_DEFAULT_REGION" --instance-ids "${INSTANCE_IDS[@]}" || true
else
  log "No aws_instance.node IDs found in state"
fi

# 2) Security group
if [[ -n "$SG_ID" ]]; then
  log "Deleting security group: $SG_ID"
  aws ec2 delete-security-group --region "$AWS_DEFAULT_REGION" --group-id "$SG_ID" >/dev/null || true
else
  log "No aws_security_group.svc ID found in state"
fi

# 3) IAM links and resources
if [[ -n "$PROFILE_NAME" && -n "$ROLE_NAME" ]]; then
  log "Removing role from instance profile: $PROFILE_NAME <- $ROLE_NAME"
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --role-name "$ROLE_NAME" >/dev/null || true
fi

if [[ -n "$PROFILE_NAME" ]]; then
  log "Deleting instance profile: $PROFILE_NAME"
  aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null || true
fi

if [[ -n "$ROLE_NAME" && -n "$POLICY_ARN" ]]; then
  log "Detaching role policy: $ROLE_NAME -X- $POLICY_ARN"
  aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" >/dev/null || true
fi

if [[ -n "$ROLE_NAME" ]]; then
  log "Deleting IAM role: $ROLE_NAME"
  aws iam delete-role --role-name "$ROLE_NAME" >/dev/null || true
fi

if [[ -n "$POLICY_ARN" ]]; then
  log "Deleting IAM policy: $POLICY_ARN"
  aws iam delete-policy --policy-arn "$POLICY_ARN" >/dev/null || true
fi

# 4) Optional S3 cleanup for build artifacts uploaded during deploys.
if [[ "$PURGE_S3" == "true" ]]; then
  log "Purging uploaded artifacts from s3://$BUCKET"
  aws s3 rm "s3://$BUCKET/build-context.zip" >/dev/null 2>&1 || true
  aws s3 rm "s3://$BUCKET/container-image.tar.gz" >/dev/null 2>&1 || true
  aws s3 rm "s3://$BUCKET/env.txt" >/dev/null 2>&1 || true
fi

cat <<EOF
[OK] Teardown attempts completed.
If you want a clean Terraform state before re-apply, run:
  rm -f terraform.tfstate terraform.tfstate.backup
Then deploy again with:
  ./deploy.sh
EOF
