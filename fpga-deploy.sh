#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FPGA_DIR="${FPGA_DIR:-$SCRIPT_DIR/fpga}"

TARGET=""
BUILD_DIR=""
BITSTREAM_PATH=""
TARGET_USER="root"
REDPITAYA_IP="${REDPITAYA_IP:-}"
SSH_PORT="22"
PROGRAM_FPGA=1
ASSUME_YES=0
FPGAUTIL_PATH="/opt/redpitaya/bin/fpgautil"

usage() {
  cat <<EOF
Usage: $(basename "$0") --target <rp125_14|rp250_12> --ip <address> [OPTIONS]

Deploys FPGA bitstream to Red Pitaya OS 2.x+ using fpgautil -b (bitstream only).
No device tree change; uses existing kernel configuration. Expects .bit.bin format.

Options:
  --target BOARD        Target board: rp125_14 or rp250_12 (required)
  --ip IP               RedPitaya IP or hostname (or use RP_IP/REDPITAYA_IP env)
  --build-dir DIR       Build directory (default: \$FPGA_DIR/work<target>, FPGA_DIR defaults to fpga)
  --bitstream FILE      Explicit bitstream path (.bit.bin)
  --user USER           SSH user [default: root]
  --port PORT           SSH port [default: 22]
  --fpgautil PATH       fpgautil path on Red Pitaya [default: /opt/redpitaya/bin/fpgautil]
  --no-program          Only copy bitstream, do not load FPGA
  --yes                 Skip confirmation prompts
  --help                Show this help

Examples:
  ./fpga-deploy.sh --target rp125_14 --ip 169.254.97.245
  ./fpga-deploy.sh --target rp250_12 --ip rp-foo.local --bitstream ./fpga.bit.bin
  ./fpga-deploy.sh --target rp250_12 --ip 169.254.97.245 --no-program
EOF
}

resolve_path() {
  if [[ "$1" = /* ]]; then
    echo "$1"
  else
    echo "$SCRIPT_DIR/$1"
  fi
}

detect_default_bitstream() {
  local base_dir="$1"
  local impl_dir="$base_dir/rpll.runs/impl_1"
  local candidates=(
    "$impl_dir/fpga.bit.bin"
    "$impl_dir/system_wrapper.bit.bin"
    "$impl_dir/red_pitaya_top.bit.bin"
    "$impl_dir/rpll.bit.bin"
    "$impl_dir/system_wrapper.bit"
    "$impl_dir/red_pitaya_top.bit"
    "$impl_dir/rpll.bit"
  )
  for path in "${candidates[@]}"; do
    if [[ -f "$path" ]]; then
      echo "$path"
      return
    fi
  done
}

# True if bitstream is .bit.bin format (required for fpgautil).
is_bit_bin_format() {
  [[ "$(basename "$1")" == *.bit.bin ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      if [[ $# -lt 2 ]]; then echo -e "${RED}Error: --target requires an argument.${NC}" >&2; usage >&2; exit 1; fi
      TARGET="$2"
      shift 2
      ;;
    --ip)
      if [[ $# -lt 2 ]]; then echo -e "${RED}Error: --ip requires an argument.${NC}" >&2; usage >&2; exit 1; fi
      REDPITAYA_IP="$2"
      shift 2
      ;;
    --build-dir)
      if [[ $# -lt 2 ]]; then echo -e "${RED}Error: --build-dir requires an argument.${NC}" >&2; usage >&2; exit 1; fi
      BUILD_DIR="$2"
      shift 2
      ;;
    --bitstream)
      if [[ $# -lt 2 ]]; then echo -e "${RED}Error: --bitstream requires an argument.${NC}" >&2; usage >&2; exit 1; fi
      BITSTREAM_PATH="$2"
      shift 2
      ;;
    --user)
      if [[ $# -lt 2 ]]; then echo -e "${RED}Error: --user requires an argument.${NC}" >&2; usage >&2; exit 1; fi
      TARGET_USER="$2"
      shift 2
      ;;
    --port)
      if [[ $# -lt 2 ]]; then echo -e "${RED}Error: --port requires an argument.${NC}" >&2; usage >&2; exit 1; fi
      SSH_PORT="$2"
      shift 2
      ;;
    --fpgautil)
      if [[ $# -lt 2 ]]; then echo -e "${RED}Error: --fpgautil requires an argument.${NC}" >&2; usage >&2; exit 1; fi
      FPGAUTIL_PATH="$2"
      shift 2
      ;;
    --no-program)
      PROGRAM_FPGA=0
      shift
      ;;
    --yes)
      ASSUME_YES=1
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

if [[ "$TARGET" != "rp125_14" && "$TARGET" != "rp250_12" ]]; then
  echo -e "${RED}Error: --target must be rp125_14 or rp250_12.${NC}" >&2
  exit 1
fi

if [[ -z "$REDPITAYA_IP" ]]; then
  REDPITAYA_IP="${RP_IP:-${REDPITAYA_IP:-${RP_HOST:-}}}"
fi

if [[ -z "$REDPITAYA_IP" ]]; then
  echo -e "${RED}Error: --ip is required (or set RP_IP/REDPITAYA_IP).${NC}" >&2
  exit 1
fi

if [[ -z "$BUILD_DIR" ]]; then
  case "$TARGET" in
    rp125_14)
      BUILD_DIR="$FPGA_DIR/work125_14"
      ;;
    rp250_12)
      BUILD_DIR="$FPGA_DIR/work250_12"
      ;;
  esac
else
  BUILD_DIR="$(resolve_path "$BUILD_DIR")"
fi

if [[ -z "$BITSTREAM_PATH" ]]; then
  BITSTREAM_PATH="$(detect_default_bitstream "$BUILD_DIR" || true)"
else
  BITSTREAM_PATH="$(resolve_path "$BITSTREAM_PATH")"
fi

if [[ -z "$BITSTREAM_PATH" || ! -f "$BITSTREAM_PATH" ]]; then
  echo -e "${RED}Error: bitstream not found.${NC}" >&2
  echo "Checked build dir: $BUILD_DIR" >&2
  echo "Expected .bit.bin in rpll.runs/impl_1/" >&2
  exit 1
fi

if ! is_bit_bin_format "$BITSTREAM_PATH"; then
  impl_dir="$BUILD_DIR/rpll.runs/impl_1"
  echo -e "${RED}Error: Deployment requires .bit.bin format. Run fpga-build.sh to generate it.${NC}" >&2
  echo "  (bootgen converts .bit -> .bit.bin for OS 2.x+ FPGA Manager)" >&2
  echo "" >&2
  echo "  Looked in: $impl_dir" >&2
  if [[ -d "$impl_dir" ]]; then
    echo "  Files found: $(ls -la "$impl_dir" 2>/dev/null | tail -n +2 || echo 'none')" >&2
  else
    echo "  Directory does not exist." >&2
  fi
  echo "" >&2
  echo "  If a .bit.bin file exists elsewhere, use: --bitstream /path/to/file.bit.bin" >&2
  exit 1
fi

if ! command -v ssh &>/dev/null || ! command -v scp &>/dev/null; then
  echo -e "${RED}Error: ssh/scp not found in PATH.${NC}" >&2
  exit 1
fi

BITSTREAM_SIZE="$(stat -f%z "$BITSTREAM_PATH" 2>/dev/null || stat -c%s "$BITSTREAM_PATH" 2>/dev/null || echo 0)"
if [[ "$BITSTREAM_SIZE" -lt 1000000 ]]; then
  echo -e "${YELLOW}Warning: bitstream file seems small (${BITSTREAM_SIZE} bytes).${NC}"
  if [[ "$ASSUME_YES" == "0" ]]; then
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      exit 1
    fi
  fi
fi

CONTROL_SOCKET="/tmp/ssh_rp_${REDPITAYA_IP//./_}_${RANDOM}${RANDOM}"
rm -f "$CONTROL_SOCKET" 2>/dev/null || true
SSH_OPTS="-p $SSH_PORT -o ControlMaster=auto -o ControlPath=$CONTROL_SOCKET -o ControlPersist=60"
SCP_OPTS="-P $SSH_PORT -o ControlPath=$CONTROL_SOCKET"

cleanup_ssh() {
  if [[ -S "$CONTROL_SOCKET" ]]; then
    ssh -p "$SSH_PORT" -o ControlPath="$CONTROL_SOCKET" -O exit "$TARGET_USER@$REDPITAYA_IP" &>/dev/null || true
    rm -f "$CONTROL_SOCKET"
  fi
}
trap cleanup_ssh EXIT INT TERM

# Verify FPGA state after load
verify_fpga_state() {
  local state fw_loaded addr
  if ! ssh $SSH_OPTS "$TARGET_USER@$REDPITAYA_IP" "[ -r /sys/class/fpga_manager/fpga0/state ]" 2>/dev/null; then
    return
  fi
  state="$(ssh $SSH_OPTS "$TARGET_USER@$REDPITAYA_IP" "cat /sys/class/fpga_manager/fpga0/state" 2>/dev/null)" || true
  if [[ -z "$state" ]]; then
    return
  fi
  echo -e "${BLUE}FPGA manager state: ${NC}$state"
  if [[ "$state" != "operating" ]]; then
    echo -e "${YELLOW}Note: expected state 'operating'; got '$state'. Write may have failed.${NC}" >&2
    return
  fi
  echo -e "${GREEN}Verified: write succeeded (kernel + FPGA DONE confirmed).${NC}"
  fw_loaded="$(ssh $SSH_OPTS "$TARGET_USER@$REDPITAYA_IP" "cat /sys/class/fpga_manager/fpga0/firmware 2>/dev/null" || true)"
  if [[ -n "$fw_loaded" ]]; then
    echo -e "${BLUE}Loaded firmware: ${NC}$fw_loaded"
  fi
  case "$TARGET" in
    rp125_14) addr="0x42000000" ;;
    rp250_12) addr="0x82000000" ;;
    *) addr="" ;;
  esac
  if [[ -n "$addr" ]] && ssh $SSH_OPTS "$TARGET_USER@$REDPITAYA_IP" "command -v devmem >/dev/null 2>&1"; then
    if ssh $SSH_OPTS "$TARGET_USER@$REDPITAYA_IP" "devmem $addr 32 2>/dev/null" >/dev/null 2>&1; then
      echo -e "${GREEN}Verified: FPGA responds at design address $addr (functional read OK).${NC}"
    else
      echo -e "${YELLOW}Warning: devmem read of $addr failed (bus error or wrong design).${NC}" >&2
    fi
  fi
}

echo -e "${GREEN}Deploying FPGA bitstream to Red Pitaya (fpgautil -b)...${NC}"
echo "Bitstream: $BITSTREAM_PATH"

echo -e "${BLUE}Testing SSH connection...${NC}"
if ! ssh $SSH_OPTS -o ConnectTimeout=5 "$TARGET_USER@$REDPITAYA_IP" "echo ok" &>/dev/null; then
  echo -e "${RED}Error: Cannot connect to $TARGET_USER@$REDPITAYA_IP${NC}" >&2
  exit 1
fi

# Copy to /tmp (writable without remounting /opt)
REMOTE_BITSTREAM="/tmp/fpga.bit.bin"
echo -e "${BLUE}Copying bitstream to Red Pitaya...${NC}"
scp $SCP_OPTS "$BITSTREAM_PATH" "$TARGET_USER@$REDPITAYA_IP:$REMOTE_BITSTREAM"

if [[ "$PROGRAM_FPGA" == "0" ]]; then
  echo -e "${GREEN}Bitstream copied successfully.${NC}"
  exit 0
fi

if [[ "$ASSUME_YES" == "0" ]]; then
  echo -e "${YELLOW}FPGA will be reconfigured.${NC}"
  read -p "Continue? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 0
  fi
fi

if ! ssh $SSH_OPTS "$TARGET_USER@$REDPITAYA_IP" "[ -x '$FPGAUTIL_PATH' ]"; then
  echo -e "${RED}Error: fpgautil not found at $FPGAUTIL_PATH. Red Pitaya OS 2.x+ required.${NC}" >&2
  exit 1
fi

echo -e "${BLUE}Loading FPGA via fpgautil -b...${NC}"
if ssh $SSH_OPTS "$TARGET_USER@$REDPITAYA_IP" "$FPGAUTIL_PATH -b $REMOTE_BITSTREAM"; then
  verify_fpga_state
  ssh $SSH_OPTS "$TARGET_USER@$REDPITAYA_IP" "rm -f $REMOTE_BITSTREAM" 2>/dev/null || true
  echo -e "${GREEN}FPGA programmed successfully.${NC}"
  exit 0
else
  echo -e "${RED}Error: fpgautil failed.${NC}" >&2
  exit 1
fi
