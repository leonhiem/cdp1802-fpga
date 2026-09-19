#!/usr/bin/env bash
#
# TODO 2.2 (doc/CDP1802_CORE_REVIEW.md): instruction-coverage test of the
# bare CDP1802 core. gen_isa_prog.py builds one program that executes every
# opcode except 0x68, with every register variant and every conditional
# branch/skip both ways, including I/O, EF, Q, interrupts and IDL.
# tb_cdp1802_lockstep.vhd runs it on src/vhdl/cdp1802.vhd, and
# lockstep1802.py --flat --coverage checks every machine cycle against its
# instruction-set model and fails unless the coverage is complete.
#
# Usage: sim/ghdl/isa/run_isa_coverage.sh      (seconds; no ROM needed)
# Exit status 0 = PASS.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SRC="$ROOT/src/vhdl"
WORK="$HERE/run"
CHECKER="$ROOT/boards/cora-z7-07s/lockstep1802.py"

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
  "$ROOT/tb/vhdl/tb_cdp1802_lockstep.vhd"
)

cd "$WORK"
python3 "$HERE/gen_isa_prog.py" prog
ghdl -a "${GHDL_FLAGS[@]}" "${SRCS[@]}"
ghdl -e "${GHDL_FLAGS[@]}" tb_cdp1802_lockstep
ghdl -r "${GHDL_FLAGS[@]}" tb_cdp1802_lockstep -gg_prog_file=prog.hex -gg_log_file=cyc.log \
     -gg_max_clocks=2000000 --ieee-asserts=disable 2>&1 | grep -E "DONE|TIMEOUT|error" || true

set +e
python3 "$CHECKER" --flat --coverage --strict-address prog.bin cyc.log 20 | tee check.txt | tail -40
RC=${PIPESTATUS[0]}
set -e
if [ "$RC" = 0 ] && grep -q " 0 mismatches" check.txt && grep -q "coverage: complete" check.txt; then
  echo "PASS: every opcode (0x68 excluded) and every branch/skip outcome, 0 mismatches"
else
  echo "FAIL: see $WORK/check.txt" >&2
  exit 1
fi
