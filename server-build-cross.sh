#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="${SERVER_DIR:-$SCRIPT_DIR/rpll_server/esw}"

BUILD_DIR="$SCRIPT_DIR/build-cross"
BINARY_NAME="server"
CC_BIN="${CC:-arm-linux-gnueabihf-gcc}"
CFLAGADD="${CFLAGADD:-}"
JOBS=""
ACTION="build"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --build-dir DIR    Output directory for the binary [default: build-cross]
  --cc PATH          Cross-compiler to use [default: arm-linux-gnueabihf-gcc]
  --cflagadd FLAGS   Extra flags appended via Makefile CFLAGADD
  --variant VAR      Build variant: laser_lock (default) or phasemeter
  --jobs N           Parallel build jobs [default: auto]
  --clean            Remove build directory and run 'make clean'
  --rebuild          Clean then build
  --help             Show this help

Environment:
  CC                Cross-compiler (same as --cc)
  CFLAGADD          Extra compiler flags (same as --cflagadd)

Examples:
  ./server-build-cross.sh
  ./server-build-cross.sh --variant phasemeter
  ./server-build-cross.sh --cc /opt/cross/bin/arm-linux-gnueabihf-gcc
  ./server-build-cross.sh --build-dir out/server --jobs 8
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
    --cc)
      CC_BIN="$2"
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

if [[ ! -f "$SERVER_DIR/Makefile" ]]; then
  echo -e "${RED}Error: Makefile not found in $SERVER_DIR${NC}" >&2
  exit 1
fi

if [[ "$CC_BIN" == */* ]]; then
  if [[ ! -x "$CC_BIN" ]]; then
    echo -e "${RED}Error: Compiler not executable: $CC_BIN${NC}" >&2
    exit 1
  fi
else
  if ! command -v "$CC_BIN" &>/dev/null; then
    echo -e "${RED}Error: Compiler not found in PATH: $CC_BIN${NC}" >&2
    echo -e "${YELLOW}Install gcc-arm-linux-gnueabihf or pass --cc PATH.${NC}" >&2
    exit 1
  fi
fi

make_clean() {
  echo -e "${YELLOW}Cleaning server build...${NC}"
  make -C "$SERVER_DIR" clean
  rm -rf "$BUILD_DIR"
}

make_build() {
  echo -e "${GREEN}Building server (cross-compile)...${NC}"
  echo "Compiler: $CC_BIN"
  echo "Jobs: $JOBS"
  echo "Output: $BUILD_DIR/$BINARY_NAME"
  mkdir -p "$BUILD_DIR"

  # If a previous build artifact exists but is for a different OS/format
  # (e.g., Mach-O from macOS), `make` may think everything is up-to-date and
  # skip rebuilding. Detect that and force a clean rebuild.
  if [[ -f "$SERVER_DIR/$BINARY_NAME" ]] && command -v file &>/dev/null; then
    existing_type="$(file "$SERVER_DIR/$BINARY_NAME" 2>/dev/null || true)"
    if ! echo "$existing_type" | grep -Eqi 'ELF.*(ARM|aarch64)'; then
      echo -e "${YELLOW}Existing $SERVER_DIR/$BINARY_NAME is not an ELF ARM binary; cleaning to force rebuild.${NC}" >&2
      make -C "$SERVER_DIR" clean
    fi
  fi

  if [[ -n "$CFLAGADD" ]]; then
    make -C "$SERVER_DIR" -j "$JOBS" CC="$CC_BIN" CFLAGADD="$CFLAGADD"
  else
    make -C "$SERVER_DIR" -j "$JOBS" CC="$CC_BIN"
  fi
  if [[ ! -f "$SERVER_DIR/$BINARY_NAME" ]]; then
    echo -e "${RED}Error: build did not produce $SERVER_DIR/$BINARY_NAME${NC}" >&2
    exit 1
  fi
  cp "$SERVER_DIR/$BINARY_NAME" "$BUILD_DIR/$BINARY_NAME"
  if command -v file &>/dev/null; then
    built_type="$(file "$BUILD_DIR/$BINARY_NAME" 2>/dev/null || true)"
    echo "$built_type"
    if ! echo "$built_type" | grep -Eqi 'ELF.*(ARM|aarch64)'; then
      echo -e "${RED}Error: built binary is not an ELF ARM executable. Did you rebuild correctly?${NC}" >&2
      echo -e "${RED}Type: $built_type${NC}" >&2
      echo -e "${YELLOW}Hint: run ./server-build-cross.sh --rebuild to force a clean build.${NC}" >&2
      exit 1
    fi
  fi
  echo -e "${GREEN}Build completed successfully.${NC}"
}

case "$ACTION" in
  clean)
    make_clean
    ;;
  rebuild)
    make_clean
    make_build
    ;;
  build)
    make_build
    ;;
  *)
    echo -e "${RED}Unknown action: $ACTION${NC}" >&2
    exit 1
    ;;
esac
