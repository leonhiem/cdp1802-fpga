#!/usr/bin/env python3
#
# TODO 2.3 (doc/CDP1802_CORE_REVIEW.md): random instruction streams.
# Generates a random but well-formed CDP1802 program for a given seed:
# random straight-line instructions (ALU, register, memory, I/O, X) with
# random operands, mixed with random control flow (short/long branches
# and skips on random conditions, SEP subroutines), random interrupts
# (immediate or delayed, some while disabled, some waking an IDL), and
# regular observation points that store D and registers and branch on DF.
# boards/cora-z7-07s/lockstep1802.py --flat --strict-address checks the
# run; the value of the test is in combinations nobody wrote by hand.
#
# Runs on tb/vhdl/tb_cdp1802_lockstep.vhd (same I/O world as
# gen_isa_prog.py, whose assembler and interrupt handler it reuses).
#
# Usage: gen_random_prog.py <seed> <out-prefix> [n_items]
#
# Safety rules (so a random program can never overwrite itself or lose
# control):
#   R1 = interrupt handler, R2 = stack, R3 = PC, RE = result pointer:
#   never touched by random code (R2 only through X=2 stack operations).
#   Pointer registers (R0, R4-RD, RF) always point into the data window
#   (R0 is also the DMA pointer, so it never holds a code address):
#   their high byte is only ever set with LDI <safe>/PHI, and INC/DEC/LDA
#   only drift them slowly. Code lives below 0x4000, data at 0x7000 and up.
#   OUT 6 (the INT control) only appears in the interrupt macros.

import random
import sys

sys.path.insert(0, __import__("os").path.dirname(__file__))
from gen_isa_prog import Asm, LDI, SEQ, REQ, NOP_C4, IDL   # noqa: E402

PTR = [0x0, 0x4, 0x5, 0x6, 0x7, 0x8, 0x9, 0xA, 0xB, 0xC, 0xD, 0xF]
RES = 0xE
DATA_LO_HI, DATA_HI_HI = 0x80, 0xE0       # pointer high bytes (data window)
RESULT_BASE = 0xF000
STACK_TOP = 0xEF00
INT_NOW, INT_DELAYED, INT_OFF = 0x01, 0x02, 0x00

MEM_ALU = [0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF7, 0x74, 0x75, 0x77, 0x72]  # incl. LDX, LDXA
IMM_ALU = [0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFF, 0x7C, 0x7D, 0x7F]
NO_OPERAND = [0xF6, 0xFE, 0x76, 0x7E, SEQ, REQ, NOP_C4]
SHORT_COND = [0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
              0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x30]
LONG_COND = [0xC0, 0xC1, 0xC2, 0xC3, 0xC9, 0xCA, 0xCB]
LONG_SKIP = [0xC5, 0xC6, 0xC7, 0xCC, 0xCD, 0xCE, 0xCF, 0xC8]


class RandGen:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.a = Asm()

    # ---- straight-line instructions ---------------------------------------
    def simple(self, exclude=()):
        """Emit one random non-control-flow instruction; returns its size.
        Never touches registers in `exclude` (besides the reserved ones)."""
        a, r = self.a, self.r
        ptr = [p for p in PTR if p not in exclude]
        k = r.randrange(100)
        n = r.choice(ptr)
        if k < 14:
            op = r.choice(MEM_ALU); a.emit(op); return 1
        if k < 28:
            a.emit(r.choice(IMM_ALU), r.randrange(256)); return 2
        if k < 36:
            a.emit(r.choice(NO_OPERAND)); return 1
        if k < 42:
            a.emit(0x80 | r.randrange(16)); return 1          # GLO any
        if k < 48:
            a.emit(0x90 | r.randrange(16)); return 1          # GHI any
        if k < 52:
            a.emit(0xA0 | n); return 1                        # PLO pointer
        if k < 55:
            a.emit(LDI, r.randrange(DATA_LO_HI, DATA_HI_HI), 0xB0 | n); return 3  # PHI (safe)
        if k < 61:
            a.emit(r.choice((0x10, 0x20)) | n); return 1      # INC/DEC pointer
        if k < 68:
            a.emit((0x00 if n else 0x40) | n); return 1       # LDN (LDA for R0)
        if k < 73:
            a.emit(0x40 | n); return 1                        # LDA
        if k < 79:
            a.emit(0x50 | n); return 1                        # STR
        if k < 84:
            x = r.choice(ptr + [2])
            a.emit(0xE0 | x); return 1                        # SEX pointer or stack
        if k < 87:
            a.emit(0x73); return 1                            # STXD
        if k < 89:
            a.emit(0x60); return 1                            # IRX
        if k < 91:
            a.emit(0x78); return 1                            # SAV
        if k < 95:
            a.emit(0x60 | r.choice((1, 2, 3, 4, 5, 7))); return 1   # OUT (not 6)
        a.emit(0x68 | r.randrange(1, 8)); return 1            # INP 1..7

    def sex_safe(self, exclude=()):
        self.a.emit(0xE0 | self.r.choice([p for p in PTR if p not in exclude]))

    # ---- structured pieces --------------------------------------------------
    def observe(self):
        """Make D, a register and DF visible on the bus."""
        a, r = self.a, self.r
        a.emit(0x50 | RES, 0x10 | RES)                        # STR RE ; INC RE  (D)
        a.room(4)
        t = a.new_label("obs")
        a.sbr(r.choice((0x33, 0x3B)), t)                      # BDF/BNF: DF decides the path
        a.emit(NOP_C4)
        a.label(t)
        a.emit(r.choice((0x80, 0x90)) | r.randrange(16))      # GLO/GHI any register
        a.emit(0x50 | RES, 0x10 | RES)

    def short_branch(self):
        a, r = self.a, self.r
        a.room(2 + 4 * 3 + 1)
        t = a.new_label("sb")
        a.sbr(r.choice(SHORT_COND), t)
        for _ in range(r.randrange(0, 4)):
            self.simple()
        a.label(t)

    def long_branch(self):
        a, r = self.a, self.r
        t = a.new_label("lb")
        a.lbr(r.choice(LONG_COND), t)
        for _ in range(r.randrange(0, 5)):
            self.simple()
        a.label(t)

    def long_skip(self):
        a, r = self.a, self.r
        a.emit(r.choice(LONG_SKIP))
        if r.randrange(2):
            a.emit(r.choice(IMM_ALU), r.randrange(256))      # one 2-byte instruction
        else:
            for _ in range(2):                               # two 1-byte ones
                while True:
                    start = a.here()
                    if self.simple() == 1:
                        break
                    del a.code[start:]                       # retry with a 1-byte one

    def short_skip(self):
        a = self.a
        a.emit(0x38)
        while True:
            start = a.here()
            if self.simple() == 1:
                break
            del a.code[start:]

    def sep_call(self):
        """SEP n to a piece of code running with P=n, then SEP 3 back.
        Never R0: it is the DMA pointer, and a DMA landing while R0 still
        held this code address would write over the program."""
        a, r = self.a, self.r
        n = r.choice([p for p in PTR if p != 0])
        there, back = a.new_label("sep"), a.new_label("back")
        a.ldr(n, there)
        a.emit(0xD0 | n)
        a.label(there)
        self.sex_safe(exclude=(n,))                          # X must not be the PC
        for _ in range(r.randrange(1, 5)):
            self.simple(exclude=(n,))
        # (simple() never emits SEX n here, and never touches R3)
        a.ldr(3, back)
        a.emit(0xD3)
        a.label(back)
        a.emit(LDI, r.randrange(DATA_LO_HI, DATA_HI_HI), 0xB0 | n)   # n back into the window

    def interrupt(self):
        a, r = self.a, self.r
        kind = r.randrange(4)
        if kind == 0:                                        # immediate
            a.emit(0xE3, 0x66, INT_NOW)
        elif kind == 1:                                      # delayed: lands somewhere later
            a.emit(0xE3, 0x66, INT_DELAYED)
        elif kind == 2:                                      # requested while disabled
            a.emit(0xE3, 0x71, 0x23)                         # DIS (X=2, P=3)
            a.emit(0xE3, 0x66, r.choice((INT_NOW, INT_DELAYED)))
            self.sex_safe()                                  # X=3 (the PC) is not safe for random code
            for _ in range(r.randrange(0, 6)):
                self.simple()
            a.emit(0xE3, 0x70, 0x23)                         # RET -> taken now/later
        else:                                                # IDL woken by a delayed INT
            # First withdraw any older request (if it is already active it
            # may still be taken right at this OUT -- fine, that's real
            # behaviour), then arm a fresh delayed one, so IDL always wakes.
            a.emit(0xE3, 0x66, INT_OFF)
            a.emit(0xE3, 0x66, INT_DELAYED, IDL)
        self.sex_safe()

    def mark(self):
        self.a.emit(0x79)                                    # MARK (X becomes P=3)
        self.sex_safe()

    # ---- whole program ------------------------------------------------------
    def build(self, n_items):
        a, r = self.a, self.r
        a.ldr(3, "main")
        a.emit(0xD3)
        # interrupt handler, same as gen_isa_prog.py's
        a.room(40)
        a.label("int_exit")
        a.emit(0x42, 0x70)
        a.label("int_entry")
        a.emit(0x22, 0x78, 0x22, 0x73, 0x12)
        a.emit(0xE1, 0x66, INT_OFF, 0xE2)
        a.sbr(0x30, "int_exit")

        a.label("main")
        a.ldr(1, "int_entry")
        a.ldr(2, STACK_TOP)
        a.ldr(RES, RESULT_BASE)
        for p in PTR:
            a.ldr(p, (r.randrange(DATA_LO_HI, DATA_HI_HI) << 8) | r.randrange(256))
        self.sex_safe()
        for addr in range(0x7000, 0xEF00):                  # random data everywhere it may read
            a.data[addr] = r.randrange(256)

        weights = [(self.simple, 60), (self.observe, 10), (self.short_branch, 8),
                   (self.long_branch, 5), (self.long_skip, 5), (self.short_skip, 3),
                   (self.sep_call, 3), (self.interrupt, 4), (self.mark, 2)]
        funcs = [f for f, w in weights for _ in range(w)]
        for _ in range(n_items):
            r.choice(funcs)()
        self.observe()
        a.emit(0xE3, 0x66, INT_OFF)                          # no request left pending
        a.ldr(0xF, 0xFFFF)
        a.emit(0x5F, IDL)                                    # end marker
        assert a.here() < 0x4000, "program too large"
        return a.finish()


def main():
    if len(sys.argv) not in (3, 4):
        print(f"usage: {sys.argv[0]} <seed> <out-prefix> [n_items]", file=sys.stderr)
        sys.exit(1)
    seed = int(sys.argv[1])
    n_items = int(sys.argv[3]) if len(sys.argv) == 4 else 3000
    img = RandGen(seed).build(n_items)
    open(sys.argv[2] + ".bin", "wb").write(img)
    with open(sys.argv[2] + ".hex", "w") as f:
        for b in img:
            f.write(f"{b:02X}\n")


if __name__ == "__main__":
    main()
