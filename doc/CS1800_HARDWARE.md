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

## RAM

8 SRAM/EPROM ICs, each either a 2764 (8Kx8 EPROM) or a 6264 (8Kx8 SRAM)
-- pin-compatible parts, mixed on the board as needed. 8 x 8KB = 64KB,
fully populating the CDP1802's 16-bit address space. Genuinely
asynchronous: no clock pin on either part.

This matches `src/vhdl/ram.vhd` and `boards/cora-z7-07s/hdl/shared_ram.vhd`'s
zero-latency, combinational-read Port A design -- that timing was a
real hardware constraint being modeled, not just a convenient choice.

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
recoverable. Instead, the plan is to read the CS1800's actual EPROM
(2764) directly with a TL866 programmer and get an Intel HEX dump of it
-- expected within a few days of 2026-09-11. That dump will be the
first real historical CDP1802 software tested against this port
(everything so far, in simulation and on the Cora Z7-07S alike, has
only ever run `src/vhdl/test_program_pkg.vhd`'s synthetic
instruction-exerciser program).

## What to do once the EPROM dump arrives

1. Convert the Intel HEX dump into whatever byte-array format
   `sim/ghdl`/`shared_ram.vhd`'s loaders need (or write a small loader
   if a generic one doesn't exist yet).
2. Load it in GHDL first -- fastest iteration, full internal
   visibility, no hardware risk.
3. Disassemble it (or watch the bus trace) to find the real CDP1854 IO
   address and the real EF/interrupt-source wiring, rather than
   guessing them ahead of time.
4. Model the CDP1854 (or a minimal stand-in sufficient to get past
   console I/O) once its address is known, and see how far the real OS
   gets.
5. Only after that succeeds in simulation, try it on the Cora Z7-07S
   hardware via the existing AXI-loadable RAM path.
