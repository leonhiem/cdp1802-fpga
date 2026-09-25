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
# Usage:
#   sim/ghdl/run.sh              the quick tier: everything below that runs
#                                in well under a minute -- run this after
#                                every change to src/vhdl/
#   sim/ghdl/run.sh full         the same, but with the exhaustive ALU sweep
#                                (all 131,072 operand combinations per
#                                instruction) and 1,000 random programs
#                                instead of their sampled/short versions
#                                (~30-45 minutes)
#   sim/ghdl/run.sh <target> ... individual targets, any of:
#       cdp18 cs1800 cdp18_sync  golden-reference bus traces
#       memory console           assertion testbenches
#       modes                    the CLEAR/WAIT control modes: LOAD, RESET,
#                                PAUSE, RUN (TODO 2.6)
#       pintiming                pin-level timing against datasheet
#                                Figure 4: TPA/TPB position and width, the
#                                address-byte handoff, MRD/MWR (TODO 2.5)
#       board                    the Cora board's own sims, incl. the
#                                memory map over all 64K addresses
#       isa                      every opcode, every register, both ways
#                                through every branch (TODO 2.2)
#       dma                      interrupt and DMA edge cases (TODO 2.4)
#       alu                      the ALU against the reference model
#                                (TODO 2.1; env STRIDE, see below)
#       random                   random programs (TODO 2.3; env SEEDS)
#
# None of this needs the PRCX-18 ROM image: the programs are generated
# here. The real-ROM lockstep test is separate, in
# boards/cora-z7-07s/sim/run_prcx18_lockstep.sh (see README.md, "Testing").
#
# cdp18_sync (added 2026-09-15, see boards/cora-z7-07s/BRINGUP_LOG.md's
# "milestone 3l"): runs cdp18_sync (ram_sync's registered, A_full-fed
# read instead of ram's combinational read) through the exact same
# stimulus and diffs it directly against cdp18's own golden reference
# -- if the design's memory-timing change is truly invisible to CPU
# behavior, the two must be byte-for-byte identical. This is the
# regression that makes sure the real fix (A_full, not the
# ram_addr/TPA-latch reconstruction milestone 3k's failed attempt used)
# stays proven as anything upstream changes.

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
  "$SRC/ram_sync.vhd"
  "$SRC/cdp18_sync.vhd"
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

run_and_diff() {
  local name="$1"
  local tb_file="$2"
  local out_file="$3"
  local golden="$4"

  echo "=== $name ==="
  (
    cd "$WORK"
    ghdl -a "${GHDL_FLAGS[@]}" "${COMMON_SRCS[@]}" "$tb_file"
    ghdl -e "${GHDL_FLAGS[@]}" "$name"
    ghdl -r "${GHDL_FLAGS[@]}" "$name" --ieee-asserts=disable
  )
  if diff -q "$WORK/$out_file" "$golden" >/dev/null; then
    echo "PASS: $out_file matches $golden"
  else
    echo "FAIL: $out_file differs from $golden" >&2
    diff "$WORK/$out_file" "$golden" || true
    exit 1
  fi
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

# The quick tier samples the ALU's operand space and runs a few random
# seeds; "full" runs both to completion. Override either directly with
# STRIDE=... / SEEDS=... on any invocation.
QUICK=(cdp18 cs1800 memory console modes pintiming cdp18_sync board isa dma alu random)

# Runs one of the other test scripts: full output to a log, only its
# verdict on the console (and the tail of the log if it fails).
run_script() {
  local name="$1"; shift
  local log="$WORK/$name.log"
  mkdir -p "$WORK"
  echo "=== $name ==="
  if "$@" > "$log" 2>&1; then
    grep -E "^PASS" "$log" | tail -2
  else
    echo "FAIL: $name -- see $log" >&2
    tail -25 "$log" >&2
    exit 1
  fi
}

TARGETS=("$@")
if [ ${#TARGETS[@]} -eq 0 ]; then
  TARGETS=("${QUICK[@]}")
  STRIDE="${STRIDE:-64}"
  SEEDS="${SEEDS:-8}"
elif [ "${TARGETS[0]}" = "full" ]; then
  TARGETS=("${QUICK[@]}")
  STRIDE="${STRIDE:-1}"
  SEEDS="${SEEDS:-1000}"
fi
STRIDE="${STRIDE:-1}"
SEEDS="${SEEDS:-200}"
export STRIDE

START=$SECONDS
for t in "${TARGETS[@]}"; do
  case "$t" in
    cdp18)    run_one tb_cdp18_dump  "$TB/tb_cdp18_dump.vhd"  tb_cdp18_tpb.txt ;;
    cs1800)   run_one tb_cs1800_dump "$TB/tb_cs1800_dump.vhd" tb_cs1800_tpb.txt ;;
    memory)   run_check tb_cs1800_memory  "$TB/tb_cs1800_memory.vhd" ;;
    modes)    run_check tb_cdp1802_modes  "$TB/tb_cdp1802_modes.vhd" ;;
    pintiming) run_check tb_cdp1802_pin_timing "$TB/tb_cdp1802_pin_timing.vhd" ;;
    console)  run_check tb_cs1800_console "$TB/tb_cs1800_console.vhd" ;;
    cdp18_sync) run_and_diff tb_cdp18_sync_dump "$TB/tb_cdp18_sync_dump.vhd" \
                  tb_cdp18_sync_tpb.txt "$REF/tb_cdp18_tpb.txt" ;;
    board)    run_script board  "$ROOT/boards/cora-z7-07s/sim/run.sh" ;;
    isa)      run_script isa    "$HERE/isa/run_isa_coverage.sh" ;;
    dma)      run_script dma    "$HERE/isa/run_dma.sh" ;;
    alu)      run_script alu    "$HERE/alu/run_alu_exhaustive.sh" ;;
    random)   run_script random "$HERE/isa/run_random.sh" 1 "$SEEDS" ;;
    *) echo "unknown target: $t" >&2; exit 1 ;;
  esac
done

echo "=== summary ==="
echo "PASS: ${#TARGETS[@]} targets (${TARGETS[*]}) in $((SECONDS - START))s"
if [ "$STRIDE" != 1 ] || [ "$SEEDS" != 1000 ]; then
  echo "      quick tier: ALU operand stride $STRIDE, $SEEDS random seeds."
  echo "      Run 'sim/ghdl/run.sh full' for the exhaustive ALU sweep and 1000 seeds."
fi
