#!/usr/bin/env bash
#
# Real-ROM regression + lockstep ISA check, in one command:
#   1. generates the ROM package from your local EPROM dump,
#   2. simulates cs1800_prcx18_top booting PRCX-18 (LC at 50 Hz), typing
#      DMP<CR> at the prompt and draining the output slowly,
#   3. checks every machine cycle against the independent CDP1802 model
#      (lockstep1802.py),
#   4. checks the console output: banner, prompt, the full 16-line dump
#      and the closing prompt.
#
# Usage: boards/cora-z7-07s/sim/run_prcx18_lockstep.sh <prcx18.bin>
# Takes ~10 minutes with GHDL mcode. Exit status 0 = PASS.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <prcx18.bin>" >&2
  exit 1
fi
ROM_BIN="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD_DIR="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$BOARD_DIR/../.." && pwd)"
SRC="$ROOT/src/vhdl"
WORK="$HERE/run_lockstep"   # own dir: sim/run.sh wipes run/

rm -rf "$WORK"
mkdir -p "$WORK"

python3 "$HERE/gen_rom_pkg.py" "$ROM_BIN" > "$WORK/prcx18_rom_pkg.vhd"

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
  "$SRC/cdp18.vhd"
  "$SRC/cs1800_cpu.vhd"
  "$SRC/cs1800.vhd"
  "$SRC/cs1800_memory.vhd"
  "$SRC/cdp1854.vhd"
  "$SRC/cs1800_io_select.vhd"
  "$SRC/cs1800_console.vhd"
  "$BOARD_DIR/hdl/byte_fifo.vhd"
  "$BOARD_DIR/hdl/cs1800_prcx18_memory.vhd"
  "$BOARD_DIR/hdl/cs1800_prcx18_top.vhd"
  "$WORK/prcx18_rom_pkg.vhd"
  "$HERE/tb_prcx18_lockstep.vhd"
)

(
  cd "$WORK"
  ghdl -a "${GHDL_FLAGS[@]}" "${SRCS[@]}"
  ghdl -e "${GHDL_FLAGS[@]}" tb_prcx18_lockstep
  echo "=== simulating (about 10 minutes) ==="
  ghdl -r "${GHDL_FLAGS[@]}" tb_prcx18_lockstep --ieee-asserts=disable 2>&1 | grep -v "metavalue" || true
)

echo "=== lockstep check ==="
LOCKSTEP_OK=1
python3 "$BOARD_DIR/lockstep1802.py" "$ROM_BIN" "$WORK/cyc.log" 20 | tee "$WORK/lockstep.txt" | tail -40
grep -q " 0 mismatches" "$WORK/lockstep.txt" || LOCKSTEP_OK=0

echo "=== console output ==="
python3 - "$WORK/drain.log" <<'EOF' | tee "$WORK/console.txt"
import sys
b = bytes(int(l, 16) for l in open(sys.argv[1]) if l.strip())
print(b.decode("ascii", "replace"))
EOF

CONSOLE_OK=1
for pat in "CS1800/PRCX-18    V1.9.0" "_08> DMP" "40F0  00" ; do
  grep -qF "$pat" "$WORK/console.txt" || { echo "missing: '$pat'" >&2; CONSOLE_OK=0; }
done
[ "$(grep -c '_08>' "$WORK/console.txt")" -ge 2 ] || { echo "missing: closing prompt after DMP" >&2; CONSOLE_OK=0; }

if [ $LOCKSTEP_OK = 1 ] && [ $CONSOLE_OK = 1 ]; then
  echo "PASS: 0 lockstep mismatches, full DMP output and closing prompt"
else
  echo "FAIL: see $WORK/lockstep.txt and $WORK/console.txt" >&2
  exit 1
fi
