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

## Not core bugs, but found on the way

- **reg_R power-up (`e9dc776`):** R1-RF started as `'U'` in simulation.
  The real chip leaves them undefined too, and the FPGA powers them to 0,
  but PRCX-18 reads R7.lo before writing it, so GHDL spread X through the
  whole simulation. Now explicitly 0. Reset still only clears R0.
- **SKP (`0x38`) bus cycle:** the core does no memory read in the SKP
  execute cycle. The lockstep checker tolerates this. Worth checking
  against the datasheet's timing table, since a real 1802 may do a
  (discarded) read there. It only matters for bus-level exactness.

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
   both are visible on the bus. `tb/vhdl/tb_cdp1802_alu.vhd` runs the
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
2. **Coverage-driven instruction tests.** Still unexercised by PRCX-18:
   `IDL` (00), `IRX` (60), `LDN`/`INC`/`DEC`/`LDA`/`STR`/`GLO`/`GHI`/
   `PHI`/`PLO`/`SEP`/`SEX` on several registers, `ADC`/`SDB`/`SMB`/
   `SDBI` (74/75/77/7D), `OR`/`AND`/`SD`/`ORI` (F1/F2/F5/F9), long
   branches `LBQ`/`LBZ`/`LBDF`/`LBNQ`/`LBNZ`/`LBNF` (C1-C3, C9-CB), all
   long skips (C5, C6, CC, CD, CF), `BQ` (31), and EF branches `B1`-`B4`/
   `BN1`-`BN4` with the flags actually toggled. Make
   `lockstep1802.py` report opcode coverage and aim for 256/256.
3. **Random instruction streams.** Generate random but well-formed
   programs (with a fixed R-register setup so memory accesses stay in
   RAM), run them in lockstep. It finds combinations nobody thought of.
4. **Interrupt and DMA edge cases:** interrupt arriving on the last
   sub-cycle of every instruction type, directly after `RET` and `DIS`,
   during `IDL`, during a long branch's second execute cycle. DMA-in/out
   between instructions and during IDL, and DMA and INT together
   (DMA has priority). Extend the lockstep model with S2 (DMA) semantics
   so these are checked automatically.
5. **Pin-level timing against the datasheet:** TPA/TPB position, nMRD/
   nMWR windows, N lines during I/O, and SC codes per cycle, checked
   against the timing tables (see `doc/CDP1802_MEMORY_TIMING.md`),
   including the SKP read question above. This matters for plugging the
   Cora into the real backplane.
6. **Reset/WAIT/CLEAR modes:** LOAD mode (`nCLEAR=0, nWAIT=1` with DMA
   loading), PAUSE mid-cycle, reset in the middle of an instruction.
7. Put 1 and 2 into `sim/ghdl/run.sh` so they run on every change. That
   works without the copyrighted ROM, since they are our own programs.
8. **Same programs on the real CS1800.** The ALU programs are plain 1802
   code. A variant that accumulates a checksum (e.g. CRC-16) over all
   results and DF values, instead of relying on the bus log, could run
   on the user's real CDP1802 in the CS1800 rack and on the Cora. The
   same checksum on the real chip, the Cora and the model would confirm
   the model's ALU definitions against real silicon, closing the caveat
   in item 1.

### TODO 3: maximum RAM size on the Cora (32 KB)
64 KB of RAM does not fit (80 RAMB36 needed, 50 available on the
XC7Z007S). The target is to allow up to 32 KB (the largest that fits),
with the 8 KB minimum as the default:
- Make the chip-select decode in `cs1800_prcx18_memory.vhd` general
  (it currently takes the RAM index from address bits, which is only
  valid up to 16 KB at `0x4000`), and keep Block RAM inference (single
  unconditional read, see the file's header).
- Check with the real CS1800 which address range a 32 KB configuration
  uses, so the decode matches the real memory cards.
- Re-investigate the earlier 32 KB real-hardware-only hang at `0x006C`
  (seen before the INP, SHRC and decode fixes; it may already be gone).
- Verify the PRCX-18 RAM test reports the right bounds for each size,
  as was done for 8 KB.

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
