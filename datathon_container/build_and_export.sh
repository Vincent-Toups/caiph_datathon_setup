#!/usr/bin/env bash
set -euo pipefail

# Build and export the datathon container image with Podman.
# All settings are intentionally hard-coded.
IMG="datathon:latest"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$PWD/container-image.tgz"

need() { command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] '$1' not found in PATH" >&2; exit 1; }; }
need podman
need gzip

cd "$SCRIPT_DIR"
echo "[INFO] Building image: $IMG"
podman build -t "$IMG" -f Containerfile .

echo "[INFO] Exporting and compressing image stream to: $OUT"
podman save "$IMG" | gzip -c > "$OUT"

# Report compressed size
if command -v du >/dev/null 2>&1; then
  GZ_SIZE=$(du -h "$OUT" | awk '{print $1}')
  echo "[INFO] Compressed image size (tar.gz): $GZ_SIZE"
fi

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256") || true
elif command -v shasum >/dev/null 2>&1; then
  (cd "$(dirname "$OUT")" && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256") || true
fi

echo "[OK] Image exported: $OUT"
