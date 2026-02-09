#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BINARY_NAME="server"
BUILD_DIR=""
BINARY_PATH=""
TARGET_USER="root"
TARGET_DIR="/usr/local/bin"
REDPITAYA_IP="${REDPITAYA_IP:-}"
SSH_PORT="22"
FORCE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") --ip <address> [OPTIONS]

Options:
  --ip IP            RedPitaya IP or hostname (or use RP_IP/REDPITAYA_IP env)
  --build-dir DIR    Build directory [default: auto-detect]
  --binary PATH      Explicit path to server binary
  --user USER        SSH user [default: root]
  --target-dir DIR   Target directory on RedPitaya [default: /usr/local/bin]
  --port PORT        SSH port [default: 22]
  --force            Deploy even if binary format looks wrong
  --help             Show this help

Examples:
  ./server-deploy.sh --ip 169.254.97.245
  ./server-deploy.sh --ip rp-foo.local --build-dir build-cross
  ./server-deploy.sh --ip 169.254.97.245 --binary /tmp/server
EOF
}

resolve_path() {
  if [[ "$1" = /* ]]; then
    echo "$1"
  else
    echo "$SCRIPT_DIR/$1"
  fi
}

auto_detect_binary() {
  # Prefer an actual ARM ELF binary. Some workflows may leave behind a host
  # artifact (e.g. Mach-O) in build-docker/ which must be ignored for RP deploy.
  local candidates=(
    "$SCRIPT_DIR/build-cross/$BINARY_NAME"
    "$SCRIPT_DIR/build-docker/$BINARY_NAME"
    "$SCRIPT_DIR/server/esw/$BINARY_NAME"
  )
  for cand in "${candidates[@]}"; do
    [[ -f "$cand" ]] || continue
    if command -v file &>/dev/null; then
      cand_type="$(file "$cand" 2>/dev/null || true)"
      if echo "$cand_type" | grep -Eqi 'ELF.*(ARM|aarch64)'; then
        echo "$cand"
        return
      fi
    else
      # No `file` command available; fall back to first existing candidate.
      echo "$cand"
      return
    fi
  done

  # If nothing matched as ARM ELF, fall back to "first existing" to preserve
  # previous behavior (caller will validate format later and error clearly).
  for cand in "${candidates[@]}"; do
    [[ -f "$cand" ]] || continue
    echo "$cand"
    return
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip)
      REDPITAYA_IP="$2"
      shift 2
      ;;
    --build-dir)
      BUILD_DIR="$2"
      shift 2
      ;;
    --binary)
      BINARY_PATH="$2"
      shift 2
      ;;
    --user)
      TARGET_USER="$2"
      shift 2
      ;;
    --target-dir)
      TARGET_DIR="$2"
      shift 2
      ;;
    --port)
      SSH_PORT="$2"
      shift 2
      ;;
    --force)
      FORCE=1
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

if [[ -z "$REDPITAYA_IP" ]]; then
  REDPITAYA_IP="${RP_IP:-${REDPITAYA_IP:-${RP_HOST:-}}}"
fi

if [[ -n "$BUILD_DIR" && -z "$BINARY_PATH" ]]; then
  BUILD_DIR="$(resolve_path "$BUILD_DIR")"
  BINARY_PATH="$BUILD_DIR/$BINARY_NAME"
fi

if [[ -z "$BINARY_PATH" ]]; then
  BINARY_PATH="$(auto_detect_binary || true)"
fi

if [[ -z "$BINARY_PATH" || ! -f "$BINARY_PATH" ]]; then
  echo -e "${RED}Error: server binary not found.${NC}" >&2
  echo "Build it with:" >&2
  echo "  ./server-build-cross.sh" >&2
  echo "  ./server-build-docker.sh" >&2
  exit 1
fi

if [[ -z "$REDPITAYA_IP" ]]; then
  echo -e "${RED}Error: --ip is required (or set RP_IP/REDPITAYA_IP).${NC}" >&2
  exit 1
fi

if ! command -v ssh &>/dev/null || ! command -v scp &>/dev/null; then
  echo -e "${RED}Error: ssh/scp not found in PATH.${NC}" >&2
  exit 1
fi

if command -v file &>/dev/null; then
  binary_type="$(file "$BINARY_PATH" 2>/dev/null || true)"
  if ! echo "$binary_type" | grep -Eqi 'ELF.*(ARM|aarch64)'; then
    if [[ "$FORCE" == "1" ]]; then
      echo -e "${YELLOW}Warning: binary does not appear to be an ELF ARM executable; deploying anyway (--force).${NC}" >&2
      echo -e "${YELLOW}Type: $binary_type${NC}" >&2
    else
      echo -e "${RED}Error: binary does not appear to be an ELF ARM executable.${NC}" >&2
      echo -e "${RED}Type: $binary_type${NC}" >&2
      echo -e "${YELLOW}Rebuild with: ./server-build-cross.sh --rebuild${NC}" >&2
      echo -e "${YELLOW}Or override with: ./server-deploy.sh ... --force${NC}" >&2
      exit 1
    fi
  fi
fi

echo -e "${GREEN}Deploying server to RedPitaya...${NC}"
echo "Source: $BINARY_PATH"
echo "Target: $TARGET_USER@$REDPITAYA_IP:$TARGET_DIR/$BINARY_NAME"

echo -e "${BLUE}Creating target directory...${NC}"
ssh -p "$SSH_PORT" "$TARGET_USER@$REDPITAYA_IP" "mkdir -p '$TARGET_DIR'"

echo -e "${BLUE}Copying binary...${NC}"
scp -P "$SSH_PORT" "$BINARY_PATH" "$TARGET_USER@$REDPITAYA_IP:$TARGET_DIR/$BINARY_NAME"

echo -e "${BLUE}Setting permissions...${NC}"
ssh -p "$SSH_PORT" "$TARGET_USER@$REDPITAYA_IP" "chmod +x '$TARGET_DIR/$BINARY_NAME'"

echo -e "${GREEN}Deployment completed successfully.${NC}"
echo "Run on device:"
echo "  ssh -p $SSH_PORT $TARGET_USER@$REDPITAYA_IP '$TARGET_DIR/$BINARY_NAME'"
