# Bring-up log

## 2026-09-11: first real hardware run

Programmed `cs1800_bringup` (commit `2c4b2a2`) onto the Cora Z7-07S over
JTAG, confirmed a live PetaLinux 2017.4 console on `/dev/ttyUSB1`, and
drove `cs1800` entirely through the AXI GPIO control register at
`0x4120_0000` (`devmem`):

- Read back the power-on default `0x01` (`reset` asserted, matches
  `C_DOUT_DEFAULT`).
- Armed the `system_ila` (trigger: `TPB` rising edge) while still in
  reset.
- Wrote `0x68` (`run=1`, `nEF="110"`, `reset` released -- matching
  `tb_cs1800.vhd`'s constant `nEF`), releasing the core to run its
  built-in test program.
- Uploaded the capture and compared `ram_addr`/`data`/`nMRD`/`nMWR`/`SC`
  against `sim/ghdl/reference/tb_cs1800_tpb.txt`.

**Good news**: the first three real bus transactions match the golden
reference exactly --

```
ram_addr data nMRD nMWR SC     (hardware, and golden reference: identical)
0000     00   1    1    01
0000     71   0    1    00     <- fetch DIS (0x71) at address 0
0001     00   0    1    01
```

This is the ported CDP1802 core's fetch/decode/execute logic, running
on real Zynq silicon, producing the identical bus trace GHDL and xsim
predicted -- for the transactions it got to.

**Bad news**: execution then runs away. Repeating the exact same
reset/run sequence twice landed in two different bogus states outside
the 276-byte test program entirely -- stuck at `ram_addr=0001` the
first time, oscillating `0xC5D3`/`0xC5D4` the second, in both cases with
`TPB` still pulsing but nothing else advancing. Non-deterministic
across otherwise-identical reset cycles.

**Diagnosis**: `ram.vhd`'s write path is level-sensitive (`PROCESS
(address, nCS, nWE, nOE, data_in)`, no clock -- see its own file
header), which synthesized as 2208 individual latches rather than a
clocked memory (flagged in `boards/cora-z7-07s/README.md`'s synthesis
notes). RTL simulators only evaluate settled values at explicit events,
so a latch's enable/data lines never glitch there; on real silicon a
level-sensitive latch is exposed to combinational hazards on its
address/control lines in a way an edge-triggered flip-flop isn't. That
lines up with everything observed: a different wrong landing address
each run (glitch timing depends on routing delays, not repeatable to
the bit), while the edge-triggered control logic -- proven correct for
the transactions it completed -- behaves exactly as simulated.

**Next**: milestone 2b -- replace `ram.vhd`'s async-write latch array
with a real clocked (dual-port) BRAM. Not new scope; this empirically
confirms exactly the risk already flagged when the 2208-latch count
first showed up in the synthesis report.

## 2026-09-11: milestone 2c -- first program loaded from Linux, running on hardware

`shared_ram` (4KB, `axi_bram_ctrl` at `0x4000_0000`) programmed,
timing-closed (WNS +5.563ns), reprogrammed onto the board. With `reset`
still asserted (the default `0x01` on power-up hands Port B write
access to software), wrote a brand-new tiny program via `devmem` --
not the test program baked into the bitstream:

```
devmem 0x40000000 32 0x0001307B   # addr0=SEQ(0x7B) addr1=BR(0x30) addr2=0x01
devmem 0x40000000                 # read back: 0x0001307B -- confirmed
```

Armed the ILA, released reset+run (`devmem 0x41200000 32 0x68`), read
`Q=1` back from the status register, and captured the bus trace:

```
ram_addr data nMRD nMWR SC
0000     7B   0    1    00     <- fetch SEQ at address 0
0001     30   0    1    00     <- fetch BR
0002     01   0    1    01     <- read branch target (0x01 -> back to 0001)
0001     30   0    1    00     <- loops forever, exactly as written
0002     01   0    1    01
...
```

Exactly the designed program (`SEQ` then an infinite `BR` self-loop),
loaded entirely from Linux userspace over AXI, executing correctly on
real silicon. The full pipeline -- `devmem` write -> `axi_bram_ctrl` ->
`shared_ram` Port B -> reset release -> `cs1800` reading via Port A --
is proven end-to-end.

## 2026-09-11: milestone 2b, same day -- latch fix confirmed on hardware

`ram.vhd`'s write path became synchronous (`rising_edge(clk)`, gated on
`nCS`/`nWE`) while the read path stayed exactly as before -- plain
combinational, zero latency. That's the standard "distributed RAM"
(LUTRAM) idiom: real synthesizable primitive, not a latch. Verified
bit-for-bit identical against the golden reference in both GHDL and
Vivado xsim before touching hardware again. Post-route utilization:
`Register as Latch: 0` (was 2208), `LUT as Distributed RAM: 72`, timing
still fully closed.

Reprogrammed, repeated the exact same reset/run/capture sequence:

- **46 consecutive TPB rows now match the golden reference exactly**
  (up from 3) -- full, uninterrupted fetch/execute agreement for as
  long as the comparison stays meaningful (see below).
- Across the entire captured buffer (4096 samples), `ram_addr` stayed
  within `0x00`-`0xC3`, well inside the 276-byte program -- no
  corruption, no runaway, anywhere. The latch-glitch bug is gone.
- Row 46 is exactly where the golden reference's *first* interrupt
  (`SC=11`) occurs -- but that's `tb_cs1800.vhd`'s testbench using a
  deliberately fast, compressed fake `LC` (200-cycle half-period) to
  exercise the interrupt path quickly in simulation, nothing like the
  real 50 Hz `LC` this hardware build actually runs (`cs1800_top`'s
  divider). A single ILA capture can't observe a real 10 ms `LC`
  half-period, so no interrupt is expected in this window, and none
  occurred -- not a bug, just two independently-correct `LC` rates that
  were never going to stay in lockstep past that point. Full-trace
  (including interrupt timing) comparison would need `LC` driven from
  the same schedule on both sides, which isn't needed to call this
  milestone done.

## 2026-09-13: milestone 3 -- porting the real PRCX-18 bring-up towards hardware

Goal: get the real PRCX-18 v1.9.0 ROM (already booting to its actual
`_08>` prompt in simulation -- `doc/PRCX18_ANALYSIS.md`) up on real
Cora hardware, motivated by the user pulling chips from the real rack
and confirming a real minimum config: 1 EPROM (2764, 8KB) + 1 RAM
(6264, 8KB) = 16KB, down from the rack's full 48KB.

New files: `hdl/cs1800_prcx18_memory.vhd` (real split ROM/RAM, see its
own header), `hdl/cs1800_prcx18_top.vhd` (wraps `cs1800`, unmodified,
plus the new memory, one `cdp1854` on port A, and `cs1800_io_select`),
`sim/tb_cs1800_prcx18_top.vhd`, `build_project_prcx18.tcl` (separate
project, `cs1800_prcx18_bringup`, so the proven `cs1800_bringup`
project is untouched), `program_prcx18.tcl`.

**Wait-state attempt, abandoned.** First tried a real dual-port
Block-RAM (synchronous read) with the CPU held off via `nWAIT`/PAUSE
(added as new, additive, default-off ports on `cs1800_cpu.vhd`/
`cs1800.vhd` -- `mem_wait`/`dbg_tpa`, zero effect on any existing
instantiation, confirmed via full regression). This is architecturally
the real 1802's own documented mechanism, but a per-access dynamic
wait-state genuinely corrupted execution a few instructions in
(reproducible: an address register read back undefined on the third
machine cycle, root-caused down to cycle level but not fully explained
-- see `cs1800_prcx18_memory.vhd`'s header). Abandoned rather than
chase a subtle core-timing bug further; the `mem_wait`/`dbg_tpa` ports
stay (harmless, unused, default-off) as this project's only capability
in that direction for now.

**LUTRAM instead, size vs. function tradeoff.** Back to the proven
async-read, zero-timing-risk idiom (`ram.vhd`/`shared_ram.vhd`'s own
timing). Full 8KB ROM (fixed) plus as much RAM as fits underneath this
part's ~6000 LUT-as-Memory ceiling. Bisected both constraints in
parallel (GHDL for function, Vivado synthesis-only for the resource
number):

| RAM size | Functional result (sim) | LUT-as-Memory (Vivado) |
|---|---|---|
| 1KB (256w) | FAIL -- stuck retrying "Starting Console Task" | not measured |
| 1.5KB (384w) | FAIL -- same symptom | 5878/6000 (97.97%) |
| 1.75KB (448w) | FAIL -- same symptom | not fully measured |
| 2KB (512w) | **PASS** -- reaches a real `_00>` prompt | 6134/6000 (102.23%) |
| 4KB (1024w) | **PASS** -- byte-identical to the full run | 7158/6000 (119.30%) |

No size in the tested range satisfies both constraints at once -- the
"fits" threshold and the "boots" threshold don't overlap. Per the
user's explicit direction, stopped bisecting and shipped at 1.5KB
(384 words) deliberately: fits the real part, but will only reach the
boot banner before looping on the Console Task retry message, not the
interactive prompt. A real fix (e.g. a correctly-debugged wait-state
approach, or another architecture entirely) is future work.

**Next**: run `build_project_prcx18.tcl` through a real bitstream,
program the board, load the real ROM via `devmem` the same way
`shared_ram` was loaded above, and watch the partial-boot behavior
(banner + repeating "-SYS-Starting Console Task-") live on hardware --
the explicit goal for this milestone is to observe that, not to fix it
yet. Deferred beyond that: a real physical UART from the CDP1854 to
external hardware (for now, `devmem`-polled AXI GPIO stands in), and
SSH access to the Cora's Linux instead of serial console.

## 2026-09-14: milestone 3b -- SSH bring-up, isolating cdp1854+UART, a real hardware-only bug found and fixed

Programmed the 1.5KB build and ran it: reset/run control and ROM
loading via `devmem` worked (confirmed on the ILA -- `ram_addr` cycles
through a bounded range of real addresses, not stuck at reset or
corrupted into garbage), but the raw `cdp1854` TX pulse (one machine
cycle, ~320ns at 25MHz) turned out to be about 4 orders of magnitude
too fast for any `devmem` round trip to catch -- 2000 back-to-back
polls over the serial console caught nothing but 0. A later ILA
capture (after switching to SSH) also showed the CPU had drifted into
a tight two-address spin at `0xC253`/`0xC2C2`, far outside the real
16KB window -- consistent with the RAM aliasing this design's memory
map already documents, and a separate problem from the FIFO bug below.

Switched to SSH+SCP (`root@10.0.0.43`, no `sshpass`/`expect` on this
host, so a small stdlib-only `pty`-based Python wrapper does password
auth) -- much more scriptable than the serial console, and it also
answered a design question: only `/dev/ttyPS0` exists on this image
(the console, already wired to the USB serial), so routing a real
UART into a second PS7 UART via EMIO for a free `/dev/ttyPS1` would
need devicetree changes not scoped here; kept as a future direction.

Per plan, before trusting or chasing the CPU/RAM finding further:
isolated `cdp1854` + a byte-FIFO bridge + a *real* bit-serial UART
(`uart_tx.vhd`/`uart_rx.vhd`, 8N1 framing, fabric self-loopback, no
physical pin yet) from the CDP1802 entirely, driven by
`dummy_cpu_driver.vhd` (a tiny stand-in that pulses cdp1854's write
bus exactly like a real 1802 `OUT` would) instead of the full CPU --
`cdp1854_uart_test_top.vhd`, proven byte-exact in simulation first
(`tb_cdp1854_uart_test_top.vhd`, `ALL CHECKS PASSED`), then built and
programmed as its own small bitstream.

First real-hardware run: 29 of 30 bytes came back exactly right, but
byte 0 read as `0x00` instead of `0x48` ('H') -- every time, on repeat
triggers of the same live bitstream, not a one-off. Localized it with
a value-triggered `system_ila` capture (arm on a signal transition,
then trigger the design over SSH while the ILA waits, decoupling JTAG
and SSH timing entirely): a capture on the loopback serial line showed
the wire itself carried all-zero data bits for the first frame, and a
follow-up capture with probes on `cdp1854`'s write latch showed
`cdp1854` correctly latched `0x48` -- so the corruption was between
`cdp1854` and the wire. Adding probes on the FIFO's own `head`/`avail`
nailed it: `avail` read '1' one cycle before `head` reflected the
newly-written byte, so `uart_tx` (which pops on the very first cycle
it sees `avail`) grabbed a stale value. Root cause: `byte_fifo.vhd`'s
`head` output was described as a plain combinational alias of
`mem(rd_ptr)` even though its own header already claimed a registered,
Block-RAM read -- GHDL just executes the VHDL as literally written, so
simulation never disagreed with itself, but Vivado's synthesis of that
specific 256-deep array evidently didn't keep `head` and `avail` in
lockstep. Fixed by actually registering both together in the same
clocked process (matching the header's original intent), which also
makes the two provably self-consistent regardless of how the
underlying RAM/mux gets synthesized. Re-verified in simulation (fixed
the testbench's own settling delay for the FIFO's new one-cycle-later
timing) and on hardware: repeated runs now come back byte-for-byte
exact -- `"Hello, CS1800 UART loopback!"`, all 30 bytes, every time.

The exact same bug existed in `cs1800_prcx18_top.vhd`'s own hand-
rolled copy of this FIFO (written before `byte_fifo.vhd` was factored
out) -- refactored it to instantiate the shared, now-proven entity
instead of carrying a second, drifted copy. Re-verified: byte-identical
CPU/memory trace against the earlier known-good run, and the real
PRCX-18 ROM boot test still reaches exactly the same point as before
(full banner + `-SYS-Starting Console Task-`, then the known RAM-size
retry loop) -- so this fix is behavior-preserving for the CPU/memory
path and only ever mattered for the TX-FIFO byte-0 case it was found
in.

**Next**: rebuild and reprogram the full `cs1800_prcx18_top` bitstream
with the fixed FIFO, then revisit the `0xC253`/`0xC2C2` CPU/RAM-
aliasing hang on real hardware -- now that cdp1854+FIFO+UART is
independently proven reliable, any further odd hardware behavior can
be trusted to be a CPU/memory-path issue, not a confound from this
FIFO bug.

## 2026-09-14: milestone 3c -- two more real hardware-only bugs found and fixed in the RAM address decode

Following straight on from 3b's plan: went after the `0xC253`/`0xC2C2`
two-address spin next. Found two separate real hardware-only bugs in
`cs1800_prcx18_memory.vhd`, neither visible in GHDL simulation (which
never disagrees with itself the way real synthesis can):

**Bug #1**: `g_ram_words` was 384 (1.5KB) -- not a power of two, picked
purely to hit the LUTRAM budget as closely as possible. That forced the
RAM index's address decode into a genuine subtract-then-`MOD 384` on
every single read, unconditionally, even ROM ones -- a real
combinational divider, not the cheap bit-slice every other design here
(`ram.vhd`, `shared_ram.vhd`) uses. Fixed by requiring a power of two
(dropped to 256 words = 1KB) so the RAM index is a pure bit-slice
again. Real, verified improvement (the CPU ran measurably further
before the next hang) but not sufficient alone -- see bug #2.

**Bug #2**: even with bug #1 fixed, ROM and RAM were still two
*separate* arrays, each read unconditionally on every access and
combined via a data-level 2:1 mux (`a_is_rom ? rom(rom_idx) :
ram(ram_idx)`) -- a shape no other proven design in this repo uses.
The hazard: even while `a_is_rom` itself stays constant (e.g. execution
sitting entirely inside ROM), the mux's other, "losing" input
(`ram(ram_idx)`) is still a live signal changing on every address
transition -- an unregistered 2:1 mux with a constantly-changing
losing input is a textbook static-hazard shape, independent of how
simple that input's own decode is. On real hardware this looked
exactly like the CPU hanging in the tight `0xC253`/`0xC2C2` two-address
spin, stuck in the execute state (SC never returning to fetch);
confirmed via ILA, and GHDL again saw nothing (zero-delay simulation
can't model this at all). Fixed by merging ROM and RAM into one `mem`
array and muxing the *index* once before a single read, never the data
after two independent reads -- the same safe idiom the write side (and
`shared_ram.vhd` generally) already used.

Re-verified with a local-only exploratory testbench
(`doc/cs1800_hardware_source/tb_prcx18_lutram.vhd`, gitignored --
loads the real PRCX-18 ROM via Port B exactly like `devmem` does, then
runs it through the real `cs1800_prcx18_top`/`cs1800_prcx18_memory`
hardware design at the new 256-word/1KB size): 12M clock cycles,
GHDL exits clean, and the UART TX trace is byte-for-byte the same
"fits but functionally short" result the earlier size-sweep table
predicted for 1KB -- full boot banner, then `-SYS-Starting Console
Task-` repeating -- with `ram_addr` cycling through a wide, changing
range the whole run, never settling into a fixed two-address spin.
Simulation obviously can't confirm the two hardware bugs themselves
(neither ever showed up here), but it does confirm the fix is
behavior-preserving and introduces no functional regression before
trusting it on real hardware.

**Next**: rebuild `build_project_prcx18.tcl` (now at 256 words/1KB,
still deliberately short of the ~2KB PRCX-18 needs to fully start its
Console Task -- see this file's size/tradeoff table and
`cs1800_prcx18_memory.vhd`'s header) and reprogram real hardware to
confirm the `0xC253`/`0xC2C2` spin is actually gone there too, not just
absent from a simulation that never modeled it in the first place.

## 2026-09-15: milestone 3d -- rebuilt and reprogrammed real hardware with both fixes; found a new, earlier hang

Rebuilt `build_project_prcx18.tcl` clean (LUT-as-Memory: 5473/6000,
91.22% -- comfortably fits now that 384 is gone) and reprogrammed the
board over JTAG (`program_prcx18.tcl`). Loaded the real ROM via
`gen_load_prcx18_rom.py` + `busybox devmem` (no python on this
PetaLinux image -- committed here, ROM binary itself stays local/
gitignored) and released reset+run (`ctrl_in = 0x68`, same as
`tb_prcx18_lutram.vhd`'s stimulus). Read back several loaded ROM words
afterward -- byte-exact match, so the load path itself is solid.

Result: no UART output at all, ever -- `drain_uart_fifo.sh` (also
committed) polled the TX FIFO for thousands of iterations across
several separate attempts and never saw `avail` go high, even though
`status_out`'s `LC` bit was visibly toggling (so the design's own
clock/reset infrastructure is alive).

Captured a `system_ila` snapshot (`capture_ila_prcx18.tcl`, committed
-- `run_hw_ila -trigger_now` needs no pre-armed trigger condition, just
grabs whatever's happening right now) on `ram_addr`/`data`/`nMRD`/
`nMWR`/`SC`/`TPB`. Verdict: the CPU is stuck fetching the *same*
instruction at `0x0090` (opcode `0x73`, `STXD` -- confirmed against the
real ROM dump) over and over, forever -- `SC` alternates S0/S1 (so it's
not frozen in reset), but the fetch address never advances past
`0x0090`/`0x0091` across the whole 4096-sample capture. `0x0090` is
straight-line register-save code (`STXD`/`GHI`/`PHI`, no branches
nearby in the disassembly) very early in PRCX-18's own boot sequence --
nowhere near where the old `0xC253`/`0xC2C2` aliasing spin happened,
and well inside the ROM region, so this isn't the RAM/mem address-
decode path bug #1/#2 fixed this session.

This is a **new, earlier, real-hardware-only symptom**: `tb_prcx18_lutram.vhd`
runs this exact RTL, this exact ROM, this exact `ctrl_in` sequence, and
reaches the full boot banner in GHDL without incident -- so whatever's
wrong here is (once again) a synthesis-only hazard GHDL's zero-delay
simulation can't see, not a logic error in the VHDL as literally
written. Root cause not yet found. Given today's pattern (two
unregistered-mux/non-power-of-two hazards already found and fixed in
the memory path), the most likely place to look next is still
somewhere in the CPU/control sequencing (`cs1800_cpu.vhd`/
`control.vhd`) rather than the memory design just re-verified in
simulation -- but that's a real guess, not yet confirmed by bisection.

**Status**: build/program/ROM-load pipeline is solid and now has
committed, reusable tooling (`gen_load_prcx18_rom.py`,
`drain_uart_fifo.sh`, `capture_ila_prcx18.tcl`). Whether today's two
memory-decode fixes actually solved the original `0xC253`/`0xC2C2`
problem is **still unconfirmed** -- this new, earlier hang blocks
execution before the CPU ever gets far enough to reach that address
range again. Next investigation: more ILA probes (e.g. the CPU's
instruction register / N-lines, P/X register values) to see what's
actually preventing `P` from advancing past `0x0090`, or a hand
bisection of `cs1800_cpu.vhd`'s combinational paths the same way
`byte_fifo.vhd`'s bug was found.

## 2026-09-15: milestone 3e -- isolated the 0x0090 hang to the rig, not the RTL, via `testram`

Per the user's direction: stopped chasing the real ROM's specific hang
and went back to the old, boring-on-purpose 276-byte instruction-
exerciser (`test_program_pkg.vhd`, what the user calls `testram` --
exercises nearly every opcode, no real function otherwise) to isolate
step by step, same discipline as every earlier milestone here.

Bisection sequence (each step: reprogram over JTAG -- resets LUTRAM to
the bitstream's built-in `test_program` default, no ROM loading needed
-- release reset+run over `devmem`, `capture_ila_prcx18.tcl` with
`-trigger_now`):

1. **Today's fixed `cs1800_prcx18_top`/`cs1800_prcx18_memory`** (256
   words): stuck after ~15 TPB pulses, oscillating `0x0000`/`0x0008`/
   `0x009E` forever.
2. **Pre-fix `cs1800_prcx18_memory`** (384 words, two separate rom/ram
   arrays, temporarily restored from commit `4347bb9` to test): stuck
   even earlier, oscillating `0x0000`/`0x0024`. **Rules out today's two
   memory-decode fixes as the cause** -- this exact symptom predates
   them.
3. **Control: `cs1800_top`+`shared_ram`** (the long-proven design from
   milestone 2, no ROM/RAM split at all) -- first programmed the
   bitstream already sitting in `~/fpga/cs1800_bringup`: **also**
   stuck, oscillating `0x0000`/`0x007A`. Initially alarming, until
   noticing the `.bit` file's mtime (2026-09-11 17:26) predates the
   `shared_ram.vhd` fix entirely (`ram.vhd`'s latch-hazard bug, milestone
   1's own documented failure -- non-deterministic 2-address
   oscillation is *exactly* that bug's signature) -- a stale build, not
   a real control.
4. **Real control: rebuilt `build_project.tcl` from current source**
   (genuinely has `shared_ram.vhd`) and reprogrammed: **also** stuck,
   oscillating `0x0000`/`0x0022`/`0x0023`.

Step 4 is the real finding: a design that has been reliably proven
correct on this exact board across many earlier sessions now fails
identically. That rules out every VHDL source file tested today --
`cs1800_prcx18_memory.vhd`, `cs1800_prcx18_top.vhd`, `cs1800_top.vhd`,
`shared_ram.vhd`, and by extension the shared `cs1800`/`cs1800_cpu`
core all of them wrap unchanged. The common factor across all four
bitstreams is this session's rig/environment: many back-to-back JTAG
reprograms without a board power cycle in between.

Restored the working tree to the committed (fixed) `cs1800_prcx18_top`/
`cs1800_prcx18_memory`, rebuilt, and reprogrammed the board so it's
left in the correct state regardless of what caused this.

**Next**: power-cycle the board (not just JTAG-reprogram) and repeat
the `testram` + `capture_ila_prcx18.tcl` check once more before
touching any VHDL again -- if a fresh boot fixes it, this was a rig/PS7
state issue (e.g. AXI interconnect or reset-network state left over
from repeated reconfiguration) and the original PRCX-18 boot test
(bug #1/#2 fixes, milestone 3d) needs to be re-run from a clean boot
before drawing any conclusion about them.

## 2026-09-15: milestone 3f -- correction: 3e's "instant hang" was a bad capture method, not a real symptom

Power-cycled the board as planned. The retest (`cs1800_top`+`shared_ram`,
freshly rebuilt) **still** showed the same oscillation
(`0x0000`/`0x0022`/`0x0023`) right after power-cycling -- ruling out
3e's rig/PS7-state theory too.

The actual problem was the capture method, not the board or the RTL:
every capture in 3e used `run_hw_ila -trigger_now`, which grabs
whatever is on the bus *at the moment Vivado happens to connect* --
seconds after `devmem` released run, over a separate SSH round trip.
None of those captures ever actually watched execution *start*; they
could easily be sampling a state the CPU reached and settled into long
after the interesting part was over.

Redid it the way milestone 1/2's own successful captures always did it
(`doc/CS1800_HARDWARE.md`'s and this file's own earlier entries --
arm the ILA trigger *first*, on `TPB`'s first rising edge, *then*
release run): a single Tcl script (`set_property
TRIGGER_COMPARE_VALUE {eq'b1} $tpb_probe`, `run_hw_ila` to arm, `exec`
the `devmem` release over `ssh` from inside the same script so there's
no cross-process race, then `wait_on_hw_ila`) on the freshly-rebuilt,
power-cycled `cs1800_top`+`shared_ram` control. Result, compared
directly against `sim/ghdl/reference/tb_cs1800_tpb.txt`:

- **First 46 TPB rows match the golden reference exactly** -- same as
  the original 2026-09-11 milestone 2b (which never checked further).
- Execution keeps going correctly well past that: ~500 TPB pulses
  captured, working through what's recognizably a real copy-loop (a
  fetch pointer and a second, `R2`-based write pointer both climbing
  in lockstep from roughly `0x28` to `0xA6`) -- further than this
  design has ever actually been checked against the golden reference
  before.
- It reliably (reproduced identically twice, back to back) ends up at
  `0x00F1`, executing what looks like `IDL` (opcode `0x00`) and
  parking there. Confirmed against the golden reference: address
  `0x00F0`/`0x00F1` **never appears anywhere in the whole 526-line
  correct trace** -- the real program is supposed to skip that dead
  filler region entirely via an unconditional long branch (`LBR` at
  `0x00C1`, jumping straight to `0x0100`, confirmed in the golden
  trace) and never touch it. So parking at `0x00F1` is a real,
  reproducible deviation, not expected behavior -- it just happens far
  later, after far more correct execution, than milestone 3e's flawed
  captures made it look.

Corrects 3e's headline conclusion: this is not "everything hangs
almost instantly," and it was never a rig/power-cycle issue. The
design executes a long, non-trivial, correct instruction sequence on
today's exact same rig; there's a specific, real, reproducible branch/
skip failure somewhere between address `~0xA6` and `0x00F1` that has
never been isolated before (nobody checked this design past address
`0xC3` until today). 3e's bisection results (which bitstream fails)
are therefore uninformative and should not be used to rule anything in
or out -- they were all `trigger_now` snapshots of unknown vintage.

**Next**: keep bisecting with the *from-start* triggered-capture
method (not `trigger_now`) toward the exact address where control flow
first diverges from the golden reference's fetch-address sequence,
somewhere between `0xA6` and `0x00C1`'s `LBR`.

## 2026-09-15: milestone 3g -- found and isolated the real bug: a single-bit real-hardware read glitch at address 0x0099

Wrote a small script comparing the from-start capture's full FETCH-
address sequence (rows with `SC="00"`) against the golden reference's
own fetch-address sequence using `difflib.SequenceMatcher` (a plain
row-by-row diff doesn't work past the interrupt divergence at row 46 --
golden's real interrupt-service instructions have no counterpart in
hardware's un-interrupted run, so the two sequences drift out of index
alignment even where the underlying code is identical; matching the
*sequences* rather than the *rows* sidesteps that entirely). Result:
**hardware's first 118 fetched addresses/opcodes match the golden
reference exactly**, character for character -- then diverge.

The exact divergence: golden fetches `BR` (`0x30`) at address `0x0098`
(an unconditional short branch), then correctly continues at its
target, `0x00B1`. Hardware instead lands at `0x00F1` immediately
after. `0x00B1` XOR `0x00F1` = `0x40` -- a single bit (bit 6) flipped
in the one byte `BR` reads as its jump target, at address `0x0099`.

Confirmed via `test_program_pkg.vhd`'s own source: `0x0099` holds the
literal constant `X"B1"`, never self-modified before this point in the
program, so this isn't a self-modifying-code timing question. Two more
checks nailed down exactly what's wrong:

- **While the CPU was still parked at the wrong address (post-capture,
  IDL at `0x00F1`)**: read address `0x0099`'s word back over the
  independent AXI/Port B path (`devmem 0x40000098`) -- by then it
  legitimately read back different, further-scrambled content, because
  IDL only *pauses* the CPU (per the real 1802: it resumes at PC+1 on
  the next DMA/interrupt, and the real 50Hz `LC` interrupt *will*
  eventually arrive and wake it, well within the tens of seconds
  between the capture ending and this readback) -- by the time this
  check ran, the woken CPU had already continued executing (and this
  program self-modifies extensively elsewhere), scrambling memory
  further. Landing at `0x00F1`/executing `IDL` was never itself a hang
  -- it's the CPU correctly doing exactly what `IDL` means, only
  starting from the wrong address because of the one bad read.
- **Fresh reprogram, read address `0x0099`'s word immediately, still
  held in reset, before any execution at all**: `devmem 0x40000098` ->
  `0x0057B130` -- byte `0x0099` = `0xB1`, exactly correct. This proves
  the stored ROM content itself is fine; the corruption happens
  specifically when **the running CPU reads that address on real
  hardware**, not in how it's stored.

This reproduced identically across two separate from-start captures
(same wrong target, `0x00F1`, both times) -- deterministic, not a
random glitch, at least at this specific address/timing.

**Why this is a big deal**: this is on `cs1800_top`+`shared_ram` -- the
plainest design in this repo, no ROM/RAM split, no `cs1800_prcx18_*`
files involved at all. `shared_ram.vhd`'s own read path (checked
directly, see its listing) already uses the exact single-array/single-
index/one-`CASE`-read shape this session's earlier fixes moved
`cs1800_prcx18_memory.vhd` *to* -- there's no obvious hazard shape in
it to point at. That makes the CPU core's own data-capture path
(`cdp1802.vhd`/`instr.vhd`/`dmux.vhd` -- wherever the D register
latches the incoming memory bus) the more likely suspect: a genuine,
previously-undiscovered real-hardware-only hazard in code shared by
*every* design in this repo, not a board-level memory bug. Nobody
found this before because nobody previously verified this design's
execution past address `0x00C3`/row 46 against the golden reference
until milestone 3f's corrected capture method made that possible.

**Next**: look at `cdp1802.vhd`/`instr.vhd`/`dmux.vhd`'s D-register
capture path for the same class of hazard already fixed twice today
(an unregistered mux with a live, changing "losing" input, or a
combinational read whose result is sampled before it's fully settled).
Also worth checking whether this is *always* address `0x0099`
specifically, or whether it's actually a timing-window hazard that
happens to land on whatever byte is being fetched at a particular
point in the boot sequence -- rerunning against a different program
(or the same one with padding/NOPs inserted before this point) would
tell them apart.

**Strong candidate found, not yet verified**: `cdp1802.vhd` (~line
413):

```
D_in <= D_in_amux WHEN (A_sel_lohi = "01" OR A_sel_lohi = "10") ELSE D_in_dmux;
```

Exactly the same shape as today's bug #2 (`cs1800_prcx18_memory.vhd`):
an unregistered mux combining two continuously-live combinational
sources (`D_in_amux` -- the A-register byte, and `D_in_dmux` -- the
external memory-bus byte, i.e. the value read at `0x0099`) based on a
control signal (`A_sel_lohi`) that isn't guaranteed to be stable
relative to them. The header comment above it explains this used to be
a real tri-state bus on the real chip (`float0`/`float1` decided who
drove it, the other side floated) -- converted here into an explicit
mux, which is exactly the kind of "made explicit but now has a real
static-hazard shape it didn't have as two separately-floating drivers"
conversion this project has already found real hardware bugs in twice
today. Not yet confirmed as the actual cause (haven't traced whether
`A_sel_lohi`'s timing during a `BR`'s operand read specifically can
overlap a `D_in_dmux` transition), and not yet touched -- this is
foundational, shared by every design in this repo including the
already-`shared_ram`-proven `cs1800_top`, so any fix here needs real
care and its own from-scratch re-verification (GHDL regression first,
then hardware) before trusting it anywhere.

## 2026-09-15: milestone 3h -- found and fixed the real cause: an OR-merged bus, not the D_in mux

The `D_in_amux`/`D_in_dmux` mux candidate above turned out to be a dead
end on closer inspection: `A_sel_lohi` (its select) is a registered
signal (`r.A_sel_lohi` in `instr.vhd`'s synchronous process), not a
combinational one, so it doesn't have the "changing losing input"
shape that made today's earlier two bugs real. Ran `report_timing
-delay_type min` (hold analysis) on the actual register that captures
a branch's memory-read target byte (`u_instr/r_reg[tmp_page][*]`,
found by grepping `instr.vhd` for `tmp_page` -- exactly the "M(R(P))
-> R(P).0" temporary the disassembly comments describe) against the
routed checkpoint: comfortable hold margins throughout (0.6-0.9ns) --
not a timing-margin problem at all.

The real mechanism, found by reading `cs1800.vhd` itself: the CPU's
memory-mapped data bus is built as `data <= cpu_data_out OR
ram_data_out_ext OR io_input_data OR io_data_in_ext;` -- an explicit
comment there says this replaces the real chip's tri-state bus
resolution, and relies on each of the four sources correctly forcing
itself to `X"00"` whenever it isn't the one actually driving (each
one's own module does this -- checked `dmux.vhd`, `io_inp.vhd`,
`shared_ram.vhd`/`cs1800_prcx18_memory.vhd` directly, all correct as
written). `cpu_data_out`'s `X"00"` XOR'd against the correct `0xB1`
gives exactly `0xF1` if `cpu_data_out` happens to be non-zero in bit 6
at the exact instant `ram_data_out_ext` is sampled -- an OR-merge only
needs ONE contributor to be non-zero when it shouldn't be, at the
exact right instant, to corrupt a read exactly like this, and (unlike
an explicit priority mux, which structurally excludes every non-
selected source) there's nothing here forcing that guarantee to hold
at the physical-timing level on real silicon, only at the
already-known-limited zero-delay-simulation level.

**Fix**: `cpu_data_out` and `io_input_data` both already have an
explicit, always-available "am I actually driving" signal in scope at
this point (`cpu_data_oe`, `n_io_in_sel`) -- rewrote the OR into an
explicit priority mux that structurally excludes each one entirely
except when its own signal says it's driving, instead of trusting each
one's own self-zeroing:

```
data <= cpu_data_out WHEN cpu_data_oe = '1' ELSE
        io_input_data WHEN n_io_in_sel = '0' ELSE
        ram_data_out_ext OR io_data_in_ext;
```

`ram_data_out_ext`/`io_data_in_ext` stay OR'd together deliberately --
they're mutually exclusive by construction (nMRD-gated vs nMWR-gated
reads can't both be active in the same real machine cycle) and neither
has its own "active" signal exposed at this level to gate on instead;
no evidence implicates either of them specifically.

**Verification, same discipline as every fix today**: full `sim/ghdl/
run.sh` (all four testbenches: `tb_cdp18_dump`, `tb_cs1800_dump`,
`tb_cs1800_memory`, `tb_cs1800_console`) and `boards/cora-z7-07s/sim/
run.sh` all pass, and -- checked explicitly, not assumed --
`sim/ghdl/reference/*.txt` come back byte-identical to their committed
golden copies (`git status` shows no diff after regenerating them).
Zero simulated behavior change, exactly as expected for a hazard
zero-delay simulation could never see in the first place.

**Real hardware, rebuilt `cs1800_top`+`shared_ram`, same from-start
capture method**: `compare_ila_to_golden.py` now finds hardware
matching the golden reference for its first **126** fetches (up from
118) -- the `0x0098` `BR` now correctly reads `0xB1` and lands there,
and every instruction from `0x00B1` through the `LBR` at `0x00C1`
(`0xB1`,`0xB5`,`0xB6`,`0xB3`,`0xB8`,`0xBA`,`0xBE`,`0xC1` -- 8 fetches)
now matches exactly. **The specific bug is confirmed fixed.**

It still diverges one step later: golden's `LBR` at `0x00C1` correctly
jumps to `0x0100`; hardware instead lands at `0x0000`, refetching `DIS`
-- i.e. it looks like a restart from address 0, not a wrong-but-live
memory value the way the `0x0099` bug did. Whether this is the exact
same OR-merge hazard striking `LBR`'s (2-byte) target read elsewhere,
or something new, is not yet known.

**Next**: keep bisecting the same way toward this new divergence at
`0x00C1`'s `LBR` (2-byte target read, landing at address 0 instead of
`0x0100`) -- check whether it's the still-untouched `ram_data_out_ext
OR io_data_in_ext` pairing, or a genuinely different mechanism (the
exact-zero landing address looks more like a real reset than a
corrupted-but-live read).

## 2026-09-15: milestone 3i -- ruled out the D_in mux and R_in's write path; not a physical timing hazard

Confirmed deterministic first (reran the exact same from-start capture
a second time on a fresh reprogram: identical divergence, matches for
126 fetches then lands at `0x0000` both times) -- rules out a random
setup/hold glitch, points at real sequencing logic instead.

First checked the raw bus reads directly: `0x00C2`->`0x01`,
`0x00C3`->`0x00` (per `LBR`'s own microcode -- `instr.vhd` around line
702 -- these are `M(R(P))` and `M(R(P)+1)`, captured into `tmp_page`
then combined as `r.tmp_page & D_in` on the following `S1` pass).
**Both bytes read correctly** -- unlike milestone 3g/3h's bug, this
isn't a corrupted memory read. The final value written into `R(P)`
(`R0`, since `P=0` throughout this program) is simply wrong: `0x0000`
instead of the correctly-formed `0x0100`.

Traced the actual write path on the routed checkpoint rather than
guessing further: `R_in` (`instr.vhd`'s `r.R_in`) is **its own real
register** (`u_instr/r_reg[R_in][*]`, confirmed via `get_cells`), not
combinational -- and it feeds `reg_R`'s `D` input almost directly
(`Logic Levels: 0` in `report_timing`, i.e. one net, no LUTs in
between). Checked both hold and setup timing on register `0`'s (`R0`,
i.e. `P`'s target) 16 `D` pins on the routed checkpoint: comfortable
positive margins throughout (0.2-0.35ns hold, nothing alarming on
setup). **This specific path is clean** -- ruled out as the cause.
Also revisited the `D_in_amux`/`D_in_dmux` mux flagged in milestone 3g
as a "strong candidate": its select (`A_sel_lohi`) turned out to
already be a registered signal (`r.A_sel_lohi`), not combinational, so
it doesn't have the "live changing losing input" shape that made
today's earlier bugs real either -- also ruled out.

Between `tmp_page`'s write (first `S1` pass) and its read (second `S1`
pass, one full extra pass later -- several real clock cycles apart,
not a same-cycle race), there's no combinational hazard shape left to
point at from static timing alone. This one doesn't look like a
physical timing hazard the way the OR-merge bug did -- it looks like a
genuine sequencing question (is `extraS1`/`forceS1` actually toggling
when and how the RTL assumes, on real hardware specifically) that
static `report_timing` can't answer; it needs to actually *see*
`tmp_page`/`R_in`/`extraS1`/`forceS1`'s live values during this exact
instruction, which means adding them as new debug probes (routing them
out through `instr.vhd`/`cdp1802.vhd`/`cs1800.vhd`'s existing `dbg_*`
plumbing) and rebuilding -- a real code change for visibility, not
just another round of passive analysis on what's already built.

**Next**: add `tmp_page`, `R_in`, `extraS1`, `forceS1` (and maybe
`wr_R`) to the `system_ila` probe set, rebuild, and capture the exact
same `LBR` sequence again to see which one actually misbehaves in real
time, the same way `dbg_ram_addr`/`dbg_sc`/`dbg_tpb` already let us
isolate the previous two bugs.

## 2026-09-15: milestone 3j -- the LBR bug moved after a rebuild; these are routing-dependent hazards, not one fixed bug

Added the four new probes (`tmp_page`, `R_in`, `forceS1`, `extraS1`,
threaded through `instr.vhd`->`cdp1802.vhd`->`cs1800_cpu.vhd`->
`cs1800.vhd`->`cs1800_top.vhd`, all with a "no real chip pin, FPGA-only"
note -- see the commit), rebuilt, reprogrammed, recaptured from the
same trigger-on-first-TPB start.

Two things happened at once, and untangling them mattered:

- **The `0x00C1` `LBR` bug from milestone 3h/3i is just... gone** in
  this rebuild -- the `BR` at `0x0098` still correctly reads `0x00B1`
  (bug from 3g/3h stays fixed) and this time execution sails straight
  through the `LBR` at `0x00C1` too, matching golden all the way to
  fetch #120 (`0x00B6`).
- **A *new*, different single-bit corruption appeared one step later**:
  golden's next fetch is `0x00B3`; hardware lands at `0x0033` instead --
  `0x00B3 XOR 0x0033 = 0x80`, bit 7 this time, not bit 6. Confirmed via
  `tmp_page`/`R_in` in the new probes that this isn't the `LBR`
  mechanism at all (`R_in` just shows the ordinary `PC+1` value the
  whole time, consistent with an unrelated, simpler branch/skip a few
  instructions later).

**This is the real finding**: the exact same, functionally-identical
RTL (confirmed via `sim/ghdl/run.sh` before rebuilding -- byte-
identical golden reference, zero behavior change) produced a
**different specific failure** after nothing but a rebuild (same
source, new placement/routing, since Vivado isn't guaranteed to place
identically even for a source-identical design). That's the signature
of a real, marginal, *routing-dependent* timing hazard, not a fixed
logic bug living at one address -- consistent with everything found
today, just confirming it more directly than before. `milestone 3h`'s
fix (`cpu_data_out`/`io_input_data` structurally gated out of the data
bus) is a real, confirmed improvement (the bug it targeted stayed
fixed across this rebuild), but it evidently didn't close every
instance of this class.

One thing this build *does* rule out for the remaining `ram_data_out_ext
OR io_data_in_ext` pairing (deliberately left alone in milestone 3h):
`cs1800_top.vhd` never wires `io_data_in_ext` at all, so for this
specific design it's a hard-wired constant `X"00"` from `cs1800.vhd`'s
own port default -- not a live signal, so it structurally cannot be
the source of a bit glitch here. Whatever's corrupting this new read is
most likely inside `shared_ram.vhd`'s own async-read combinational
path (the same general shape -- a live combinational value sampled
without a hard guarantee it's settled -- as the `cs1800.vhd` bug, just
in a different file).

**Where this leaves things**: this looks less like "one more bug to
find" and more like a recurring *class* of hazard (an async/
combinational value read at a moment real hardware doesn't fully
guarantee it's settled, invisible to zero-delay GHDL simulation by
construction) that can surface at different addresses/bits depending
on how a given build happens to route. Chasing each specific manifestation
one rebuild at a time, the way milestones 3g-3i did, will keep finding
*a* bug each time, but may not converge on "done." A more systematic
option worth considering: making the memory read path (currently
async/combinational, matching the real 1802's own timing but not
provably hazard-free once merged onto a shared bus in an FPGA) properly
registered/synchronous throughout -- noted elsewhere in this project as
previously attempted and abandoned (see `cs1800_prcx18_memory.vhd`'s
header: "an earlier real-Block-RAM/wait-state attempt... hit a genuine,
reproducible CPU-timing corruption") -- so not a quick fix either, but
possibly the actual way to close this class of bug rather than
continuing to patch individual instances.

**Next**: user input needed on direction -- keep bisecting this
specific new `0x00B3`/`0x0033` instance the same way as before, or step
back and consider the synchronous-memory-path option, or stop here for
now. Three real, confirmed, hardware-verified bug fixes landed today
regardless of which way this goes next.

## 2026-09-15: milestone 3k -- a real synchronous-memory attempt, and why it's genuinely hard (not committed -- see below)

Per the user's direction: stepped back from bisecting individual
routing-dependent manifestations and investigated whether the memory
read path could be made properly synchronous throughout, closing this
whole class of hazard rather than patching one instance at a time.

**First, understood why the *previous* attempt (milestone 3, this
file, and `cs1800_prcx18_memory.vhd`'s header) was abandoned**: it used
the CDP1802's own real `nWAIT`/PAUSE mechanism (`cs1800_cpu.vhd`'s
`mem_wait` -- a genuine per-access dynamic wait-state) and found "an
address register went undefined on the third machine cycle." Before
retrying anything like that, read `instr.vhd` directly to check whether
a dynamic wait is even necessary: for every instruction checked
(`S0_FETCH`, `BR`), the address is presented at `clk_cnt=0` (`wr_A`)
and the read data isn't consumed until `clk_cnt=3` or `4` -- 3-4 real
`CLOCK` cycles of built-in slack already exist in the CPU's own 8-clock
machine cycle. That's comfortably more than a single Block-RAM read's
1-cycle latency needs, suggesting a **fixed**, always-1-cycle
synchronous read might work with *no* dynamic wait-state at all -- no
`mem_wait`, no PAUSE, no changes to `cs1800_cpu.vhd`/`control.vhd`/
`instr.vhd` whatsoever, sidestepping the previous attempt's whole
failure mode by construction.

**Tested this directly and cheaply, in simulation only, before risking
anything real**: built two throwaway files -- `ram_sync.vhd` (a copy of
`ram.vhd` with the read process changed from combinational to a plain
`IF rising_edge(clk) THEN data_out <= ...`) and `cdp18_sync.vhd` (a
copy of `cdp18.vhd` instantiating `ram_sync` instead of `ram`, nothing
else changed) -- plus a matching `tb_cdp18_sync_dump.vhd` writing to
its own output file, diffed directly against the exact same
`sim/ghdl/reference/tb_cdp18_tpb.txt` `ram.vhd`/`cdp18.vhd` already
pass.

**Result: it does not work, and GHDL itself proves why, precisely.**
The dumped trace showed `ram_addr` as `XXXX` (VHDL's genuine
"undefined" value, not a display glitch) for 469 of 622 lines.
Confirmed this wasn't a pre-existing/harmless artifact by running the
*original*, proven `cdp18`/`ram` design through the identical
`NUMERIC_STD.TO_INTEGER: metavalue detected` warning count: **7**
warnings for the working design (baseline, apparently a harmless
startup artifact at time 0 -- same count either way), versus **3523**
for `cdp18_sync`/`ram_sync`. That's real, ongoing internal corruption,
not cosmetic -- GHDL is tracking actual undefined bits propagating
through the CPU's own registers over the whole run, confirmed by an
objective, reproducible count rather than eyeballing a trace.

**Why, best guess**: the CDP1802's real `ADDR` pin is only 8 bits,
time-multiplexed between the address's high and low byte within a
single machine cycle (`control.vhd`'s `addr_lohi`, latched into
`addr_high` on `TPA` -- see `cdp18.vhd`/`cs1800.vhd`'s own
`p_reg_high_addr` process). The *reconstructed* 16-bit `ram_addr` this
project's memories all key off is therefore only guaranteed valid
during the specific portion of the machine cycle memory access
actually happens in -- not necessarily held rock-stable for the entire
cycle the way a naive "just delay the read by 1 clock" idea assumes.
A blanket `rising_edge(clk)`-gated read captures *whatever* `ram_addr`
happens to show on every single clock edge, including moments outside
that valid window, when the low byte may be mid-transition for reasons
having nothing to do with the current memory access. The 3-4 cycle
slack found in `instr.vhd` is real, but it's slack in *when data must
be consumed*, not proof that the *address* stays valid for that whole
window -- a real synchronous read would need to latch only within the
specific, narrower window `nCS`/`nOE`/`nWE` actually mark as a real
access, not unconditionally every cycle.

**Not committed**: per this project's own established convention (see
`cs1800_prcx18_memory.vhd`'s header, which documents the *previous*
abandoned attempt in prose only, keeping no broken files around),
`ram_sync.vhd`/`cdp18_sync.vhd`/`tb_cdp18_sync_dump.vhd` were deleted
after this experiment rather than committed -- they don't work, and
the finding is fully captured here in prose. Regenerate them from this
description if picking this up again.

**Next**: a real synchronous-memory attempt would need the registered
read to update only within the actual access window (e.g. gated on
`nOE`/`nCS` freshly asserting, or captured once per machine cycle at a
specific `clk_cnt` known to fall inside the valid-address window,
rather than unconditionally on every `CLOCK` edge) -- worth trying, but
a more careful design than the one-line change tested here. Given how
deep both the wait-state and the naive-registered-read approaches turn
out to be, whack-a-moling individual routing-dependent manifestations
of the `OR`-merge-style hazard (milestone 3g/3h/3j) may honestly be the
more tractable path in the near term, even though it doesn't close the
whole class at once.

## 2026-09-15: milestone 3l -- the fix: A_full, and PRCX-18 reaches its real prompt in simulation

The user, after milestone 3k's negative result, pointed out the actual
mechanism directly (confirmed against the real memory board's own
schematic: `TPA` clocks the high address byte into 4042 latch ICs
straight off the backplane) and asked whether the real CDP1802
datasheet's own timing diagram was available locally rather than
needing a fresh screenshot. It was (`~/Cdp1802-datasheet.pdf`, 27
pages, no `pdftoppm` on this machine so rendered with `gs` instead --
see the new `doc/CDP1802_MEMORY_TIMING.md` and the `cdp1802-datasheet`
memory entry for how). Page 9's `Figure 3` confirmed the exact
mechanism and gave a real number: `tACC` (address-to-data) = `5T-250ns`
typical -- a real memory chip gets nearly 5 whole `CLOCK` periods.

**The actual fix, found from that reading**: the real chip's `ADDR`
pin is only 8 bits *because it's a real 40-pin package* -- a
constraint that doesn't exist for a fully-integrated FPGA design at
all. `cdp1802.vhd`'s internal address register (`A_out`, written by
`wr_A`, always at `clk_cnt=0`) already holds the complete, settled
16-bit address *before* `ADDR`/`TPA` ever multiplex it out to 8 pins --
milestone 3k's failure was entirely an artifact of reconstructing that
16 bits back out of the narrow external bus, not anything wrong with
registering a read per se. Added a new `A_full` port
(`cdp1802.vhd`->`cs1800_cpu.vhd`->`cs1800.vhd`, purely additive, same
"no real chip pin" pattern as the earlier debug taps) exposing `A_out`
directly, and fed *that* to a registered read instead.

**Verified in simulation first, same discipline as every fix today**:
rebuilt the milestone-3k experiment (`ram_sync.vhd`/`cdp18_sync.vhd`)
with the one change (`A_full` instead of the `ram_addr`
reconstruction) -- **byte-for-byte identical to the golden reference,
zero `NUMERIC_STD` metavalue warnings** (down from 3523). Confirms the
theory exactly: a genuinely stable, non-multiplexed address is all a
registered read ever needed.

**Applied to both real memory designs, in place** (not new "_sync"
files this time -- the concept is proven, so evolved the actual
target files the way milestone 3h's `cs1800.vhd` fix did):

- `cs1800_prcx18_memory.vhd`: Port A read is now registered
  (word+lane+selected captured together in lockstep, matching this
  file's own established "single index, single read" safe shape),
  fed by `A_full`. `g_ram_words` default raised from 256 (1KB,
  LUTRAM-budget-constrained) to **2048 (8KB)** -- the real minimum
  config the user identified by pulling chips from the actual rack,
  now trivial to fit since Block RAM (inferred automatically once the
  array is large and the read is registered) has vastly more capacity
  than the ~6000-LUT LUTRAM ceiling that forced the undersized-RAM
  tradeoff in the first place. Port B (AXI-facing) stays combinational,
  unchanged -- this fix only ever targeted Port A's real-time hazard.
- `shared_ram.vhd`/`cs1800_top.vhd`: same treatment (registered Port A
  read, fed by `A_full`) -- this is the design milestone 3g/3h/3j's
  `0x00B3` bit-7 corruption was found on, so this should close that
  specific hazard too, not just the PRCX-18-specific one.

**Full regression, all green, zero reference-file diffs** (`git
status` shows none after regenerating): `sim/ghdl/run.sh` (all four
testbenches) and `boards/cora-z7-07s/sim/run.sh` (`tb_cs1800_top`
against the golden reference, `tb_shared_ram`'s own direct Port A/B
checks) -- neither testbench needed any changes.

**Then the real target test**: updated the local-only
`tb_prcx18_lutram.vhd` to the new default (`g_ram_words => 2048`) and
a longer run (20M cycles, up from 12M -- the earlier limit only ever
needed to be long enough to demonstrate the 1KB failure symptom
quickly). Result -- **the real PRCX-18 v1.9.0 ROM reaches its actual
interactive prompt**:

```
Dutch 1800 MicroProUsers
CS1800/PRCX-18    V1.9.0

-SYS-Starting Console Task-
_08>
```

No more repeating "Starting Console Task" retry loop -- the Console
Task completes and the real prompt appears, exactly once, matching the
success criterion `doc/PRCX18_ANALYSIS.md` already documented for the
full-RAM simulation run. This is the first time this design (the real
ROM/RAM split, sized to the real machine's own minimum config, no
aliasing) has reached the prompt.

**Not yet done**: this is simulation only. The whole reason this
session's earlier bugs (3g/3h) were hardware-only and invisible to
GHDL means simulation success here, while an excellent and necessary
signal, is not proof real hardware will match -- especially since the
`A_full`/registered-read mechanism is new and hasn't been synthesized
or run on the actual board yet. Also still outstanding, per the user's
explicit request: an XDC file (worth revisiting now -- with a properly
registered, real Block-RAM-shaped design throughout, the unusual
timing exceptions milestone 3g-3j's async design might have needed are
much less likely to be necessary at all, but real timing closure
should still be checked, not assumed).

**Next**: rebuild `build_project_prcx18.tcl`/`build_project.tcl`,
confirm Block RAM inference (not LUTRAM) and real utilization/timing
numbers, program real hardware, and re-run the from-start ILA capture
method (`capture_ila_from_start.tcl`) against the golden reference the
same way milestone 3f/3g did -- this is the real test of whether
today's whole line of investigation, starting from the user's own
schematic reading, actually closes the gap between simulation and real
silicon.

**Immediate follow-up**: the first real build attempt failed outright
at DRC (`place_design` refused to run): `LUT as Memory` and `LUT as
Distributed RAM` both massively over-budget (9070/6000, 8622/6000) --
Vivado's own synthesis log showed `cs1800_prcx18_memory`'s 4K x 32
`mem` array still mapped to **Distributed RAM** (`RAM128X1D x 2048`),
not Block RAM at all, despite Port A's read now being registered.
Root cause: **Port B's read was still combinational/unregistered**
(left that way deliberately, reasoning "`axi_bram_ctrl` already
tolerates it") -- but a single VHDL array with one read port
async and the other synchronous cannot map to a single real Block RAM
primitive at all (a real BRAM's read ports are always registered, on
every port), so Vivado fell back to distributed RAM for the *whole*
array to satisfy both ports. Fixed by registering Port B's read too,
in `cs1800_prcx18_memory.vhd` and `shared_ram.vhd` (gated on `b_en`,
same "register word+select together" shape as Port A) -- also the
more *correct* choice on its own terms, since `axi_bram_ctrl`'s native
BRAM_PORTA interface (`SINGLE_PORT_BRAM` mode) is designed against a
real, registered Block RAM's actual latency already, not zero.
`tb_shared_ram.vhd` needed updating (its Port B checks assumed an
immediate, ungated read -- added `b_en`+one clock edge before each
one). Full regression green again (`sim/ghdl/run.sh`,
`boards/cora-z7-07s/sim/run.sh`), and the local `tb_prcx18_lutram.vhd`
re-run confirms the real prompt is still reached with this change.
Rebuilding for real hardware now.
