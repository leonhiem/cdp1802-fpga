# CDP1802 memory bus timing reference

Condensed, VHDL-modeling-oriented reference distilled from the RCA/
Intersil CDP1802A/AC/BC datasheet (local copy: `~/Cdp1802-datasheet.pdf`,
27 pages -- pages 8-9, "Dynamic Electrical Specifications"/"Timing
Specifications"/"Timing Waveforms", `Figure 3. Basic DC Timing
Waveform, One Instruction Cycle`), so the next phase of the
async-vs-synchronous-memory work (see `boards/cora-z7-07s/
BRINGUP_LOG.md`'s "milestone 3k") doesn't need to re-fetch and re-read
the PDF. Written up 2026-09-15 after the user pointed out this is
exactly the mechanism the real CS1800 memory board's schematic already
shows (TPA clocks the high address byte into 4042 latch ICs, straight
off the backplane).

## The address bus is time-multiplexed, 8 bits wide

One machine cycle = 8 `CLOCK` periods, split into two 4-clock halves in
the datasheet's own numbering (`00,01,10,11,20,21,...,70,71` -- each
pair is one `CLOCK` period's two edges): the first half is `FETCH
(READ)`, the second is `EXECUTE (WRITE)`. Both halves have the *same*
internal address-byte shape:

- **`ADDRESS` bus shows the HIGH byte** for roughly the first 1.5
  `CLOCK` periods of the half-cycle.
- **`TPA` pulses once**, right at the HIGH-byte-to-LOW-byte handoff.
  This is the *only* moment the high byte is actually on the bus --
  external hardware (the real memory board's 4042s, this project's own
  `addr_high`/`p_reg_high_addr` process in `cdp18.vhd`/`cs1800.vhd`)
  must latch it right there.
- **`ADDRESS` bus then shows the LOW byte** for the *rest* of that
  half-cycle (roughly 6.5 of the 8 `CLOCK` periods) -- this is also
  when `MRD`/`MWR` are asserted and the actual memory access happens.
- **`TPB` pulses once**, well into the LOW-byte window (around `CLOCK`
  state 6 of 8), well after the datasheet's own required access time
  has elapsed.

## The real hardware access-time budget is generous

- **`tACC` (Required Memory Access Time, Address to Data)**: `5T-250ns`
  typ (`T` = one `CLOCK` period). I.e. a real memory chip gets nearly
  **5 whole `CLOCK` periods** after the low-order address byte is
  valid before the CPU actually needs data back -- not 1, not a handful
  of nanoseconds.
- **High-Order Address Byte Setup to `TPA`↓**: `2T-400ns` typ -- the
  high byte must already be stable *before* `TPA` falls, comfortably
  ahead of the latch moment.
- **High-Order Address Byte Hold after `TPA`↓**: `T/2-15ns` typ -- the
  high byte only needs to stay valid a little past `TPA`, which is
  exactly why a real (or FPGA) latch clocked *by* `TPA` is the right
  primitive, not a plain flip-flop clocked by the free-running
  `CLOCK`.
- **Low-Order Address Byte Hold after `WR`↑**: `T+0ns` typ -- the low
  byte stays valid essentially through the end of the access.

## Why this matters for this project's own memory (LUTRAM/BRAM)

This project's `cs1800.vhd`/`cdp18.vhd` already replicate the
high-byte-latch-on-TPA half of this picture correctly
(`p_reg_high_addr`, matching the real 4042s exactly). The low byte
(`addr`) is a *live*, unlatched reflection of the CPU's internal
address register the whole time, including briefly during the HIGH-
byte phase (before `addr_lohi` switches) -- so the naively-reconstructed
16-bit `ram_addr` genuinely is invalid/meaningless for a short window
every half-cycle, tolerated today only because the read is
combinational (a live value, never latched, so a stale glimpse during
that window is simply never looked at -- see `ram.vhd`'s own header).
A synchronous (Block-RAM, registered) read cannot get away with
sampling `ram_addr` on just any `CLOCK` edge for exactly this reason
(confirmed empirically -- see BRINGUP_LOG.md's "milestone 3k",
`ram_addr` reads back genuinely undefined, not just displayed oddly,
when read unconditionally every edge): it needs to be triggered by (or
otherwise correctly gated on) the point in the cycle the address is
actually settled -- e.g. `TPA`-relative, mirroring the real 4042
latches, or `MRD`/`MWR`-window-relative.

The **5T access-time budget** is also the concrete number behind why
an XDC-constrained, still-combinational approach is plausible too: the
real chip already assumes a memory device can take most of a machine
cycle to respond, so a proper `set_multicycle_path` (or similar)
constraint on this specific address-to-data path, instead of Vivado's
default single-`CLOCK`-period assumption, would let the tool route it
knowing it has that much real margin -- worth trying before or instead
of a full synchronous-memory redesign.
