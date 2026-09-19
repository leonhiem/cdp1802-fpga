#!/usr/bin/env python3
#
# Generates a CDP1802 program that runs one ALU instruction over every
# operand combination: D = 0..255, operand M = 0..255 (M(R(X)) or the
# immediate byte), DF = 0 and 1 -- 131,072 cases -- and makes every
# result observable on the bus:
#   - D after the operation is stored with STR R7,
#   - DF after the operation decides a BDF branch (different fetch
#     addresses for DF=0 and DF=1).
# No expected values are needed: boards/cora-z7-07s/lockstep1802.py
# (--flat) checks every stored byte and every branch against its own
# instruction-set model. Shift instructions (no M operand) run D x DF only.
#
# Usage: gen_alu_prog.py <opcode-hex> <out-prefix>
#   writes <out-prefix>.bin (for the checker) and <out-prefix>.hex (one
#   byte per line, for tb_cdp1802_alu.vhd)
#
# Program layout (all short branches stay inside page 0x00):
#   R8 -> operand byte (memory ops) or the first immediate byte
#   RA -> the second immediate byte (immediate ops: two copies of the op)
#   R7 -> result byte (0x0100), R9.0 = D counter, RC.0 = M counter
#   X = 8, so M(R(X)) is the operand for memory ops.
#   Ends by writing 0xFFFF (the testbench's end marker), then IDL.

import sys

MEM_OPS = {0xF1: "OR", 0xF2: "AND", 0xF3: "XOR", 0xF4: "ADD", 0xF5: "SD",
           0xF7: "SM", 0x74: "ADC", 0x75: "SDB", 0x77: "SMB"}
IMM_OPS = {0xF9: "ORI", 0xFA: "ANI", 0xFB: "XRI", 0xFC: "ADI", 0xFD: "SDI",
           0xFF: "SMI", 0x7C: "ADCI", 0x7D: "SDBI", 0x7F: "SMBI"}
SHIFT_OPS = {0xF6: "SHR", 0xFE: "SHL", 0x76: "SHRC", 0x7E: "SHLC"}
ALL_OPS = {**MEM_OPS, **IMM_OPS, **SHIFT_OPS}

OPERAND_ADDR = 0x00F0   # memory-op operand byte
RESULT_ADDR = 0x0100


class Asm:
    def __init__(self):
        self.code = []
        self.labels = {}
        self.fixups = []  # (position, label)

    def here(self):
        return len(self.code)

    def label(self, name):
        self.labels[name] = self.here()

    def emit(self, *bs):
        self.code.extend(bs)

    def branch(self, op, name):  # short branch, same page
        self.emit(op)
        self.fixups.append((self.here(), name))
        self.emit(0)

    def ldr(self, reg, value):  # R(reg) = value, via D
        self.emit(0xF8, value >> 8, 0xB0 | reg, 0xF8, value & 0xFF, 0xA0 | reg)


def build(op):
    a = Asm()
    imm = op in IMM_OPS
    shift = op in SHIFT_OPS

    a.ldr(7, RESULT_ADDR)
    a.emit(0xF8, 0x01 if shift else 0x00, 0xAC)  # RC.0: 1 pass for shifts, else 256
    a.emit(0xE8)                                  # SEX 8
    imm_pos = []

    a.label("outer")
    a.emit(0xF8, 0x00, 0xA9)                      # R9.0 = 0

    a.label("inner")
    for n, set_df in enumerate((0xFC, 0xFF)):     # ADI 00 -> DF=0 ; SMI 00 -> DF=1
        a.emit(0x89)                              # GLO R9
        a.emit(set_df, 0x00)
        a.emit(op)                                # instruction under test
        if imm:
            imm_pos.append(a.here())
            a.emit(0x00)                          # its immediate byte (self-modified)
        a.emit(0x57)                              # STR R7   -> D is checked
        a.branch(0x33, f"df{n}")                  # BDF      -> DF is checked
        a.emit(0x1B)                              # INC RB   (DF=0 path only)
        a.label(f"df{n}")
    a.emit(0x29, 0x89)                            # DEC R9 ; GLO R9
    a.branch(0x3A, "inner")                       # BNZ inner

    if not shift:
        a.emit(0x08, 0xFC, 0x01, 0x58)            # LDN R8 ; ADI 01 ; STR R8
        if imm:
            a.emit(0x5A)                          # STR RA (second copy)
    a.emit(0x2C, 0x8C)                            # DEC RC ; GLO RC
    a.branch(0x3A, "outer")                       # BNZ outer

    a.emit(0xF8, 0xFF, 0xBF, 0xAF, 0x5F)          # RF = FFFF ; STR RF -> end marker
    a.label("halt")
    a.emit(0x00)                                  # IDL

    # R8/RA setup goes in front, now that the immediate positions are known
    pre = Asm()
    if imm:
        shift_by = 12
        pre.ldr(8, imm_pos[0] + shift_by)
        pre.ldr(10, imm_pos[1] + shift_by)
    else:
        shift_by = 6
        pre.ldr(8, OPERAND_ADDR)
    assert len(pre.code) == shift_by
    # relocate the short-branch targets of the body by shift_by
    code = pre.code + relocate(a, shift_by)
    image = bytearray(max(len(code), OPERAND_ADDR + 1))
    image[:len(code)] = bytes(code)
    image[OPERAND_ADDR] = 0x00
    assert len(code) < OPERAND_ADDR
    return bytes(image)


def relocate(a, offset):
    code = list(a.code)
    for pos, name in a.fixups:
        target = a.labels[name] + offset
        assert target >> 8 == (pos + offset) >> 8
        code[pos] = target & 0xFF
    return code


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <opcode-hex> <out-prefix>", file=sys.stderr)
        print("opcodes: " + " ".join(f"{o:02X}={n}" for o, n in sorted(ALL_OPS.items())), file=sys.stderr)
        sys.exit(1)
    op = int(sys.argv[1], 16)
    if op not in ALL_OPS:
        print(f"not an ALU opcode here: {op:02X}", file=sys.stderr)
        sys.exit(1)
    image = build(op)
    open(sys.argv[2] + ".bin", "wb").write(image)
    with open(sys.argv[2] + ".hex", "w") as f:
        for b in image:
            f.write(f"{b:02X}\n")


if __name__ == "__main__":
    main()
