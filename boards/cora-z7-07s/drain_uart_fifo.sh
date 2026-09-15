#!/bin/sh
#
# Run ON THE BOARD (not over SSH per-byte -- a devmem round trip over
# SSH costs low-single-digit milliseconds, see BRINGUP_LOG.md) to drain
# cs1800_prcx18_top's software-drainable TX byte FIFO: axi_gpio_1
# channel 2 (0x41210008) carries bit8=avail, bits7:0=head byte; popping
# is ctrl_in(7) (axi_gpio_0 channel 1, 0x41200000) edge-detected, so a
# 1-then-0 write pulses it while preserving whatever run/reset/nEF bits
# are already live in $BASE_CTRL (0x68 = reset=0,run=1,nEF="110" by
# default -- override via argv if the board was started differently).
#
# Prints one hex byte pair per captured FIFO byte to stdout.
#
# Usage: drain_uart_fifo.sh [iterations] [base_ctrl_hex]
N=${1:-4000}
BASE_CTRL=${2:-0x68}
POP_CTRL=$((BASE_CTRL | 0x80))

i=0
while [ $i -lt $N ]; do
  v=$(busybox devmem 0x41210008 32)
  if [ $(( v & 0x100 )) -ne 0 ]; then
    printf '%02x\n' $(( v & 0xff ))
    busybox devmem 0x41200000 32 $(printf '0x%02x' $POP_CTRL)
    busybox devmem 0x41200000 32 $(printf '0x%02x' $BASE_CTRL)
  fi
  i=$((i + 1))
done
