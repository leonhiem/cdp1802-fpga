#!/usr/bin/env python3
#
# Generates a small POSIX shell script that loads the real PRCX-18 EPROM
# dump into cs1800_prcx18_top's memory via axi_bram_ctrl_0 (Port B,
# 0x40000000+), using only `busybox devmem` (no python on the target
# PetaLinux image -- see boards/cora-z7-07s/BRINGUP_LOG.md). Also
# releases reset and starts the CPU (ctrl_in = 0x68: reset=0, run=1,
# nEF="110", matching tb_prcx18_lutram.vhd's own stimulus exactly).
#
# The ROM itself is NOT in this repo (doc/cs1800_hardware_source/ is
# gitignored -- it's the user's own real, dumped EPROM, not ours to
# redistribute); point this at that local file explicitly.
#
# Usage:
#   python3 gen_load_prcx18_rom.py <path-to-prcx18.bin> > /tmp/load_and_run.sh
#   scp -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
#       /tmp/load_and_run.sh root@<board>:/tmp/
#   ssh ... root@<board> 'sh /tmp/load_and_run.sh'
#
import sys

def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <path-to-prcx18.bin>", file=sys.stderr)
        sys.exit(1)

    rom = open(sys.argv[1], "rb").read()
    if len(rom) != 8192:
        print(f"warning: expected 8192 bytes (real 2764 EPROM size), got {len(rom)}", file=sys.stderr)

    print("#!/bin/sh")
    print("set -e")
    # Hold the CPU in reset for the whole load -- otherwise it keeps
    # running (ctrl_in keeps its previous value, e.g. 0x68 after an
    # earlier run) while its own ROM is overwritten underneath it.
    print("busybox devmem 0x41200000 32 0x01   # reset=1 during the load")
    print("echo LOADING_ROM")
    for i in range(0, len(rom) - (len(rom) % 4), 4):
        word = rom[i] | (rom[i + 1] << 8) | (rom[i + 2] << 16) | (rom[i + 3] << 24)
        addr = 0x40000000 + i
        print(f"busybox devmem 0x{addr:08x} 32 0x{word:08x}")
    print("echo ROM_LOADED")
    print("busybox devmem 0x41200000 32 0x01   # reset=1, run=0 (make sure)")
    # Zero uart_rx_data/uart_rx_available (axi_gpio_1 channel 1) before
    # releasing reset, so no stale injected keystroke from an earlier
    # session is pending when PRCX-18 starts. Defensive only -- added
    # 2026-09-18 on a misread "DA stuck at 1" (see BRINGUP_LOG.md), not
    # a confirmed bug.
    print("busybox devmem 0x41210000 32 0x0   # zero uart_rx_data/uart_rx_available before release")
    print("busybox devmem 0x41200000 32 0x68   # reset=0, run=1, nEF=110")
    print("echo RUNNING")

if __name__ == "__main__":
    main()
