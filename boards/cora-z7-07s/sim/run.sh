#!/usr/bin/env bash
#
# Compile and run tb_cs1800_top (cs1800_top + shared_ram) and diff its
# trace against the same golden reference tb_cs1800.vhd is checked
# against, with g_lc_half_period overridden to match tb_cs1800.vhd's LC
# exactly -- see tb_cs1800_top.vhd's header for why that lets this check
# the *entire* trace, not just the pre-interrupt segment.
#
# Usage: boards/cora-z7-07s/sim/run.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD_DIR="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$BOARD_DIR/../.." && pwd)"
SRC="$ROOT/src/vhdl"
TB="$ROOT/tb/vhdl"
WORK="$HERE/run"
GOLDEN="$ROOT/sim/ghdl/reference/tb_cs1800_tpb.txt"

rm -rf "$WORK"
mkdir -p "$WORK"

GHDL_FLAGS=(--std=08 --workdir="$WORK" -fsynopsys -frelaxed)

SRCS=(
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
  "$SRC/cs1800_cpu.vhd"
  "$SRC/cs1800.vhd"
  "$BOARD_DIR/hdl/shared_ram.vhd"
  "$BOARD_DIR/hdl/cs1800_top.vhd"
  "$BOARD_DIR/sim/tb_cs1800_top.vhd"
)

(
  cd "$WORK"
  ghdl -a "${GHDL_FLAGS[@]}" "${SRCS[@]}"
  ghdl -e "${GHDL_FLAGS[@]}" tb_cs1800_top
  ghdl -r "${GHDL_FLAGS[@]}" tb_cs1800_top --ieee-asserts=disable
)

if diff -q "$WORK/tb_cs1800_top_tpb.txt" "$GOLDEN" >/dev/null; then
  echo "PASS: tb_cs1800_top_tpb.txt matches $GOLDEN"
else
  echo "FAIL: tb_cs1800_top_tpb.txt differs from $GOLDEN" >&2
  diff "$WORK/tb_cs1800_top_tpb.txt" "$GOLDEN" || true
  exit 1
fi
