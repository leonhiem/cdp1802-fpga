#!/usr/bin/env python3
#
# Lockstep checker: replays a machine-cycle log from the VHDL CDP1802 core
# through an independent instruction-level CDP1802 model and reports the
# first places where the two disagree (fetch address, memory access
# address, written data, interrupt taken while IE=0, ...).
#
# Input log format (one event per line, as written by a GHDL testbench):
#   C <sc> <addr> <data> <R|->   at each TPB rising edge (one per machine cycle)
#   W <addr> <data>              at the end of each nMWR pulse
# <sc> is the CDP1802 state code: 0=S0 fetch, 1=S1 execute, 2=S2 DMA,
# 3=S3 interrupt.
#
# Read data is taken from the log (it is what the core actually saw on the
# bus); a separate memory image (ROM file + logged writes) cross-checks
# memory reads so memory-side bugs show up too.
#
# Usage: lockstep1802.py [--flat] <rom.bin> <cyc.log> [max_errors]
#   default: the Cora/CS1800 map -- ROM 0x0000-0x1FFF, RAM 0x4000-0x5FFF,
#            everything else void (reads must return 0xFF)
#   --flat : one 64 KB RAM holding <rom.bin> at 0x0000, rest 0x00
#            (tb/vhdl/tb_cdp1802_alu.vhd)

import sys

ROM_END = 0x2000
RAM_LO, RAM_HI = 0x4000, 0x5FFF


def load_events(path):
    ev = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if not p:
                continue
            if p[0] == 'C' and len(p) == 5:
                ev.append(('C', int(p[1], 16), int(p[2], 16), int(p[3], 16), p[4] == 'R'))
            elif p[0] == 'W' and len(p) == 3:
                ev.append(('W', int(p[1], 16), int(p[2], 16)))
    return ev


def group_cycles(ev):
    """Return list of cycles: dict(sc, addr, data, rd, w=(addr,data)|None).
    A W event is attached to the adjacent C cycle with the same address
    (checked both the preceding and the following cycle)."""
    cyc = []
    pending_w = []
    for e in ev:
        if e[0] == 'C':
            c = dict(sc=e[1], addr=e[2], data=e[3], rd=e[4], w=None)
            for w in pending_w:
                if w[1] == c['addr']:
                    c['w'] = (w[1], w[2])
                elif cyc and cyc[-1]['addr'] == w[1]:
                    cyc[-1]['w'] = (w[1], w[2])
                else:
                    c['w_orphan'] = (w[1], w[2])
            pending_w = []
            cyc.append(c)
        else:
            # A write whose address equals the last cycle's address most
            # likely belongs to it (write ended after its TPB).
            if cyc and cyc[-1]['addr'] == e[1] and cyc[-1]['w'] is None:
                cyc[-1]['w'] = (e[1], e[2])
            else:
                pending_w.append(e)
    return cyc


class CPU:
    def __init__(self):
        self.R = [0] * 16
        self.P = self.X = 0
        self.D = 0
        self.DF = 0
        self.IE = 1
        self.T = 0
        self.Q = 0


def main():
    global ROM_END, RAM_LO, RAM_HI
    args = sys.argv[1:]
    flat = '--flat' in args
    args = [a for a in args if a != '--flat']
    rom = open(args[0], 'rb').read()
    cyc = group_cycles(load_events(args[1]))
    max_err = int(args[2]) if len(args) > 2 else 10

    mem = {}
    if flat:
        ROM_END, RAM_LO, RAM_HI = 0, 0x0000, 0xFFFF
        for i in range(0x10000):
            mem[i] = rom[i] if i < len(rom) else 0
    else:
        for i, b in enumerate(rom[:ROM_END]):
            mem[i] = b

    c = CPU()
    errors = 0
    hist = []  # recent instruction trace lines
    n_instr = 0
    n_int = 0
    n_phantom = 0
    i = 0

    # Skip until the first S0 fetch at 0x0000 (end of reset).
    while i < len(cyc) and not (cyc[i]['sc'] == 0 and cyc[i]['addr'] == 0):
        i += 1

    def err(msg):
        nonlocal errors
        errors += 1
        print(f"\n*** MISMATCH #{errors} at cycle {i}: {msg}")
        print("    recent instructions:")
        for h in hist[-25:]:
            print("     ", h)
        if errors >= max_err:
            print("too many errors, stopping")
            sys.exit(1)

    def memchk(cy, what):
        a = cy['addr']
        if not cy['rd']:
            err(f"{what}: expected a memory read at {a:04X}, nMRD never asserted")
            return
        if a < ROM_END or RAM_LO <= a <= RAM_HI:
            if a in mem and mem[a] != cy['data']:
                err(f"{what}: bus read M({a:04X})={cy['data']:02X} but memory image has {mem[a]:02X}")
        elif cy['data'] != 0xFF:
            err(f"{what}: read from void {a:04X} returned {cy['data']:02X} (expected FF)")

    def memwrite(cy, expect_addr, expect_data, what):
        w = cy.get('w')
        if w is None:
            err(f"{what}: expected write M({expect_addr:04X})<={expect_data:02X}, no write seen (cycle addr {cy['addr']:04X}, orphan {cy.get('w_orphan')})")
            return
        if w[0] != expect_addr or w[1] != expect_data:
            err(f"{what}: expected write M({expect_addr:04X})<={expect_data:02X}, got M({w[0]:04X})<={w[1]:02X}")
        if RAM_LO <= w[0] <= RAM_HI:
            mem[w[0]] = w[1]

    def addrchk(cy, expect, what):
        if cy['addr'] != expect:
            err(f"{what}: expected bus address {expect:04X}, got {cy['addr']:04X}")

    def nowrite(cy, what):
        if cy.get('w') is not None:
            err(f"{what}: unexpected write M({cy['w'][0]:04X})<={cy['w'][1]:02X}")

    while i < len(cyc):
        cy = cyc[i]
        if cy['sc'] == 2:
            i += 1
            continue
        if cy['sc'] != 0:
            err(f"expected S0 fetch, got SC={cy['sc']} addr {cy['addr']:04X}")
            i += 1
            continue
        pc = c.R[c.P]
        addrchk(cy, pc, "fetch")
        memchk(cy, "fetch")
        nowrite(cy, "fetch")
        op = cy['data']
        c.R[c.P] = (pc + 1) & 0xFFFF
        i += 1
        # Collect S1 cycles
        ex = []
        while i < len(cyc) and cyc[i]['sc'] == 1:
            ex.append(cyc[i])
            i += 1
            if op != 0x00 and (op >> 4) != 0xC:
                break
            if (op >> 4) == 0xC and len(ex) == 2:
                break
        if not ex:
            if i >= len(cyc):
                break  # log ends mid-instruction (simulation stopped)
            err(f"no S1 cycle after fetch of {op:02X} at {pc:04X}")
            continue
        e0 = ex[0]
        hi, lo = op >> 4, op & 0xF
        before = f"{pc:04X}: {op:02X}  P={c.P:X} X={c.X:X} D={c.D:02X} DF={c.DF} IE={c.IE} R{c.X:X}={c.R[c.X]:04X}"
        hist.append(before)
        n_instr += 1

        def rd(addr, what):
            addrchk(e0, addr, what)
            memchk(e0, what)
            nowrite(e0, what)
            return e0['data']

        def imm(what):
            v = rd(c.R[c.P], what)
            c.R[c.P] = (c.R[c.P] + 1) & 0xFFFF
            return v

        def add(a, b, cin):
            s = a + b + cin
            c.DF = 1 if s > 0xFF else 0
            c.D = s & 0xFF

        def sub(a, b, bin_):  # a - b - (1-DF), DF=1 means no borrow
            s = a - b - bin_
            c.DF = 0 if s < 0 else 1
            c.D = s & 0xFF

        branch_ef = False
        if hi == 0x0:
            if lo == 0:
                # IDL: stays in S1 until interrupt/DMA
                while i < len(cyc) and cyc[i]['sc'] == 1:
                    i += 1
            else:
                c.D = rd(c.R[lo], f"LDN R{lo:X}")
        elif hi == 0x1:
            nowrite(e0, "INC")
            c.R[lo] = (c.R[lo] + 1) & 0xFFFF
        elif hi == 0x2:
            nowrite(e0, "DEC")
            c.R[lo] = (c.R[lo] - 1) & 0xFFFF
        elif hi == 0x3:
            if lo == 0x8:  # SKP: this core does no operand read; fine either way
                addrchk(e0, c.R[c.P], "SKP")
                tgt = 0
            else:
                tgt = rd(c.R[c.P], "short branch operand")
            cond = {0x0: True, 0x1: c.Q == 1, 0x2: c.D == 0, 0x3: c.DF == 1,
                    0x8: False, 0x9: c.Q == 0, 0xA: c.D != 0, 0xB: c.DF == 0}.get(lo)
            if cond is None:
                # EF branch: outcome not knowable here; take it from the next fetch
                branch_ef = True
                nxt = next((x for x in cyc[i:i + 4] if x['sc'] == 0), None)
                taken_addr = (c.R[c.P] & 0xFF00) | tgt
                cond = nxt is not None and nxt['addr'] == taken_addr and taken_addr != ((c.R[c.P] + 1) & 0xFFFF)
            if cond:
                c.R[c.P] = (c.R[c.P] & 0xFF00) | tgt
            else:
                c.R[c.P] = (c.R[c.P] + 1) & 0xFFFF
        elif hi == 0x4:
            c.D = rd(c.R[lo], f"LDA R{lo:X}")
            c.R[lo] = (c.R[lo] + 1) & 0xFFFF
        elif hi == 0x5:
            addrchk(e0, c.R[lo], f"STR R{lo:X}")
            memwrite(e0, c.R[lo], c.D, f"STR R{lo:X}")
        elif hi == 0x6:
            if lo == 0:
                nowrite(e0, "IRX")
                c.R[c.X] = (c.R[c.X] + 1) & 0xFFFF
            elif lo < 8:
                rd(c.R[c.X], f"OUT {lo}")
                c.R[c.X] = (c.R[c.X] + 1) & 0xFFFF
            elif lo == 8:
                err("opcode 68 (undefined on 1802)")
            else:
                # INP: bus -> M(R(X)) and D
                addrchk(e0, c.R[c.X], f"INP {lo - 8}")
                w = e0.get('w')
                if w is None:
                    err(f"INP {lo - 8}: no memory write seen")
                    c.D = e0['data']
                else:
                    c.D = w[1]
                    if w[0] != c.R[c.X]:
                        err(f"INP {lo - 8}: wrote to {w[0]:04X}, R(X)={c.R[c.X]:04X}")
                    if RAM_LO <= w[0] <= RAM_HI:
                        mem[w[0]] = w[1]
                hist[-1] += f"  [IN={c.D:02X}]"
        elif hi == 0x7:
            if lo in (0, 1):
                v = rd(c.R[c.X], "RET/DIS")
                c.R[c.X] = (c.R[c.X] + 1) & 0xFFFF
                c.X, c.P = v >> 4, v & 0xF
                c.IE = 1 if lo == 0 else 0
            elif lo == 2:
                c.D = rd(c.R[c.X], "LDXA")
                c.R[c.X] = (c.R[c.X] + 1) & 0xFFFF
            elif lo == 3:
                addrchk(e0, c.R[c.X], "STXD")
                memwrite(e0, c.R[c.X], c.D, "STXD")
                c.R[c.X] = (c.R[c.X] - 1) & 0xFFFF
            elif lo == 4:
                add(c.D, rd(c.R[c.X], "ADC"), c.DF)
            elif lo == 5:
                sub(rd(c.R[c.X], "SDB"), c.D, 1 - c.DF)
            elif lo == 6:
                nowrite(e0, "SHRC")
                ndf = c.D & 1
                c.D = (c.D >> 1) | (c.DF << 7)
                c.DF = ndf
            elif lo == 7:
                sub(c.D, rd(c.R[c.X], "SMB"), 1 - c.DF)
            elif lo == 8:
                addrchk(e0, c.R[c.X], "SAV")
                memwrite(e0, c.R[c.X], c.T, "SAV")
            elif lo == 9:
                c.T = (c.X << 4) | c.P
                addrchk(e0, c.R[2], "MARK")
                memwrite(e0, c.R[2], c.T, "MARK")
                c.X = c.P
                c.R[2] = (c.R[2] - 1) & 0xFFFF
            elif lo == 0xA:
                c.Q = 0
            elif lo == 0xB:
                c.Q = 1
            elif lo == 0xC:
                add(c.D, imm("ADCI"), c.DF)
            elif lo == 0xD:
                sub(imm("SDBI"), c.D, 1 - c.DF)
            elif lo == 0xE:
                nowrite(e0, "SHLC")
                ndf = c.D >> 7
                c.D = ((c.D << 1) & 0xFF) | c.DF
                c.DF = ndf
            elif lo == 0xF:
                sub(c.D, imm("SMBI"), 1 - c.DF)
        elif hi == 0x8:
            c.D = c.R[lo] & 0xFF
        elif hi == 0x9:
            c.D = c.R[lo] >> 8
        elif hi == 0xA:
            c.R[lo] = (c.R[lo] & 0xFF00) | c.D
        elif hi == 0xB:
            c.R[lo] = (c.R[lo] & 0x00FF) | (c.D << 8)
        elif hi == 0xC:
            if len(ex) != 2:
                err(f"long instruction {op:02X} has {len(ex)} S1 cycles")
            conds = {0x0: True, 0x1: c.Q == 1, 0x2: c.D == 0, 0x3: c.DF == 1,
                     0x9: c.Q == 0, 0xA: c.D != 0, 0xB: c.DF == 0}
            skips = {0x4: False, 0x5: c.Q == 0, 0x6: c.D != 0, 0x7: c.DF == 0,
                     0x8: True, 0xC: c.IE == 1, 0xD: c.Q == 1, 0xE: c.D == 0,
                     0xF: c.DF == 1}
            if lo in conds:
                a = c.R[c.P]
                addrchk(ex[0], a, "long branch hi")
                if len(ex) == 2:
                    addrchk(ex[1], (a + 1) & 0xFFFF, "long branch lo")
                if conds[lo]:
                    c.R[c.P] = (ex[0]['data'] << 8) | (ex[1]['data'] if len(ex) == 2 else 0)
                else:
                    c.R[c.P] = (a + 2) & 0xFFFF
            else:
                if skips[lo]:
                    c.R[c.P] = (c.R[c.P] + 2) & 0xFFFF
        elif hi == 0xD:
            c.P = lo
        elif hi == 0xE:
            c.X = lo
        elif hi == 0xF:
            if lo == 0:
                c.D = rd(c.R[c.X], "LDX")
            elif lo == 8:
                c.D = imm("LDI")
            else:
                if lo in (0x6, 0xE):
                    m = None
                elif lo < 8:
                    m = rd(c.R[c.X], f"ALU {op:02X}")
                else:
                    m = imm(f"ALU-imm {op:02X}")
                k = lo & 7
                if lo == 0x6:
                    c.DF = c.D & 1; c.D >>= 1
                elif lo == 0xE:
                    c.DF = c.D >> 7; c.D = (c.D << 1) & 0xFF
                elif k == 1:
                    c.D |= m
                elif k == 2:
                    c.D &= m
                elif k == 3:
                    c.D ^= m
                elif k == 4:
                    add(c.D, m, 0)
                elif k == 5:
                    sub(m, c.D, 0)
                elif k == 7:
                    sub(c.D, m, 0)
        if branch_ef:
            hist[-1] += "  [EF branch]"

        # Interrupt?
        while i < len(cyc) and cyc[i]['sc'] == 2:
            i += 1
        if i < len(cyc) and cyc[i]['sc'] == 3 and c.IE == 0:
            # A real 1802 never enters S3 with IE=0. control.vhd used to
            # (a "phantom" S3 that didn't vector, but did acknowledge and
            # so lose the interrupt request, since the system's INT
            # acknowledge is SC=11). Fixed; now an error if it comes back.
            n_phantom += 1
            err(f"S3 cycle with IE=0 after {op:02X} at {pc:04X}")
            i += 1
        elif i < len(cyc) and cyc[i]['sc'] == 3:
            n_int += 1
            nowrite(cyc[i], "S3")
            c.T = (c.X << 4) | c.P
            c.X, c.P, c.IE = 2, 1, 0
            hist.append(f"      ---- INTERRUPT (T={c.T:02X}, R1={c.R[1]:04X}) ----")
            i += 1

        if len(hist) > 200:
            del hist[:100]

    print(f"done: {n_instr} instructions, {n_int} interrupts, {n_phantom} phantom S3 (IE=0), {errors} mismatches")


if __name__ == '__main__':
    main()
