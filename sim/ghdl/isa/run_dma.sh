#!/usr/bin/env bash
#
# TODO 2.4 (doc/CDP1802_CORE_REVIEW.md): interrupt and DMA edge cases.
# gen_dma_prog.py puts DMA requests and interrupts at the awkward moments
# (DMA single/burst/in/out, DMA around long branches, long skips and NOP,
# DMA during IDL, DMA together with INT, and an interrupt right after
# every instruction shape). lockstep1802.py checks every cycle, including
# each DMA cycle's address, direction and data, against the datasheet's
# Table 2 and the Figure 25 state diagram.
#
# Usage: sim/ghdl/isa/run_dma.sh      (seconds; no ROM needed)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SRC="$ROOT/src/vhdl"
WORK="$HERE/run_dma"
CHECKER="$ROOT/boards/cora-z7-07s/lockstep1802.py"

rm -rf "$WORK"
mkdir -p "$WORK"
GHDL_FLAGS=(--std=08 --workdir="$WORK" -fsynopsys -frelaxed)
SRCS=(
  "$SRC/cdp1802_pkg.vhd" "$SRC/instr_pkg.vhd" "$SRC/test_program_pkg.vhd"
  "$SRC/dff.vhd" "$SRC/ff.vhd" "$SRC/reg.vhd" "$SRC/amux.vhd" "$SRC/dmux.vhd"
  "$SRC/alu.vhd" "$SRC/reg_R.vhd" "$SRC/control.vhd" "$SRC/instr.vhd"
  "$SRC/cdp1802.vhd" "$ROOT/tb/vhdl/tb_cdp1802_lockstep.vhd"
)

cd "$WORK"
python3 "$HERE/gen_dma_prog.py" prog
ghdl -a "${GHDL_FLAGS[@]}" "${SRCS[@]}"
ghdl -e "${GHDL_FLAGS[@]}" tb_cdp1802_lockstep
ghdl -r "${GHDL_FLAGS[@]}" tb_cdp1802_lockstep -gg_prog_file=prog.hex -gg_log_file=cyc.log \
     -gg_max_clocks=2000000 --ieee-asserts=disable 2>&1 | grep -E "DONE|TIMEOUT|error" || true

set +e
python3 "$CHECKER" --flat --strict-address prog.bin cyc.log 20 | tee check.txt | tail -30
RC=${PIPESTATUS[0]}
set -e
DMA=$(sed -E 's/.*, ([0-9]+) DMA cycles.*/\1/;t;d' check.txt)
if [ "$RC" = 0 ] && grep -q " 0 mismatches" check.txt && [ "${DMA:-0}" -ge 10 ]; then
  echo "PASS: DMA and interrupt edge cases, $DMA DMA cycles, 0 mismatches"
else
  echo "FAIL: see $WORK/check.txt" >&2
  exit 1
fi
