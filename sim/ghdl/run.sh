#!/usr/bin/env bash
#
# Compile and run the GHDL reference-dump testbenches for cdp18 and cs1800,
# plus plain assertion-based checks for the newer, non-golden-reference
# units (cs1800_memory's ROM/RAM split, cs1800_console's IO device decode).
#
# For cdp18/cs1800, this analyzes the sources (order taken from
# hdllib.cfg), elaborates the *_dump testbench, runs it, and copies the
# resulting trace (one line per TPB pulse: time_ns ram_addr data nMRD
# nMWR Q SC) into sim/ghdl/reference/. For memory/console, it just runs
# the testbench and relies on its own ASSERT ... SEVERITY FAILURE checks
# (see boards/cora-z7-07s/sim/run.sh's tb_shared_ram for the same style).
#
# Usage: sim/ghdl/run.sh [cdp18] [cs1800] [memory] [console]
#        (with no arguments, all four are run)

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
  "$SRC/test_program_pkg.vhd"
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
  "$SRC/cs1800_memory.vhd"
  "$SRC/cdp1854.vhd"
  "$SRC/cs1800_io_select.vhd"
  "$SRC/cs1800_console.vhd"
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

run_check() {
  local name="$1"
  local tb_file="$2"

  echo "=== $name ==="
  (
    cd "$WORK"
    ghdl -a "${GHDL_FLAGS[@]}" "${COMMON_SRCS[@]}" "$tb_file"
    ghdl -e "${GHDL_FLAGS[@]}" "$name"
    ghdl -r "${GHDL_FLAGS[@]}" "$name" --ieee-asserts=disable
  )
  echo "PASS: $name"
}

TARGETS=("$@")
if [ ${#TARGETS[@]} -eq 0 ]; then
  TARGETS=(cdp18 cs1800 memory console)
fi

for t in "${TARGETS[@]}"; do
  case "$t" in
    cdp18)    run_one tb_cdp18_dump  "$TB/tb_cdp18_dump.vhd"  tb_cdp18_tpb.txt ;;
    cs1800)   run_one tb_cs1800_dump "$TB/tb_cs1800_dump.vhd" tb_cs1800_tpb.txt ;;
    memory)   run_check tb_cs1800_memory  "$TB/tb_cs1800_memory.vhd" ;;
    console)  run_check tb_cs1800_console "$TB/tb_cs1800_console.vhd" ;;
    *) echo "unknown target: $t" >&2; exit 1 ;;
  esac
done
