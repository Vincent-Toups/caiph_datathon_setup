#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-datathon:latest}"
TEAM_FQDN="${TEAM_FQDN:-team0.caiphdatathon.com}"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$WORKDIR/env.txt}"
CONTEXT_DIR="${CONTEXT_DIR:-$WORKDIR/datathon_container}"
HOST_MOUNT="${HOST_MOUNT:-$WORKDIR}"
CONTAINER_WORKDIR="${CONTAINER_WORKDIR:-/workspace}"

if ! command -v podman >/dev/null 2>&1; then
  echo "podman not found in PATH" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

if ! podman image exists "$IMAGE_NAME"; then
  if [[ -d "$CONTEXT_DIR" ]]; then
    echo "Image $IMAGE_NAME not found. Building from $CONTEXT_DIR ..."
    podman build -t "$IMAGE_NAME" "$CONTEXT_DIR"
  else
    echo "Image $IMAGE_NAME not found and build context missing: $CONTEXT_DIR" >&2
    exit 1
  fi
fi

TOKEN="${JUPYTER_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    TOKEN="$(openssl rand -hex 16)"
  else
    TOKEN="token-$(date +%s)"
  fi
fi

# Clean up any previous containers
podman rm -f team00-jupyter >/dev/null 2>&1 || true
podman rm -f team00-opencode >/dev/null 2>&1 || true

# Start Jupyter (with /jupyter base URL)
podman run -d --name team00-jupyter \
  --user 0 \
  -v "$HOST_MOUNT:$CONTAINER_WORKDIR:rw" \
  --workdir "$CONTAINER_WORKDIR" \
  --env-file "$ENV_FILE" \
  -p 8888:8888 \
  "$IMAGE_NAME" bash -lc "jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root --ServerApp.token=$TOKEN --ServerApp.base_url=/jupyter"

# Start Opencode
podman run -d --name team00-opencode \
  --user 0 \
  -v "$HOST_MOUNT:$CONTAINER_WORKDIR:rw" \
  --workdir "$CONTAINER_WORKDIR" \
  --env-file "$ENV_FILE" \
  -p 3000:3000 \
  "$IMAGE_NAME" bash -lc "/root/.opencode/bin/opencode web --port 3000 --hostname 0.0.0.0"

cat <<EOT

Local containers started:
- team00-jupyter on http://localhost:8888 (token: $TOKEN)
- team00-opencode on http://localhost:3000

$TEAM_FQDN {
  handle /jupyter* {
    reverse_proxy 127.0.0.1:8888
  }
  handle {
    reverse_proxy 127.0.0.1:3000
  }
}

Likely Caddyfile location on Linux: /etc/caddy/Caddyfile
EOT
