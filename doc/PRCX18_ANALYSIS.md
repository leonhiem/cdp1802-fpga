# PRCX-18 v1.9.0 disassembly notes

Findings from disassembling the user's real EPROM dump of the CS1800's
boot ROM (see `doc/CS1800_HARDWARE.md`) -- a genuine, historical
CDP1802 operating system, not a synthetic test program. The raw HEX
dump and binary stay local-only (`doc/cs1800_hardware_source/`,
gitignored) -- this repo is public and the OS is third-party
copyrighted material; only these derived, factual notes are committed,
same policy as the hardware schematics.

## What it is

Sign-on banner found in ROM: `CS1800/PRCX-18    V1.9.0`, credited to
`Dutch 1800 MicroProUsers`. This is a real **multitasking OS**, not a
simple monitor -- embedded strings show a `-SYS-Starting Console
Task-` message and a task-list display (`ID FLAGS PRI STACK PID CMD`,
i.e. a `ps`-style command). It has a command interpreter with a real
command table: `CMDL DMP ECHO INS LOAD RUN SH STAT TIME TSKL`, each
with its own syntax-error string (e.g. `-LOA-SYNTAX/SYSPAR ERR-`), and
`LOAD` has progress messages (`-LOA-Loading ` ... ` done.`). The most
useful find for testing: **`>>`** sits immediately after the command
table, in exactly the position a prompt/table-terminator sentinel
would occupy -- very likely the actual command prompt printed over
serial. That's a concrete string to watch for in a future GHDL bus
trace or capture: reaching it is the "it booted for real" signal for
this whole effort.

## The `N=4, Q=1` UART address is directly confirmed

`doc/CS1800_HARDWARE.md`'s jumper analysis predicted the SIO board's
"i/o select = 14" setting decodes to CDP1802 opcode `OUT 4` (`0x64`) /
`INP 4` (`0x6C`), only while `Q=1`. The ROM disassembly confirms this
directly: a repeated code pattern (`SEX R3; DIS <byte>` as a defensive
prologue, then a register-select step, then `SEX R2; INP4` or `OUT4`)
appears at multiple call sites, and the status bits it tests against
the `INP4` result match the **real CDP1854 Status Register layout**
(see `doc/CDP1854_UART.md`) exactly:

- `ANI 01` (bit 0 = `DA`, Data Available) in a receive-ready poll
- `ANI 80` (bit 7 = `THRE`) in a transmit-ready poll
- `ANI 0A` (bits 1+3 = `OE`+`FE`) in error checking after a read

That's about as strong a confirmation as static analysis can give:
independently-derived hardware facts (schematic) and independently-
derived software facts (ROM) land on the exact same address and match
a third independent source (the datasheet's register bit layout).

## Bonus: resolves the port-A/B ambiguity the schematic left open

`doc/CS1800_HARDWARE.md` flagged that tracing the CD4028's decoded
output all the way to a specific CDP1854's `CS1` pin hit the limits of
a 30-year-old photocopy. The disassembly makes that moot: **`OUT 1`
is a software-managed port/register-select latch**, not a second fixed
hardware address. Its value is consistently `0x00`/`0x02`/`0x04`/`0x06`
right before every `INP4`/`OUT4`, and the pattern is exactly:

- bit 1 (`0x02`): RSEL -- 0 = Data (Receiver/Transmitter Holding)
  register, 1 = Status/Control register (matches the CDP1854's own
  RSEL semantics in `doc/CDP1854_UART.md` exactly)
- bit 2 (`0x04`): port select -- 0 = port A, 1 = port B

`Q` stays fixed at 1 throughout (satisfying the CD4028's requirement
for the chip to be selected at all); it does not toggle per
transaction the way originally guessed. Best guess for the hardware
side: this is what the SIO board's CD4076 quad register actually does
-- originally assumed to be plain modem-control (DTR/RTS-style)
signals in the schematic analysis.

## Boot-time UART configuration

Control byte `0x1B` is written to *both* ports right after boot.
Decoded against the CDP1854 Control Register bit layout: `PI=1`
(parity inhibit), `WLS2,WLS1=1,1` with `SBS=0` -> **8 data bits, no
parity, 1 stop bit** (standard 8N1). `IE=0`, `TR=0` at this point (a
second write, not yet located, presumably sets `TR=1` to actually
enable the transmitter, per the datasheet's own two-write convention).

## Other things noticed, not yet needed

- The 1802's self-relative addressing idiom is used for position-
  independent code (`GHI R0` read as "what page am I executing from"
  while `P=0`, since `R0` doubles as the live PC).
- `RET`/`DIS` and a `SEP R4`-based micro-dispatch convention (a tiny
  "byte-code interpreter" trampoline register) are both used
  extensively -- normal for compact 1802 monitors, but means a plain
  linear disassembly desyncs from real control flow at every `SEP`;
  reading it needs tracking which register is live-`P` at each point,
  not just walking bytes in order.
- Two full passes through `OUT 1..7`/`INP 1..7` happen very early in
  boot (once with `Q=0`, once with `Q=1`) -- a comprehensive
  device-clear/detect sweep across the full 14-code address space
  (`N=1..7` x `Q=0/1`), independent confirmation that real firmware
  does exercise the full N+Q addressing space, not just N alone.

## Implemented (2026-09-12)

The register interface and memory split described above are now real,
committed VHDL: `src/vhdl/cs1800_memory.vhd` (the ROM+RAM split),
`src/vhdl/cdp1854.vhd` and `src/vhdl/cs1800_io_select.vhd` (the UART
pair and its `OUT 1` port/register-select latch), wired together by
`src/vhdl/cs1800_console.vhd`. All content-agnostic and copyright-clean
-- none of them embed the real ROM. `sim/ghdl/run.sh memory`/`console`
exercise them with synthetic content (see those files' own headers).

One real hardware/software subtlety worth recording here, found while
wiring this up and confirmed directly against `instr.vhd`: **on this
CPU, `OUT` electrically asserts `nMRD` and `INP` asserts `nMWR`** --
backwards from naive intuition, but correct once you think about it
from the CPU's own memory-system perspective: `OUT` is mechanically
"read `M(R(X))` into `D`" (so IO devices snoop the read strobe to
*capture* a byte), and `INP` is mechanically "write the bus value into
`M(R(X))`" (so an IO device *drives* the bus on the write strobe).
Matches `cs1800.vhd`'s own pre-existing `io_out.vhd` wiring
(`nWE => nmrd`) exactly, so this generalizes, not something specific to
the CDP1854.

**Next step**: run the real PRCX-18 ROM (kept local-only, see the top
of this file) through `cs1800_console` in GHDL and watch for the CPU
reaching its `>>` prompt in a bus-trace capture -- that, not real
serial timing or physical hardware, is the meaningful "it worked"
signal for this phase.
