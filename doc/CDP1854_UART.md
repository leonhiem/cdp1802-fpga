# CDP1854 UART reference

The CS1800's serial port is a real CDP1854A/CDP1854AC UART chip (see
`CS1800_HARDWARE.md`), not bit-banged. This is a condensed, VHDL-
modeling-oriented reference distilled from the datasheet (Intersil,
March 1997, File Number 1193.2 -- found at
http://www.cosmacelf.com/publications/data-sheets/cdp1854.pdf), so the
next phase of work doesn't need to re-fetch and re-read the PDF. It's a
good target for RTL modeling: **Mode 1** is a purpose-built,
CDP1800-series-compatible interface with literally zero glue logic
between it and the CPU bus, and underneath that it's a completely
ordinary programmable UART -- nothing here needs gate-level reverse
engineering the way the CPU core did.

## Two modes, only one matters here

- **Mode 0** (`MODE` pin low): generic industry-standard UART
  interface (compatible with the TR1602A/CDP6402), meant for a system
  with its own address-decode glue logic.
- **Mode 1** (`MODE` pin high): wires directly to the CDP1802/CDP1800-
  series bus with no additional components -- `TPB` connects straight
  to the CPU's TPB, `N0`/`N1`/`N2` (or a decode of them) drive the chip
  selects, etc. **This is what the CS1800 uses.** Everything below is
  Mode 1 only.

## Register map (Table 3 in the datasheet)

Two bus-facing register *pairs*, selected by two signals:

| RSEL | RD/`WR` | Selects |
|---|---|---|
| low | low (write) | **Transmitter Holding Register** (load from T BUS) |
| low | high (read) | **Receiver Holding Register** (read onto R BUS) |
| high | low (write) | **Control Register** (load from T BUS) |
| high | high (read) | **Status Register** (read onto R BUS) |

`RD/WR` is the natural signal here: on a real 1802, `OUT` asserts the
write-strobe side (loading Transmitter Holding or Control) and `INP`
asserts the read-strobe side (reading Receiver Holding or Status) --
this falls straight out of the CPU's own `nMRD`/`nMWR` qualified by
`N != 0` during an IO cycle, exactly the way `shared_ram.vhd`'s
Port A already works. `RSEL` is a second, independent address bit that
picks which of the two register pairs within the UART -- **this is very
likely what the extra `Q` line is for** in the CS1800's "N lines + Q"
IO addressing scheme: the N lines (via CS1/`CS2`/CS3, see below) select
*which device* on the backplane, and `Q` selects *which register pair
inside the UART* once it's selected. Worth confirming once the real
ROM's I/O sequences are visible, but it lines up exactly.

Chip select is three pins ANDed together (`CS1 . /CS2 . CS3 = 1`
selects the chip) -- a real board ties some of these to fixed levels
(the datasheet's own recommended non-interrupt-driven hookup, Figure 2,
shows `N0`/`N1`/`N2` and two of the three CS pins tied through simple
switches to `VDD`/`VSS`), so in practice only the number of N-line
combinations actually wired to a variable CS pin determines how many
device codes are available -- consistent with the CS1800 possibly using
only one or two of the three CS pins as the real N-line-driven select
and the rest hardwired.

## Status register (Table 2, read when RSEL=high)

| bit | name | meaning |
|---|---|---|
| 0 | `DA` (Data Available) | a full character has been received into the Receiver Holding Register |
| 1 | `OE` (Overrun Error) | `DA` wasn't cleared before the next character arrived |
| 2 | `PE` (Parity Error) | received parity didn't match the programmed sense |
| 3 | `FE` (Framing Error) | no valid stop bit |
| 4 | `ES` (External Status) | latched level of the `ES` input pin (peripheral status, e.g. modem DCD) |
| 5 | `PSI` (Peripheral Status Interrupt) | a high-to-low edge occurred on the `PSI` input |
| 6 | `TSRE` (Transmitter Shift Register Empty) | shift register finished sending a full character incl. stop bit(s) |
| 7 | `THRE` (Transmitter Holding Register Empty) | holding register's contents moved to the shift register; ready to reload |

## Control register (Table 4, written when RSEL=high)

| bit | name | meaning |
|---|---|---|
| 0 | `PI` (Parity Inhibit) | 1 = no parity bit at all |
| 1 | `EPE` (Even Parity Enable) | 1 = even parity, 0 = odd (ignored if `PI`=1) |
| 2 | `SBS` (Stop Bit Select) | see word-length table below |
| 3 | `WLS1` (Word Length Select 1) | see word-length table below |
| 4 | `WLS2` (Word Length Select 2) | see word-length table below |
| 5 | `IE` (Interrupt Enable) | 1 = `THRE`/`DA`/`THRE.TSRE`/`CTS`/`PSI` conditions can assert `INT` |
| 6 | `BREAK` | 1 = force `SDO` low (transmit break) |
| 7 | `TR` (Transmit Request) | 1 = enable transmitter, asserts `RTS`; **also locks the other 7 bits** until reloaded with `TR`=0 (so a real driver does two writes: one to set format, one to set `TR`) |

Word length / stop bits, selected by bits 4:2 (`WLS2`,`WLS1`,`SBS`):

| WLS2 | WLS1 | SBS | Format |
|---|---|---|---|
| 0 | 0 | 0 | 5 data bits, 1 stop bit |
| 0 | 0 | 1 | 5 data bits, 1.5 stop bits |
| 0 | 1 | 0 | 6 data bits, 1 stop bit |
| 0 | 1 | 1 | 6 data bits, 2 stop bits |
| 1 | 0 | 0 | 7 data bits, 1 stop bit |
| 1 | 0 | 1 | 7 data bits, 2 stop bits |
| 1 | 1 | 0 | 8 data bits, 1 stop bit |
| 1 | 1 | 1 | 8 data bits, 2 stop bits |

## Interrupt behavior (Table 1) -- for matching real ISR polling exactly

`INT` (active low output, feeds the 1802's `nINT` directly) is asserted
by any of these (only once `IE`=1 in the Control Register), and cleared
as shown:

| Cause | Cleared by | When |
|---|---|---|
| `DA` (data received) | read of Receiver Holding Register | TPB leading edge |
| `THRE` (may reload) | read of Status or write of a character | TPB leading edge |
| `THRE . TSRE` (transmitter fully done) | read of Status or write of a character | TPB leading edge |
| `PSI` negative edge | read of Status | TPB trailing edge |
| `CTS` positive edge (while `THRE.TSRE`) | read of Status | TPB leading edge |

Firmware distinguishes *which* condition fired by reading the Status
Register (an `INP` to the RSEL=high/read register pair) and checking
its bits -- it does **not** need separate EF lines to identify the UART
as an interrupt source; the single `INT` -> `nINT` path plus a status
read is self-contained. (EF-line polling, per `CS1800_HARDWARE.md`,
is presumably how *other* devices on the backplane without a dedicated
interrupt pin identify themselves, or how a non-interrupt-driven driver
polls the UART's status bits directly via the `PE/OE`, `FE`, `THRE`,
`DA` pins the datasheet also breaks out individually -- Figure 2 shows
exactly this: those four status pins wired straight to spare `EF`
inputs for a polled, non-interrupt system.)

## Clocking

Both `RCLOCK` (pin 17) and `TCLOCK` (pin 40) need an external clock at
**16x** the desired baud rate -- there's no internal baud-rate
generator (real hardware would use a separate programmable divider
chip, e.g. a CDP1863, driven off the board's oscillator). For the FPGA
model this is just a free-running counter off `CLOCK` producing a
16x-baud tick -- ordinary synthesizable UART technique, not something
that needs the specific rate until the real ROM's baud setting is
known.

## `CLEAR` (async reset)

Active-low. Resets the Interrupt flip-flop, Receiver Holding Register,
Control Register, and Status Register, and forces `SDO` high.

## Suggested VHDL modeling approach

This does **not** need gate-level reverse engineering like the CPU
core -- a standard register-transfer-level UART core is fine, as long
as the register map and Table 1/2/4 semantics above are matched
exactly (that's what real firmware actually depends on). Rough shape,
following this project's existing style (an external, `dbg_*`-like bus
interface rather than literal DIP pins, same pattern as
`shared_ram.vhd`):

- `CLOCK`, `RESET` (`CLEAR`, active-high internally to match the rest
  of this codebase's convention)
- CPU-side: `data_in`/`data_out`/`data_oe`, `cs` (decoded externally
  from whatever N/Q combination the real ROM turns out to use),
  `rsel`, `rd_wr` (or just reuse `nmrd`/`nmwr`+`cs` directly, matching
  how `cs1800.vhd` already exposes those)
- `int_n` out, wired to the core's `nINT` input the same way
  `shared_ram` wires into the RAM interface
- `sdi`/`sdo` (serial in/out), and optionally `cts_n`/`rts_n` if real
  firmware turns out to check them (a plain terminal loopback won't)
- Internal: control register, status bits (computed per Table 1/2),
  tx holding/shift registers + transmit state machine, rx shift/holding
  registers + receive state machine (start-bit detect, mid-bit sampling
  at the 16x tick, parity check), a 16x baud-tick divider.

## Before writing any of this in earnest

Don't guess the real N/Q device code, the control-register value the
real firmware programs at boot (which reveals the actual baud rate and
frame format), or whether the real OS is even interrupt-driven for the
console. All of that will fall straight out of disassembling the
EPROM dump once it arrives (see `CS1800_HARDWARE.md`'s "what to do
once the EPROM dump arrives" section) -- build the address decode and
interrupt wiring from what the disassembly actually shows, not ahead of
it.
