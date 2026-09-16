#!/bin/sh
#
# Live interactive bridge between this shell's stdin/stdout and
# cs1800_prcx18_top's CDP1854 port A (the real PRCX-18 console), via
# devmem -- runs a real, live terminal session against the CPU on the
# Cora board, in place of scripted-timing testbench guesses. Built
# 2026-09-16 (see boards/cora-z7-07s/BRINGUP_LOG.md's "DMP command"
# investigation) after several fixed-timing simulation attempts to
# catch PRCX-18 reading a keystroke all came back negative -- a human
# trying it live, with real reaction-time typing, is the next useful
# experiment a static testbench timing choice can't substitute for.
#
# Run this ON THE BOARD (ssh in first) -- avoids the ~100-300ms SSH
# round-trip latency a per-keystroke remote devmem call from the host
# would add; this way only the local tty<->this shell path matters.
#
# Design:
#   - Puts THIS session's tty into raw, no-echo mode (stty raw -echo)
#     so keystrokes go straight through with no local line-buffering.
#   - Backgrounds a tight, unsloped polling loop that continuously
#     drains cs1800_prcx18_top's software TX FIFO (axi_gpio_1 channel
#     2, 0x41210008) and prints each byte to this same session's
#     stdout the instant it appears -- see drain_uart_fifo.sh's own
#     header for why the FIFO (not the raw uart_tx_data/valid pulse)
#     is needed here. No sleep in the loop deliberately, for the
#     lowest possible latency; the board's single Cortex-A9 core
#     handles this fine since the foreground reader below blocks
#     (yields the CPU) between keystrokes.
#   - Foreground loop reads one raw byte at a time from stdin (`dd
#     bs=1 count=1`) and immediately writes it into
#     cs1800_prcx18_top's uart_rx_data/uart_rx_available
#     (axi_gpio_1 channel 1, 0x41210000), then clears it -- a single
#     keystroke, not held indefinitely (matching how a real UART
#     receives one character at a time).
#   - Ctrl-C (or any exit) restores the tty and kills the background
#     drain loop via a trap.
#
# Usage (from the board's own shell, after the design is programmed,
# the ROM is loaded, and reset released -- see gen_load_prcx18_rom.py's
# generated script):
#   sh interactive_console.sh [base_ctrl_hex]
#
# base_ctrl_hex defaults to 0x68 (reset=0, run=1, nEF="110", LC
# free-running) -- matching every other tool in this repo's own
# convention. Pass e.g. 0x48 to also freeze LC (see
# cs1800_prcx18_top.vhd's own ctrl_in(5) note) if LC/timer-interrupt
# noise needs to be eliminated for a specific experiment.

CTRL=0x41200000
RX=0x41210000
TXFIFO=0x41210008
BASE_CTRL=${1:-0x68}
POP_CTRL=$((BASE_CTRL | 0x80))

old_stty=$(stty -g)
stty raw -echo

cleanup() {
  kill "$bg_pid" 2>/dev/null
  stty "$old_stty"
  echo ""
  echo "[interactive_console.sh: session ended]"
  exit 0
}
trap cleanup INT TERM

# Background: drain the TX FIFO, print each byte as it arrives.
(
  while true; do
    v=$(busybox devmem $TXFIFO 32)
    if [ $((v & 0x100)) -ne 0 ]; then
      byte=$((v & 0xff))
      printf "\\$(printf '%03o' "$byte")"
      busybox devmem $CTRL 32 "$(printf '0x%02x' $POP_CTRL)"
      busybox devmem $CTRL 32 "$(printf '0x%02x' "$BASE_CTRL")"
    fi
  done
) &
bg_pid=$!

# Foreground: forward one typed byte at a time.
while true; do
  ch=$(dd bs=1 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')
  [ -z "$ch" ] && continue
  val=$(( (1 << 8) | ch ))
  busybox devmem $RX 32 "$(printf '0x%03x' $val)"
  busybox devmem $RX 32 0x0
done
