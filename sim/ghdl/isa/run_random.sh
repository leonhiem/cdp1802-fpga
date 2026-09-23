#!/usr/bin/env bash
#
# TODO 2.3 (doc/CDP1802_CORE_REVIEW.md): random instruction streams on the
# bare CDP1802 core. For each seed, gen_random_prog.py builds a random but
# well-formed program (random instructions and operands, branches, skips,
# SEP calls, interrupts, IDL), tb_cdp1802_lockstep.vhd runs it, and
# lockstep1802.py --flat --strict-address checks every machine cycle.
#
# Usage: sim/ghdl/isa/run_random.sh [first_seed] [n_seeds] [n_items]
#        defaults: seeds 1..200, 3000 items per program
# Env:   JOBS=<n>  parallel simulations (default: number of CPUs - 1)
# A failing seed is reproducible: re-run with that seed and n_seeds=1; its
# program, log and checker output stay in sim/ghdl/isa/run_random/seed_<n>/.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SRC="$ROOT/src/vhdl"
WORK="$HERE/run_random"
CHECKER="$ROOT/boards/cora-z7-07s/lockstep1802.py"
FIRST="${1:-1}"
COUNT="${2:-200}"
ITEMS="${3:-3000}"
JOBS="${JOBS:-$(( $(nproc) > 1 ? $(nproc) - 1 : 1 ))}"

exec 9>"$HERE/.lock_random"
if ! flock -n 9; then
  echo "another run_random.sh is already running" >&2
  echo "(if you interrupted one, its simulations may still hold the lock:" >&2
  echo " pkill -f tb_cdp1802_lockstep)" >&2
  exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK"
GHDL_FLAGS=(--std=08 --workdir="$WORK" -fsynopsys -frelaxed)
SRCS=(
  "$SRC/cdp1802_pkg.vhd" "$SRC/instr_pkg.vhd" "$SRC/test_program_pkg.vhd"
  "$SRC/dff.vhd" "$SRC/ff.vhd" "$SRC/reg.vhd" "$SRC/amux.vhd" "$SRC/dmux.vhd"
  "$SRC/alu.vhd" "$SRC/reg_R.vhd" "$SRC/control.vhd" "$SRC/instr.vhd"
  "$SRC/cdp1802.vhd" "$ROOT/tb/vhdl/tb_cdp1802_lockstep.vhd"
)
(
  cd "$WORK"
  ghdl -a "${GHDL_FLAGS[@]}" "${SRCS[@]}"
  echo 00 > prog.hex   # elaboration opens the default g_prog_file
  ghdl -e "${GHDL_FLAGS[@]}" tb_cdp1802_lockstep
)

run_seed() {
  local seed="$1"
  local d="$WORK/seed_$seed"
  mkdir -p "$d"
  cd "$d"
  python3 "$HERE/gen_random_prog.py" "$seed" prog "$ITEMS"
  ghdl -r --std=08 --workdir="$WORK" -fsynopsys -frelaxed tb_cdp1802_lockstep \
       -gg_prog_file=prog.hex -gg_log_file=cyc.log -gg_max_clocks=20000000 \
       --ieee-asserts=disable > sim.txt 2>&1 || true
  if ! grep -q "DONE" sim.txt; then
    echo "seed $seed FAIL: simulation did not finish (see $d/sim.txt)"
    return
  fi
  python3 "$CHECKER" --flat --strict-address prog.bin cyc.log 10 > check.txt 2>&1 || true
  if grep -q " 0 mismatches" check.txt; then
    echo "seed $seed PASS: $(grep '^done:' check.txt)"
    rm -rf "$d"
  else
    echo "seed $seed FAIL: $(grep -m1 -E 'MISMATCH|^done|Error' check.txt) -- see $d/check.txt"
  fi
}
export -f run_seed
export HERE WORK CHECKER ITEMS

seq "$FIRST" $((FIRST + COUNT - 1)) | xargs -P "$JOBS" -I{} bash -c 'run_seed {}' | tee "$WORK/results.txt"

PASS=$(grep -c " PASS:" "$WORK/results.txt" || true)
if [ "$PASS" = "$COUNT" ]; then
  INSTR=$(sed -E 's/.*done: ([0-9]+) instructions, ([0-9]+) interrupts, ([0-9]+) DMA cycles.*/\1 \2 \3/' "$WORK/results.txt" | awk '{i+=$1; n+=$2; d+=$3} END {print i" instructions, "n" interrupts, "d" DMA cycles"}')
  echo "PASS: all $COUNT random programs (seeds $FIRST..$((FIRST + COUNT - 1))), $INSTR, 0 mismatches"
else
  echo "FAIL: $((COUNT - PASS)) of $COUNT seeds failed (see above)" >&2
  exit 1
fi
