#!/usr/bin/env bash
set -euo pipefail

# Uploads a code archive to S3 using the repo convention.
# Bucket: podman-build-context-<account>-<region>
# Key:    code.tar.gz
#
# Usage:
#   ./upload_code.sh [--force] [path_to_code_tgz]
#   default path: ./code.tgz

FORCE_UPLOAD=false
TAR="code.tgz"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE_UPLOAD=true
      ;;
    --help|-h)
      echo "Usage: $0 [--force] [path_to_code_tgz]"
      exit 0
      ;;
    *)
      TAR="$1"
      ;;
  esac
  shift
done
KEY_CODE=code.tar.gz
KEY_CODE_SHA256="${KEY_CODE}.sha256"

need() { command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] '$1' not found" >&2; exit 1; }; }
need aws
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  echo "[ERROR] Need sha256sum or shasum in PATH" >&2
  exit 1
fi

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

if [[ ! -f "$TAR" ]]; then
  echo "[ERROR] Code archive not found: $TAR" >&2
  exit 1
fi

if [[ -z "${AWS_DEFAULT_REGION:-}" ]]; then
  AWS_DEFAULT_REGION=$(aws configure get region || true)
  AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}
  export AWS_DEFAULT_REGION
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="podman-build-context-${ACCOUNT_ID}-${AWS_DEFAULT_REGION}"
LOCAL_HASH=$(sha256_of "$TAR")
TMP_REMOTE_HASH=$(mktemp)
TMP_LOCAL_HASH=$(mktemp)
trap 'rm -f "$TMP_REMOTE_HASH" "$TMP_LOCAL_HASH"' EXIT

bucket_exists() { aws s3api head-bucket --bucket "$1" 2>/dev/null; }
if ! bucket_exists "$BUCKET"; then
  echo "[INFO] Creating bucket $BUCKET"
  if [[ "$AWS_DEFAULT_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET"
  else
    aws s3api create-bucket --bucket "$BUCKET" \
      --create-bucket-configuration LocationConstraint="$AWS_DEFAULT_REGION"
  fi
fi

REMOTE_HASH=""
if aws s3 cp "s3://$BUCKET/$KEY_CODE_SHA256" "$TMP_REMOTE_HASH" >/dev/null 2>&1; then
  REMOTE_HASH=$(awk '{print $1}' "$TMP_REMOTE_HASH" | tr -d '\r\n')
fi

if [[ "$FORCE_UPLOAD" != "true" && -n "$REMOTE_HASH" && "$REMOTE_HASH" == "$LOCAL_HASH" ]]; then
  echo "[INFO] Code archive unchanged (sha256 matches); skipping upload for s3://$BUCKET/$KEY_CODE"
else
  if [[ "$FORCE_UPLOAD" == "true" ]]; then
    echo "[INFO] Force upload enabled; uploading code archive even if unchanged"
  fi
  echo "[INFO] Uploading code archive to s3://$BUCKET/$KEY_CODE"
  aws s3 cp "$TAR" "s3://$BUCKET/$KEY_CODE"
  printf '%s\n' "$LOCAL_HASH" > "$TMP_LOCAL_HASH"
  echo "[INFO] Updating checksum marker: s3://$BUCKET/$KEY_CODE_SHA256"
  aws s3 cp "$TMP_LOCAL_HASH" "s3://$BUCKET/$KEY_CODE_SHA256"
fi

echo "[OK] Code upload complete"
