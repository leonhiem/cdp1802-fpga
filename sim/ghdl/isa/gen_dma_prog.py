#!/usr/bin/env python3
#
# TODO 2.4 (doc/CDP1802_CORE_REVIEW.md): interrupt and DMA edge cases.
# Generates a program that puts DMA requests and interrupts at the awkward
# moments, so boards/cora-z7-07s/lockstep1802.py can check what the core
# does against the datasheet (Table 2 and the Figure 25 state diagram):
#
#   DMA between instructions, single and in bursts, in and out
#   DMA requested right before a long branch / long skip / NOP
#     (Figure 25: FORCE S1 has priority over DMA, so the forced second
#      execute cycle must come first and the instruction must complete)
#   DMA during IDL, with an interrupt to leave the idle state
#   DMA and INT requested together (priority: DMA IN, DMA OUT, INT)
#   interrupt right after every instruction shape: 1-cycle, 2-cycle
#     (long branch taken/not taken, long skip, NOP), after RET, and
#     masked by DIS
#
# Runs on tb/vhdl/tb_cdp1802_lockstep.vhd:
#   OUT 4 = the byte a DMA-in writes
#   OUT 7 = EF1..4 (bits 0..3), DMA-in (bit 4), DMA-out (bit 5),
#           number of DMA cycles - 1 (bits 6..7)
#   OUT 6 = interrupt control (bit 0 now, bit 1 delayed, 0 off)
#
# Usage: gen_dma_prog.py <out-prefix>

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from gen_isa_prog import Asm, LDI, IDL, NOP_C4   # noqa: E402

DATA = 0x9000
RESULT = 0x8000
STACK_TOP = 0xEF00
INT_NOW, INT_DELAYED, INT_OFF = 0x01, 0x02, 0x00
DMA_IN, DMA_OUT = 0x10, 0x20
DMA_BURST, DMA_LATE = 0x40, 0x80     # 4 cycles / start after a delay
DMA_BYTE = 0xC7


class Gen:
    def __init__(self):
        self.a = Asm()
        self.res = RESULT

    def out(self, port, value):          # X=P inline OUT
        self.a.emit(0xE3, 0x60 | port, value)

    def store(self, value):              # a marker, so the log is readable
        self.a.emit(LDI, value, 0x5D, 0x1D)

    def r0(self, addr=DATA):             # R0 is the DMA pointer
        self.a.emit(LDI, addr >> 8, 0xB0, LDI, addr & 0xFF, 0xA0)

    def build(self):
        a = self.a
        a.ldr(3, "main")
        a.emit(0xD3)
        a.room(40)                       # interrupt handler
        a.label("int_exit")
        a.emit(0x42, 0x70)
        a.label("int_entry")
        a.emit(0x22, 0x78, 0x22, 0x73, 0x12)
        a.emit(0xE1, 0x66, INT_OFF, 0xE2)
        a.sbr(0x30, "int_exit")

        a.label("main")
        a.ldr(1, "int_entry")
        a.ldr(2, STACK_TOP)
        a.ldr(0xD, RESULT)               # RD: marker pointer
        a.ldr(9, DATA + 0x100)
        a.emit(0xE9)                     # SEX 9
        self.out(4, DMA_BYTE)            # the byte DMA-in writes
        self.r0()

        # --- plain DMA, single and burst, in and out ----------------------
        for value, tag in ((DMA_IN, 0x11), (DMA_OUT, 0x22),
                           (DMA_IN | DMA_BURST, 0x33), (DMA_OUT | DMA_BURST, 0x44)):
            self.out(7, value)
            self.store(tag)
            self.store(tag + 1)
            self.r0()

        # --- DMA requested right before a multi-cycle instruction ---------
        # (both immediate and delayed, so it also lands mid-instruction)
        for op, tag in ((0xC0, 0x55), (0xC4, 0x66), (0xC8, 0x77)):
            self.out(7, DMA_IN | (DMA_LATE if tag == 0x66 else 0))
            if op == 0xC0:               # LBR to the next instruction
                t = a.new_label("lbr")
                a.lbr(0xC0, t)
                a.label(t)
            elif op == 0xC4:             # NOP
                a.emit(NOP_C4)
            else:                        # LSKP over two bytes
                a.emit(0xC8, LDI, 0x00)
            self.store(tag)
            self.r0()

        # --- DMA during IDL, left by a delayed interrupt -------------------
        # (the DMA starts late, so it lands while the CPU is idling)
        self.out(7, DMA_IN | DMA_BURST | DMA_LATE)
        self.out(6, INT_DELAYED)
        a.emit(IDL)
        self.store(0x88)
        self.r0()

        # --- DMA and INT requested together --------------------------------
        self.out(7, DMA_IN)
        self.out(6, INT_NOW)             # DMA has priority over INT
        self.store(0x99)
        self.r0()

        # --- interrupt right after each instruction shape -------------------
        # 1-cycle instruction
        self.out(6, INT_NOW)
        a.emit(0xE9)                     # SEX 9 (1 cycle)
        self.store(0xA1)
        # long branch, taken
        self.out(6, INT_NOW)
        t = a.new_label("i_lbr")
        a.lbr(0xC0, t)
        a.label(t)
        self.store(0xA2)
        # long branch, not taken (LBZ with D /= 0)
        self.out(6, INT_NOW)
        a.emit(LDI, 0x5A)
        t = a.new_label("i_lbz")
        a.lbr(0xC2, t)
        a.label(t)
        self.store(0xA3)
        # long skip, taken / NOP
        self.out(6, INT_NOW)
        a.emit(0xC8, LDI, 0x00)
        self.store(0xA4)
        self.out(6, INT_NOW)
        a.emit(NOP_C4)
        self.store(0xA5)
        # right after RET (interrupt requested while disabled)
        a.emit(0xE3, 0x71, 0x23)         # DIS
        self.out(6, INT_NOW)
        self.store(0xA6)
        a.emit(0xE3, 0x70, 0x23)         # RET -> IE=1, interrupt now
        self.store(0xA7)
        # during a 3-cycle instruction's own cycles: request, then IDL
        self.out(6, INT_DELAYED)
        a.emit(IDL)
        self.store(0xA8)

        self.out(6, INT_OFF)
        self.out(7, 0x00)
        a.ldr(0xF, 0xFFFF)
        a.emit(0x5F, IDL)
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
