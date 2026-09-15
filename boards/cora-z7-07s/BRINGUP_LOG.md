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
