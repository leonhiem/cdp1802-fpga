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
`LOAD` has progress messages (`-LOA-Loading ` ... ` done.`).

**Real hardware ground truth (2026-09-13)**: the user checked the
actual boot sequence and prompt on the real CS1800 via its 4th
backplane board's bus-activity display. The real prompt is **`_08>`**
-- the `>>` guessed above from static analysis (sitting right after
the command table) was wrong, corrected here. Full real boot text, in
order: `Dutch 1800 MicroProUsers` -> `CS1800/PRCX-18    V1.9.0` ->
(blank line) -> `-SYS-Starting Console Task-` -> `_08>`. Also
confirmed: the console is port A at 4800 baud (resolves the port-A/B
ambiguity below definitively); `dmp` shows a 256-byte page dump (e.g.
`0x4000`-`0x40FF`); `tskl` lists exactly 3 tasks (`System`, `Console`,
and the transient one running the command itself, e.g. `tskl`).

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

**First real boot attempt (2026-09-12)**: ran the actual ROM through
`cs1800_console` in GHDL. Confirmed real port-A transactions matching
the disassembly during the boot-time device-clear sweep, and the
simulation genuinely completes the demanding full-64KB RAM-detection
sweep (~8.6M clock cycles) before settling into the OS scheduler's
task-dispatch loop -- no prompt yet at that point. Independently
validated by the user's own real-hardware timing: real RAM-counting
takes ~2-3 seconds, matching the simulation's 8.6M cycles at 4MHz
(2.15s) almost exactly. The user also confirmed reaching the prompt
does not depend on LC/timer interrupts (tested with the CPU board's
`CLOCK OFF` switch either way).

## MILESTONE (2026-09-13): exact match against real hardware

A longer run (150M cycles) still hadn't reached the prompt, settling
instead into what looked like legitimate but extended OS-internal
looping. Root cause: the exploratory testbench drove `LC` as a
continuously-toggling *compressed* clock (~10kHz, for fast interrupt-
path testing elsewhere in this project) -- a rate matching *neither*
of the two real conditions the user had actually tested (LC stopped,
or LC at real 50Hz), and not something the real firmware was ever
designed against. Holding `LC` constant instead (matching the real
"CLOCK OFF" switch state) fixed it immediately: the boot completed in
~5,000,000 TPB pulses (~10M CLOCK cycles, ~2.5s simulated) -- far
faster than the failed 150M-cycle run.

The resulting port-A transmit capture is a **byte-for-byte exact
match** to the boot transcript the user read directly off the real
CS1800's bus-activity board: the `Dutch 1800 MicroProUsers` /
`CS1800/PRCX-18    V1.9.0` banner, a blank line, `-SYS-Starting
Console Task-`, and the real prompt `_08>` (plus a few leading
non-printing terminal control bytes -- a clear-screen and two bells --
consistent with what a real serial terminal would act on rather than
display).

This is the meaningful "it worked" signal for this whole phase: the
ported CDP1802 core, the new CDP1854 UART model, and the ROM+RAM
memory split -- running the real, unmodified, historical PRCX-18
firmware -- reproduce the real machine's behavior exactly, through to
its actual login prompt.

**Possible next steps** (undecided): inject real characters via the
CDP1854 model's already-stubbed `rx_data`/`rx_data_available` ports to
try commands (`dmp`, `tskl`, ...) against the simulation the way the
user already has on real hardware, or move toward the Cora Z7-07S
hardware bring-up path now that the simulation-side milestone is
solid.

## Address 11 is a general-purpose reset/preset latch, not UART-RSEL-dedicated

Per the user's own SIO board schematic review (2026-09-16/17): address
`11` (`N=1`, `Q=1`) selects a CD4076 latch whose bit 1 drives the
CDP1854's `RSEL` pin directly -- but the latch is general-purpose (its
other bits almost certainly drive unrelated reset/preset lines
elsewhere on the board), so not every `OUT 1` in the ROM is really
about the UART. This directly informed a real hardware/simulation bug
fix: this model's `sel1_n` decode was missing the `Q=1` qualifier that
address 14's decode already correctly had (see
`boards/cora-z7-07s/BRINGUP_LOG.md`'s "real SIO-board correction"
entry) -- during the boot-time device-clear sweep above (which
explicitly runs with `Q=0`), the model was incorrectly capturing that
sweep's `OUT 1` as a real RSEL-latch write; real hardware would ignore
it.

Every `OUT 1`/`OUT 4` occurrence in the full 8192-byte ROM (a full
pass -- earlier passes in this project missed the tail end past
roughly `0x1B64` due to the disassembler's own instruction-count
limit), classified by adjacency:

```
000A: OUT 1   (isolated -- next OUT4 is 6 bytes away at 0010, part of
0010: OUT 4    the boot-time N=1..7 device-clear sweep above, not a
               real RSEL pairing)
0023: OUT 1   -- isolated, likely general reset/preset
03BD: OUT 1   -- isolated (in a SEP-dispatch region -- exact address
               uncertain, see the disassembly-desync note above)
03CD: OUT 1   -- isolated (same caveat)
0A70: OUT 1   -- isolated
0AE2: OUT 1   -- isolated
0FA8: OUT 1   \_ paired (2 bytes apart) -- a real RSEL+access sequence
0FAA: OUT 4   /
0FAC: OUT 1   \_ paired (2 bytes apart) -- a second RSEL+access
0FAE: OUT 4   /  sequence, right after the first
1057: OUT 4   -- isolated
10C7: OUT 4   -- isolated
1481: OUT 1   -- isolated
1E66: OUT 1   \_ paired (1 byte apart!) -- a real RSEL+access sequence
1E67: OUT 4   /
1E71: OUT 4   -- isolated (10 bytes after the pair above)
```

Three tightly-adjacent `OUT1`->`OUT4` pairs (`0x0FA8`/`0x0FAA`,
`0x0FAC`/`0x0FAE`, `0x1E66`/`0x1E67`) look like genuine
RSEL-then-register-access sequences; the rest are isolated `OUT 1`s or
`OUT 4`s, consistent with address 11 being a general-purpose
reset/preset line most of the time, not a dedicated per-access RSEL
toggle.

## Boot-time RAM test + count (verified 2026-09-18/19)

Traced directly from a GHDL bus trace of the real ROM running on the
Cora port's own memory model (`cs1800_prcx18_memory.vhd`, ROM
`0x0000-0x1FFF`, RAM `0x4000-0x5FFF`, every other address genuinely
unmapped -- reads `0xFF`, writes discarded), and confirmed
byte-for-byte by the user on a real minimal CS1800 (one 2764 EPROM at
`0x0000`, one 6264 SRAM at `0x4000`).

**Search for the bottom of RAM**, starting at a hard-coded `0x4000`
(`0x2000-0x3FFF` is the real backplane's second-EPROM/macro-assembler
slot, never probed at all -- so a minimal machine's RAM chip *must*
sit at `0x4000`, not directly after the OS ROM):

```
0025: F8 40     LDI 40
0027: BA        PHI RA
0028: F8 00     LDI 00
002A: AA        PLO RA         ; RA = 0x4000
002B: EA        SEX RA
002C: 38        SKP
002D: 1A        INC RA         ; <-- loop: next candidate byte
002E: 0A        LDN RA         ;   D = original byte
002F: BF        PHI RF         ;   save it
0030: FB FF     XRI FF         ;   complement
0032: 5A        STR RA         ;   write complement
0033: F3        XOR            ;   D = complement xor readback (0 = RAM)
0034: 3A 2D     BNZ 002D       ;   not RAM -> keep searching
0036: 9F 5A     GHI RF / STR RA  ; restore original byte
0038: 9A BB 8A AB  RB = RA     ; RB = first RAM byte (bottom)
003C: EB        SEX RB
```

**Walk upward to find the top**, same non-destructive
read/complement/verify/restore test per byte:

```
003D: 1B        INC RB         ; <-- loop
003E: 0B        LDN RB
003F: BF        PHI RF
0040: FB FF     XRI FF
0042: 5B        STR RB
0043: F3        XOR
0044: 3A 4B     BNZ 004B       ; first non-RAM byte -> done
0046: 9F 5B     GHI RF / STR RB  ; restore
0048: 9B        GHI RB
0049: 3A 3D     BNZ 003D       ; else loop until RB wraps to 0x0000
```

**Store the result** (`004B` onward):

```
004B: 2A              DEC RA
004C: 9A FC 01 BA     RA.1 = bottom page (0x40)
0050: 9B FF 01 BB     RB   = top page    (0x5F00)
0054: B2 F8 FF A2     R2   = 0x5FFF      ; stack pointer = top of RAM
0058..0064            R7.1=5E, R6.1=5D, R1.1=5C, RE.1=5B
                      (work pages carved down from the top; R1 is the
                      CDP1802's fixed interrupt register)
0065: F8 FF AE EE     RE = 0x5BFF, X = E
0069..0072            4x STXD:
                        M(5BFF)=FF  M(5BFE)=5F   -> top    = 0x5FFF
                        M(5BFD)=00  M(5BFC)=40   -> bottom = 0x4000
```

I.e. the RAM bounds are stored as two big-endian words **four pages
below the top of RAM**: `bottom` at `top_page-4:FC`, `top` at
`top_page-4:FE`. On the minimal 8K machine that is `0x5BFC = 40 00`,
`0x5BFE = 5F FF` -- identical on real hardware and in simulation.

Consequences, both confirmed:
- Any memory model that **aliases** high addresses onto a small RAM
  (the Cora port's original bits-15:13-only decode) defeats this test
  entirely: every probe from `0x4000` up "passes", the walk only stops
  when `RB` wraps past `0xFFFF`, and PRCX-18 believes it has RAM up to
  `0xFFFF` (table at `0xFBFC`, stack at `0xFFFF`) -- then scatters its
  own data structures across mirrors of the same few KB.
- Unmapped addresses must fail a write-then-readback of the
  complement. Returning a fixed value (here `0xFF`) is sufficient: at
  `0x6000` the test reads `FF`, writes `00` (discarded), reads `FF`
  back, `XOR` = `FF`, exit.
