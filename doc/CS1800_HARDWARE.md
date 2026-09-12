# CS1800 real hardware reference

Facts about the real CS1800 CDP1802 backplane rack, from its paper
documentation, that matter for this port. This is the target the Cora
Z7-07S bring-up (`boards/cora-z7-07s/`) is ultimately meant to be swapped
into, in place of the original CPU card, running the rack's own EPROM
operating system.

## LC (line clock)

Generated directly by the rack's 220VAC -> 5V power supply, i.e.
genuinely mains-frequency (50Hz in this case), not crystal-derived. It
drives interrupts, a real-time clock, and the OS's task scheduler tick.

This confirms `boards/cora-z7-07s/hdl/cs1800_top.vhd`'s 50Hz `LC` divider
matches the real board, and that `LC` being asynchronous to the CPU
clock is how the hardware actually works, not a simulation
simplification.

## Memory map

From the memory board schematic (refined 2026-09-12):

| Range | Size | Chip | Contents |
|---|---|---|---|
| `0x0000`-`0x1FFF` | 8KB | 2764 EPROM | **PRCX-18 v1.9.0**, the OS -- this is the boot ROM |
| `0x2000`-`0x3FFF` | 8KB | 2764/2864 EPROM or EEPROM | a macro assembler -- **out of scope for now** |
| `0x4000`-`0xFFFF` | 48KB | 6x 6264 SRAM | general RAM |

For the FPGA model, per the user's own simplification: treat this as
**1x 8KB EPROM at `0x0000`-`0x1FFF` + 7x 8KB-equivalent SRAM covering
`0x2000`-`0xFFFF`** (56KB) -- i.e. everything from `0x2000` up is just
writable RAM for now, including where the real macro-assembler EPROM
actually sits. All 8 real chips are genuinely asynchronous (no clock
pin on either part), matching `src/vhdl/ram.vhd` and
`boards/cora-z7-07s/hdl/shared_ram.vhd`'s zero-latency, combinational-
read Port A design -- that timing was a real hardware constraint being
modeled, not just a convenient choice. The FPGA model does need one
new thing neither of those has yet: an actual read-only region for the
boot EPROM, so software can't corrupt its own boot code the way it
could a plain RAM.

## Serial port

A real CDP1854 UART chip on the bus -- not bit-banged on `Q`/`EF` lines.
Running the real OS's console driver will eventually need a CDP1854 (or
a register-compatible stand-in) modeled at whatever IO address the real
firmware expects. That address isn't known yet; don't guess it ahead of
disassembling the real ROM (see below).

## IO addressing

Uses the CPU's 3 `N` lines *and* the `Q` line together -- 4 bits, 16
possible IO device select codes, twice what bare `N(2:0)` gives on a
stock CDP1802 (which reserves `N=0` and so only has 7 usable codes).
Matters for correctly decoding `INP`/`OUT` instructions once real
firmware is available to test against.

## Interrupts

A single interrupt line into the CDP1802, as usual for the architecture.
The `EF1`-`EF4` flag lines are polled by firmware to identify which
device raised the interrupt -- the standard CDP1802 technique for an
architecture with only one interrupt input.

## Original firmware

The real OS shipped on 3.5" floppy disks, which are not practically
recoverable. Instead, the user read the CS1800's actual EPROM at
`0x0000` (a 2764) directly with a TL866 programmer: **PRCX-18 v1.9.0**,
dumped as an Intel HEX file. That dump is the first real historical
CDP1802 software to test this port against (everything so far, in
simulation and on the Cora Z7-07S alike, has only ever run
`src/vhdl/test_program_pkg.vhd`'s synthetic instruction-exerciser
program). The user has also scanned the CPU board, memory board, and
serial I/O board schematics to PDF.

**Neither the ROM dump nor the schematics belong in this repo's git
history**: this repo is public on GitHub, and both are third-party
copyrighted material regardless of the hardware's age. Keep them local
only; only commit documentation *derived* from them (memory maps,
register maps, boot-sequence notes) the way this file and
`doc/CDP1854_UART.md` already do.

## What to do with the schematics and EPROM dump

1. Read the schematics for the real N/Q-line address decode (which
   device codes are actually wired to the UART vs. other peripherals)
   and the real EF-line wiring, instead of guessing.
2. Convert the Intel HEX dump into whatever byte-array format
   `sim/ghdl`/`shared_ram.vhd`'s loaders need (or write a small loader
   if a generic one doesn't exist yet), and disassemble it to find the
   real CDP1854 IO address, the boot-time control-register value (baud
   rate and frame format), and whether the console is interrupt-driven
   or polled -- see `doc/CDP1854_UART.md` for what that control byte's
   bits mean.
3. Load the ROM in GHDL first -- fastest iteration, full internal
   visibility, no hardware risk. This also needs a real EPROM region
   (read-only) alongside the existing RAM, not just a bigger RAM --
   see "Memory map" above.
4. Model the CDP1854 (or a minimal stand-in sufficient to get past
   console I/O) once its address and format are known, and see how far
   the real OS gets -- ideally all the way to a serial prompt.
5. Only after that succeeds in simulation, try it on the Cora Z7-07S
   hardware via the existing AXI-loadable RAM path.
