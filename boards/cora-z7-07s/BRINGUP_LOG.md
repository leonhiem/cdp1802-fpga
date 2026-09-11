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
