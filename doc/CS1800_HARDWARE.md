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

The SIO board (`SIO/8706`, "Dual RS232 interface") carries **two**
CDP1854 UARTs -- "port A" and "port B", each through its own MAX232
level-shifter to a physical RS232 connector. Not bit-banged on `Q`/`EF`
lines. Running the real OS's console driver will need a CDP1854 (or a
register-compatible stand-in) modeled at whatever IO address the real
firmware expects for whichever port is the console. That address isn't
known yet; don't guess it ahead of disassembling the real ROM (see
below) -- see "Schematics analysis" for why the schematic alone can't
settle it either.

## IO addressing

Uses the CPU's 3 `N` lines *and* the `Q` line together -- 4 bits, 16
possible IO device select codes, twice what bare `N(2:0)` gives on a
stock CDP1802 (which reserves `N=0` and so only has 7 usable codes).
Schematic-confirmed: the SIO board's address decode is a **CD4028**
decoder fed by exactly `N2`, `N1`, `N0`, `Q`. Matters for correctly
decoding `INP`/`OUT` instructions once real firmware is available to
test against.

## Interrupts

A single interrupt line into the CDP1802, as usual for the architecture.
Schematic-confirmed (SIO board): both mechanisms coexist and are wired
together, not either/or. Each CDP1854's own `INT` pin feeds the shared
bus `INT` line (wakes the CPU), **and** a jumper ("int. select") also
routes that same interrupt onto one of `EF1`/`EF2`/`EF3`, so the ISR
identifies which board/port raised it by checking that `EF` line after
taking the interrupt.

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
only (`doc/cs1800_hardware_source/`, gitignored); only commit
documentation *derived* from them (memory maps, register maps,
boot-sequence notes) the way this file and `doc/CDP1854_UART.md`
already do.

## Schematics analysis (2026-09-12)

The user scanned three boards to PDF: `CPU/9111` (Revisie 9206),
`32K/8605` (Revisie 9201, x2 in the rack), and `SIO/8706` (Revisie
9202). What each confirms, beyond what's already folded into the
sections above:

- **CPU board**: runs a genuine **4MHz crystal** -- independent
  confirmation that this port's 4MHz timing-validation target matches
  the real hardware exactly, not just a round-number assumption. The
  CPU socket supports both the 1802 and the enhanced 1806 (not
  relevant yet). No address decoding happens on this board -- it only
  presents the raw bus (`N0-N2`, `TPA`, `TPB`, `MRD`, `MWR`, `Q`,
  `EF1-4`, `INT`, address/data) onto the backplane; all decoding lives
  on the peripheral boards. There's also SC-decoded FETCH/EXECUTE/
  DMA/INT-ACK front-panel LEDs and watchdog/reset/single-step debug
  logic -- cosmetic/debug, not needed for the emulation goal.
- **Memory board**: matches "Memory map" above exactly, and shows the
  actual decode: a CD4556 (fed by two `TPA`-latched 4042s holding the
  upper address bits) generates the 4 chip-selects within each 32K
  module; a strap picks which half of the 64K space a given module
  answers to. `MRD`/`MWR` from the bus drive every socket's `OE`/`WE`
  directly and unqualified -- exactly `shared_ram.vhd`'s plain
  strobe-driven design already models. One detail worth carrying into
  the model: a real EPROM's `WE` pin does nothing, so **writes to the
  EPROM range (`0x0000`-`0x1FFF`) are hardware no-ops** on the real
  board -- the FPGA's ROM region should silently discard writes, not
  corrupt or crash.
- **SIO board**: see "IO addressing" and "Interrupts" above for the
  two big confirmations (CD4028 decode on N+Q, dual EF+INT interrupt
  ID). A CD4076 quad register also generates some additional
  modem-control-type signals (`Z1`-`Z7`) -- likely DTR/RTS-style lines
  to the physical connectors, low priority for a plain terminal
  console.

### This unit's actual jumper settings (given by the user, 2026-09-12)

- Memory: module 1 = "0-32K" (`0x0000`-`0x7FFF`), module 2 = "32-64K"
  (`0x8000`-`0xFFFF`) -- matches "Memory map" above exactly.
- SIO "int select" = **EF2**: the SIO board's combined interrupt (both
  CDP1854 `INT` outputs, diode-OR'd) asserts `EF2` in addition to the
  shared bus `INT` line.
- SIO "i/o select" = **14**. The CD4028's exact input wiring, read off
  the schematic: `A0=N0, A1=N2, A2=N1, A3=/Q` (a gate inverts `Q`
  before A3). Jumper position 14 ties the decoder's `SEL` output to
  `Q2`, active when `A3 A2 A1 A0 = 0010`. Solving backwards: `N0=0`,
  `N2=1`, `N1=0` (**N=4**) and `A3=0` means **`Q=1`**. So whichever
  port this jumper drives responds to **`OUT 4` (`0x64`) / `INP 4`
  (`0x6C`), only while `Q=1`** (i.e. after a `SEQ`) -- a concrete grep
  target for the ROM disassembly.
- SIO baud: **port A = 4800**, **port B = 9600** (jumper-selected taps
  off the shared 2.4576MHz crystal + CD4040 divider).
- **Resolved by the ROM disassembly** (see `doc/PRCX18_ANALYSIS.md`):
  tracing the CD4028's decoded output all the way to one specific
  port's `CS1` pin had hit the limits of what's legible on a
  30-year-old photocopy. Turns out that ambiguity was moot -- the real
  firmware picks port A vs. B (and Data-vs-Status/Control register
  select) entirely in software via `OUT 1`, not via a second hardware
  address. `Q` just stays fixed at 1.

## What to do with the schematics and EPROM dump

1. ~~Read the schematics for the real N/Q-line address decode and EF
   wiring~~ -- done above, including this unit's actual jumper values.
   The prime candidate device code is **N=4, Q=1** (`OUT 4`/`INP 4`) --
   confirm which port that is (4800 or 9600 baud) from what the ROM's
   boot code actually configures.
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
