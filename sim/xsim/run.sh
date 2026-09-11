#!/usr/bin/env bash
#
# Compile and run the reference-dump testbenches (see sim/ghdl/) on Vivado's
# simulator (xvhdl/xelab/xsim) instead of GHDL, and diff the resulting trace
# against the golden reference committed under sim/ghdl/reference/. This is
# a cross-simulator check, not a second source of truth.
#
# Requires xvhdl/xelab/xsim on PATH, i.e. source Vivado's settings64.sh
# first:
#   source <Vivado install>/<version>/settings64.sh
#
# Usage: sim/xsim/run.sh [cdp18] [cs1800]
#        (with no arguments, both are run)

set -euo pipefail

if ! command -v xvhdl >/dev/null 2>&1; then
  echo "xvhdl not found on PATH. Source Vivado's settings64.sh first, e.g.:" >&2
  echo "  source <Vivado install>/<version>/settings64.sh" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$ROOT/src/vhdl"
TB="$ROOT/tb/vhdl"
WORK="$HERE/run"
GOLDEN="$ROOT/sim/ghdl/reference"

rm -rf "$WORK"
mkdir -p "$WORK"

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
)

run_one() {
  local name="$1"
  local tb_file="$2"
  local out_file="$3"

  echo "=== $name ==="
  (
    cd "$WORK"
    xvhdl --2008 --relax --nolog "${COMMON_SRCS[@]}" "$tb_file"
    xelab --debug off --relax "work.$name" -s "$name" --nolog
    xsim "$name" -runall --nolog
  )

  if diff -q "$WORK/$out_file" "$GOLDEN/$out_file" >/dev/null; then
    echo "PASS: $out_file matches sim/ghdl/reference/$out_file"
  else
    echo "FAIL: $out_file differs from sim/ghdl/reference/$out_file" >&2
    diff "$WORK/$out_file" "$GOLDEN/$out_file" || true
    exit 1
  fi
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
