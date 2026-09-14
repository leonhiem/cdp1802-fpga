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
