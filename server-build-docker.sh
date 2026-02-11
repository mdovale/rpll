#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="${SERVER_DIR:-$SCRIPT_DIR/rpll_server/esw}"
DOCKERFILE="$SCRIPT_DIR/server.Dockerfile"

IMAGE_NAME="${IMAGE_NAME:-rp-ll-server-builder}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
BUILD_DIR="$SCRIPT_DIR/build-docker"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-}"
CFLAGADD="${CFLAGADD:-}"
JOBS=""
ACTION="build"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --build-dir DIR    Output directory for the binary [default: build-docker]
  --image NAME       Docker image name [default: rp-ll-server-builder]
  --tag TAG          Docker image tag [default: latest]
  --platform PLAT    Docker platform (optional)
  --cflagadd FLAGS   Extra flags appended via Makefile CFLAGADD
  --variant VAR      Build variant: laser_lock (default) or phasemeter
  --jobs N           Parallel build jobs [default: auto]
  --clean            Remove build directory only
  --rebuild          Rebuild Docker image and build
  --shell            Open interactive shell in builder container
  --help             Show this help

Environment:
  IMAGE_NAME         Docker image name (same as --image)
  IMAGE_TAG          Docker image tag (same as --tag)
  DOCKER_PLATFORM    Docker platform (same as --platform)
  CFLAGADD           Extra compiler flags (same as --cflagadd)

Examples:
  ./server-build-docker.sh
  ./server-build-docker.sh --rebuild
  ./server-build-docker.sh --shell
EOF
}

resolve_path() {
  if [[ "$1" = /* ]]; then
    echo "$1"
  else
    echo "$SCRIPT_DIR/$1"
  fi
}

detect_jobs() {
  getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir)
      BUILD_DIR="$2"
      shift 2
      ;;
    --image)
      IMAGE_NAME="$2"
      shift 2
      ;;
    --tag)
      IMAGE_TAG="$2"
      shift 2
      ;;
    --platform)
      DOCKER_PLATFORM="$2"
      shift 2
      ;;
    --cflagadd)
      CFLAGADD="$2"
      shift 2
      ;;
    --variant)
      if [[ "$2" == "phasemeter" ]]; then
        CFLAGADD="${CFLAGADD:+$CFLAGADD }-DRP_VARIANT_PHASEMETER"
      elif [[ "$2" != "laser_lock" ]]; then
        echo -e "${RED}Error: --variant must be 'laser_lock' or 'phasemeter'${NC}" >&2
        exit 1
      fi
      shift 2
      ;;
    --jobs)
      JOBS="$2"
      shift 2
      ;;
    --clean)
      ACTION="clean"
      shift
      ;;
    --rebuild)
      ACTION="rebuild"
      shift
      ;;
    --shell)
      ACTION="shell"
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}" >&2
      usage >&2
      exit 1
      ;;
  esac
done

BUILD_DIR="$(resolve_path "$BUILD_DIR")"
JOBS="${JOBS:-$(detect_jobs)}"
IMAGE_REF="${IMAGE_NAME}:${IMAGE_TAG}"
if [[ "$BUILD_DIR" != "$SCRIPT_DIR/"* ]]; then
  echo -e "${RED}Error: --build-dir must be within repo when using Docker.${NC}" >&2
  exit 1
fi
BUILD_DIR_REL="${BUILD_DIR#"$SCRIPT_DIR/"}"

if [[ ! -f "$SERVER_DIR/Makefile" ]]; then
  echo -e "${RED}Error: Makefile not found in $SERVER_DIR${NC}" >&2
  exit 1
fi

if [[ ! -f "$DOCKERFILE" ]]; then
  echo -e "${RED}Error: Dockerfile not found at $DOCKERFILE${NC}" >&2
  exit 1
fi

if ! command -v docker &>/dev/null; then
  echo -e "${RED}Error: docker is not installed or not in PATH${NC}" >&2
  exit 1
fi

docker_user_args=()
if command -v id &>/dev/null; then
  uid="$(id -u 2>/dev/null || true)"
  gid="$(id -g 2>/dev/null || true)"
  if [[ -n "${uid:-}" && -n "${gid:-}" ]]; then
    docker_user_args=(--user "${uid}:${gid}")
  fi
fi

build_image() {
  local no_cache="${1:-}"
  echo -e "${BLUE}Building Docker image: ${IMAGE_REF}${NC}"
  build_cmd=(docker build)
  if [[ "$no_cache" == "--no-cache" ]]; then
    build_cmd+=(--no-cache)
  fi
  if [[ -n "$DOCKER_PLATFORM" ]]; then
    build_cmd+=(--platform "$DOCKER_PLATFORM")
  fi
  build_cmd+=(-t "$IMAGE_REF" -f "$DOCKERFILE" "$SCRIPT_DIR")
  "${build_cmd[@]}"
}

run_shell() {
  echo -e "${GREEN}Opening shell in Docker container...${NC}"
  run_cmd=(docker run --rm -it)
  if [[ -n "$DOCKER_PLATFORM" ]]; then
    run_cmd+=(--platform "$DOCKER_PLATFORM")
  fi
  run_cmd+=("${docker_user_args[@]}" -v "$SCRIPT_DIR:/work" -w /work/rpll_server/esw "$IMAGE_REF" bash)
  "${run_cmd[@]}"
}

run_build() {
  echo -e "${GREEN}Building server in Docker...${NC}"
  mkdir -p "$BUILD_DIR"
  local container_build_dir="/work/$BUILD_DIR_REL"
  run_cmd=(docker run --rm)
  if [[ -n "$DOCKER_PLATFORM" ]]; then
    run_cmd+=(--platform "$DOCKER_PLATFORM")
  fi
  run_cmd+=("${docker_user_args[@]}" -v "$SCRIPT_DIR:/work" -w /work/rpll_server/esw "$IMAGE_REF")
  # Always do a clean + forced rebuild.
  # This avoids confusing "make: Nothing to be done for 'all'" cases and ensures
  # the output binary is always freshly produced by the container toolchain.
  local build_make_cmd=""
  if [[ -n "$CFLAGADD" ]]; then
    build_make_cmd="make -B -j $JOBS CC=arm-linux-gnueabihf-gcc CFLAGADD=\"${CFLAGADD}\""
  else
    build_make_cmd="make -B -j $JOBS CC=arm-linux-gnueabihf-gcc"
  fi
  run_cmd+=(bash -lc "make clean >/dev/null 2>&1 || true; rm -f server; ${build_make_cmd} && cp server \"${container_build_dir}/server\"")
  "${run_cmd[@]}"
  if command -v file &>/dev/null; then
    built_type="$(file "$BUILD_DIR/server" 2>/dev/null || true)"
    echo "$built_type"
    if ! echo "$built_type" | grep -Eqi 'ELF.*(ARM|aarch64)'; then
      echo -e "${RED}Error: built binary is not an ELF ARM executable.${NC}" >&2
      echo -e "${RED}Type: $built_type${NC}" >&2
      echo -e "${YELLOW}Hint: run 'make -C rpll_server/esw clean' (or delete rpll_server/esw/server) and then rerun:${NC}" >&2
      echo -e "${YELLOW}  ./server-build-docker.sh${NC}" >&2
      exit 1
    fi
  fi
  echo -e "${GREEN}Build completed successfully.${NC}"
}

case "$ACTION" in
  clean)
    echo -e "${YELLOW}Cleaning build directory...${NC}"
    rm -rf "$BUILD_DIR"
    ;;
  rebuild)
    build_image --no-cache
    run_build
    ;;
  shell)
    if ! docker image inspect "$IMAGE_REF" &>/dev/null; then
      build_image
    fi
    run_shell
    ;;
  build)
    if ! docker image inspect "$IMAGE_REF" &>/dev/null; then
      build_image
    fi
    run_build
    ;;
  *)
    echo -e "${RED}Unknown action: $ACTION${NC}" >&2
    exit 1
    ;;
esac
