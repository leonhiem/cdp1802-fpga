#!/usr/bin/env bash
#
# One command for "does the current bitstream still boot PRCX-18 on the
# Cora?" -- the board-side counterpart of sim/ghdl/run.sh, and the test
# every A/B bitstream bisect needs (see BRINGUP_LOG.md).
#
# It does the three steps that must happen in this order, because
# cs1800_prcx18_top's ROM is runtime-loaded Block RAM, NOT part of the
# bitstream (gen_load_prcx18_rom.py's header): program, load the ROM
# while the CPU is held in reset, release reset, then drain the TX FIFO
# and print what the OS said.
#
# Usage:
#   BOARD_PW=<password> BOARD_HOST=<board-ip> \
#       boards/cora-z7-07s/boot_test.sh [--program] [--rom <prcx18.bin>]
#
# (or --host <board-ip> instead of BOARD_HOST)
#
# The ROM is not in this repo (doc/cs1800_hardware_source/ is gitignored):
# it defaults to doc/cs1800_hardware_source/prcx18.bin if that exists.
# The board's address and password come from the environment, never from
# this file.
#
# A good boot prints the real banner:
#   Dutch 1800 MicroProUsers / CS1800/PRCX-18  V1.9.0 /
#   -SYS-Starting Console Task- / _08>
# and the RAM-detection result the OS stores at
# 0x7BFC-0x7BFF -- see README.md's "DMP <page>".

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HOST="${BOARD_HOST:-}"
ROM="$ROOT/doc/cs1800_hardware_source/prcx18.bin"
PROGRAM=0
FREEZE_LC=0
SETTLE=${SETTLE:-4}

while [ $# -gt 0 ]; do
  case "$1" in
    --program) PROGRAM=1; shift ;;
    --freeze-lc) FREEZE_LC=1; shift ;;
    --host) HOST="$2"; shift 2 ;;
    --rom)  ROM="$2";  shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

: "${BOARD_PW:?set BOARD_PW to the board root password -- never commit it}"
: "${HOST:?set BOARD_HOST (or pass --host) to the board address}"

SSH=("$HERE/sshpw.py" "$BOARD_PW" ssh
     -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa
     -o StrictHostKeyChecking=no -o LogLevel=ERROR "root@$HOST")
SCP=("$HERE/sshpw.py" "$BOARD_PW" scp
     -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa
     -o StrictHostKeyChecking=no -o LogLevel=ERROR)

if [ "$PROGRAM" = 1 ]; then
  echo "=== programming the FPGA ==="
  vivado -mode batch -source "$HERE/program_prcx18.tcl" > /tmp/boot_test_program.log 2>&1 \
    || { echo "programming FAILED, see /tmp/boot_test_program.log" >&2; exit 1; }
fi

echo "=== loading the ROM and releasing reset ==="
[ -r "$ROM" ] || { echo "no ROM image at $ROM (use --rom)" >&2; exit 1; }
python3 "$HERE/gen_load_prcx18_rom.py" "$ROM" > /tmp/load_and_run.sh || exit 1
# --freeze-lc: release the CPU with ctrl_in(5)=0, which stops the 50 Hz
# line-clock generator (and so the LC interrupt) instead of starting it at
# the same instant reset is released.
#
# EXPECT A DOUBLE BOOT with this flag. PRCX-18 does reach its prompt with
# the line clock off, but it resets itself once on the way -- user-verified
# on the real CS1800 with the CPU board's CLOCK OFF switch, and only at
# power-on, not on a reset press. So two banners here are correct
# behaviour, not a fault; this flag is for taking the LC interrupt out of
# the picture, not for a clean pass/fail.
if [ "$FREEZE_LC" = 1 ]; then
  sed -i 's/32 0x68/32 0x48/' /tmp/load_and_run.sh
  echo "(LC frozen: releasing with ctrl_in=0x48)"
fi
"${SCP[@]}" /tmp/load_and_run.sh "root@$HOST:/tmp/" > /dev/null || exit 1
"${SSH[@]}" 'sh /tmp/load_and_run.sh' 2>&1 | tail -2

echo "=== draining the TX FIFO after ${SETTLE}s ==="
# axi_gpio_1 channel 2 (0x41210008): bit 8 = "byte available", bits 7:0 =
# the byte; popping is ctrl_in(7) high then low (interactive_console.sh).
cat > /tmp/boot_test_drain.sh <<'DRAIN'
#!/bin/sh
sleep "$1"
n=0; out=""
while [ $n -lt 2000 ]; do
  v=$(busybox devmem 0x41210008 32)
  [ $((v & 0x100)) -ne 0 ] || break
  out="$out $(printf %02x $((v & 0xff)))"
  busybox devmem 0x41200000 32 0xe8
  busybox devmem 0x41200000 32 0x68
  n=$((n+1))
done
echo "BYTES:$out"
echo "bounds: $(busybox devmem 0x40007bfc 32)"
DRAIN
"${SCP[@]}" /tmp/boot_test_drain.sh "root@$HOST:/tmp/" > /dev/null || exit 1
"${SSH[@]}" "sh /tmp/boot_test_drain.sh $SETTLE" 2>&1 | tr -d '\r' > /tmp/boot_test_out.txt

BYTES=$(sed -n 's/^BYTES://p' /tmp/boot_test_out.txt)
BOUNDS=$(sed -n 's/^bounds: //p' /tmp/boot_test_out.txt)
echo "--- console output ($(echo $BYTES | wc -w) bytes) ---"
for b in $BYTES; do printf "\\x$b"; done | cat -v
echo
# 0x7BFC..0x7BFF little-endian: bottom then top of the detected RAM
echo "--- RAM bounds word at 0x7BFC: $BOUNDS (good boot: 0xFF7F0040 = 4000..7FFF) ---"
if echo "$BYTES" | grep -qi "5f 30 38 3e"; then   # "_08>"
  echo "PASS: reached the _08> prompt"
else
  echo "FAIL: no _08> prompt in the output above"
  exit 1
fi
