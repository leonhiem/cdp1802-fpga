#!/usr/bin/env bash
#
# Compile and run the board-level testbenches:
#   tb_cs1800_top   -- cs1800_top + shared_ram, diffed against the same
#                      golden reference tb_cs1800.vhd is checked against
#                      (g_lc_half_period overridden to match tb_cs1800.vhd's
#                      LC exactly, so this checks the *entire* trace, not
#                      just the pre-interrupt segment).
#   tb_shared_ram   -- shared_ram's Port B byte-lane adapter directly
#                      (untested by tb_cs1800_top, which only ever drives
#                      Port A): full-word and single-byte-lane writes,
#                      cross-port coherency.
#
# Usage: boards/cora-z7-07s/sim/run.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD_DIR="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$BOARD_DIR/../.." && pwd)"
SRC="$ROOT/src/vhdl"
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
  "$BOARD_DIR/sim/tb_shared_ram.vhd"
  "$BOARD_DIR/hdl/cs1800_prcx18_memory.vhd"
  "$BOARD_DIR/sim/tb_prcx18_memory_map.vhd"
)

(
  cd "$WORK"
  ghdl -a "${GHDL_FLAGS[@]}" "${SRCS[@]}"

  ghdl -e "${GHDL_FLAGS[@]}" tb_cs1800_top
  ghdl -r "${GHDL_FLAGS[@]}" tb_cs1800_top --ieee-asserts=disable

  ghdl -e "${GHDL_FLAGS[@]}" tb_shared_ram
  ghdl -r "${GHDL_FLAGS[@]}" tb_shared_ram

  # The memory map, over all 64K addresses: the real 32KB card (ROM
  # 0x0000-0x1FFF, RAM 0x2000-0x7FFF, rest void) and the minimal config
  # (one RAM IC at 0x4000). Proves the decode uses all 16 address lines:
  # no aliasing, writes to ROM/void ignored, void reads 0xFF.
  ghdl -e "${GHDL_FLAGS[@]}" tb_prcx18_memory_map
  ghdl -r "${GHDL_FLAGS[@]}" tb_prcx18_memory_map \
       -gg_ram_base_addr=8192 -gg_ram_words=6144
  ghdl -r "${GHDL_FLAGS[@]}" tb_prcx18_memory_map \
       -gg_ram_base_addr=16384 -gg_ram_words=2048
)

if diff -q "$WORK/tb_cs1800_top_tpb.txt" "$GOLDEN" >/dev/null; then
  echo "PASS: tb_cs1800_top_tpb.txt matches $GOLDEN"
else
  echo "FAIL: tb_cs1800_top_tpb.txt differs from $GOLDEN" >&2
  diff "$WORK/tb_cs1800_top_tpb.txt" "$GOLDEN" || true
  exit 1
fi

echo "PASS: tb_shared_ram (see report above for details)"
echo "PASS: tb_prcx18_memory_map, both configurations (see reports above)"
