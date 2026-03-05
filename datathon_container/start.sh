#!/usr/bin/env bash
set -euo pipefail

# Defaults
IMAGE_NAME=vincenttoups/datathon
CONTAINERFILE=Containerfile
RUN_CMD=()
PASSTHRU_ARGS=()
DAEMONIZE=false
SERVE_MODE=false
CONTAINER_NAME=""
JUST_BUILD=false
SKIP_BUILD=false
CUDA_VERSION_OVERRIDE=""
NVIDIA_TEST=false
SHOW_BUILD=false
PORTS=()
BUILD_WITH_HOST_NETWORK=false   # build-time networking
CONFIG_FILE_CANDIDATE="config.yaml"  # unused; legacy

# Detect host architecture; force amd64 on arm64 hosts
HOST_ARCH="$(uname -m 2>/dev/null || echo unknown)"
FORCE_AMD64=false
if [[ "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64" ]]; then
  FORCE_AMD64=true
  printf '[INFO] Host arch %s detected; forcing linux/amd64 for build/run.\n' "$HOST_ARCH"
fi

# No X11/GUI handling; Jupyter runs in the browser
USE_GUI=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--image)    IMAGE_NAME="$2"; shift 2 ;;
    -f|--file)     CONTAINERFILE="$2"; shift 2 ;;
    --run)         shift; RUN_CMD=("$1"); shift ;;
    --daemonize|-d) DAEMONIZE=true; shift ;;
    --name)        CONTAINER_NAME="$2"; shift 2 ;;
    --cuda-version) CUDA_VERSION_OVERRIDE="$2"; shift 2 ;;
    --nvidia-test)
      NVIDIA_TEST=true
      RUN_CMD=(nvidia-smi)
      DAEMONIZE=false
      shift ;;
    --show-container-build)
      SHOW_BUILD=true; shift ;;
    --skip-build)
      SKIP_BUILD=true; shift ;;
    --serve)
      DAEMONIZE=true
      SERVE_MODE=true
      shift
      ;;
    --port)
      PORTS+=("$2"); shift 2 ;;
    --just-build)
      JUST_BUILD=true; shift ;;
    --build-network-host)
      BUILD_WITH_HOST_NETWORK=true; shift ;;
    --help|-h)
      cat <<EOF
Usage: $0 [options] [-- command args...]

Options:
      -i, --image NAME         Set image name (default: vincenttoups/labradore)
  -f, --file FILE          Containerfile to build (default: Containerfile)
      --run CMD            Command to run in container
  -d, --daemonize          Run container in background
      --name NAME          Assign container name
      --cuda-version VER   Override CUDA for build (e.g., 12.8.0)
      --nvidia-test        Run 'nvidia-smi' inside container and exit
      --show-container-build Stream build output and tee to .build-log
      --port PORTSPEC      Publish a port (repeatable). Examples: 8767, 8767:8767, 127.0.0.1:8767:8767
                           Note: specifying any --port disables host networking.
      --just-build         Only build the image, do not start a container
      --skip-build         Do not build; just launch the container
      --build-network-host Build the image with --network=host (use host DNS/network during build)
  -h, --help               Show this help message
EOF
      exit 0
      ;;
    --)            shift; PASSTHRU_ARGS=("$@"); break ;;
    *)             echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Validate incompatible flags
if [[ "$JUST_BUILD" == true && "$SKIP_BUILD" == true ]]; then
  echo "[ERROR] --just-build and --skip-build are mutually exclusive." >&2
  exit 2
fi

# Detect CUDA version and GPU availability (after parsing for override)
GPU_AVAILABLE=false
CUDA_VERSION_DEFAULT="13.0.0"
CudaHostToolPresent=false
CUDA_VERSION=""
if command -v nvidia-smi >/dev/null 2>&1; then
  CudaHostToolPresent=true
  ver=$(nvidia-smi --version 2>/dev/null \
    | awk -F': ' '/CUDA Version/ {print $2}' \
    | tr -d '[:space:]') || ver=""
  if [[ -n "$ver" ]]; then
    GPU_AVAILABLE=true
    # Normalize to major.minor.patch (append .0 if only major.minor)
    if [[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]]; then
      CUDA_VERSION="${ver}.0"
    elif [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      CUDA_VERSION="$ver"
    else
      CUDA_VERSION="$CUDA_VERSION_DEFAULT"
    fi
  fi
fi
if [[ -z "$CUDA_VERSION" ]]; then
  CUDA_VERSION="$CUDA_VERSION_DEFAULT"
fi

# Ensure required helper files exist
# No envfile/container_mounts support; keeping things simple

# Allow explicit override of build CUDA version
if [[ -n "$CUDA_VERSION_OVERRIDE" ]]; then
  if [[ "$CUDA_VERSION_OVERRIDE" =~ ^[0-9]+\.[0-9]+$ ]]; then
    CUDA_VERSION="${CUDA_VERSION_OVERRIDE}.0"
  else
    CUDA_VERSION="$CUDA_VERSION_OVERRIDE"
  fi
  printf '[INFO] CUDA version override: %s\n' "$CUDA_VERSION"
fi

if [[ "$GPU_AVAILABLE" == true ]]; then
  printf '[INFO] NVIDIA GPU detected. CUDA version: %s\n' "$CUDA_VERSION"
else
  if [[ "$CudaHostToolPresent" != true ]]; then
    printf '[INFO] Host tool nvidia-smi not found; assuming no NVIDIA GPU.\n'
  fi
  printf '[INFO] No NVIDIA GPU detected. Using CPU-only settings.\n'
fi

# Always use Containerfile (GPU or not)
CONTAINERFILE="Containerfile"

if [[ "$SKIP_BUILD" != true ]]; then
  printf '[INFO] Building %s from %s using podman…\n' "$IMAGE_NAME" "$CONTAINERFILE"
  BUILD_LOG=.build-log
  build_cmd=(podman build --pull=missing --layers --build-arg CUDA_VERSION="$CUDA_VERSION" -t "$IMAGE_NAME" -f "$CONTAINERFILE")
  if [[ "$FORCE_AMD64" == true ]]; then
    build_cmd+=( --platform=linux/amd64 )
  fi
  if [[ "$BUILD_WITH_HOST_NETWORK" == true ]]; then
    build_cmd+=( --network=host )
  fi
  build_cmd+=( . )

  if [[ "$SHOW_BUILD" == true ]]; then
    "${build_cmd[@]}" 2>&1 | tee "$BUILD_LOG"
  else
    "${build_cmd[@]}"
  fi

  if [[ "$JUST_BUILD" == true ]]; then
    printf '[INFO] Build-only flag set; not starting a container.\n'
    exit 0
  fi
else
  printf '[INFO] --skip-build set; skipping image build.\n'
fi

# If explicitly testing NVIDIA but none is detected, exit early with guidance
if [[ "$NVIDIA_TEST" == true && "$GPU_AVAILABLE" != true ]]; then
  printf '[ERROR] --nvidia-test requested, but no NVIDIA GPU or host nvidia-smi found.\n'
  printf '        Ensure NVIDIA drivers and container toolkit are installed, then retry.\n'
  exit 1
fi

# Initialize arrays and derive home target inside container
env_args=()
mounts=( -v "$(pwd)":/book )

# Fixed HOME inside container
TARGET_HOME="/book"
env_args+=( -e "HOME=$TARGET_HOME" )

# No X11 support

# No extra HOME mounts



# No supplemental mounts file

# No Podman socket exposure

# No editor mounts

# No config.yaml mounting or FUSE flags

# Jupyter defaults and URL computation
JL_IP="0.0.0.0"
JL_ROOT="/book"
JL_TOKEN_DEFAULT="datathon"
JL_PORT_DEFAULT="8888"

# Determine effective host/container ports for Jupyter
JL_HOST_PORT="$JL_PORT_DEFAULT"
JL_CONTAINER_PORT="$JL_PORT_DEFAULT"
if [[ ${#PORTS[@]} -gt 0 ]]; then
  p="${PORTS[0]}"
  # Supported forms: 8767 | 8767:8767 | 127.0.0.1:8767:8767
  if [[ "$p" == *:*:* ]]; then
    # ip:host:container
    JL_HOST_PORT="${p#*:}"
    JL_HOST_PORT="${JL_HOST_PORT%%:*}"
    JL_CONTAINER_PORT="${p##*:}"
  elif [[ "$p" == *:* ]]; then
    # host:container
    JL_HOST_PORT="${p%%:*}"
    JL_CONTAINER_PORT="${p##*:}"
  else
    # single number: same host/container port
    JL_HOST_PORT="$p"
    JL_CONTAINER_PORT="$p"
  fi
fi

# Build default Jupyter Lab command when not explicitly set or in --serve
if [[ ${#RUN_CMD[@]} -eq 0 || "$SERVE_MODE" == true ]]; then
  JL_TOKEN="$JL_TOKEN_DEFAULT"
  RUN_CMD=(
      jupyter lab
      --allow-root
    --ServerApp.ip="$JL_IP"
    --ServerApp.port="$JL_CONTAINER_PORT"
    --ServerApp.token="$JL_TOKEN"
    --ServerApp.open_browser=False
    --ServerApp.root_dir="$JL_ROOT"
    --collaborative
  )
fi

# Compose URL for user visibility (host-side)
JUPYTER_URL="http://127.0.0.1:${JL_HOST_PORT}/lab?token=${JL_TOKEN_DEFAULT}"

# Append passthrough args
if [[ ${#PASSTHRU_ARGS[@]} -gt 0 ]]; then
  RUN_CMD+=("${PASSTHRU_ARGS[@]}")
fi

# Run functions
run_podman() {
  local run_flags=(--user root --workdir /book)
  if [[ "$FORCE_AMD64" == true ]]; then
    run_flags+=( --arch amd64 )
  fi
  if [[ ${#PORTS[@]} -gt 0 ]]; then
    for p in "${PORTS[@]}"; do run_flags+=( -p "$p" ); done
  else
    run_flags+=( --network host )
  fi
  if [[ "$GPU_AVAILABLE" == true ]]; then
    run_flags+=( --device nvidia.com/gpu=all )
  fi
  if [[ "$DAEMONIZE" == true ]]; then
    echo "[INFO] JupyterLab URL: $JUPYTER_URL"
    run_flags=(-d "${run_flags[@]}")
    [[ -n "$CONTAINER_NAME" ]] && run_flags=(--name "$CONTAINER_NAME" "${run_flags[@]}")
    cid=$(podman run "${run_flags[@]}" "${mounts[@]}" "${env_args[@]}" "$IMAGE_NAME" "${RUN_CMD[@]}")
    echo "[INFO] Container started in daemon mode."
    echo "[INFO] Container ID: $cid"
    [[ -n "$CONTAINER_NAME" ]] && echo "[INFO] Container name: $CONTAINER_NAME"
  else
    run_flags=(-it --rm "${run_flags[@]}")
    echo "[INFO] JupyterLab URL: $JUPYTER_URL"
    podman run "${run_flags[@]}" "${mounts[@]}" "${env_args[@]}" "$IMAGE_NAME" "${RUN_CMD[@]}"
  fi
}

printf '[INFO] Launching container with podman…\n'
run_podman
