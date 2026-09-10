#!/usr/bin/env bash
#
# Compile and run the GHDL reference-dump testbenches for cdp18 and cs1800.
#
# For each design, this analyzes the sources (order taken from hdllib.cfg),
# elaborates the *_dump testbench, runs it, and copies the resulting trace
# (one line per TPB pulse: time_ns ram_addr data nMRD nMWR Q SC) into
# sim/ghdl/reference/.
#
# Usage: sim/ghdl/run.sh [cdp18] [cs1800]
#        (with no arguments, both are run)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$ROOT/src/vhdl"
TB="$ROOT/tb/vhdl"
WORK="$HERE/run"
REF="$HERE/reference"

rm -rf "$WORK"
mkdir -p "$WORK" "$REF"

GHDL_FLAGS=(--std=08 --workdir="$WORK" -fsynopsys -frelaxed)

COMMON_SRCS=(
  "$SRC/cdp1802_pkg.vhd"
  "$SRC/instr_pkg.vhd"
  "$SRC/dff.vhd"
  "$SRC/ff.vhd"
  "$SRC/reg.vhd"
  "$SRC/amux.vhd"
  "$SRC/dmux.vhd"
  "$SRC/alu.vhd"
  "$SRC/reg_R.vhd"
  "$SRC/control.vhd"
  "$SRC/instr.vhd"
  "$SRC/cdp1802.vhd"
  "$SRC/ram.vhd"
  "$SRC/io_out.vhd"
  "$SRC/io_inp.vhd"
  "$SRC/cdp18.vhd"
  "$SRC/cs1800_cpu.vhd"
  "$SRC/cs1800.vhd"
)

run_one() {
  local name="$1"
  local tb_file="$2"
  local out_file="$3"

  echo "=== $name ==="
  # Run from $WORK: elaboration opens the testbench's report file (relative
  # to cwd) as part of elaborating its file declaration, before simulation
  # even starts, so cwd must already be the scratch dir at the -e step.
  (
    cd "$WORK"
    ghdl -a "${GHDL_FLAGS[@]}" "${COMMON_SRCS[@]}" "$tb_file"
    ghdl -e "${GHDL_FLAGS[@]}" "$name"
    ghdl -r "${GHDL_FLAGS[@]}" "$name" --ieee-asserts=disable
  )
  cp "$WORK/$out_file" "$REF/$out_file"
  echo "wrote $REF/$out_file ($(wc -l < "$REF/$out_file") lines)"
}

TARGETS=("$@")
if [ ${#TARGETS[@]} -eq 0 ]; then
  TARGETS=(cdp18 cs1800)
fi

for t in "${TARGETS[@]}"; do
  case "$t" in
    cdp18)  run_one tb_cdp18_dump  "$TB/tb_cdp18_dump.vhd"  tb_cdp18_tpb.txt ;;
    cs1800) run_one tb_cs1800_dump "$TB/tb_cs1800_dump.vhd" tb_cs1800_tpb.txt ;;
    *) echo "unknown target: $t" >&2; exit 1 ;;
  esac
done
