#!/usr/bin/env python3
#
# Turns a system_ila CSV capture of cs1800_prcx18_top into the same
# machine-cycle log the simulation writes (sim/tb_prcx18_lockstep.vhd's
# cyc.log), so a board capture can be read -- and diffed -- against the
# simulation of the very same RTL:
#
#   boards/cora-z7-07s/ila2cyc.py capture.csv > board.log
#   grep -n "<the board's first line>" sim/run_lockstep/cyc.log
#   diff <(tail -n +N sim/run_lockstep/cyc.log) board.log | head
#
# One line per cycle, at every TPB rising edge:
#   C <sc> <addr> <data> <R|->      (R = this cycle asserted nMRD)
# preceded by "W <addr> <data>" for a cycle that wrote memory, exactly
# like the testbench. lockstep1802.py reads this format directly.
#
# The CSV must come from capture_ila_prcx18.tcl (or any capture of the
# same u_ila_0): probe1=data, probe2=nMRD, probe3=nMWR, probe4=SC,
# probe5=TPB, probe18=A_full. Columns are found by probe name, not
# position, so extra probes are fine.

import csv
import re
import sys


def column_map(header):
    """probe number -> column index, from names like '.../probe18_1[15:0]'."""
    cols = {}
    for i, name in enumerate(header):
        m = re.search(r"probe(\d+)_", name)
        if m:
            cols[int(m.group(1))] = i
    return cols


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <ila-capture.csv>", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1], newline="") as f:
        rows = list(csv.reader(f))
    cols = column_map(rows[0])
    for need in (1, 2, 3, 4, 5, 18):
        if need not in cols:
            print(f"capture has no probe{need} -- not a cs1800_prcx18 ILA CSV",
                  file=sys.stderr)
            sys.exit(1)

    prev_tpb = prev_nmwr = "1"
    read = False
    write = None
    out = []
    for row in rows[2:]:   # row 1 is the radix line
        if not row:
            continue
        data, nmrd, nmwr, sc, tpb, addr = (row[cols[n]].strip()
                                           for n in (1, 2, 3, 4, 5, 18))
        if nmrd == "0":
            read = True
        # A write belongs to the cycle its pulse STARTED in -- the same
        # rule the testbench uses, so the two logs line up.
        if nmwr == "0" and (prev_nmwr == "1" or write):
            write = (addr, data)
        if tpb == "1" and prev_tpb == "0":
            if write:
                out.append(f"W {write[0].upper()} {write[1].upper()}")
                write = None
            out.append(f"C {int(sc, 16)} {addr.upper()} {data.upper()} "
                       f"{'R' if read else '-'}")
            read = False
        prev_tpb, prev_nmwr = tpb, nmwr

    print("\n".join(out))


if __name__ == "__main__":
    main()
