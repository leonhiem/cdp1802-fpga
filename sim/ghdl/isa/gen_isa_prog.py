#!/usr/bin/env python3
#
# TODO 2.2 (doc/CDP1802_CORE_REVIEW.md): generates one CDP1802 program that
# executes every opcode except 0x68 (undefined on the 1802), with every
# register variant, and every conditional branch/skip both ways. It makes
# every effect visible on the bus (results are stored, flags steer
# branches), so boards/cora-z7-07s/lockstep1802.py --flat --coverage can
# check it against its instruction-set model and confirm the coverage.
#
# It runs on tb/vhdl/tb_cdp1802_lockstep.vhd, whose loopback I/O it uses:
#   OUT n / INP n  : write / read back io latch n (n = 1..7)
#   EF1..EF4       : io latch 7 bits 0..3
#   INT            : io latch 6 (bit 0 = now, bit 1 = after a delay, 0 = off)
#
# Usage: gen_isa_prog.py <out-prefix>   -> <out-prefix>.bin and .hex
#
# Conventions: main code runs with P=3. R1 = interrupt handler entry,
# R2 = stack (0xEF00 downwards). Each test block gets its own result area
# (RR, stored with STR + INC) and data area, and reloads R1/R2 at its end.
# The program ends by writing 0xFFFF (the testbench's end marker).

import sys

RESULT_BASE = 0x8000
DATA_BASE = 0x9000
STACK_TOP = 0xEF00
INT_NOW, INT_DELAYED, INT_OFF = 0x01, 0x02, 0x00

# opcode constants
IDL, SEQ, REQ, NOP_C4 = 0x00, 0x7B, 0x7A, 0xC4
LDI, ADI, SMI = 0xF8, 0xFC, 0xFF


class Asm:
    def __init__(self):
        self.code = bytearray()
        self.labels = {}
        self.fix_short = []   # (pos, label)
        self.fix_long = []    # (pos, label)
        self.fix_hi = []      # (pos, label) : LDI high byte of a label
        self.fix_lo = []
        self.data = {}        # extra bytes at absolute addresses
        self.n_label = 0

    def here(self):
        return len(self.code)

    def new_label(self, stem="L"):
        self.n_label += 1
        return f"{stem}{self.n_label}"

    def label(self, name):
        assert name not in self.labels, name
        self.labels[name] = self.here()

    def emit(self, *bs):
        for b in bs:
            self.code.append(b & 0xFF)

    def room(self, n):
        """Make sure the next n bytes don't cross a page (short branches)."""
        if (self.here() & 0xFF) + n > 0x100:
            while self.here() & 0xFF:
                self.emit(NOP_C4)

    def sbr(self, op, name):          # short branch (operand in the same page as target)
        self.emit(op)
        self.fix_short.append((self.here(), name))
        self.emit(0)

    def lbr(self, op, name):          # long branch
        self.emit(op)
        self.fix_long.append((self.here(), name))
        self.emit(0, 0)

    def ldr(self, reg, value):        # R(reg) = value (an int or a label), via D
        if isinstance(value, str):
            self.emit(LDI); self.fix_hi.append((self.here(), value)); self.emit(0)
            self.emit(0xB0 | reg)
            self.emit(LDI); self.fix_lo.append((self.here(), value)); self.emit(0)
            self.emit(0xA0 | reg)
        else:
            self.emit(LDI, value >> 8, 0xB0 | reg, LDI, value & 0xFF, 0xA0 | reg)

    def finish(self):
        for pos, name in self.fix_short:
            t = self.labels[name]
            assert t >> 8 == pos >> 8, f"short branch at {pos:04X} to {name}={t:04X} leaves the page"
            self.code[pos] = t & 0xFF
        for pos, name in self.fix_long:
            t = self.labels[name]
            self.code[pos], self.code[pos + 1] = t >> 8, t & 0xFF
        for pos, name in self.fix_hi:
            self.code[pos] = self.labels[name] >> 8
        for pos, name in self.fix_lo:
            self.code[pos] = self.labels[name] & 0xFF
        top = max([len(self.code)] + [a + 1 for a in self.data])
        img = bytearray(top)
        img[:len(self.code)] = self.code
        for a, b in self.data.items():
            assert a >= len(self.code), f"data at {a:04X} overlaps code"
            img[a] = b
        return bytes(img)


class Gen:
    def __init__(self):
        self.a = Asm()
        self.P = 3
        self.RR = 0xD
        self.block_no = 0

    # --- helpers (emitted code runs with P = self.P) -----------------------
    def store(self):
        """Store D at M(RR) and advance RR: every stored byte is checked."""
        self.a.emit(0x50 | self.RR, 0x10 | self.RR)

    def new_block(self, rr=0xD):
        self.RR = rr
        self.a.ldr(self.RR, RESULT_BASE + self.block_no * 0x80)
        self.block_no += 1

    def set_df(self, v):              # D is clobbered
        self.a.emit(LDI, 0x00, SMI if v else ADI, 0x00)

    def inline_out(self, port, value):
        """X=P idiom: OUT reads the byte right after it."""
        self.a.emit(0xE0 | self.P, 0x60 | port, value)

    def init_conventions(self):
        self.a.ldr(1, "int_entry")
        self.a.ldr(2, STACK_TOP)

    def fill_data(self, addr, n, seed):
        for k in range(n):
            self.a.data[addr + k] = (seed * 37 + k * 11 + 0x5A) & 0xFF

    # --- test blocks --------------------------------------------------------
    def register_block(self, n):
        a = self.a
        main_p = 3
        if n == 3:                    # R3 is the main PC: run this block with P=4
            lbl = a.new_label("p4_")
            a.ldr(4, lbl)
            a.emit(0xD4)              # SEP 4
            a.label(lbl)
            self.P = 4
        rr = 0xE if n == 0xD else 0xD
        self.new_block(rr)
        P = self.P
        data = DATA_BASE + n * 0x40
        self.fill_data(data, 0x40, n)

        # PHI / PLO / GHI / GLO, INC/DEC across a byte boundary
        a.ldr(n, ((0x10 + n) << 8) | 0xFF)
        a.emit(0x90 | n); self.store()           # GHI
        a.emit(0x80 | n); self.store()           # GLO
        a.emit(0x10 | n)                         # INC -> (hi+1)00
        a.emit(0x90 | n); self.store()
        a.emit(0x80 | n); self.store()
        a.emit(0x20 | n)                         # DEC -> back
        a.emit(0x90 | n); self.store()
        a.emit(0x80 | n); self.store()

        # memory reference through R(N)
        a.ldr(n, data)
        if n != 0:
            a.emit(0x00 | n); self.store()       # LDN (0x00 is IDL)
        a.emit(0x40 | n); self.store()           # LDA
        a.emit(0x40 | n); self.store()           # LDA
        a.emit(0x80 | n); self.store()           # GLO: R(N) advanced by 2
        a.emit(LDI, 0xA0 ^ n, 0x50 | n)          # STR N
        a.emit((0x00 | n) if n else 0x40)        # read it back (LDN; LDA for R0, 0x00 is IDL)
        self.store()

        # R(X) = R(N): LDX, LDXA, IRX, STXD, OUT/INP, ALU through X
        a.ldr(n, data + 0x10)
        a.emit(0xE0 | n)                         # SEX N
        a.emit(0xF0); self.store()               # LDX
        a.emit(0x72); self.store()               # LDXA
        a.emit(0x60)                             # IRX
        a.emit(0x80 | n); self.store()
        a.emit(LDI, 0x3C ^ n, 0x73)              # STXD
        a.emit(0x80 | n); self.store()
        a.emit(0x60, 0x60)                       # back to the byte just written
        port = (1, 2, 3, 4, 5, 7)[n % 6]         # not 6: io latch 6 drives INT
        a.emit(0x60 | port)                      # OUT port  (M(R(X)) -> io latch, R(X)+1)
        a.emit(0x20 | n)                         # DEC N: point at that byte again
        a.emit(LDI, 0x00)
        a.emit(0x68 | port)                      # INP port  (io latch -> M(R(X)) and D)
        self.store()
        a.emit(0xF1); self.store()               # OR  M(R(X))
        a.emit(0xF4); self.store()               # ADD M(R(X))
        a.emit(0xE0 | P)                         # SEX P again

        # SEP N and back
        if n != P:
            there, back = a.new_label("sep"), a.new_label("back")
            a.ldr(n, there)
            a.emit(0xD0 | n)                     # SEP N  -> now P=N
            a.label(there)
            a.emit(0xE0 | n)                     # SEX N (X=P) -> inline OUT works here too
            a.emit(0x65, 0x40 | n)               # OUT 5, inline byte
            a.ldr(P, back)
            a.emit(0xD0 | P)                     # SEP back
            a.label(back)

        if n == 3:                               # back to P=3
            lbl = a.new_label("p3_")
            a.ldr(3, lbl)
            a.emit(0xD3)
            a.label(lbl)
            self.P = 3
        self.init_conventions()

    def branch_block(self):
        """Every short/long branch and long skip, both outcomes."""
        a = self.a
        self.new_block()
        P = self.P

        def setup(kind, value):
            if kind == "Z":
                a.emit(LDI, 0x00 if value else 0x5A)
            elif kind == "DF":
                self.set_df(value)
            elif kind == "Q":
                a.emit(SEQ if value else REQ)
            elif kind.startswith("EF"):
                bit = int(kind[2]) - 1
                self.inline_out(7, (1 << bit) if value else 0x0F ^ (1 << bit))
                a.emit(0xE0 | P)

        # (opcode, condition kind, branch taken when condition value is ...)
        short = [(0x31, "Q", True), (0x39, "Q", False), (0x32, "Z", True),
                 (0x3A, "Z", False), (0x33, "DF", True), (0x3B, "DF", False)]
        for k in range(4):
            short += [(0x34 + k, f"EF{k + 1}", True), (0x3C + k, f"EF{k + 1}", False)]
        for op, kind, when in short:
            for value in (False, True):
                setup(kind, value)
                a.room(8)
                t = a.new_label("t")
                a.sbr(op, t)
                a.emit(LDI, 0x11); self.store()      # not-taken path
                a.label(t)
                a.emit(LDI, op); self.store()

        # BR (30), SKP (38)
        a.room(8)
        t = a.new_label("t")
        a.sbr(0x30, t)
        a.emit(LDI, 0xEE); self.store()
        a.label(t)
        a.emit(0x38, 0xF8)                           # SKP skips the next byte (would be LDI)
        a.emit(0xE0 | P)
        # 1802 quirk: a short branch takes its target page from the operand
        # byte's address. With the opcode at xxFF, the operand is at
        # (xx+1)00, so the branch lands in the *next* page.
        while (a.here() & 0xFF) != 0xFF:
            a.emit(NOP_C4)
        t = a.new_label("pagecross")
        a.emit(0x30)                                 # BR at xxFF, operand at (xx+1)00
        a.fix_short.append((a.here(), t))
        a.emit(0)
        a.emit(LDI, 0x22); self.store()              # (skipped)
        a.label(t)                                   # in the next page
        a.emit(LDI, 0x33); self.store()

        longs = [(0xC1, "Q", True), (0xC9, "Q", False), (0xC2, "Z", True),
                 (0xCA, "Z", False), (0xC3, "DF", True), (0xCB, "DF", False)]
        for op, kind, when in longs:
            for value in (False, True):
                setup(kind, value)
                t = a.new_label("lt")
                a.lbr(op, t)
                a.emit(LDI, 0x44); self.store()
                a.label(t)
                a.emit(LDI, op); self.store()
        t = a.new_label("lt")
        a.lbr(0xC0, t)                               # LBR
        a.emit(LDI, 0x55); self.store()
        a.label(t)

        # long skips: skip the next two bytes (an LDI xx) when the condition holds
        skips = [(0xC5, "Q"), (0xCD, "Q"), (0xC6, "Z"), (0xCE, "Z"),
                 (0xC7, "DF"), (0xCF, "DF")]
        for op, kind in skips:
            for value in (False, True):
                setup(kind, value)                   # D keeps the setup value if skipped
                a.emit(op, LDI, 0x77)
                self.store()
        a.emit(LDI, 0x01, NOP_C4, 0xC8, LDI, 0x02)   # NOP, LSKP
        self.store()
        a.emit(REQ)
        self.inline_out(7, 0x00)                     # EF lines inactive again
        a.emit(0xE0 | P)
        self.init_conventions()

    def io_block(self):
        a = self.a
        self.new_block()
        P = self.P
        for port in range(1, 8):
            if port == 6:
                continue                              # io latch 6 is the INT control
            self.inline_out(port, 0x10 * port + port)
        a.ldr(9, DATA_BASE + 0x800)
        a.emit(0xE9)                                  # SEX 9
        for port in range(1, 8):                      # INP 6 reads the INT latch (0)
            a.emit(0x68 | port)                       # INP port
            self.store()
        # OUT through R(X) = data, not inline
        a.emit(LDI, 0xC3, 0x59)                       # STR R9
        a.emit(0x66 - 1)                              # OUT 5 from M(R9), R9+1
        a.emit(0x29, 0x6D)                            # DEC R9 ; INP 5
        self.store()
        a.emit(0xE0 | P)
        self.inline_out(6, INT_OFF)
        a.emit(0xE0 | P)
        self.init_conventions()

    def control_block(self):
        """RET, DIS, MARK, SAV, LSIE, and interrupts incl. IDL wake-up."""
        a = self.a
        self.new_block()
        P = self.P
        # DIS / RET with the X=P idiom (byte 0x23: X=2, P=3)
        a.emit(0xE0 | P, 0x71, 0x23)                  # DIS -> IE=0
        t = a.new_label("lsie")
        a.emit(0xCC, LDI, 0x81); self.store()         # LSIE: IE=0 -> no skip
        a.emit(0xE0 | P, 0x70, 0x23)                  # RET -> IE=1
        a.emit(0xCC, LDI, 0x82); self.store()         # LSIE: IE=1 -> skip (stores D from before)
        # RET changing P: continue at a label with P=4
        lbl = a.new_label("retp4")
        a.ldr(4, lbl)
        a.emit(0xE0 | P, 0x70, 0x24)                  # RET -> X=2, P=4
        a.label(lbl)
        lbl2 = a.new_label("retp3")
        a.ldr(3, lbl2)
        a.emit(0xE4, 0x70, 0x23)                      # (P=4, X=4) RET -> X=2, P=3
        a.label(lbl2)

        # MARK: T=(X,P), M(R2)=T, X=P, R2-1 ; then SAV via another X
        a.emit(0xE7)                                  # SEX 7 -> X=7
        a.emit(0x79)                                  # MARK: T=0x73, M(R2)=0x73, X=3, R2-1
        a.emit(0x82); self.store()                    # GLO R2
        a.ldr(9, DATA_BASE + 0x900)
        a.emit(0xE9, 0x78)                            # SEX 9 ; SAV: M(R9)=T
        a.emit(0x09); self.store()                    # LDN R9
        a.emit(0xE0 | P)

        # interrupt immediately (IE=1): taken right after the OUT
        self.inline_out(6, INT_NOW)
        a.emit(LDI, 0x91); self.store()
        a.emit(LDI, 0x92); self.store()
        # masked: DIS, request, nothing may happen; RET -> taken right after
        a.emit(0xE0 | P, 0x71, 0x23)                  # DIS
        self.inline_out(6, INT_NOW)
        a.emit(LDI, 0x93); self.store()
        a.emit(LDI, 0x94); self.store()
        a.emit(0xE0 | P, 0x70, 0x23)                  # RET -> interrupt now
        a.emit(LDI, 0x95); self.store()
        # IDL woken by a delayed interrupt
        self.inline_out(6, INT_DELAYED)
        a.emit(IDL)
        a.emit(LDI, 0x96); self.store()
        # Q with the interrupt handler in between
        a.emit(SEQ)
        self.inline_out(6, INT_NOW)
        a.emit(REQ)
        a.emit(LDI, 0x97); self.store()
        self.init_conventions()

    def alu_block(self):
        """One of each ALU instruction (exhaustively tested in TODO 2.1)."""
        a = self.a
        self.new_block()
        P = self.P
        a.ldr(9, DATA_BASE + 0xA00)
        self.fill_data(DATA_BASE + 0xA00, 1, 77)
        a.emit(0xE9)                                   # SEX 9
        for op in (0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF7, 0x74, 0x75, 0x77):
            self.set_df(op & 1)
            a.emit(LDI, 0x5C, op); self.store()
        for op in (0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFF, 0x7C, 0x7D, 0x7F):
            self.set_df(op & 1)
            a.emit(LDI, 0x5C, op, 0xA7); self.store()
        for op in (0xF6, 0xFE, 0x76, 0x7E):
            self.set_df(1)
            a.emit(LDI, 0x5C, op); self.store()
        a.emit(0xE0 | P)

    def interrupt_handler(self):
        """Entered with P=1, X=2, IE=0. Clears the request, saves/restores D,
        DF, returns with RET (IE=1). R1 ends up at int_entry again."""
        a = self.a
        a.room(40)
        a.label("int_exit")
        a.emit(0x42)                                   # LDA R2: restore D
        a.emit(0x70)                                   # RET (X=2): X,P from M(R2), IE=1
        a.label("int_entry")
        a.emit(0x22, 0x78)                             # DEC R2 ; SAV (T)
        a.emit(0x22, 0x73)                             # DEC R2 ; STXD (D)
        a.emit(0x12)                                   # INC R2 (STXD moved R2 one further)
        a.emit(0xE1, 0x66, INT_OFF)                    # SEX 1 ; OUT 6, 00 (inline) -> INT off
        a.emit(0xE2)                                   # SEX 2
        a.sbr(0x30, "int_exit")

    def build(self):
        a = self.a
        # reset: P=0, X=0. Set up R3 and continue with P=3.
        a.ldr(3, "main")
        a.emit(0xD3)
        self.interrupt_handler()
        a.label("main")
        self.init_conventions()
        for n in range(16):
            self.register_block(n)
        self.branch_block()
        self.io_block()
        self.alu_block()
        self.control_block()
        a.ldr(0xF, 0xFFFF)
        a.emit(0x5F)                                   # STR RF -> end marker
        a.emit(IDL)
        return a.finish()


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <out-prefix>", file=sys.stderr)
        sys.exit(1)
    img = Gen().build()
    open(sys.argv[1] + ".bin", "wb").write(img)
    with open(sys.argv[1] + ".hex", "w") as f:
        for b in img:
            f.write(f"{b:02X}\n")
    print(f"{sys.argv[1]}: {len(img)} bytes", file=sys.stderr)


if __name__ == "__main__":
    main()
