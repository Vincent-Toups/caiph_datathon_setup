#!/usr/bin/env bash
#
# upload_build_context.sh
#
# Usage:
#   ./upload_build_context.sh <context_dir> [bucket_name] [zip_key]
#
# Example:
#   ./upload_build_context.sh ./myapp
#

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <context_dir> [bucket_name] [zip_key]" >&2
  exit 1
fi

CONTEXT_DIR="$1"
ZIP_KEY="${3:-build-context.zip}"

if [[ ! -d "$CONTEXT_DIR" ]]; then
  echo "Directory '$CONTEXT_DIR' not found." >&2
  exit 1
fi

# Load AWS credentials from env.txt inside context dir if present
ENV_FILE="$CONTEXT_DIR/env.txt"
if [[ -f "$ENV_FILE" ]]; then
  echo "Loading AWS credentials from $ENV_FILE"
  set -o allexport
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +o allexport
fi

# Resolve region
REGION="${AWS_DEFAULT_REGION:-$(aws configure get region)}"
if [[ -z "$REGION" ]]; then
  echo "AWS region not set. Set AWS_DEFAULT_REGION or configure AWS CLI." >&2
  exit 1
fi

# Default bucket name if not provided
if [[ $# -ge 2 ]]; then
  BUCKET_NAME="$2"
else
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  BUCKET_NAME="podman-build-context-${ACCOUNT_ID}-${REGION}"
fi

echo "Using bucket: $BUCKET_NAME"

CONTAINERFILE="$CONTEXT_DIR/Containerfile"
if [[ ! -f "$CONTAINERFILE" ]]; then
  echo "Containerfile not found in $CONTEXT_DIR" >&2
  exit 1
fi

bucket_exists() {
  aws s3api head-bucket --bucket "$1" 2>/dev/null
}

if ! bucket_exists "$BUCKET_NAME"; then
  echo "Creating bucket $BUCKET_NAME ..."
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME"
  else
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
fi

echo "Collecting build context from $CONTEXT_DIR ..."
cd "$CONTEXT_DIR"

files_to_zip=("Containerfile")

while IFS= read -r line; do
  line="$(echo "$line" | sed 's/#.*//')"
  [[ -z "$line" ]] && continue

  if [[ "$line" =~ ^[[:space:]]*(COPY|ADD)[[:space:]]+ ]]; then
    rest=$(echo "$line" | sed -E 's/^[[:space:]]*(COPY|ADD)[[:space:]]+//')
    read -ra tokens <<< "$rest"
    unset 'tokens[${#tokens[@]}-1]'

    for src in "${tokens[@]}"; do
      if [[ "$src" =~ ^https?:// ]]; then
        continue
      fi

      if [[ "$src" == "." ]]; then
        mapfile -t all_files < <(find . -type f ! -path "./.git/*")
        files_to_zip+=("${all_files[@]}")
      elif [[ -d "$src" ]]; then
        mapfile -t dir_files < <(find "$src" -type f)
        files_to_zip+=("${dir_files[@]}")
      elif [[ -f "$src" ]]; then
        files_to_zip+=("$src")
      fi
    done
  fi
done < Containerfile

mapfile -t files_to_zip < <(printf "%s\n" "${files_to_zip[@]}" | sort -u)

tmpdir=$(mktemp -d)
zip_path="$tmpdir/$ZIP_KEY"

echo "Creating zip archive ..."
zip -q -r "$zip_path" "${files_to_zip[@]}"

echo "Uploading to s3://$BUCKET_NAME/$ZIP_KEY ..."
aws s3 cp "$zip_path" "s3://$BUCKET_NAME/$ZIP_KEY"

rm -rf "$tmpdir"

echo "Done."
