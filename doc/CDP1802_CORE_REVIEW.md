# CDP1802 core review: bugs found and fixed while running PRCX-18

September 2026. This is a report on what bringing up the real PRCX-18
v1.9.0 operating system on the Cora Z7-07S revealed about the CDP1802
core (`src/vhdl/`). It separates what was wrong **in the core itself**
from what was wrong in the system around it (memory, UART, board glue).
It describes how the regression testing works and lists the TODOs.
The day-by-day account is in `boards/cora-z7-07s/BRINGUP_LOG.md`.

## Summary

| # | Where | Bug | Effect on PRCX-18 | Status |
|---|---|---|---|---|
| 1 | `instr.vhd` (INP, `0x69`-`0x6F`) | D was loaded from the bus one sub-cycle after the device had stopped driving it | status reads always gave D=0; the console never saw a keystroke | fixed, `eb9d247` |
| 2 | `alu.vhd` (SHRC `0x76`, SHLC `0x7E`) | rotate *without* carry: DF was ignored | interrupt handler saved/restored DF wrongly, so an interrupted task resumed with a random DF. The console "received" phantom `^@` characters and was respawned (`_10>`, `_18>`...) | fixed, `d82e04a` |
| 3 | `control.vhd` (S3) | the state machine entered S3 on INT even when IE=0 (without vectoring) | the S3 cycle acknowledged the LC interrupt, so every 50 Hz tick arriving while interrupts were disabled was **lost**; an IDL with IE=0 also woke up | fixed (TODO 1) |
| 4 | `instr.vhd` (bus cycles) | memory reads missing or at the wrong address in IDL, IRX, SKP, NOP, long skips, LSKP and not-taken long branches, versus the datasheet's Table 2 | none for PRCX-18 (results were right); matters for memory-mapped hardware with read side effects, e.g. in the real backplane | fixed (TODO 2.2) |
| 5 | `control.vhd` (S3) | nMRD stayed active for half a clock into the interrupt cycle after a reading instruction | none for PRCX-18; a device with a read side effect would see a spurious read at every interrupt | fixed (TODO 2.3) |
| 6 | `control.vhd` (S1/S2) | a DMA was serviced *between* the two execute cycles of a long branch/skip/NOP, and the second cycle was then dropped | any DMA arriving during such an instruction left R(P) inside the instruction: the CPU executed the operand byte and ran away | fixed (TODO 2.4) |
| 7 | `instr.vhd` (INP) | the write strobe ran half a clock past the end of the cycle | a real memory latches on the trailing edge of MWR, so the byte written was the *next* cycle's data | fixed (TODO 2.4) |
| 8 | `control.vhd` (S1_EXEC) | an interrupt was not taken at the end of a multi-cycle instruction | every interrupt after a long branch/skip/NOP was delayed by one instruction | fixed (TODO 2.4) |
| 9 | `control.vhd` (S2) | after a DMA that interrupted an IDL, the CPU left the idle state | an `IDL` waiting for an interrupt continued early if a DMA arrived | fixed (TODO 2.4) |
| 10 | `instr.vhd` (S2) | the DMA direction came from the live request lines during the cycle | a controller that drops its request once the cycle is granted got a DMA cycle with no strobes at all | fixed (TODO 2.4) |
| 11 | `control.vhd` (init) | the initialization cycle after reset was 8 clocks | the datasheet gives it 9 (every other cycle is 8), so every reset released the CPU one clock early | fixed (TODO 2.6) |
| 12 | `control.vhd` (S1_IDLE) | TPA was suppressed for the IDL instruction as well as for LOAD mode | an `IDL` produced idle cycles with no TPA, so a memory system latching the high address byte on TPA saw nothing | fixed (TODO 2.6) |

Everything else checked out. Over the 0.93 s of PRCX-18 execution checked
by the lockstep model (below), 230,893 instructions using **166 distinct
opcodes** plus 23 interrupts behave exactly as the independent reference
model predicts. That covers bus addresses, written data, branch targets
and interrupt vectoring. So most of the core was right from the start:
the register file, the fetch/execute sequencing, long branches, SEP/SEX
based subroutine calls, the MARK/SAV/RET/DIS interrupt machinery, all
memory-reference instructions, ADD/SUB-family arithmetic used by PRCX-18,
and short branches on D/DF.

## Bug 1: INP never loaded D (instr.vhd)

**Real 1802:** `INP N` (`0x69`-`0x6F`) puts the device's byte on the bus
and writes it into *both* `M(R(X))` and D, from the same bus value.

**The core:** the write strobe (`Do_MWR`, which is also what enables the
I/O device onto the bus) was active for one sub-cycle only (`clk_cnt =
"011"`), while D was latched at the *next* sub-cycle (`clk_cnt =
"100"`):

```vhdl
IF clk_cnt = "000" THEN
    v.wr_A := '1';        -- R(X) -> A
ELSIF clk_cnt = "011" THEN
    v.Do_MWR := '1';      -- device drives the bus only here...
ELSIF clk_cnt = "100" THEN
    v.wr_D := '1';        -- ...but D is latched here: bus already released
END IF;
```

The memory copy was correct, but D got whatever was left on the bus
(0x00 in this system). All the other memory-reading instructions (`LDN`,
`LDXA`, `ADD`, `OUT`, ...) hold `Do_MRD` for the whole instruction and
latch later. INP was the only one that didn't.

**Why it hid:** `cdp18.vhd`/`cs1800.vhd`'s built-in test I/O port kept
driving the bus after the strobe, so the golden-reference test program
got the right value. The real CDP1854 UART releases the bus as soon as
its `nOE` (wired to nMWR) goes high, as the real chip does.

**Fix:** hold `Do_MWR` for the whole INP instruction (same shape as the
read instructions). The golden reference changed in one line
(the nMWR field of that INP cycle).

**Audit that followed:** every other `Do_MRD`/`Do_MWR` use in
`instr.vhd` was checked for the same pattern. `STR`, `STXD`, `SAV`,
`MARK` and DMA-in also use a one-sub-cycle write strobe, but none of
them latches a second destination from the bus afterwards, so they are
correct. Note that this audit only looked at bus timing, not at ALU
semantics, which is why it could not find bug 2.

## Bug 2: SHRC/SHLC ignored DF (alu.vhd)

**Real 1802:**
- `SHRC` / `RSHR` (`0x76`): DF -> D7, D shifted right, old D0 -> DF.
- `SHLC` / `RSHL` (`0x7E`): DF -> D0, D shifted left, old D7 -> DF.

**The core** (`alu.vhd`, `tmp(8)` is the carry out to DF):

```vhdl
WHEN c_ALU_RSHR => tmp <= alu_in(0) & alu_in(0) & alu_in(7 DOWNTO 1); -- D7 <- D0 (!)
WHEN c_ALU_RSHL => tmp <= alu_in & alu_in(7);                          -- D0 <- D7 (!)
```

Both were rotates of D onto itself. The carry-out to DF was right; the
carry-*in* was wrong. The decode in `instr.vhd` was correct (and its
comment for `0x7E` said `D >>= 1`; fixed to `D <<= 1`).

**Fix:**

```vhdl
WHEN c_ALU_RSHR => tmp <= alu_in(0) & carry_in & alu_in(7 DOWNTO 1);
WHEN c_ALU_RSHL => tmp <= alu_in & carry_in;
```

(`carry_in` is DF, wired in `cdp1802.vhd`.)

**Why it mattered:** PRCX-18's interrupt entry (RAM `0x5CD3`, copied
from ROM `0x01D3`) saves DF like this:

```
DEC R2 / SAV / DEC R2 / STXD      ; T, D
SHRC / STXD                        ; DF shifted into bit 7, saved
...
LDA R2 / SHLC                      ; on exit: bit 7 back into DF
```

With the bug, bit 7 held D0 instead of DF, so every task resumed with DF
equal to some bit of its D. When the LC (50 Hz) interrupt hit the
console between its UART status poll and the `BNF` that tests it, the
console believed a character had arrived. It echoed the empty buffer
byte as `^@`, and the supervisor restarted it. With LC switched off the
bug is invisible, which matched the observation that the Cora was fine
with LC frozen.

**Why it hid:** `test_program_pkg.vhd`'s SHRC test (`0x85`) happened to
have DF = D0 = 1, so the wrong formula gave the right answer. Its SHLC
test did give a wrong answer (`0x3A` instead of `0x3B`), but that value
was *recorded* as the golden reference, so the regression happily
confirmed the bug. This is the main weakness of golden-reference testing:
it proves "unchanged", not "correct". The reference dumps were updated:
SHLC `0x3A` -> `0x3B`, and the ADD/ADI results built on it `0x2A` -> `0x2B`,
`0x1A` -> `0x1B`.

## Bug 3: phantom S3 cycle with IE=0 (control.vhd) -- TODO 1, fixed

**Real 1802:** an interrupt request is only recognised while IE=1. With
IE=0 there is no S3 (interrupt) cycle at all, and `IDL` keeps waiting.

**The core:** `control.vhd` went to `c_S3_INTERRUPT` whenever
`interrupt = '1'` at the end of S1 (and from S1_IDLE and S2_DMA),
without looking at `ie`. Inside S3 the T/P/X updates *were* gated by
`ie`, so with IE=0 the CPU did not vector. But it still produced a full
machine cycle with SC=11 on the pins.

**Why it mattered (more than first thought):** in `cs1800_cpu.vhd` the
interrupt acknowledge is simply `SC = "11"`, as on the real CS1800. The
phantom S3 therefore *acknowledged and cleared* the LC interrupt latch
while interrupts were disabled, so that tick was lost. The real chip
would keep the request pending and take it as soon as `RET` sets IE=1.
Over the same ~0.8 s PRCX-18 run: before the fix 17 interrupts taken + 24
phantom S3 (= 24 lost LC ticks); after, 23 interrupts taken, 0 phantom.
PRCX-18's 50 Hz clock ran noticeably slow. A second consequence: an
`IDL` executed with IE=0 was woken by a masked interrupt.

**Fix:** `AND ie = '1'` on the three transitions into S3. `ie` is written by
`RET`/`DIS` at `clk_cnt = "100"`, before the `clk_cnt = 7` decision, so
an interrupt pending during `RET` is taken right after it and one
pending during `DIS` is not, as on the real chip.

**Verification:**
- Lockstep (real PRCX-18, LC at 50 Hz, `DMP`): 205,538 instructions,
  23 interrupts, 0 phantom S3, 0 mismatches. `lockstep1802.py` now
  reports any S3 with IE=0 as an error.
- The golden references changed (whole files, since all later
  timestamps shift). Checked row by row with the time column and S3
  rows removed:
  - `tb_cdp18_tpb.txt`: 2 phantom S3 gone. The only other difference is
    that the program reaches its `IDL` at `0x00D8` two cycles earlier and
    so idles two cycles longer. The real interrupt is taken at the same
    time (700375 ns) with the same handler sequence.
  - `tb_cs1800_tpb.txt`: 8 phantom S3 gone. At `0x00D5` the handler's
    `RET` now takes the LC interrupt that arrived while IE=0 (at
    626375 ns), where before it had been swallowed by a phantom S3 at
    604375 ns. This is the behaviour change the fix is meant to make.

## Bug 4: execute-cycle bus activity differed from the datasheet (instr.vhd) -- TODO 2.2, fixed

The coverage test (TODO 2.2) checks every execute cycle against the
datasheet's **Table 2, "Conditions on data bus and memory address lines
during all machine states"**. That table gives, per instruction, the
address on the bus and whether MRD or MWR is active. The results in
registers and memory were already right for every opcode. The bus
activity was not:

| Instruction | Table 2 | Core before |
|---|---|---|
| IDL (00) | reads M(R0), in its own cycle and every idle cycle | no read |
| IRX (60) | reads M(R(X)) | no read |
| SKP (38) | reads M(R(P)) (like every short branch) | no read |
| NOP (C4) | reads M(R(P)) in both cycles | no read |
| long skips (C5-C7, CC-CF) | taken: reads R(P), R(P)+1; not taken: R(P) twice | no reads |
| LSKP (C8) | reads R(P), R(P)+1 (listed with the long branches) | no reads |
| long branch not taken (C1-C3, C9-CB) | reads R(P), then R(P)+1 | R(P) twice |
| PHI/PLO, SEP/SEX, REQ/SEQ, SHR/SHRC, SHL/SHLC | address R(N), R(X) or R(P); no access | previous (fetch) address |

The last row has no read or write strobe, so only a logic analyser could
see it. The others are real reads: a memory-mapped device whose read has
a side effect (a status register that clears on read, for example) would
see an access pattern different from a real 1802. That matters once the
Cora sits in the real CS1800 backplane.

**Fixes** (`instr.vhd`):
- IDL: `Do_MRD` with R(0) selected, in the IDL cycle and in `c_S1_IDLE`.
  A new `idl` flag limits this to IDL; LOAD mode also uses `S1_IDLE` and
  has its own row in Table 2 (not changed).
- IRX, SKP, NOP, long skips, LSKP: `Do_MRD`.
- Long branches and skips now advance R(P) by 1 per execute cycle
  (address R(P), then R(P)+1) when they move on, instead of +2 in the
  second cycle. Not-taken skips explicitly keep R(P).
- The no-access instructions load the address register (`wr_A`) at
  `clk_cnt = "000"` from the register Table 2 names.

**A robustness point found on the way:** `R_in` is not reset at the start
of a cycle (`v := r`). The old not-taken long branch and long-skip
sequences relied on the stale `R_in` from the fetch happening to equal
R(P), because they wrote R(P) back with `wr_R` without setting `R_in`.
The new code sets `R_in` on every path.

**0x68:** decoded as "INP with N=0" (N lines 000, memory write). On the
1802 this opcode is undefined (the 1804/1805 use it as a prefix), so it
is left out of the tests.

**Verification:** coverage test with `--strict-address`: 0 mismatches.
Golden references: all 313 changed rows (72 + 241) are execute-cycle rows
of exactly these instructions (plus one S3 row that follows an IDL).
Only address, data and nMRD change; there are no changes in time, SC,
nMWR, Q or any fetch row, and the row count is unchanged.

## Bug 5: a spurious memory read at the start of every interrupt (control.vhd) -- TODO 2.3, fixed

Found by the random-program test (TODO 2.3), once the checker also
compared the S3 cycle with Table 2 (S3: MRD=1, MWR=1, no memory access).
When an interrupt followed an instruction that reads memory (RET, LDA,
OUT, ...), nMRD stayed low for the first half clock of the S3 cycle.

**Cause:** `instr.vhd` registers `Do_MRD`/`Do_MWR` on the rising clock
edge, while `control.vhd` changes `state` on the falling edge. So an
execute cycle's `Do_MRD` runs half a clock into the next cycle. Before an
S0 or S1 cycle that is invisible, because those read anyway. Before S3 it
is an extra read.

**Fix:** `control.vhd` masks `Do_MRD`/`Do_MWR` while the state is S3.
Nothing else changes: the golden references are identical. The same
half-clock overlap into a DMA cycle (S2) is left for TODO 2.4.

## Bugs 6-10: interrupt and DMA edge cases (TODO 2.4, all fixed)

DMA had never been exercised before this test. The datasheet's Figure 25
(state transition diagram) and its priority list -- **FORCE S0/S1, then
DMA IN, DMA OUT, INT** -- are the reference here.

**Bug 6 (severe): a DMA during a long branch dropped its second cycle.**
`control.vhd` tested for DMA *before* the forced second execute cycle, so
a DMA request arriving during a long branch, long skip or NOP was served
in between, and the state machine then went on to the next fetch:

```
007D C0      fetch LBR
007E 00      first execute cycle (high byte of the target)
S2   9000    DMA served here
007F 80      ... and the second execute cycle never happened
```

R(P) was left pointing inside the instruction, so the CPU executed the
branch's own operand byte and ran off into the data area. Fixed by giving
FORCE S1 priority over DMA, as Figure 25 requires. In the real backplane,
where DMA is used for disk/console transfers, this would have been a
random crash whenever a transfer coincided with a long branch.

**Bug 7: INP's write strobe ran past the end of its cycle.** The INP fix
of bug 1 holds `Do_MWR` for the whole instruction, but the strobes are
registered half a clock late, so nMWR was still low in the first half of
the *next* cycle -- with that cycle's data already on the bus. A real
memory latches on the trailing edge of MWR, so the addressed byte got the
wrong value (in the failing random program, `M(916B)` received a DMA
byte instead of the input byte). `instr.vhd` now drops the strobe at
`clk_cnt = 7`, still covering the sub-cycle where D is latched.

**Bug 8: an interrupt after a multi-cycle instruction was delayed.** The
S3 transition required `r.extraS1 = '0'`, which is true only for
single-cycle instructions, so an interrupt pending at the end of a long
branch/skip/NOP was taken one instruction later. Figure 25 has no such
restriction: the forced-S1 arrow already has priority, so the interrupt
belongs at the end of the last execute cycle. The condition was removed.

**Bug 9: a DMA ended an IDL.** Figure 25 returns from S2 to the state it
interrupted. After a DMA served during an `IDL`, the core went to S0
FETCH, so the idle ended early. `control.vhd` now remembers that it was
idling (`resume_idle`) and goes back to S1_IDLE; only an interrupt ends
the idle.

**Bug 10: the DMA direction was read from the live request lines.**
`instr.vhd`'s S2 case used `dma_in`/`dma_out` throughout the cycle. A
controller that drops its request as soon as the cycle is granted (the
usual design, and what a real one does) left the cycle with no read or
write strobe at all. Latching the direction inside `instr.vhd` at
`clk_cnt = 0` was not enough either: the request lines can change between
the moment `control.vhd` decides to run the cycle (the end of the previous
cycle) and that first sub-cycle, and then the two disagreed -- a DMA-in
cycle ran with the read strobe of a DMA-out.

The direction is now decided **once**, in `control.vhd`, at the same
falling edge as the state change (`s2_out`, DMA IN over DMA OUT as Figure
25 specifies), and passed to `instr.vhd` (`s2_dir_out`), which carries the
cycle out. The read-strobe mask uses the same flag, so it is valid from
the cycle's first instant. All five places that enter S2 record it --
from S1 EXECUTE, from S1_IDLE, from another S2 (a burst), from S3 (a DMA
right after an interrupt) and from S1 INIT (right after reset). The last
two were missed at first, and the random test found them within 1,000
seeds: such a cycle ran with the *previous* DMA's direction.

This one also shows in the repo's own golden reference: in `tb_cdp18`'s
DMA-out burst, the last granted cycle used to perform no read at all
(`nMRD=1`) because the testbench had already released the request. It now
reads, which is the single changed line in
`sim/ghdl/reference/tb_cdp18_tpb.txt`.

Also extended: the S3 read-strobe mask of bug 5 now covers a DMA-in
cycle, which likewise must not read.

## Bugs 11-12: the control modes (control.vhd) -- TODO 2.6, fixed

The CLEAR and WAIT pins select four modes, and only RESET and RUN had ever
been exercised:

| CLEAR | WAIT | mode |
|---|---|---|
| L | L | **LOAD** -- idle; DMA-IN fills memory with no bootstrap loader, and does *not* force execution afterwards |
| L | H | **RESET** |
| H | L | **PAUSE** -- the timing generator stops; state is preserved |
| H | H | **RUN** |

**Bug 11: the initialization cycle was 8 clocks, not 9.** The datasheet is
explicit: "Each machine cycle requires the same period of time, 8 clock
pulses, except the initialization cycle, which requires 9". Ours ran 8, so
every reset released the CPU one clock early relative to a real chip --
invisible inside the FPGA, but a real backplane's reset circuit and any
scope comparison would see it. `control.vhd` now holds the cycle counter
at 7 for one extra clock in `S1_INIT` (the counter is decoded as 3 bits by
`instr.vhd`, so stretching it is cheaper than widening it everywhere).

**Bug 12: TPA was suppressed during the IDL instruction.** The datasheet
says "TPA is suppressed in IDLE when the CPU is in the **load mode**" --
only there. Our `S1_IDLE` suppressed it unconditionally, and that state
serves both LOAD and the `IDL` instruction, whose idle cycles are ordinary
memory read cycles (Table 2, note 4 -> Figure 8). A memory system latches
the high address byte on TPA, so an idling CPU presented no address.
Now conditional on the mode. (This was the open candidate listed under
TODO 2.5.)

**What the new test covers** (`tb/vhdl/tb_cdp1802_modes.vhd`, target
`modes` in `sim/ghdl/run.sh`), all checked per clock:
- no TPA/TPB while reset is held;
- LOAD: TPA suppressed in its idle cycles, the CPU never fetches, and a
  13-byte program is loaded **purely by DMA-IN** -- no bootstrap;
- the initialization cycle is 9 clocks, measured TPB to TPB;
- the first fetch after reset is at 0x0000 and the loaded program runs
  (it sets Q and writes a marker);
- the `IDL` instruction: TPA *is* present in its idle cycles, and the CPU
  stays idle until an interrupt wakes it;
- PAUSE: no machine cycle passes while WAIT is low, and execution
  continues correctly afterwards;
- reset in the middle of an instruction: Q clears, and the CPU restarts
  from 0x0000 through another 9-clock initialization cycle.

Mutation checks: reverting either fix makes the test fail with the exact
message for it.

**Hardware status:** verified on the Cora, 6 boots out of 6. Getting there
took two days and cost a wrong conclusion in each direction, because this
change was what finally exposed a latent defect in the board design: TPA and
TPB were used as clocks, which left 43 register pins outside Vivado's timing
analysis, so the Cora's boot was a per-build lottery (see BRINGUP_LOG.md,
2026-09-25). With those clocks removed the same RTL boots reliably. Bug 12
itself still cannot be *confirmed* by the Cora -- TPA's only consumer there
feeds the ILA -- so its real test remains the DE0-Nano in the backplane,
whose memory cards latch the high address byte on TPA (TODO 2.5/6).

**Known, not changed:** Table 2 gives LOAD's idle cycles the address
`R(0)-1` with MRD active (it shows the byte just loaded). Ours drives no
read there. Reaching R(0)-1 would need an address-path decrement the
design does not have, and nothing can act on a cycle with no strobe, so
this stays a documented difference.

## Not core bugs, but found on the way

- **reg_R power-up (`e9dc776`):** R1-RF started as `'U'` in simulation.
  The real chip leaves them undefined too, and the FPGA powers them to 0,
  but PRCX-18 reads R7.lo before writing it, so GHDL spread X through the
  whole simulation. Now explicitly 0. Reset still only clears R0.
- **T, D, DF power-up (TODO 2.3):** the same for `reg.vhd` (T, D, ...)
  and `ff.vhd` (DF, ...): a random program doing `SAV` before any
  interrupt or `MARK` stored an undefined T (`XX` in the log). Now
  explicitly 0, matching the FPGA; reset behaviour unchanged.
- **SKP (`0x38`) bus cycle:** the core did no memory read in the SKP
  execute cycle. The datasheet's Table 2 says it reads; fixed as part of
  bug 4.

System-level fixes (not in the core), for completeness:
`cs1800.vhd` OR-merged data bus; `ram.vhd` latches -> synchronous write;
LC edge/level mixing in `cs1800_cpu.vhd`; `A_full` for synchronous Block
RAM; TX FIFO push edge detection; I/O address 11 needs Q=1; CDP1854 DA
cleared on read; CDP1854 `nMR` from the `OUT 1` latch; full 16-bit
address decode with RAM at `0x4000`; and TX back-pressure (THRE follows
the TX FIFO, `2bb23e4`), without which long output such as `DMP` was cut
off after 256 bytes.

## How the regression testing works

Three layers, from fast and synthetic to slow and real:

**1. Golden-reference bus traces** (`sim/ghdl/run.sh`, `sim/xsim/run.sh`,
seconds). `tb_cdp18_dump`/`tb_cs1800_dump` run the synthetic
`test_program_pkg.vhd` program and write one line per TPB (`time addr
data nMRD nMWR Q SC`) into `sim/ghdl/reference/`. Those files are
committed. After any change, `git diff sim/ghdl/reference/` shows
exactly which bus cycles changed, if any. `sim/xsim/run.sh` runs the same
on Vivado's simulator and must match bit for bit. Also here: assertion
testbenches for the memory map and the console I/O decode, and
`boards/cora-z7-07s/sim/run.sh` for the board-level wrapper.
*Strength:* catches any unintended change. *Weakness:* it records
whatever the core did when the reference was made, bugs included (see
bug 2).

**2. Lockstep check against an independent model**
(`boards/cora-z7-07s/sim/run_prcx18_lockstep.sh`, ~10 min). The
simulation boots the real PRCX-18 ROM, types `DMP<CR>`, and logs every
machine cycle (state code, address, data, read strobe) and every write.
`boards/cora-z7-07s/lockstep1802.py` then replays that log through its own
CDP1802 instruction-set model, written separately from the datasheet. For
every instruction it checks:
- the fetch address,
- the memory access address and read/write direction,
- written data (so D, DF and the ALU results show up as soon as they
  are stored),
- branch outcomes (D/DF/Q branches are computed by the model; EF
  branches are taken from the trace),
- interrupts: vectoring only with IE=1.

Read data is taken from the log (what the core actually saw), and a
separate memory image (ROM + logged writes) cross-checks every memory
read. So memory-side bugs show up too.
*Strength:* checks correctness, not just "unchanged", against real
software. This is what found bug 2 in one run. *Weakness:* only covers the
instructions and operand values the software happens to use (166 of 256
opcodes in the current run, see TODO 2), and internal state is only
checked once it reaches the bus.

**3. Real hardware** (Cora Z7-07S). The same ROM on the board, with the
console reached through `interactive_console.sh` (or scripted with
devmem), compared against the real CS1800. It catches synthesis and
timing issues that no simulation shows, as several of the system-level
bugs above proved.

Procedures for all three are in the top-level `README.md`, section
"Testing".

## TODOs

### TODO 1: no S3 cycle when IE=0 -- done
See bug 3 above.

### TODO 2: tests that prove the core correct
The lockstep run proves the instructions PRCX-18 uses. To prove the rest:

1. **Exhaustive ALU test -- done, all PASS.**
   `sim/ghdl/alu/run_alu_exhaustive.sh` (README, "Layer 1b"). For each of
   the 22 ALU instructions, `gen_alu_prog.py` generates a program that
   runs it over all 256 D x 256 operand x 2 DF combinations (shifts: 256
   D x 2 DF). The operand is M(R(X)) for the memory forms and a
   self-modified immediate byte for the immediate forms. After every
   case the result D is stored (`STR`) and DF selects a `BDF` branch, so
   both are visible on the bus. `tb/vhdl/tb_cdp1802_lockstep.vhd` runs the
   program on the bare core with a flat 64 KB memory, and
   `lockstep1802.py --flat` checks every stored byte and every branch.
   Result: **2,361,344 cases, 0 mismatches** (18 memory/immediate
   instructions x 131,072 + 4 shifts x 512; about 920,000 instructions
   checked per instruction; 18 minutes on 11 parallel GHDL jobs).
   Mutation check: with the old SHRC/SHLC code put back, `76` and `7E`
   fail on their first case while the other shifts pass, so the test
   does detect this class of bug.
   Caveat: "correct" here means "agrees with `lockstep1802.py`'s ALU
   definitions", which were written from the datasheet independently of
   `alu.vhd`, but by one person (me). See item 8.
2. **Instruction coverage -- done, all PASS.**
   `sim/ghdl/isa/run_isa_coverage.sh` (README, "Layer 1c"; seconds).
   `gen_isa_prog.py` generates one program that executes **every opcode
   except 0x68 (255/255)**, with every register variant R0-RF (for R3,
   the main PC, the block runs with P=4), and **every conditional
   branch and skip both ways (54/54 outcomes)**. It covers:
   - PHI/PLO/GHI/GLO, INC/DEC across a byte boundary, LDN/LDA/STR;
   - SEX N with LDX/LDXA/IRX/STXD/OUT/INP/ALU through that X;
   - SEP N and back;
   - all short and long branches and long skips, with D, DF, Q and
     EF1-4 set both ways, including the short-branch page quirk (opcode
     at xxFF, target in the next page);
   - OUT 1-7 and INP 1-7 through a loopback;
   - RET/DIS (also changing P), MARK, SAV, LSIE with IE=0/1;
   - interrupts: taken immediately, masked by DIS then taken right after
     RET, and waking an IDL.
   `tb_cdp1802_lockstep.vhd` provides the I/O world (OUT n latches, INP n
   reads it back, EF1-4 and INT driven from latches) and logs the Q pin
   and N lines. `lockstep1802.py --flat --coverage --strict-address`
   models that world and checks, per machine cycle:
   - every result;
   - INP data, EF branches, Q and the N lines;
   - interrupt timing (no S3 without a request, no missed request);
   - every execute cycle against the datasheet's Table 2.

   It fails unless the coverage is complete. **Result: 0 mismatches, after
   fixing bug 4** (the functional results were right before; the bus
   activity was not).
3. **Random instruction streams -- done, all PASS.**
   `sim/ghdl/isa/run_random.sh [first_seed] [n_seeds]` (README, "Layer
   1d"). For each seed, `gen_random_prog.py` generates a random but
   well-formed program of about 3,000 items (about 8,400 executed
   instructions):
   - random ALU, register, memory, X and I/O instructions with random
     operands;
   - short and long branches and skips on random conditions (D, DF, Q
     and EF, with the EF lines set by random `OUT 7` data);
   - SEP subroutines;
   - interrupts: immediate, delayed so that they land at random points,
     requested while disabled, and waking an IDL;
   - `MARK`;
   - regular observation points that store D and registers and branch
     on DF.

   Safety rules keep it well-formed: R1/R2/R3/RE are reserved, pointer
   registers stay in a data window, and `OUT 6` is only used in the
   interrupt macros. Each program is checked with `lockstep1802.py
   --flat --strict-address`.
   **Result: 1,000 seeds, 8,432,868 instructions, 111,732 interrupts,
   0 mismatches** (23 minutes on 11 parallel jobs). On the way it found
   bug 5 (spurious read in S3) and the undefined T/D/DF power-up values,
   plus three testbench/generator issues. Every `OUT 6` now restarts the
   interrupt delay. The IDL macro withdraws an older request before
   arming a new one. And the checker accepts the real race where a
   request withdrawn by an `OUT 6` is still sampled at the end of that
   instruction.
4. **Interrupt and DMA edge cases -- done, all PASS.**
   `sim/ghdl/isa/run_dma.sh` (README, "Layer 1e"; seconds).
   `gen_dma_prog.py` puts the awkward cases in one program: DMA in and
   out, single and in bursts; a DMA requested right before a long branch,
   a long skip and a NOP (immediate and delayed, so it also lands
   mid-instruction); a DMA during an IDL; DMA and INT requested together;
   and an interrupt right after every instruction shape (1-cycle, long
   branch taken and not taken, long skip, NOP), after `RET`, and masked by
   `DIS`. The testbench models a DMA controller on io latch 7 (request in
   or out, burst of 4, delayed start) with the DMA-in byte from io latch 4.
   `lockstep1802.py` models every S2 cycle -- address = R(0), direction,
   data, R(0) advancing -- wherever it appears, including between the two
   execute cycles of a long instruction and inside an IDL, and checks it
   against Table 2.
   Result: **0 mismatches**, after fixing bugs 6-10. The random test
   (TODO 2.3) now exercises DMA too, since its random `OUT 7` data sets
   the request bits: 1,000 seeds with DMA active also pass.
5. **Pin-level timing against the datasheet -- first test in, one
   deviation found.** `sim/ghdl/run.sh pintiming`
   (`tb/vhdl/tb_cdp1802_pin_timing.vhd`, in the quick tier) measures the
   pins only -- TPA, TPB, ADDR, nMRD, nMWR, SC, N, never a signal inside
   the core -- in the datasheet's own half-CLOCK numbering (Figure 3/4's
   `00 01 10 11 ... 70 71`), counting from TPA's rising edge. It confirms:
   the machine cycle is 8 CLOCK periods and the initialization cycle 9
   (bug 11, now visible at the pins); TPA and TPB are each one CLOCK wide;
   the high-order address byte is still on the bus at TPA's trailing edge,
   which is the edge the real memory board's 4042 latches with; and nMWR
   falls only inside the low-byte window.

   **TPA/TPB positions: correct, and a retracted false alarm.** This test
   first reported "TPB rises half a CLOCK period late". That was wrong.
   The expectation had been taken from the datasheet PDF's *text* layer,
   where the waveform columns carry no positional meaning. Rendering
   Figure 5 ("General Timing Waveforms") as an image settles it, and the
   user checked the 1976 User Manual MPM-201A p.86 independently: **TPA's
   edges sit on the clock's FALLING edges and TPB's on its RISING edges**
   -- TPA rises at the falling edge of clock 1 and falls at the falling
   edge of clock 2; TPB rises on the rising edge of clock 7. That puts
   them 5.5 CLOCK periods apart by design, which is exactly what the core
   produces. `c_tpb_rise` is now 11 half-phases and is a hard check.

   Lesson recorded in the testbench header: render the page, do not read
   waveform positions out of a PDF text dump.

   **The N lines: also correct, also a retracted false alarm.** The
   second reported deviation ("N stays asserted half a CLOCK past the
   execute cycle") was the same mistake in a different dress: it measured
   N against a machine-cycle boundary inferred from TPA, and TPA is not
   where the boundary is. The check now asks what a real device actually
   depends on, with no cycle-boundary assumption at all: an I/O controller
   latches on TPB, so at every instant TPB is high, N non-zero must mean
   SC says execute. Both pins are read at the same moment. It passes.

   **So no re-timing of the core is needed for TPA, TPB or N.** Two of
   the three "deviations" this test reported were artifacts of how the
   expectation was derived, not of the core -- both caught by going back
   to the primary source rather than by arguing. The third one (the read
   window, below) is real and was found a different way: by building the
   memory card instead of reading a drawing.

   SC is checked as "all states are valid at TPA" (datasheet, SC0/SC1 pin
   description) and passes.

   **nMRD and nMWR widths: different from the drawing, safe for the real
   parts.** Checked 2026-09-26 after the user noted from MPM-201A p.86
   that the strobes look too short. Measured, against Figures 6 and 7
   rendered as images:

   | strobe | datasheet | ours | the user's parts need |
   |---|---|---|---|
   | nMRD low | ~7/8 of the cycle, rising at the cycle end | up to the **whole** cycle -- wider, not shorter | `t_OE` 35 / 50 / 150 ns |
   | nMWR low | ~2 CLOCK periods (500 ns), late in the execute cycle | **1 CLOCK period** (250 ns) | `t_WP` 35 / 60 ns |

   So nMWR is half the drawn width and nMRD is wider than drawn. Neither
   breaks anything: the write pulse still has 4x the widest `t_WP` among
   the real RAMs, and a wider read strobe is the safe direction. The one
   real risk from an MRD that never releases -- the memory still driving
   the bus when the CPU starts to -- is now an explicit check
   ("no bus contention: nMRD never low while the CPU drove the bus"), and
   it passes: the core does deassert MRD before driving.

   **Margins.** The test also measures what a real memory card or CDP1854 actually
   gets, against what the real chip *guarantees* it (datasheet "Timing
   Specifications as a function of T", at 5V, T = 250 ns for 4 MHz):

   | margin | ours | the real chip guarantees |
   |---|---|---|
   | high address byte held after TPA | 250 ns | T/2-25 = 100 ns |
   | N valid before TPB rises | 1375 ns | (peripheral's own requirement) |
   | N still valid after TPB falls | 125 ns | (peripheral's own requirement) |

   The high-order address byte -- the one a real memory board latches on
   TPA's trailing edge -- gets 2.5x the hold the datasheet promises, and
   that is a hard check: falling below it would break real hardware. The
   CDP1854's own requirement is `t_TRS` = 75 ns of hold (user's datasheet,
   timings.txt) against our 125 ns, which is the tightest margin in the
   design; the remaining 50 ns is the budget for skew between the TPB path
   and the data/N paths through the level converters, and is why the move
   to SN74LVC8T245 (TODO 6) matters.

   **Third finding, and the one that actually blocks the backplane: the
   read window is 125 ns, not 875 ns.** Found 2026-09-25/26 with
   `tb/vhdl/tb_cdp1802_mux_addr.vhd` (`sim/ghdl/run.sh muxaddr`), the first
   testbench in this project whose memory is a *real* CS1800 card: no
   `A_full`, just the 8-bit multiplexed ADDR bus and a 4042 latch clocked
   by TPA's trailing edge, with the part's access time as a generic.

   Five instructions -- `LDN`, `LDX`, `OR`, `AND`, `XOR` -- assert `wr_D`
   at `clk_cnt = 2`; the other 21 use `clk_cnt = 4`. The card cannot start
   its access until the LOW address byte appears, and `addr_lohi` holds the
   HIGH byte through `clk_cnt = 2`, so the low byte arrives at `clk_cnt =
   3`. Those five then capture D half a clock later:

       clk_cnt   0      1      2      3      4      5      6      7
       ADDR   |--- HIGH byte ---|------------ LOW byte ------------|
       TPA          ~~|_|                     (latches the HIGH byte)
                               ^         ^
                               |         +- the 21 slow instructions capture
                               +- the card's address is COMPLETE here
                               ^
                               +- the 5 fast ones capture 125 ns after it

   Measured threshold, sharp: 120 ns passes, 125 ns fails -- exactly half a
   CLOCK period.

   **Corrected 2026-09-26, the first comparison here was wrong.** It said
   "the real chip gives 875 ns, we are ~7x stricter". That compared the
   datasheet's `t_ACC` (= `5T-375` = 875 ns), which is measured from the
   start of the cycle when the HIGH byte appears, against our 125 ns,
   measured from the COMPLETE address. Apples to oranges. Measuring
   Figure 5 properly -- the machine-cycle row as the ruler, 8 clocks =
   1206 px at 600 dpi, and the MA row's HIGH-to-LOW separator at x = 1320
   against a cycle starting at x = 929 -- puts the real chip's address
   handoff at **2.6 T**, where ours is at 3.0 T:

   | | address complete | data required | window |
   |---|---|---|---|
   | real CDP1802 | 2.6 T | 3.5 T (`t_ACC`) | ~230 ns |
   | ours, the five fast instructions | 3.0 T | 3.5 T | 125 ns |

   So we are about **half a clock tighter than the original**, not seven
   times. That also answers why the real rack works with the same EPROM:
   it is a designed-to-just-fit system -- a 2764's 250 ns sits right at
   the real chip's ~230 ns window -- and our core takes another 105 ns out
   of an already tight budget. The measured threshold and the verdict per
   part are unchanged; only the magnitude was overstated.

   Against the user's own parts (timings.txt), allowing ~4.4 ns each way
   through an SN74LVC8T245:

   | part | needs | fits 125 ns? |
   |---|---|---|
   | FCB61C65L-70 RAM | 70 ns | yes, 46 ns spare |
   | LC3664BL-10 RAM | 100 ns | yes, but only 16 ns spare |
   | 2764 EPROM | 250 ns (`t_ACC`), 450 (`t_CE`) | **no** |

   (The user's actual part is a 2764**-20**, `t_ACC` 200 ns -- so the
   numbers above are from a slower datasheet and the real margin is
   better still. It made no difference to the verdict: 200 ns does not
   fit a 125 ns window either.)

   So the real rack's RAM would work and its ROM would not -- and PRCX-18
   certainly runs `LDX`/`OR`/`AND`/`XOR` against ROM-resident data.

   **FIXED 2026-09-26.** The user chose the safe option over the faithful
   one: those five `wr_D` sample points moved from `clk_cnt = 2` to
   `clk_cnt = 4`, where the other 21 memory reads already were, so all 26
   now sample at the same step. That opens the window to 2.5T = 625 ns --
   not merely restoring the real chip's ~230 ns but nearly tripling it.
   The alternative (also moving the address handoff to 2.6T to reproduce
   the original exactly) was rejected: it needs half-clock granularity and
   would keep the tight fit for no benefit.

   Verified, all four:

   | check | before | after |
   |---|---|---|
   | `muxaddr` threshold | 120 ns pass / 125 fail | **600 ns pass / 625 fail** |
   | `sim/ghdl/run.sh` | 13 targets | 13 targets, PASS |
   | PRCX-18 real-ROM lockstep | PASS | PASS, 0 mismatches, full `DMP` |
   | Cora, 5 boots | 5/5 | **5/5** |

   Margins against the user's own parts afterwards: 2764 `t_ACC` 250 ns
   has 375 ns spare and `t_CE` 450 ns has 175 ns; the RAMs went from
   16-46 ns of margin to over 500.

   Note the board can only prove *no harm* here, not that the fix works:
   the Cora's memory is fed `A_full`, so it never had the problem. The
   proof the fix works is the threshold measurement, and the real proof
   will be the backplane.

   Note this is invisible on the Cora by construction:
   `cs1800_prcx18_memory.vhd` is fed `A_full`, the core's own settled
   16-bit address, which its header says is deliberate. Only a
   multiplexed-address card exposes it, which is why this testbench had to
   exist before any backplane wiring.

   Remaining for this TODO: the constraints file below. Reference numbers are in
   `doc/CDP1802_MEMORY_TIMING.md`,
   This matters for plugging the FPGA into the real backplane. The TPA
   candidate listed here before (suppressed in `S1_IDLE` for the IDL
   instruction as well as LOAD) turned out to be real and is fixed as
   bug 12; the remaining work is the pulse positions and widths
   themselves, which on the DE0-Nano module also have to account for the
   level translators' delays (TODO 6).

   **Deliverable: a strict output-timing constraints file** (user,
   2026-09-25). Inside an FPGA the surrounding chips are RTL and the tool
   times them for us -- once the CDP1854 and the CD4076 are real parts on
   the backplane, nothing does. Every output the backplane samples needs
   a real constraint against those parts' own setup/hold: TPA, TPB,
   nMRD, nMWR, the data bus, the multiplexed address bus, the N lines
   and Q. `.xdc` for the Cora (Vivado), `.sdc` for the DE0-Nano
   (Quartus, Cyclone IV) -- the same Synopsys language and largely the
   same content, plus the level translators' delay (MOSFET for the
   single-direction signals, TXS0108E for the bidirectional ones) in the
   budget. This is the same class of defect as the untimed internal
   clocks fixed on 2026-09-25 (TODO 4), one step further out: there, 43
   register pins had no constraint and the boot was a per-build lottery.

   Three more datasheet facts to check the core against while doing
   this, taken verbatim from the PDF on 2026-09-25:
   - **I/O request sampling window:** "These inputs [INTERRUPT, DMA-IN,
     DMA-OUT] are sampled by the CPU during the interval between the
     leading edge of TPB and the leading edge of TPA." `control.vhd`
     samples them at `clk_cnt = 7`; confirm that lands inside that
     window, and that nothing outside it can be seen.
   - **What the initialization cycle resets:** "During this cycle the
     CPU remains in S1 and register X, P, and R(0) are reset." Ours
     resets them while reset is *held* (`S1_RESET` asserts `rst`), not
     during the initialization cycle itself. Same end state before the
     first fetch, but not the same on the pins if anything watches.
   - **TPA's active edge:** "The trailing edge of TPA is used by the
     memory system to latch the higher-order byte." Since 2026-09-25
     `cs1800.vhd` samples on the CLOCK edge at the end of the TPA pulse,
     which is that trailing edge -- it used to use the leading one.
6. **Reset/WAIT/CLEAR modes -- done, all PASS.** `sim/ghdl/run.sh modes`
   (`tb/vhdl/tb_cdp1802_modes.vhd`), in the quick tier. LOAD, RESET, PAUSE
   and RUN are now exercised, including loading a program by DMA with no
   bootstrap and waking an `IDL` with an interrupt. It found bugs 11 and
   12 (see above).
7. **One command for everything ROM-free -- done.** `sim/ghdl/run.sh`
   now runs the golden references, the board sims (including the memory
   map over all 64K addresses), instruction coverage, the DMA/interrupt
   edge cases, the ALU and random programs: ~50 s, which is short enough
   to run after every change to `src/vhdl/`. It keeps that budget by
   sampling instead of cutting: the ALU test gained a `STRIDE` that walks
   the second operand in steps (every D and both DF values are still
   tried for each M), and the random tier runs 8 seeds.
   `sim/ghdl/run.sh full` runs the ALU exhaustively (131,072 combinations
   per instruction) and 1,000 random seeds, ~30-45 min. Each target logs
   to `sim/ghdl/run/<target>.log` and only its verdict reaches the
   console, so a failure names the log.
8. **Same programs on the real CS1800.** The ALU programs are plain 1802
   code. A variant that accumulates a checksum (e.g. CRC-16) over all
   results and DF values, instead of relying on the bus log, could run
   on the user's real CDP1802 in the CS1800 rack and on the Cora. The
   same checksum on the real chip, the Cora and the model would confirm
   the model's ALU definitions against real silicon, closing the caveat
   in item 1.

### TODO 3: the real 32KB memory card -- done
The real card carries four 8KB ICs and the first one is the ROM, so a
fully populated card is **ROM 0x0000-0x1FFF, RAM 0x2000-0x7FFF (24KB)**,
with 0x8000-0xFFFF void (the second card absent). That is now the Cora's
configuration (`g_ram_base_addr = 0x2000`, `g_ram_words = 6144`).

The decode already used all 16 address lines, but the *index* did not:
the RAM offset was a bit-slice of the address, which is only the same
thing while the window is aligned to its own size. That holds for 8KB at
0x4000 and fails for 24KB at 0x2000 (and for 32KB at 0x4000, where 0x8000
would alias onto 0x0000). `cs1800_prcx18_memory.vhd` now computes the
offset with a real `address - base` subtraction, so any size at any base
works, and Port B (the AXI loading path) is a flat window over the whole
array -- ROM at offset 0, RAM behind it -- instead of selecting RAM by
address bits and indexing it with the same slice. Nothing aliases on
either port; anything past the end of the array is not backed at all.

Proof, not assertion: `boards/cora-z7-07s/sim/tb_prcx18_memory_map.vhd`
(in `boards/cora-z7-07s/sim/run.sh`) walks **all 65,536 addresses** in
both configurations. It writes an address-derived byte (high and low byte
mixed, so any two addresses differing in any bit get different data) to
every address, then reads every address back:
- RAM: every address returns its own byte -- any shared storage would
  show up as a wrong byte, naming the address;
- ROM: unchanged against a snapshot taken first (writes ignored);
- void: reads 0xFF and ignores writes.
Counts for the card: 24,576 RAM + 8,192 ROM + 32,768 void. Mutation
check: put the old bit-slice index back and the test stops immediately
(the index runs past the array); in synthesis that same index would have
aliased silently.

PRCX-18 on this map (lockstep, 295,626 instructions, 0 mismatches) finds
RAM 0x4000-0x7FFF and stores the bounds at 0x7BFC/0x7BFE as `40 00` /
`7F FF` -- the same structure as the 8KB config's `40 00` / `5F FF` at
0x5BFC. The RAM at 0x2000-0x3FFF is present but never touched: the sweep
starts hard-coded at 0x4000, because on a real rack that slot is the
second EPROM (macro assembler).

### TODO 4: cleanup and release check
- Remove or gate the bring-up debug probes (`dbg_*` ports, the ILA with
  21 probes) behind a generic, so a release build is lean.
- Remove stale comments that describe earlier wrong conclusions (the
  BRINGUP_LOG keeps the history; the source comments should describe
  what is true now), e.g. in `cdp1854.vhd`'s header.
- `README.md`: update the milestone/status sections (done partly with
  this report), and document the Cora PRCX-18 flow end to end (build,
  program, load ROM, console).
- Run all three test layers on a clean checkout: `sim/ghdl/run.sh`,
  `sim/xsim/run.sh`, `boards/cora-z7-07s/sim/run.sh`,
  `run_prcx18_lockstep.sh`, and the board test.
- Longer soak test on the Cora (hours, LC on) with commands such as
  `TSKL`/`DMP`, checking for respawns or hangs.
- **`io_sel_reg` has no reset -- correct as is, no change needed.** The
  latch survives the CPU's system reset, and the real SIO board's CD4076
  has no reset either (user, from the schematic): PRCX-18 walks the whole
  I/O space at boot and writes every port to 0, `OUT 11` included. The
  `io_sel_reg = 0x80` seen in every failing capture was the *symptom* of
  the untimed-clock defect above -- the CPU stalling after PRCX-18 sets
  bit 7 to reset the CDP1854 and before it clears it again -- not its
  cause. Recorded here because it looked like a cause for a whole
  evening.
- **Board tests need repeats.** `boot_test.sh` makes one boot cheap, and a
  single boot per bitstream was enough to produce a confident but wrong
  A/B result once already (same BRINGUP_LOG entry). Run it several times
  per bitstream, and treat a mixed result as "the board has its own
  problem", not as evidence about the RTL.
- **The generated clocks -- done, 2026-09-25.** TPA and TPB were used as
  clocks, leaving 43 register pins with no clock at all in Vivado's eyes
  (35 on TPB: the whole CDP1854 and the `OUT 1` latch; 8 on TPA), while
  the report still said "all user specified timing constraints are met".
  Their margin was per-build luck, and it was making the Cora's PRCX-18
  boot unreliable -- 1 failure in 5 before TODO 2.6, 7 in 7 after it, 0 in
  6 once fixed. `cdp1854`, `cs1800_io_select` and `io_out` now take a `ce`
  (default `'1'`), and the Cora top drives them from `CLOCK` with TPA/TPB
  as the enable. Vivado now reports 0 pins with no clock. Full account in
  BRINGUP_LOG.md.
- Make sure nothing copyrighted or secret is committed (ROM dump,
  schematics, board password): `git ls-files` review.
- Carry the core fixes back to the original
  [cdp1802](https://github.com/leonhiem/cdp1802) repo: INP (`instr.vhd`,
  `eb9d247`), SHRC/SHLC (`alu.vhd` + `instr.vhd` comment, `d82e04a`),
  no S3 with IE=0 (`control.vhd`), plus the matching
  `test_program_pkg.vhd` expected-value comments. Check how that repo's
  own golden references/testbenches change, same as here.
- Tag a release.

### TODO 5: faster interactive console
`interactive_console.sh` works but is slow to use: output arrives at
~35 characters/s, so a `DMP` draws line by line. The limit is the shell
loop, which starts a `busybox devmem` process for every GPIO access (about
3 per byte). Options, roughly in order of effort:
- A small C program (cross-compiled for the Cortex-A9, or built on the
  board if it has a compiler) that `mmap`s `/dev/mem` once and polls the
  FIFO in a tight loop. Should be at least an order of magnitude faster.
- Pop several bytes per status read: a wider FIFO read port (e.g. up to
  4 bytes plus count in one 32-bit AXI GPIO read) to cut the accesses per
  byte.
- Longer term: route the CDP1854's TX/RX to a real UART (PL pins or the
  PS UART via EMIO) so a normal terminal program (`minicom`) can connect,
  which is also closer to the real CS1800's serial port.

### TODO 6: the core in the real CS1800 backplane

**The backplane target is not the Cora.** The user has built a module that
plugs into the CS1800 backplane in place of the original CPU card,
carrying a **Terasic DE0-Nano** (Cyclone IV, Quartus) with 3V3<->5V level
translation: MOSFET shifters for the single-direction signals and
TXS0108E for the bidirectional ones. The Cora keeps its role as the
simulation/regression platform and a second synthesis target; the DE0
board is what goes into the rack (open question, to discuss: a separate
repo, or `boards/de0-nano/` beside `boards/cora-z7-07s/` here -- one repo
keeps the shared `src/vhdl/` from diverging, which matters after ten core
fixes). Note the module only has to implement the **CPU**: memory, the
CDP1854 and the LC all come from the rack, so no BRAM memory model, no
UART model, no AXI and no TX FIFO travel with it.

Three hardware notes from reviewing that module (2026-09-23), to check
before or during bring-up:

1. **TXS0108E on the data bus is the part to watch.** It is an
   auto-direction translator with one-shot accelerators and weak (~4k)
   internal pull-ups, meant for lightly driven buses; against a strongly
   driven 5V CMOS bus with real backplane capacitance it can glitch or
   latch the wrong way during turnaround. Auto-direction is not needed
   here: the core already provides an explicit direction signal
   (`DATA_OE`, which `nMRD` mirrors), so a direction-controlled
   translator such as **74LVC8T245** with DIR driven from it is faster
   and deterministic. Worth having on hand if the data bus misbehaves.
2. **MOSFET shifters are likely too slow for the strobes.** A BSS138-style
   shifter rises through its pull-up: with 10k and backplane capacitance
   that is easily hundreds of ns, against a 125 ns clock period at 4 MHz.
   Fine for the EF inputs, marginal for TPA/TPB/nMRD/nMWR and the clock.
   Push-pull alternatives: **74HCT245/541 powered at 5V** for 3V3->5V
   (HCT inputs read 2.0V as high, so 3.3V drives them cleanly) and
   **74LVC245 at 3V3** for 5V->3V3 (5V-tolerant inputs). Or lower the
   pull-ups to 1k-2.2k.
3. **Clock and the rack's watchdog.** The watchdog checks that the crystal
   runs, so the CPU card generates and drives the clock. The DE0-Nano's
   50 MHz does not divide to exactly 4 MHz (/12 = 4.167 MHz), so use a
   PLL -- and confirm whether the backplane expects that clock driven out
   (at 5V) for the other cards.

What has to change or be verified when the FPGA's CDP1802 drives the real
backplane, instead of the Cora's internal memory/UART models:
- **Electrical interface:** the backplane is 5 V CMOS (4000-series and the
  CDP1854/memory cards); the Zynq I/O is 3.3 V. Needs level shifters,
  bidirectional ones with a direction control for the data bus
  (`DATA_OE`), and open-drain handling for `nINT` (and `nDMA`).
  **Decided 2026-09-26 (user): 4x SN74LVC8T245**, replacing the earlier
  TXS0108E + MOSFET plan. Better choice: the '8T245 is a buffered
  translator with push-pull outputs and a specified propagation delay of a
  few ns, where the TXS0108E is built for lightly loaded auto-direction
  lines, drives a loaded 5 V bus weakly and specifies data rate rather
  than a clean tPD. That directly helps the tightest margin in the design
  -- the CDP1854's 75 ns `t_TRS` hold against our 125 ns -- because the
  remaining budget is skew between the TPB path and the data/N paths, and
  '8T245s make that single-digit ns instead of tens.
  Two consequences of one DIR pin per 8 bits: signals must be grouped
  strictly by direction (CPU outputs on one part, backplane inputs on
  another, no mixing), and the data bus needs its own part with DIR driven
  live from `DATA_OE`.
- **Route every `nOE` back to the FPGA** (decided 2026-09-26, at minimum
  the data-bus part). Bus turnaround is the tightest path in the whole
  budget: the core stops reading and starts driving 125 ns later
  (measured, `tb_cdp1802_pin_timing.vhd`), so a memory slow to let go is
  still driving when the FPGA arrives -- two CMOS outputs on the 5 V side,
  once per read-then-write turnaround. Flipping `DIR` does not help, since
  it swaps direction without ever turning the driver off; `nOE` does, and
  at 6.8 ns (`nOE`->B) it can be placed precisely. It costs one pin per
  device and cannot be added after layout.
  With the user's 2764 **-20** the margin is probably fine unaided
  (`t_ACC` 200 ns, and `t_DF` for that grade is typically 55-60 ns against
  our 125 ns) -- the alarming 130 ns came from a slower part's datasheet.
  **Open: confirm the -20's actual `t_DF`.** The dead-time capability is
  worth having either way, because it turns turnaround into a design
  parameter rather than something we hope fits, and a second memory card
  or a different part changes the number.
- **Multiplexed address bus:** inside the FPGA the memory uses `A_full`.
  The real memory cards latch the high address byte from `ADDR` on TPA
  (4042 latches), so the core's 8-bit `ADDR` + TPA timing must be
  datasheet-exact (TODO 2.5).
- **Pin timing (TODO 2.5):** TPA/TPB width and position, MRD/MWR windows,
  data setup/hold at the real clock, N lines during I/O, SC codes.
  TPA in IDL: fixed (bug 12), suppressed only in LOAD mode now.
  The execute-cycle address/access per instruction already matches
  Table 2 (bug 4).
- **Clock and control inputs:** clock from the backplane (or the Cora
  generating it); `nCLEAR`/`nWAIT` from the backplane's reset/run logic,
  with the real reset timing; LOAD mode with DMA loading (TODO 2.6).
- **DMA:** the backplane can do DMA-in/out; the S2 cycle is not yet
  covered by the lockstep model (TODO 2.4).
- **Remove the internal models:** the CDP1854 UART, the CD4076 I/O
  latch, the memory, the LC generator and the software TX/RX FIFOs become
  real cards. Keep them only as a simulation/Cora-standalone option.
- **Undefined behaviour real software might rely on:** 0x68 (on the
  1802 undefined; the core does "INP with N=0"); registers not cleared at
  power-up (the core powers them to 0); the value of D/DF/Q after reset.
  Compare with the real chip where possible (TODO 2.8).
- **Real-machine test:** the same PRCX-18 session as on the Cora, plus
  the checksum programs of TODO 2.8, on the real backplane.
