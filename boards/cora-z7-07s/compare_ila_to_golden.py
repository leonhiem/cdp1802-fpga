#!/usr/bin/env python3
#
# Compare a real-hardware system_ila capture (from capture_ila_from_start.tcl,
# CSV with columns ...,ram_addr,data,nMRD,nMWR,SC,TPB) against
# sim/ghdl/reference/tb_cs1800_tpb.txt to find exactly where real
# hardware's execution first diverges from the golden reference.
#
# Why not just diff the two files row-by-row: past the golden
# reference's first interrupt (its testbench uses a fast, compressed
# fake LC specifically to exercise that path quickly -- see
# BRINGUP_LOG.md), golden's trace has extra interrupt-service
# instructions with no counterpart in a real hardware run that hasn't
# seen a real (50Hz) interrupt yet. That shifts every row index after
# the interrupt out of alignment even where the underlying code is
# identical. Matching the *sequence* of fetched addresses with
# difflib (which finds the longest common subsequence) sidesteps that
# entirely -- see BRINGUP_LOG.md's 2026-09-15 "milestone 3g" entry for
# how this found a real single-bit hardware read glitch this way.
#
# Usage: compare_ila_to_golden.py <ila_capture.csv> [golden_reference.txt]
#
import csv
import difflib
import sys

def load_golden_fetches(path):
    fetches = []
    with open(path) as f:
        next(f)  # header
        for line in f:
            t, addr, data, nmrd, nmwr, q, sc = line.split()
            if sc == "00":  # S0 = fetch
                fetches.append((int(addr, 16), data.upper()))
    return fetches

def load_hw_fetches(path):
    with open(path) as f:
        rows = list(csv.reader(f))
    data_rows = rows[2:]  # skip header + radix rows
    tpb_rows = [r for r in data_rows if r[8] == '1']
    # probe4 (SC) is a 2-bit field written in HEX radix, so binary "00" -> hex "0"
    return [(int(r[3], 16), r[4].upper()) for r in tpb_rows if r[7] == '0']

def main():
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <ila_capture.csv> [golden_reference.txt]", file=sys.stderr)
        sys.exit(1)
    hw_csv = sys.argv[1]
    golden_path = sys.argv[2] if len(sys.argv) > 2 else "sim/ghdl/reference/tb_cs1800_tpb.txt"

    golden = load_golden_fetches(golden_path)
    hw = load_hw_fetches(hw_csv)
    print(f"golden fetch count: {len(golden)}, hw fetch count: {len(hw)}")

    hw_addrs = [a for a, _ in hw]
    golden_addrs = [a for a, _ in golden]
    sm = difflib.SequenceMatcher(None, hw_addrs, golden_addrs, autojunk=False)
    blocks = [b for b in sm.get_matching_blocks() if b.size > 0]

    if not blocks:
        print("No matching subsequence found at all -- diverges from the very first fetch.")
        return

    first = blocks[0]
    print(f"Longest match from the start: hw[{first.a}:{first.a+first.size}] == "
          f"golden[{first.b}:{first.b+first.size}] ({first.size} fetches)")

    div_hw = first.a + first.size
    div_golden = first.b + first.size
    if div_hw < len(hw) and div_golden < len(golden):
        print(f"\nDivergence at hw fetch #{div_hw}:")
        print(f"  hw:     addr={hw[div_hw][0]:04X} data={hw[div_hw][1]}")
        print(f"  golden: addr={golden[div_golden][0]:04X} data={golden[div_golden][1]}")
        xor = hw[div_hw][0] ^ golden[div_golden][0]
        if xor:
            print(f"  address XOR = 0x{xor:X}")
    else:
        print("\nHardware capture matched the golden reference for its entire length.")

    if len(blocks) > 1:
        print(f"\n({len(blocks)} matching blocks total -- later ones may be coincidental re-syncs.)")

if __name__ == "__main__":
    main()
