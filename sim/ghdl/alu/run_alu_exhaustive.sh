#!/usr/bin/env bash
#
# TODO 2.1 (doc/CDP1802_CORE_REVIEW.md): exhaustive ALU test of the bare
# CDP1802 core. For every ALU instruction, gen_alu_prog.py builds a program
# that runs it over all D x M x DF combinations (131,072; shifts D x DF),
# tb_cdp1802_lockstep.vhd runs it on src/vhdl/cdp1802.vhd with a flat 64 KB
# memory, and lockstep1802.py --flat checks every result byte and every
# DF-dependent branch against its own instruction-set model.
#
# Usage: sim/ghdl/alu/run_alu_exhaustive.sh [opcode-hex ...]
#        (no arguments = all 22 ALU instructions)
# Env:   JOBS=<n>  parallel simulations (default: number of CPUs - 1)
#
# Runs without any ROM image (only our own generated programs), so it can
# be part of the normal regression. Exit status 0 = every instruction PASS.
# Per-instruction results: sim/ghdl/alu/run/<op>.result (+ .check on FAIL).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SRC="$ROOT/src/vhdl"
WORK="$HERE/run"
CHECKER="$ROOT/boards/cora-z7-07s/lockstep1802.py"

ALL_OPS=(F1 F2 F3 F4 F5 F7 74 75 77  F9 FA FB FC FD FF 7C 7D 7F  F6 FE 76 7E)
if [ $# -gt 0 ]; then OPS=("$@"); else OPS=("${ALL_OPS[@]}"); fi
JOBS="${JOBS:-$(( $(nproc) > 1 ? $(nproc) - 1 : 1 ))}"

# Only one run at a time: a second one would wipe this one's files.
exec 9>"$HERE/.lock"
if ! flock -n 9; then
  echo "another run_alu_exhaustive.sh is already running" >&2
  exit 1
fi

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

(
  cd "$WORK"
  ghdl -a "${GHDL_FLAGS[@]}" "${SRCS[@]}"
  echo 00 > prog.hex   # elaboration opens the default g_prog_file
  ghdl -e "${GHDL_FLAGS[@]}" tb_cdp1802_lockstep
)

run_op() {
  local op="$1"
  local d="$WORK/op_$op"
  mkdir -p "$d"
  cd "$d"
  python3 "$HERE/gen_alu_prog.py" "$op" prog
  local t0=$SECONDS
  ghdl -r "${GHDL_FLAGS[@]}" tb_cdp1802_lockstep -gg_prog_file=prog.hex -gg_log_file=cyc.log \
       --ieee-asserts=disable > sim.txt 2>&1 || true
  if ! grep -q "DONE" sim.txt; then
    echo "$op FAIL: simulation did not finish (see $d/sim.txt)" > "$WORK/$op.result"
    return
  fi
  python3 "$CHECKER" --flat prog.bin cyc.log 20 > check.txt 2>&1 || true
  local summary
  summary="$(grep -m1 -E '^done:|MISMATCH' check.txt || echo 'checker did not finish')"
  if grep -q " 0 mismatches" check.txt; then
    echo "$op PASS: $summary ($((SECONDS - t0)) s)" > "$WORK/$op.result"
    rm -f cyc.log
  else
    cp check.txt "$WORK/$op.check"
    echo "$op FAIL: $summary -- see $WORK/$op.check" > "$WORK/$op.result"
  fi
}
export -f run_op
export HERE WORK CHECKER
export GHDL_FLAGS_STR="${GHDL_FLAGS[*]}"

echo "=== running ${#OPS[@]} instruction(s), $JOBS in parallel ==="
printf '%s\n' "${OPS[@]}" | xargs -P "$JOBS" -I{} bash -c \
  'GHDL_FLAGS=($GHDL_FLAGS_STR); run_op {}; cat "$WORK/{}.result"'

echo "=== summary ==="
FAIL=0
for op in "${OPS[@]}"; do
  cat "$WORK/$op.result"
  grep -q " PASS:" "$WORK/$op.result" || FAIL=1
done
if [ $FAIL = 0 ]; then
  echo "PASS: all ${#OPS[@]} ALU instructions match the reference model exhaustively"
else
  echo "FAIL: see the .check files in $WORK" >&2
  exit 1
fi
