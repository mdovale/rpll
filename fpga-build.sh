#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FPGA_DIR="${FPGA_DIR:-$SCRIPT_DIR/rpll_fpga}"
LIB_DIR="$FPGA_DIR/library/lib_src"

TARGET=""
VARIANT="${VARIANT:-laser_lock}"
VIVADO_BIN="${VIVADO_BIN:-}"
MAKE_CORES=1
JOBS=""
ACTION="build"
USE_DOCKER=0
DOCKER_IMAGE="${VIVADO_DOCKER_IMAGE:-}"
DOCKER_PLATFORM="${VIVADO_DOCKER_PLATFORM:-}"
USE_REMOTE=0
REMOTE_HOST=""
REMOTE_USER="${REMOTE_USER:-}"
REMOTE_PORT="${REMOTE_PORT:-22}"
REMOTE_DIR="${REMOTE_DIR:-~/rpll-dev}"
REMOTE_VIVADO="${REMOTE_VIVADO:-}"
FORCE=0

# Board work dir names (TCL board config in fpga/tcl/board_config_*.tcl)
get_board_work_dir() {
  case "$1" in
    rp125_14) echo "work125_14" ;;
    rp250_12) echo "work250_12" ;;
    *) echo "" ; return 1 ;;
  esac
}

bitstream_basename() {
  case "$VARIANT" in
    phasemeter) echo "phasemeter" ;;
    *) echo "laser_lock" ;;
  esac
}

find_bitstream_path() {
  local impl_dir="$1"
  local candidate
  for candidate in "$impl_dir/system_wrapper.bit" "$impl_dir/red_pitaya_top.bit" "$impl_dir/rpll.bit"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

ensure_variant_bitstream_names() {
  local impl_dir="$1"
  local bit_path="$2"
  local base_name variant_bit base_bin variant_bin
  base_name="$(bitstream_basename)"
  if [[ -z "$bit_path" ]]; then
    bit_path="$(find_bitstream_path "$impl_dir" || true)"
  fi
  [[ -n "$bit_path" ]] || return 0
  variant_bit="$impl_dir/${base_name}.bit"
  if [[ "$bit_path" != "$variant_bit" ]]; then
    cp -f "$bit_path" "$variant_bit"
  fi
  base_bin="${bit_path%.bit}.bit.bin"
  if [[ -f "$base_bin" ]]; then
    variant_bin="$impl_dir/${base_name}.bit.bin"
    if [[ "$base_bin" != "$variant_bin" ]]; then
      cp -f "$base_bin" "$variant_bin"
    fi
  fi
}

# Preflight: check required paths exist before running Vivado
preflight_check() {
  local target="$1" missing=""
  [[ -z "$target" ]] && return 1
  [[ ! -f "$FPGA_DIR/tcl/board_config_${target}.tcl" ]] && missing="$FPGA_DIR/tcl/board_config_${target}.tcl"
  [[ ! -f "$FPGA_DIR/tcl/create_project_common.tcl" ]] && missing="${missing:+$missing }$FPGA_DIR/tcl/create_project_common.tcl"
  [[ ! -f "$FPGA_DIR/source/cfg_${target}/rpll.tcl" ]] && missing="${missing:+$missing }$FPGA_DIR/source/cfg_${target}/rpll.tcl"
  [[ ! -f "$FPGA_DIR/source/system_design_bd_${target}/system.tcl" ]] && missing="${missing:+$missing }$FPGA_DIR/source/system_design_bd_${target}/system.tcl"
  if [[ -n "$missing" ]]; then
    echo -e "${RED}Error: required path(s) missing:${NC}" >&2
    printf '  %s\n' $missing >&2
    exit 1
  fi
  if [[ "$MAKE_CORES" == "1" ]]; then
    if [[ ! -f "$LIB_DIR/make_cores.tcl" ]]; then
      echo -e "${RED}Error: $LIB_DIR/make_cores.tcl not found.${NC}" >&2
      exit 1
    fi
    if [[ ! -d "$LIB_DIR/my_cores_build_src" ]]; then
      echo -e "${RED}Error: $LIB_DIR/my_cores_build_src not found.${NC}" >&2
      exit 1
    fi
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") --target <rp125_14|rp250_12> [OPTIONS]

Options:
  --target BOARD        Target board: rp125_14 or rp250_12 (required)
  --variant VAR         Build variant: laser_lock (default) or phasemeter
  --vivado CMD_OR_PATH  Vivado command (in PATH) or full path (optional)
  --make-cores          Build custom IP cores (default)
  --skip-cores          Skip custom IP core generation
  --jobs N              Parallel jobs for implementation [default: auto]
  --clean               Remove Vivado work directories for the target
  --docker              Run Vivado inside a Docker container
  --docker-image IMAGE  Docker image containing Vivado (required with --docker)
  --docker-platform PL  Docker platform (optional)
  --remote HOST         Run Vivado on remote host via SSH
  --remote-user USER    SSH user for remote host (optional)
  --remote-port PORT    SSH port (optional)
  --remote-dir DIR      Repo directory on remote host [default: ~/rpll-dev]
  --remote-vivado PATH  Vivado binary on remote host (optional)
  --force               Overwrite existing Vivado projects (e.g. IP cores)
  --help                Show this help

Environment:
  VIVADO_BIN            Vivado command or path (same as --vivado)
  VIVADO_DOCKER_IMAGE   Docker image for Vivado
  VIVADO_DOCKER_PLATFORM Docker platform
  REMOTE_USER           SSH user for remote host
  REMOTE_PORT           SSH port for remote host
  REMOTE_DIR            Repo directory on remote host
  REMOTE_VIVADO         Vivado binary on remote host

Examples:
  ./fpga-build.sh --target rp125_14
  ./fpga-build.sh --target rp125_14 --variant phasemeter
  ./fpga-build.sh --target rp250_12 --skip-cores
  ./fpga-build.sh --target rp125_14 --vivado vivado2017
  ./fpga-build.sh --target rp250_12 --docker --docker-image my-vivado:2020.2
  ./fpga-build.sh --target rp125_14 --remote 192.168.1.20 --remote-user vivado
  ./fpga-build.sh --target rp125_14 --remote 10.128.100.63 --force
EOF
}

detect_jobs() {
  getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4
}

detect_jobs_remote() {
  local target="$1"
  ssh -p "$REMOTE_PORT" "$target" "getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 4"
}

resolve_vivado_bin() {
  if [[ -n "$VIVADO_BIN" ]]; then
    # Allow specifying a Vivado command name (e.g. "vivado2017") instead of a path.
    if command -v "$VIVADO_BIN" &>/dev/null; then
      VIVADO_BIN="$(command -v "$VIVADO_BIN")"
    fi
    return
  fi
  if command -v vivado &>/dev/null; then
    VIVADO_BIN="$(command -v vivado)"
    return
  fi
  case "$TARGET" in
    rp125_14)
      VIVADO_BIN="/opt/Xilinx/Vivado/2017.2/bin/vivado"
      ;;
    rp250_12)
      VIVADO_BIN="/opt/Xilinx/Vivado/2020.2/bin/vivado"
      ;;
    *)
      return
      ;;
  esac
}

# Resolve bootgen path (same Xilinx install as Vivado). Required for OS 2.x+ .bit.bin output.
resolve_bootgen_bin() {
  local vivado_dir
  vivado_dir="$(dirname "$VIVADO_BIN")"
  if [[ -x "$vivado_dir/bootgen" ]]; then
    BOOTGEN_BIN="$vivado_dir/bootgen"
    return
  fi
  if command -v bootgen &>/dev/null; then
    BOOTGEN_BIN="$(command -v bootgen)"
    return
  fi
  BOOTGEN_BIN=""
}

run_vivado() {
  local work_dir="$1"
  local tcl_path="$2"
  if [[ "$USE_REMOTE" == "1" ]]; then
    local target="$3"
    local remote_base="${REMOTE_DIR%/}"
    local remote_work="${remote_base}${work_dir#"$SCRIPT_DIR"}"
    local remote_tcl="${remote_base}${tcl_path#"$SCRIPT_DIR"}"
    local remote_vivado="${REMOTE_VIVADO:-vivado}"
    sync_remote_repo "$target"
    # Use bash -lc so remote .profile/.bashrc (e.g. Xilinx env) is sourced
    ssh -p "$REMOTE_PORT" "$target" "bash -lc 'cd \"$remote_work\" && \"$remote_vivado\" -mode batch -source \"$remote_tcl\"'"
    ssh -p "$REMOTE_PORT" "$target" "rm -f '$remote_tcl'" || true
  elif [[ "$USE_DOCKER" == "1" ]]; then
    local container_repo="/work"
    local container_work="${container_repo}${work_dir#"$SCRIPT_DIR"}"
    local container_tcl="${container_repo}${tcl_path#"$SCRIPT_DIR"}"
    local run_cmd=(docker run --rm)
    if [[ -n "$DOCKER_PLATFORM" ]]; then
      run_cmd+=(--platform "$DOCKER_PLATFORM")
    fi
    run_cmd+=(-v "$SCRIPT_DIR:$container_repo" -w "$container_work" "$DOCKER_IMAGE")
    run_cmd+=(bash -lc "vivado -mode batch -source \"$container_tcl\"")
    "${run_cmd[@]}"
  else
    (cd "$work_dir" && "$VIVADO_BIN" -mode batch -source "$tcl_path")
  fi
}

clean_work_dirs() {
  local work_dir
  work_dir="$(get_board_work_dir "$TARGET")"
  echo -e "${YELLOW}Cleaning Vivado work directories...${NC}"
  rm -rf "$FPGA_DIR/$work_dir" "$FPGA_DIR/work"
}

clean_work_dirs_remote() {
  local target="$1" work_dir
  work_dir="$(get_board_work_dir "$TARGET")"
  echo -e "${YELLOW}Cleaning remote Vivado work directories...${NC}"
  ssh -p "$REMOTE_PORT" "$target" "rm -rf '$REMOTE_DIR/fpga/$work_dir' '$REMOTE_DIR/fpga/work'"
}

sync_remote_repo() {
  local target="$1"
  local remote_dir_escaped="${REMOTE_DIR// /\\ }"
  echo -e "${BLUE}Syncing repo to remote...${NC}"
  ssh -p "$REMOTE_PORT" "$target" "mkdir -p '$REMOTE_DIR'"
  if command -v rsync &>/dev/null; then
    rsync -az \
      --exclude ".DS_Store" \
      --exclude "fpga/work" \
      --exclude "fpga/work125_14" \
      --exclude "fpga/work250_12" \
      --exclude "fpga/.Xil" \
      --exclude "fpga/library/lib_src/.Xil" \
      --exclude "fpga/library/lib_src/ip_user_files" \
      --exclude "fpga/library/lib_src/.cache" \
      --exclude "fpga/ip_user_files" \
      -e "ssh -p $REMOTE_PORT" \
      "$SCRIPT_DIR/" "$target:$remote_dir_escaped/"
  else
    echo -e "${YELLOW}rsync not found; using scp (slower).${NC}"
    scp -r -P "$REMOTE_PORT" "$SCRIPT_DIR/." "$target:$remote_dir_escaped/"
  fi
}

fetch_remote_bitstream() {
  local target="$1" work_dir remote_impl_dir local_impl_dir remote_impl_dir_escaped
  work_dir="$(get_board_work_dir "$TARGET")"
  remote_impl_dir="$REMOTE_DIR/fpga/$work_dir/rpll.runs/impl_1"
  local_impl_dir="$SCRIPT_DIR/fpga/$work_dir/rpll.runs/impl_1"
  remote_impl_dir_escaped="${remote_impl_dir// /\\ }"
  mkdir -p "$local_impl_dir"
  if command -v rsync &>/dev/null; then
    rsync -az -e "ssh -p $REMOTE_PORT" --include="fpga.bit.bin" --include="*.bit" --include="*.bit.bin" --exclude="*" \
      "$target:$remote_impl_dir_escaped/" "$local_impl_dir/"
  else
    remote_bits=$(ssh -p "$REMOTE_PORT" "$target" "ls -1 '$remote_impl_dir'/*.bit '$remote_impl_dir'/*.bit.bin 2>/dev/null" || true)
    for bit in $remote_bits; do
      scp -P "$REMOTE_PORT" "$target:$bit" "$local_impl_dir/"
    done
  fi
}

# Convert .bit to .bit.bin using bootgen (required for Red Pitaya OS 2.x+ FPGA Manager).
# Output: fpga.bit.bin in the same directory as the input .bit file.
convert_bit_to_bin() {
  local bit_path="$1"
  local impl_dir bif_path bit_name out_name
  impl_dir="$(dirname "$bit_path")"
  bif_path="$impl_dir/design.bif"

  if [[ ! -f "$bit_path" ]]; then
    echo -e "${RED}Error: bitstream not found: $bit_path${NC}" >&2
    return 1
  fi

  if [[ -z "$BOOTGEN_BIN" || ! -x "$BOOTGEN_BIN" ]]; then
    echo -e "${RED}Error: bootgen not found. Required for OS 2.x+ .bit.bin output.${NC}" >&2
    echo "  bootgen is typically in the same directory as Vivado." >&2
    return 1
  fi

  # BIF format for Zynq-7000 (rp125_14, rp250_12)
  bit_name="$(basename "$bit_path")"
  out_name="${bit_name%.bit}.bit.bin"
  printf 'all:\n{\n  %s\n}\n' "$bit_name" > "$bif_path"
  (cd "$impl_dir" && "$BOOTGEN_BIN" -image design.bif -arch zynq -process_bitstream bin -o "$out_name" -w) || return 1
  rm -f "$bif_path"
  echo -e "${GREEN}Generated $impl_dir/$out_name (OS 2.x+ compatible)${NC}"
}

# Run bootgen conversion on remote host (for --remote builds).
# Resolves bootgen via: 1) PATH, 2) same dir as vivado, 3) find in /opt/Xilinx.
convert_bit_to_bin_remote() {
  local target="$1" work_dir remote_impl_dir vivado_cmd tmp_script
  work_dir="$(get_board_work_dir "$TARGET")"
  remote_impl_dir="$REMOTE_DIR/fpga/$work_dir/rpll.runs/impl_1"
  vivado_cmd="${REMOTE_VIVADO:-vivado}"
  tmp_script="$(mktemp "$FPGA_DIR/.remote_bootgen_XXXXXX")"
  trap "rm -f '$tmp_script'" RETURN
  cat > "$tmp_script" << REMOTEEOF
set -e
out_dir='$remote_impl_dir'
cd "\$out_dir"
bit_name=\$(ls -1 *.bit 2>/dev/null | head -1 | xargs basename)
[[ -n "\$bit_name" ]] || { echo 'Error: no .bit file found'; exit 1; }
bootgen_path=\$(command -v bootgen 2>/dev/null)
if [[ -z "\$bootgen_path" ]]; then
  vd=\$(command -v $vivado_cmd 2>/dev/null)
  if [[ -n "\$vd" ]] && [[ -x "\$(dirname "\$vd")/bootgen" ]]; then
    bootgen_path="\$(dirname "\$vd")/bootgen"
  fi
fi
if [[ -z "\$bootgen_path" ]]; then
  bootgen_path=\$(find /opt/Xilinx -name bootgen -type f 2>/dev/null | head -1)
fi
[[ -n "\$bootgen_path" ]] || { echo 'Error: bootgen not found. Add to PATH or ensure Xilinx Vivado is installed.'; exit 1; }
out_name="\${bit_name%.bit}.bit.bin"
printf 'all:\n{\n  %s\n}\n' "\$bit_name" > design.bif
"\$bootgen_path" -image design.bif -arch zynq -process_bitstream bin -o "\$out_dir/\$out_name" -w
rm -f design.bif
REMOTEEOF
  remote_tmp="/tmp/rpll_bootgen_$$.sh"
  scp -P "$REMOTE_PORT" "$tmp_script" "$target:$remote_tmp"
  ssh -p "$REMOTE_PORT" "$target" "chmod +x '$remote_tmp' && bash -l '$remote_tmp'"
  ssh -p "$REMOTE_PORT" "$target" "rm -f '$remote_tmp'"
  echo -e "${GREEN}Generated .bit.bin on remote (OS 2.x+ compatible)${NC}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="$2"
      shift 2
      ;;
    --variant)
      if [[ "$2" != "laser_lock" && "$2" != "phasemeter" ]]; then
        echo -e "${RED}Error: --variant must be 'laser_lock' or 'phasemeter'${NC}" >&2
        exit 1
      fi
      VARIANT="$2"
      shift 2
      ;;
    --vivado)
      VIVADO_BIN="$2"
      shift 2
      ;;
    --make-cores)
      MAKE_CORES=1
      shift
      ;;
    --skip-cores)
      MAKE_CORES=0
      shift
      ;;
    --jobs)
      JOBS="$2"
      shift 2
      ;;
    --clean)
      ACTION="clean"
      shift
      ;;
    --docker)
      USE_DOCKER=1
      shift
      ;;
    --docker-image)
      DOCKER_IMAGE="$2"
      shift 2
      ;;
    --docker-platform)
      DOCKER_PLATFORM="$2"
      shift 2
      ;;
    --remote)
      USE_REMOTE=1
      REMOTE_HOST="$2"
      shift 2
      ;;
    --remote-user)
      REMOTE_USER="$2"
      shift 2
      ;;
    --remote-port)
      REMOTE_PORT="$2"
      shift 2
      ;;
    --remote-dir)
      REMOTE_DIR="$2"
      shift 2
      ;;
    --remote-vivado)
      REMOTE_VIVADO="$2"
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

if [[ "$USE_REMOTE" == "1" ]]; then
  if ! command -v ssh &>/dev/null; then
    echo -e "${RED}Error: ssh not found in PATH.${NC}" >&2
    exit 1
  fi
  if [[ "$REMOTE_HOST" == *"@"* && -z "$REMOTE_USER" ]]; then
    REMOTE_USER="${REMOTE_HOST%@*}"
    REMOTE_HOST="${REMOTE_HOST#*@}"
  fi
  if [[ -z "$REMOTE_HOST" ]]; then
    echo -e "${RED}Error: --remote requires a host.${NC}" >&2
    exit 1
  fi
  if [[ -n "$REMOTE_USER" ]]; then
    REMOTE_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
  else
    REMOTE_TARGET="${REMOTE_HOST}"
  fi
  if [[ "$REMOTE_DIR" == "~"* ]]; then
    REMOTE_HOME="$(ssh -p "$REMOTE_PORT" "$REMOTE_TARGET" "printf %s \"\$HOME\"")"
    REMOTE_DIR="${REMOTE_HOME}${REMOTE_DIR#\~}"
  fi
  if [[ -z "${JOBS:-}" ]]; then
    JOBS="$(detect_jobs_remote "$REMOTE_TARGET")"
  fi
  # Normalize REMOTE_DIR (no trailing slash) for path construction in run_vivado
  REMOTE_DIR="${REMOTE_DIR%/}"
else
  JOBS="${JOBS:-$(detect_jobs)}"
fi
# Ensure JOBS is never empty for launch_runs -jobs $JOBS
[[ -z "${JOBS:-}" ]] && JOBS=4

if [[ "$TARGET" != "rp125_14" && "$TARGET" != "rp250_12" ]]; then
  echo -e "${RED}Error: --target must be rp125_14 or rp250_12.${NC}" >&2
  exit 1
fi

if [[ "$USE_REMOTE" == "1" && "$USE_DOCKER" == "1" ]]; then
  echo -e "${RED}Error: --remote and --docker cannot be used together.${NC}" >&2
  exit 1
fi

if [[ "$USE_REMOTE" == "1" ]]; then
  :
elif [[ "$USE_DOCKER" == "1" ]]; then
  if [[ -z "$DOCKER_IMAGE" ]]; then
    echo -e "${RED}Error: --docker-image or VIVADO_DOCKER_IMAGE is required.${NC}" >&2
    exit 1
  fi
  if ! command -v docker &>/dev/null; then
    echo -e "${RED}Error: docker not found in PATH.${NC}" >&2
    exit 1
  fi
else
  resolve_vivado_bin
  if [[ -z "$VIVADO_BIN" || ! -x "$VIVADO_BIN" ]]; then
    echo -e "${RED}Error: Vivado not found. Use --vivado or set VIVADO_BIN.${NC}" >&2
    exit 1
  fi
fi

if [[ ! -f "$FPGA_DIR/regenerate_project_and_bd.tcl" ]]; then
  echo -e "${RED}Error: regenerate_project_and_bd.tcl not found in $FPGA_DIR${NC}" >&2
  exit 1
fi

if [[ "$ACTION" != "clean" ]]; then
  preflight_check "$TARGET"
fi

if [[ "$ACTION" == "clean" ]]; then
  if [[ "$USE_REMOTE" == "1" ]]; then
    clean_work_dirs_remote "$REMOTE_TARGET"
  else
    clean_work_dirs
  fi
  exit 0
fi

if [[ "$MAKE_CORES" == "1" ]]; then
  echo -e "${GREEN}Generating custom IP cores...${NC}"
  tmpfile="$(mktemp "$LIB_DIR/.make_cores_${TARGET}_XXXXXX")"
  if [[ "$USE_REMOTE" == "1" && "$tmpfile" != "$SCRIPT_DIR"* ]]; then
    echo -e "${RED}Error: mktemp created temp file outside repo: $tmpfile${NC}" >&2
    rm -f "$tmpfile"
    exit 1
  fi
  if [[ "$FORCE" == "1" ]]; then
    rp_force_line="set rp_force 1"
  else
    rp_force_line=""
  fi
  cat > "$tmpfile" <<EOF
set rp_model $TARGET
$rp_force_line
source make_cores.tcl
EOF
  if [[ "$USE_REMOTE" == "1" ]]; then
    run_vivado "$LIB_DIR" "$tmpfile" "$REMOTE_TARGET"
  else
    run_vivado "$LIB_DIR" "$tmpfile"
  fi
  rm -f "$tmpfile"
fi

echo -e "${GREEN}Building FPGA bitstream...${NC}"
tmpfile="$(mktemp "$FPGA_DIR/.build_${TARGET}_XXXXXX")"
# Temp file must be under SCRIPT_DIR so remote path (REMOTE_DIR + relative path) is correct
if [[ "$USE_REMOTE" == "1" && "$tmpfile" != "$SCRIPT_DIR"* ]]; then
  echo -e "${RED}Error: mktemp created temp file outside repo: $tmpfile${NC}" >&2
  rm -f "$tmpfile"
  exit 1
fi
if [[ "$FORCE" == "1" ]]; then
  rp_force_line="set rp_force 1"
else
  rp_force_line=""
fi
  cat > "$tmpfile" <<EOF
set rp_model $TARGET
set rp_variant $VARIANT
$rp_force_line
source regenerate_project_and_bd.tcl
launch_runs impl_1 -to_step write_bitstream -jobs $JOBS
wait_on_run impl_1
EOF
if [[ "$USE_REMOTE" == "1" ]]; then
  run_vivado "$FPGA_DIR" "$tmpfile" "$REMOTE_TARGET"
else
  run_vivado "$FPGA_DIR" "$tmpfile"
fi
rm -f "$tmpfile"

if [[ "$USE_REMOTE" == "1" ]]; then
  echo -e "${BLUE}Converting .bit to .bit.bin on remote (OS 2.x+)...${NC}"
  convert_bit_to_bin_remote "$REMOTE_TARGET"
  echo -e "${BLUE}Fetching bitstream from remote...${NC}"
  fetch_remote_bitstream "$REMOTE_TARGET"
  work_dir="$(get_board_work_dir "$TARGET")"
  impl_dir="$SCRIPT_DIR/fpga/$work_dir/rpll.runs/impl_1"
  ensure_variant_bitstream_names "$impl_dir" ""
else
  work_dir="$(get_board_work_dir "$TARGET")"
  impl_dir="$SCRIPT_DIR/fpga/$work_dir/rpll.runs/impl_1"
  bit_path="$(find_bitstream_path "$impl_dir" || true)"
  if [[ -n "$bit_path" ]]; then
    if [[ "$USE_DOCKER" == "1" ]]; then
      echo -e "${BLUE}Converting .bit to .bit.bin (OS 2.x+)...${NC}"
      run_cmd=(docker run --rm)
      [[ -n "$DOCKER_PLATFORM" ]] && run_cmd+=(--platform "$DOCKER_PLATFORM")
      run_cmd+=(-v "$SCRIPT_DIR:/work" -w "/work/fpga/$work_dir/rpll.runs/impl_1" "$DOCKER_IMAGE")
      bit_name="$(basename "$bit_path")"
      out_name="${bit_name%.bit}.bit.bin"
      run_cmd+=(bash -lc "printf 'all:\n{\n  %s\n}\n' '$bit_name' > design.bif && bootgen -image design.bif -arch zynq -process_bitstream bin -o '$out_name' -w && rm -f design.bif")
      "${run_cmd[@]}"
      echo -e "${GREEN}Generated $out_name (OS 2.x+ compatible)${NC}"
    else
      resolve_bootgen_bin
      echo -e "${BLUE}Converting .bit to .bit.bin (OS 2.x+)...${NC}"
      convert_bit_to_bin "$bit_path"
    fi
  fi
  ensure_variant_bitstream_names "$impl_dir" "$bit_path"
fi

echo -e "${GREEN}FPGA build completed successfully.${NC}"
