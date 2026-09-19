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
# Usage: lockstep1802.py [--flat] [--coverage] <rom.bin> <cyc.log> [max_errors]
#   default: the Cora/CS1800 map -- ROM 0x0000-0x1FFF, RAM 0x4000-0x5FFF,
#            everything else void (reads must return 0xFF). EF inputs are
#            unknown here, so EF branch outcomes are taken from the trace.
#   --flat : tb/vhdl/tb_cdp1802_lockstep.vhd's world: one 64 KB RAM holding
#            <rom.bin> at 0x0000 (rest 0x00), and a loopback I/O model:
#            OUT n latches M(R(X)) into io[n], INP n must read io[n] back,
#            EF1..4 = io[7] bits 0..3, INT requested by io[6] (bit 0 now,
#            bit 1 delayed). So EF branches, INP data, the N lines and
#            interrupts are all checked, not taken from the trace.
#   --coverage : also fail unless every opcode except 0x68 was executed and
#            every conditional branch/skip went both ways.
#   --strict-address : also fail when the address on an S1 cycle without a
#            memory access differs from the datasheet's Table 2 (otherwise
#            only counted in a note: no strobe, so nothing can act on it).
# Every S1 cycle is checked against the datasheet's Table 2 (address and
# read/write/no access per instruction).
# Log lines may carry two extra fields, "<Q> <N>" (Q pin, N lines); when
# present, both are checked every machine cycle.

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
            if p[0] == 'C' and len(p) in (5, 7):
                q = int(p[5]) if len(p) == 7 else None
                n = int(p[6], 16) if len(p) == 7 else None
                ev.append(('C', int(p[1], 16), int(p[2], 16), int(p[3], 16), p[4] == 'R', q, n))
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
            c = dict(sc=e[1], addr=e[2], data=e[3], rd=e[4], q=e[5], n=e[6], w=None)
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


def table2(op, c):
    """Expected (address, access) of each S1 cycle of opcode op, from the
    CDP1802 datasheet's Table 2 ("Conditions on data bus and memory address
    lines during all machine states"). access: 'R' = memory read (MRD low),
    'W' = memory write (MWR low), '-' = neither. c is the state after the
    fetch (so R(P) already points past the opcode).
    Long branch/skip instructions have two S1 cycles; the long-skip entry
    depends on whether the skip is taken (see the caller)."""
    hi, lo = op >> 4, op & 0xF
    RP, RX, RN = c.R[c.P], c.R[c.X], c.R[lo]
    if hi == 0x0:
        return [(c.R[0], 'R')] if lo == 0 else [(RN, 'R')]      # IDL reads M(R0)
    if hi in (0x1, 0x2, 0x8, 0x9, 0xA, 0xB, 0xD, 0xE):
        return [(RN, '-')]                                        # INC DEC GLO GHI PLO PHI SEP SEX
    if hi == 0x3:
        return [(RP, 'R')]                                        # all short branches incl. SKP
    if hi == 0x4:
        return [(RN, 'R')]
    if hi == 0x5:
        return [(RN, 'W')]
    if hi == 0x6:
        if lo == 8:
            return None                                           # undefined
        return [(RX, 'W' if lo > 8 else 'R')]                    # IRX, OUT read; INP writes
    if hi == 0x7:
        if lo in (0x3, 0x8):
            return [(RX, 'W')]                                    # STXD, SAV
        if lo == 0x9:
            return [(c.R[2], 'W')]                                # MARK
        if lo == 0x6:
            return [(RX, '-')]                                    # SHRC
        if lo in (0xA, 0xB, 0xE):
            return [(RP, '-')]                                    # REQ SEQ SHLC
        if lo in (0xC, 0xD, 0xF):
            return [(RP, 'R')]                                    # ADCI SDBI SMBI
        return [(RX, 'R')]                                        # RET DIS LDXA ADC SDB SMB
    if hi == 0xC:
        return 'long'
    if hi == 0xF:
        if lo == 0x6:
            return [(RX, '-')]
        if lo == 0xE:
            return [(RP, '-')]
        return [(RX if lo < 8 else RP, 'R')]
    return None


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
    want_coverage = '--coverage' in args
    strict_address = '--strict-address' in args
    args = [a for a in args if a not in ('--flat', '--coverage', '--strict-address')]
    idle_addr_diff = {}                # opcode -> count, see Table 2 check
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
    io = {k: 0 for k in range(1, 8)}   # --flat loopback I/O latches
    op_count = [0] * 256
    outcomes = set()                   # (opcode, taken/skipped) seen
    int_missed = 0                     # instruction boundaries with INT due but no S3

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
        if cy['q'] is not None and cy['q'] != c.Q:
            err(f"Q pin is {cy['q']} at fetch of {pc:04X}, model Q={c.Q}")
        if cy['n'] is not None and cy['n'] != 0:
            err(f"N lines are {cy['n']} during fetch of {pc:04X}, expected 0")
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

        # Datasheet Table 2: address and read/write of every S1 cycle
        exp = table2(op, c)
        if exp == 'long':
            RP = c.R[c.P]
            if lo in (0x5, 0x6, 0x7, 0xC, 0xD, 0xE, 0xF):          # long skips
                taken = {0x5: c.Q == 0, 0x6: c.D != 0, 0x7: c.DF == 0, 0xC: c.IE == 1,
                         0xD: c.Q == 1, 0xE: c.D == 0, 0xF: c.DF == 1}[lo]
                exp = [(RP, 'R'), ((RP + 1) & 0xFFFF if taken else RP, 'R')]
            elif lo == 0x4:
                exp = [(RP, 'R'), (RP, 'R')]                           # NOP
            else:
                exp = [(RP, 'R'), ((RP + 1) & 0xFFFF, 'R')]            # long branches, LSKP (C8)
        if exp is not None:
            for k, (x, (ea, acc)) in enumerate(zip(ex, exp)):
                got = 'W' if x.get('w') is not None else ('R' if x['rd'] else '-')
                if got != acc or (acc != '-' and x['addr'] != ea):
                    err(f"Table 2: {op:02X} at {pc:04X}, S1 cycle {k + 1}: expected {acc} at {ea:04X}, "
                        f"core did {got} at {x['addr']:04X}")
                elif x['addr'] != ea:
                    # no read/write strobe in this cycle, so only a logic
                    # analyser can see the address; counted, not an error
                    idle_addr_diff[op] = idle_addr_diff.get(op, 0) + 1
                    if strict_address:
                        err(f"Table 2: {op:02X} at {pc:04X}, S1 cycle {k + 1} (no access): address "
                            f"{x['addr']:04X}, datasheet says {ea:04X}")
        before = f"{pc:04X}: {op:02X}  P={c.P:X} X={c.X:X} D={c.D:02X} DF={c.DF} IE={c.IE} R{c.X:X}={c.R[c.X]:04X}"
        hist.append(before)
        n_instr += 1
        op_count[op] += 1
        if ex[0]['n'] is not None:
            exp_n = (lo & 7) if hi == 0x6 and lo not in (0, 8) else 0
            for x in ex:
                if x['n'] != exp_n:
                    err(f"N lines are {x['n']} during execute of {op:02X} at {pc:04X}, expected {exp_n}")

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
                # IDL: stays in S1 until interrupt/DMA, reading M(R0)
                # every cycle (datasheet Table 2)
                while i < len(cyc) and cyc[i]['sc'] == 1:
                    x = cyc[i]
                    got = 'W' if x.get('w') is not None else ('R' if x['rd'] else '-')
                    if got != 'R' or x['addr'] != c.R[0]:
                        err(f"Table 2: IDL at {pc:04X}, idle cycle: expected R at {c.R[0]:04X}, "
                            f"core did {got} at {x['addr']:04X}")
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
            if cond is None and flat:
                ef_active = (io[7] >> ((lo & 3))) & 1 == 1   # EF1..4 = io[7] bits 0..3
                cond = ef_active if lo < 8 else not ef_active
            if cond is None:
                # EF branch: outcome not knowable here; take it from the next fetch
                branch_ef = True
                nxt = next((x for x in cyc[i:i + 4] if x['sc'] == 0), None)
                taken_addr = (c.R[c.P] & 0xFF00) | tgt
                cond = nxt is not None and nxt['addr'] == taken_addr and taken_addr != ((c.R[c.P] + 1) & 0xFFFF)
            if lo not in (0x0, 0x8):
                outcomes.add((op, bool(cond)))
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
                io[lo] = rd(c.R[c.X], f"OUT {lo}")
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
                if flat and c.D != io[lo - 8]:
                    err(f"INP {lo - 8}: read {c.D:02X}, but OUT {lo - 8} last wrote {io[lo - 8]:02X}")
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
            if lo in conds and lo != 0:
                outcomes.add((op, bool(conds[lo])))
            if lo in skips and lo not in (0x4, 0x8):
                outcomes.add((op, bool(skips[lo])))
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
            if flat and io[6] == 0:
                err(f"S3 after {op:02X} at {pc:04X} with no interrupt requested")
            int_missed = 0
            n_int += 1
            nowrite(cyc[i], "S3")
            c.T = (c.X << 4) | c.P
            c.X, c.P, c.IE = 2, 1, 0
            hist.append(f"      ---- INTERRUPT (T={c.T:02X}, R1={c.R[1]:04X}) ----")
            i += 1

        elif flat and (io[6] & 1) and c.IE == 1 and hi != 0x0:
            # INT requested (immediately) and enabled, but not taken. Allow
            # one instruction of latency for the request to reach the pin.
            int_missed += 1
            if int_missed >= 2:
                err(f"interrupt requested and IE=1, but no S3 after {op:02X} at {pc:04X}")
                int_missed = 0

        if len(hist) > 200:
            del hist[:100]

    print(f"done: {n_instr} instructions, {n_int} interrupts, {n_phantom} phantom S3 (IE=0), {errors} mismatches")

    if idle_addr_diff:
        print("note: address differs from Table 2 on no-access S1 cycles of: "
              + " ".join(f"{o:02X}(x{n})" for o, n in sorted(idle_addr_diff.items())))
    missing_ops = [o for o in range(256) if op_count[o] == 0 and o != 0x68]
    cond_ops = [o for o in range(0x31, 0x40) if o != 0x38] + \
               [o for o in range(0xC1, 0xD0) if o not in (0xC4, 0xC8)]
    missing_out = [(o, t) for o in cond_ops for t in (False, True) if (o, t) not in outcomes]
    print(f"opcode coverage: {256 - 1 - len(missing_ops)}/255 (0x68 excluded)"
          + (": missing " + " ".join(f"{o:02X}" for o in missing_ops) if missing_ops else ""))
    print(f"branch/skip outcome coverage: {2 * len(cond_ops) - len(missing_out)}/{2 * len(cond_ops)}"
          + (": missing " + " ".join(f"{o:02X}{'+' if t else '-'}" for o, t in missing_out) if missing_out else ""))
    if want_coverage:
        if missing_ops or missing_out:
            print("coverage: INCOMPLETE")
            sys.exit(1)
        print("coverage: complete")


if __name__ == '__main__':
    main()
