#!/usr/bin/env bash
set -euo pipefail

# Local dev runner using podman. Mounts datasets and code into the container
# and starts Jupyter + Opencode without Caddy.
#
# Usage:
#   ./local_run.sh
#
# Optional env vars:
#   IMAGE_NAME        (default: datathon:latest)
#   DATASETS_DIR      (default: ./datasets)
#   CODE_DIR          (default: ./code)
#   ENV_FILE          (default: ./env.txt if exists)
#   JUPYTER_PORT      (default: 8888)
#   OPENCODE_PORT     (default: 3000)
#   JUPYTER_TOKEN     (default: empty => no token)

IMAGE_NAME="${IMAGE_NAME:-datathon:latest}"
DATASETS_DIR="${DATASETS_DIR:-datasets}"
CODE_DIR="${CODE_DIR:-code}"
ENV_FILE="${ENV_FILE:-env.txt}"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"
OPENCODE_PORT="${OPENCODE_PORT:-3000}"
JUPYTER_TOKEN="${JUPYTER_TOKEN:-}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] '$1' not found" >&2; exit 1; }; }
need podman

DATASETS_DIR_ABS="$(cd "$DATASETS_DIR" && pwd)"
CODE_DIR_ABS="$(cd "$CODE_DIR" && pwd)"

if [[ ! -d "$DATASETS_DIR_ABS" ]]; then
  echo "[ERROR] datasets dir not found: $DATASETS_DIR" >&2
  exit 1
fi
if [[ ! -d "$CODE_DIR_ABS" ]]; then
  echo "[ERROR] code dir not found: $CODE_DIR" >&2
  exit 1
fi

ENV_ARGS=()
if [[ -f "$ENV_FILE" ]]; then
  ENV_ARGS=( --env-file "$ENV_FILE" )
fi

DATASETS_MOUNT=( -v "$DATASETS_DIR_ABS:/data:ro" )
CODE_MOUNT=( -v "$CODE_DIR_ABS:/code:rw" )

RUN1_CMD="jupyter lab --ip=0.0.0.0 --port=${JUPYTER_PORT} --no-browser --allow-root --ServerApp.base_url=/jupyter --ServerApp.root_dir=/code"
if [[ -n "$JUPYTER_TOKEN" ]]; then
  RUN1_CMD="$RUN1_CMD --ServerApp.token=${JUPYTER_TOKEN}"
else
  RUN1_CMD="$RUN1_CMD --ServerApp.token=''"
fi

# Clean up any existing containers
podman rm -f jupyter-local >/dev/null 2>&1 || true
podman rm -f opencode-local >/dev/null 2>&1 || true

echo "[INFO] Starting Jupyter at http://localhost:${JUPYTER_PORT}/jupyter"
podman run -d --name jupyter-local \
  --user 0 \
  --workdir /code \
  "${ENV_ARGS[@]}" \
  "${DATASETS_MOUNT[@]}" \
  "${CODE_MOUNT[@]}" \
  -p "${JUPYTER_PORT}:${JUPYTER_PORT}" \
  "${IMAGE_NAME}" bash -lc "$RUN1_CMD"

echo "[INFO] Starting Opencode at http://localhost:${OPENCODE_PORT}/"
podman run -d --name opencode-local \
  --user 0 \
  --workdir /code \
  "${ENV_ARGS[@]}" \
  "${DATASETS_MOUNT[@]}" \
  "${CODE_MOUNT[@]}" \
  -p "${OPENCODE_PORT}:${OPENCODE_PORT}" \
  "${IMAGE_NAME}" bash -lc "/root/.opencode/bin/opencode web --port ${OPENCODE_PORT} --hostname 0.0.0.0"

echo "[OK] Local containers running"
