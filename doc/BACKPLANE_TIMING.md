# Backplane timing data for the DE0-Nano module

Everything needed to write the `.sdc` constraints file for the DE0-Nano
module that replaces the CS1800's CPU card, gathered 2026-09-26 so that it
does not have to be re-derived when the module is laid out and the pin
assignments finally exist.

Two halves: **what the real parts require** (from the user's own
datasheets) and **what the core provides at its pins** (measured, not
assumed, by `tb/vhdl/tb_cdp1802_pin_timing.vhd` and
`tb/vhdl/tb_cdp1802_mux_addr.vhd`). The margins fall out of the two, and
every `set_output_delay` is "what the part requires" plus "what the level
translator costs".

All core figures are at **T = 250 ns** (4 MHz, the real CDP1802 clock). A
machine cycle is 8 T = 2000 ns; the initialization cycle after reset is
9 T = 2250 ns.

---

## 1. The parts

### ROM -- 2764-20 EPROM (8K x 8)

| parameter | symbol | value |
|---|---|---|
| address to data | `t_ACC` | max **200 ns** |
| output disable / float after OE high | `t_DF` | max **55 ns** |
| output enable to data | `t_OE` | not yet read for the -20 |
| chip enable to data | `t_CE` | not yet read for the -20 |

The `t_OE` = 150 ns and `t_CE` = 450 ns figures used earlier came from a
**slower** 2764 datasheet and are upper bounds only; the -20's own numbers
scale down with the grade. They were never the binding constraint (the
read window is 625 ns), so reading them exactly was not worth the effort.
`t_DF` was worth it, because turnaround is the tightest path.

### RAM 1 -- FCB61C65L-70

| parameter | symbol | value |
|---|---|---|
| write pulse width | `t_WP` | min 35 ns |
| data setup before end of write | `t_DW` | min 30 ns |
| data hold after end of write | `t_DH` | min 5 ns |
| address setup before write | `t_AS` | min 0 ns |
| address hold / write recovery | `t_WR` | min 0 ns |
| address to data | `t_AA` | max 70 ns |
| output enable to data | `t_OE` | max 35 ns |
| output float after OE high | `t_OHZ` | max 30 ns |
| chip enable to data | `t_ACE` | max 70 ns |

### RAM 2 -- LC3664BL-10

| parameter | symbol | value |
|---|---|---|
| write pulse width | `t_WP` | min 60 ns |
| data setup before end of write | `t_DS` | min 35 ns |
| data hold after end of write | `t_DH` | min 0 ns |
| address setup before write | `t_AS` | min 0 ns |
| address hold / write recovery | `t_WR` | min 0 ns |
| address to data | `t_AA` | max 100 ns |
| output enable to data | `t_OA` | max 50 ns |
| output float after OE high | `t_OOD` | max 30 ns |
| chip enable to data | `t_CA1` | max 100 ns |

LC3664BL-10 is the slower of the two and therefore the binding RAM.

### UART -- CDP1854

| parameter | symbol | value |
|---|---|---|
| CS / RSEL / data valid **after** TPB | `t_TRS` | min 50 ns, **max 75 ns** |

Take the 75 ns as the requirement. This is the tightest *hold* in the
design. The setup side was never in question -- the core gives 1375 ns.

### Level translators -- SN74LVC8T245, VCCA = 3.3 V, VCCB = 5 V

| path | max |
|---|---|
| Port A -> B (FPGA -> backplane) | **4.4 ns** |
| Port B -> A (backplane -> FPGA) | **6.0 ns** |
| nOE -> A | 8.2 ns |
| nOE -> B | **6.8 ns** |

Minima are not specified in the table the user read, so every margin below
assumes **min = 0**, which is deliberately pessimistic: it charges the full
max to one path and nothing to the other. Real channel-to-channel skew
within one device is well under a nanosecond.

---

## 2. What the core provides, measured at its pins

From `sim/ghdl/run.sh pintiming` (`tb_cdp1802_pin_timing.vhd`), which
observes only TPA, TPB, ADDR, DATA, nMRD, nMWR, SC and N -- never a signal
inside the core -- and from `sim/ghdl/run.sh muxaddr`
(`tb_cdp1802_mux_addr.vhd`), whose memory is a real card: 4042 latch on
TPA's trailing edge, live low byte, no `A_full`.

| what | value |
|---|---|
| machine cycle | 2000 ns (init cycle 2250 ns) |
| TPA width | 250 ns, on the clock's falling edges |
| TPB width | 250 ns, on the clock's rising edges, 5.5 T after TPA |
| high address byte held after TPA's trailing edge | 250 ns |
| **read window** (complete address -> data captured) | **625 ns** |
| nMRD low | up to the whole 2000 ns cycle |
| nMWR low (write pulse) | 250 ns |
| CPU data valid before nMWR rises | 875 ns |
| CPU data valid after nMWR rises | 875 ns |
| N valid before TPB rises | 1375 ns |
| N valid after TPB falls | 125 ns |
| **bus turnaround** (nMRD high -> CPU drives, and back) | **125 ns** |

The read window was 125 ns until 2026-09-26; see TODO 2.5 in
`CDP1802_CORE_REVIEW.md` for why it changed and what it broke.

---

## 3. The margins

Each row charges the level translator's full max delay to whichever path
makes the margin worst.

| path | core provides | part requires | crossing | margin |
|---|---|---|---|---|
| read window | 625 ns | 200 ns (`t_ACC`, 2764-20) | 4.4 out + 6.0 back | **415 ns** |
| read window, RAM | 625 ns | 100 ns (`t_AA`, LC3664) | 4.4 + 6.0 | **515 ns** |
| write pulse | 250 ns | 60 ns (`t_WP`, LC3664) | -- | **190 ns** |
| data setup before write end | 875 ns | 35 ns (`t_DS`) | 4.4 | **836 ns** |
| data hold after write end | 875 ns | 5 ns (`t_DH`) | 4.4 | **866 ns** |
| address setup / hold at write | >= 250 ns | 0 ns | 4.4 | ample |
| high address byte after TPA | 250 ns | 4042 latch hold (not read) | 4.4 | 245 ns less the latch's own need |
| **CDP1854 hold after TPB** | 125 ns | 75 ns (`t_TRS`) | 4.4 | **45.6 ns** |
| **bus turnaround** | 125 ns | 55 ns (`t_DF`) | 4.4 | **65.6 ns** |

**Everything clears.** The two tight ones, and why they are tight:

- **CDP1854 hold, 45.6 ns.** TPB, N, CS and the data bus are all CPU
  outputs, so all cross A->B and the common delay cancels; what eats this
  margin is *skew between the TPB path and the N/data paths*. Keeping
  those signals on the same '8T245 where possible makes the real skew
  sub-nanosecond.
- **Bus turnaround, 65.6 ns.** nMRD reaches the ROM in <= 4.4 ns, the ROM
  floats by 59.4 ns, and the core does not drive until 125 ns. This was
  the one path that did not close until the user confirmed the EPROM is a
  **-20** (`t_DF` 55 ns); a slower part's 130 ns would have overlapped by
  a few ns. A second memory card or a different part changes this number,
  which is why every '8T245's `nOE` should reach the FPGA -- see TODO 6.

---

## 4. Writing the .sdc, when the pins exist

Nothing above depends on the pinout, and nothing below can be written
without it. The Cora needs no such file at all: there, the memory and the
CDP1854 are RTL inside the FPGA, so none of these signals reach a pin.

**Approach.** The backplane has no clock of its own that Quartus can see
-- TPA and TPB are FPGA *outputs*. So declare a virtual clock for the
backplane and constrain everything against it:

```tcl
create_clock -name cpu_clk -period 250 [get_ports CLOCK]
create_clock -name backplane_virt -period 250    ;# virtual, no source
```

Then, per signal group:

- **Outputs the backplane samples on TPA or TPB** (ADDR, DATA when the CPU
  drives, N, SC, Q, nMRD, nMWR):
  `set_output_delay -clock backplane_virt -max <part setup + 4.4> [get_ports {...}]`
  `set_output_delay -clock backplane_virt -min <-(part hold) + 4.4> [get_ports {...}]`
- **Inputs** (DATA when the memory drives, EF1-4, nINT, nDMA_IN/OUT,
  nCLEAR, nWAIT): `set_input_delay` with the part's own output delay plus
  the 6.0 ns B->A crossing.
- **The strobes themselves** (TPA, TPB) carry the reference edge, so
  constrain their output delay tightly and keep their skew against the
  data/N groups inside the 45.6 ns of section 3.

**Group the signals by direction before assigning pins.** Each '8T245 has
**one DIR pin for all eight bits**, so a device cannot mix directions.

| group | signals | count | direction |
|---|---|---|---|
| address | MA0-7 | 8 | A->B, DIR fixed |
| data | DATA0-7 | 8 | bidirectional, DIR from `DATA_OE` |
| control out | TPA, TPB, nMRD, nMWR, SC0, SC1, N0, N1, N2, Q | 10 | A->B, DIR fixed |
| control in | nCLEAR, nWAIT, CLOCK, EF1-4, nINT, nDMA_IN, nDMA_OUT | 10 | B->A, DIR fixed |

**That totals 36 lines, and 4 x SN74LVC8T245 gives 32.** Worth resolving
before layout: either a fifth device, or four lines that do not need to
cross -- the likely candidates are CLOCK (if the module generates the
4 MHz itself rather than taking it from the backplane) and nDMA_IN /
nDMA_OUT / one EF if the rack does not use them. Check against the real
backplane pinout in `CS1800_HARDWARE.md`.

---

## 5. Sources

- Part figures: the user's own datasheets, transcribed in `timings.txt`
  (repo root), plus the 2764-20 corrections given 2026-09-26 (`t_ACC`
  200 ns, `t_DF` 55 ns) and the SN74LVC8T245 figures for
  VCCA 3.3 V / VCCB 5 V.
- Core figures: measured by `sim/ghdl/run.sh pintiming` and `muxaddr`,
  both in the quick tier, so they are re-checked on every regression run
  and will not silently drift.
- Reasoning and history: `CDP1802_CORE_REVIEW.md` TODO 2.5 and TODO 6,
  and `boards/cora-z7-07s/BRINGUP_LOG.md` for 2026-09-24 to 26.
