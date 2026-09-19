# cdp1802-fpga

An FPGA port of [cdp1802](https://github.com/leonhiem/cdp1802), a
reverse-engineered VHDL model of the RCA CDP1802 COSMAC microprocessor.
Proven on real hardware: a program written from Linux userspace over AXI
(not baked into the bitstream) has run correctly on a Zynq-7000 board --
see `boards/cora-z7-07s/BRINGUP_LOG.md` for the full account.

This repo started as a straight import of `cdp1802` (full history carried
over) at the point where its bus behavior was captured as a golden
reference trace (`sim/ghdl/reference/`, cross-checked against Vivado
xsim). That reference is the regression baseline for every change made
here: it should still be reproduced (or the difference explained and
verified) after any edit, checked with `sim/ghdl/run.sh` / `sim/xsim/run.sh`.

## Milestone: proven against real historical software

The real, unmodified **PRCX-18 v1.9.0** operating system -- historical
CDP1802 software this core was never designed against, running on the
real CS1800 backplane rack this project is ultimately targeting --
boots correctly under this implementation, all the way to its actual
login prompt, in a GHDL simulation of the full system (CPU + a CDP1854
UART model + a real ROM/RAM memory split, see `doc/PRCX18_ANALYSIS.md`
and `doc/CS1800_HARDWARE.md`). The transmitted serial output is a
byte-for-byte exact match against the boot transcript captured directly
off the real, physical rack.

That's strong, independent proof that the CDP1802 core's reverse-
engineered instruction-set logic is correct -- not just able to run a
synthetic test program, but able to run real, independently-written
historical software exactly as the original chip did. See "Authorship"
below for who did what to get here.

## Overview

This is a gate/register-level re-implementation of the CDP1802, built
directly from the datasheet and user manual rather than a black-box
reinterpretation of its instruction set. The internal architecture mirrors
the real chip: a register file (R0-RF), an ALU, N/I opcode decode, an
address mux (AMUX) and data mux (DMUX) forming the internal data paths, and
a state machine driving the S0 (fetch) / S1 (execute) / S2 (DMA) / S3
(interrupt) machine cycle with its TPA/TPB timing pulses. Timing is close
to the real CDP1802, with a few small documented exceptions.

All pins are implemented per the datasheet, except the XTAL pin.

- Datasheet: https://wiki.techinc.nl/images/5/5f/Cdp1802.pdf
- User manual: http://bitsavers.trailing-edge.com/components/rca/cosmac/MPM-201A_User_Manual_for_the_CDP1802_COSMAC_Microprocessor_1976.pdf
- See also: http://www.cosmacelf.com/

## Getting started

A step-by-step path from a fresh clone to (optionally) a program you wrote
running on real hardware. Each step only needs what the previous one
needed, so stop wherever suits you -- the GHDL step alone requires no
Xilinx tools and no hardware at all.

### Prerequisites

- **GHDL** with VHDL-2008 support (tested with GHDL 4.1.0, mcode backend).
  This is the fast, everyday simulator -- no license, no GUI.
- **Xilinx Vivado 2024.1** (or close to it), for the Vivado Simulator
  (`xsim`) cross-check and for anything under `boards/`. Needed only from
  step 3 onward.
- For the Cora Z7-07S hardware steps specifically: a Digilent Cora Z7-07S
  board with a Linux image on its SD card (this was built against a
  PetaLinux 2017.4 image) reachable over USB (JTAG + UART) and/or Ethernet;
  and the [Digilent board files](https://github.com/Digilent/vivado-boards)
  cloned locally with Vivado's `board.repoPaths` pointed at their
  `new/board_files` directory (e.g. in `~/.Xilinx/Vivado/init.tcl`):
  ```tcl
  set_param board.repoPaths [list "/path/to/vivado-boards/new/board_files"]
  ```

### 1. Clone

```
git clone git@github.com:leonhiem/cdp1802-fpga.git
cd cdp1802-fpga
```

### 2. Run the GHDL simulation

```
sim/ghdl/run.sh
```

This analyzes, elaborates, and runs `tb_cdp18_dump` and `tb_cs1800_dump`
(a few hundred microseconds of simulated CDP1802 execution each, done in
well under a second), and writes their bus traces into
`sim/ghdl/reference/`. Those files are already committed as the golden
reference, so on an unmodified checkout this is a no-op: `git status`
should show nothing changed. That's the actual point of the script --
after editing anything under `src/vhdl/`, re-run it and `git diff
sim/ghdl/reference/` to see exactly what changed, if anything. See
`sim/ghdl/README.md` for the trace format.

### 3. Cross-check with Vivado xsim

```
source <Vivado install>/2024.1/settings64.sh   # puts xvhdl/xelab/xsim on PATH
sim/xsim/run.sh
```

Runs the same testbenches on Vivado's simulator and diffs the result
against `sim/ghdl/reference/`, printing `PASS`/`FAIL`. Confirmed
bit-for-bit identical on both designs. See `sim/xsim/README.md`.

### 4. Build and run on the Cora Z7-07S

Everything below lives under `boards/cora-z7-07s/`; its own `README.md`
and `BRINGUP_LOG.md` have the full reference and the story of what was
found along the way. This is the condensed, do-it-now version.

**Build the project and bitstream** (a few minutes; creates the actual
Vivado project as a sibling directory, `~/fpga/cs1800_bringup`, not inside
this repo -- Vivado project trees are build output, regenerated from this
script, not version-controlled):
```
source <Vivado install>/2024.1/settings64.sh
vivado -mode batch -source boards/cora-z7-07s/build_project.tcl
```

**Program the board** (needs it connected over USB):
```
vivado -mode batch -source boards/cora-z7-07s/program.tcl
```

**Control it.** The design exposes two memory-mapped regions to the ARM
cores, both `devmem`-accessible from Linux on the board:

| Address | What |
|---|---|
| `0x4120_0000` | control (write) / status (read) byte -- see table below |
| `0x4000_0000` | the CDP1802's RAM (4KB), for loading a program |

Control byte, at `0x4120_0000` (defaults to `0x01` on power-up, holding
the CPU in reset so its RAM's write access starts out belonging to
software, not the CPU):

| bit | meaning |
|---|---|
| 0 | `reset` (also selects who may write the RAM: `1`=software, `0`=the CPU) |
| 1 | `halt` |
| 3 | `run` |
| 6:4 | `nEF(2:0)` (external flag inputs) |

Status byte, at `0x4120_0008`: bit 0 = `Q`, bit 1 = `LC`.

**Load and run a program**, from a shell on the board (while `reset` is
still asserted, i.e. right after power-up, before writing anything else
to the control byte):
```
devmem 0x40000000 32 0x0001307B   # example: SEQ (sets Q=1), then BR back to itself
devmem 0x41200000 32 0x68         # reset=0, run=1, nEF="110"
devmem 0x41200008                 # read status back -- bit 0 (Q) should be 1
```
Programs are loaded 32 bits (4 bytes) at a time, little-endian: the byte
at the lowest address goes in bits 7:0 of the word.

## Testing

Three layers, from seconds to real silicon. Why each exists and what it
can and cannot catch is explained in `doc/CDP1802_CORE_REVIEW.md`
("How the regression testing works"). Run layers 1 and 2 after every
change to `src/vhdl/`. Run layer 3 before trusting a new bitstream.

### Layer 1: golden-reference regression (seconds, no ROM, no hardware)

```
sim/ghdl/run.sh                  # cdp18/cs1800 bus traces + memory/console assertion tests
git diff --stat sim/ghdl/reference/
boards/cora-z7-07s/sim/run.sh    # board-level wrapper against the same reference
source <Vivado install>/2024.1/settings64.sh && sim/xsim/run.sh   # optional: same on Vivado xsim
```

Pass = every script prints `PASS` and `git diff sim/ghdl/reference/` is
empty. If the reference *does* change, the diff shows exactly which bus
cycles changed (`time addr data nMRD nMWR Q SC`, one line per TPB).
Only commit the new reference once you've explained every changed line.
For example, the SHRC/SHLC fix legitimately changed four lines.

### Layer 2: real-ROM lockstep check (~10 minutes, needs your ROM dump)

```
boards/cora-z7-07s/sim/run_prcx18_lockstep.sh /path/to/prcx18.bin
```

This boots the real PRCX-18 (8 KB EPROM image, not in this repo) on
the Cora design in GHDL, with LC at 50 Hz. It types `DMP<CR>` at the
prompt and drains the output slowly, as the board does. Then
`boards/cora-z7-07s/lockstep1802.py` checks every machine cycle against an
independent CDP1802 instruction-set model. Pass looks like:

```
done: 2xxxxx instructions, NN interrupts, NN phantom S3 (IE=0), 0 mismatches
...
PASS: 0 lockstep mismatches, full DMP output and closing prompt
```

On a mismatch it prints the failing check and the 25 instructions
before it, with P, X, D, DF, IE and R(X) at each step, for example:

```
*** MISMATCH #1 at cycle 209752: STXD: expected write M(5FF6)<=80, got M(5FF6)<=00
      5CD7: 76  P=1 X=2 D=00 DF=1 IE=0 R2=5FF6    <- SHRC with DF=1 should give 0x80
```

Output files are in `boards/cora-z7-07s/sim/run_lockstep/` (gitignored):
`cyc.log` (the cycle log), `lockstep.txt`, and `console.txt` (what the
console printed). The generated ROM package is placed there too, so it
never ends up in git. You can also run the checker on any cycle log
yourself: `python3 boards/cora-z7-07s/lockstep1802.py <rom.bin> <cyc.log> [max_errors]`.

### Layer 3: on the Cora Z7-07S

Use the PRCX-18 design (`build_project_prcx18.tcl`), not the older
`build_project.tcl` shown in "Getting started". From the host:

```
source <Vivado install>/2024.1/settings64.sh
vivado -mode batch -source boards/cora-z7-07s/build_project_prcx18.tcl   # ~10 min
# on the board first: make sure no old devmem loops are running,
#   ps | grep -E "devmem|interactive"   -- reprogramming under one can hang the board
vivado -mode batch -source boards/cora-z7-07s/program_prcx18.tcl
python3 boards/cora-z7-07s/gen_load_prcx18_rom.py /path/to/prcx18.bin > /tmp/load.sh
scp /tmp/load.sh boards/cora-z7-07s/interactive_console.sh root@<board>:/tmp/
```

(The board's SSH server needs `-o HostKeyAlgorithms=+ssh-rsa -o
PubkeyAcceptedAlgorithms=+ssh-rsa` with current OpenSSH.) Then on the board:

```
sh /tmp/load.sh                       # holds reset, loads the ROM, starts the CPU with LC running
sh /tmp/interactive_console.sh        # live console; exit with Ctrl-]  (0x48 as argument = LC off)
```

The ROM lives in Block RAM loaded at runtime, not in the bitstream, so
repeat `load.sh` after every reprogram or power cycle. The board runs
from a ramdisk, so `/tmp` is empty after a power cycle.

Expected session (compare with the real CS1800):

```
Dutch 1800 MicroProUsers
CS1800/PRCX-18    V1.9.0

-SYS-Starting Console Task-
_08>                      <CR> gives a new _08> prompt
_08> TSKL                 task list: System 00, Console 08, TSKL 10
_08> DMP                  16 lines, 4000-40F0, then _08>
```

Things to check: exactly one "Starting Console Task", the prompt stays
`_08>` (no `_10>`, `_18>` or `^@` appearing by itself, even after
minutes with LC on), and long output such as `DMP` completes with a
closing prompt. Output arrives at ~35 characters/s because of the devmem
bridge; that is expected.

## Repository layout

```
src/vhdl/              the CPU and example systems around it
tb/vhdl/               testbenches
sim/ghdl/              GHDL simulation flow + committed golden reference trace
sim/xsim/              Vivado xsim cross-check against that same golden trace
boards/cora-z7-07s/    Zynq board bring-up: block design, RTL glue, hardware log
doc/                   original design sketches and simulation screenshots
```

### `src/vhdl/`

| File | Role |
|---|---|
| `cdp1802.vhd` | Top-level CDP1802 entity: every datasheet pin (`DATA` is an `IN`/`OUT`/output-enable triplet, not a single `INOUT` pin -- see "FPGA porting notes" below). |
| `control.vhd` | Main state machine: fetch/execute/DMA/interrupt sequencing, TPA/TPB. |
| `instr.vhd` | Instruction decoder/micro-sequencer for the full opcode map. |
| `instr_pkg.vhd` | Opcode encodings for every CDP1802 mnemonic (incl. aliases like `BDF`/`BGE`/`BPZ`). |
| `test_program_pkg.vhd` | The instruction sequence exercising most of the instruction set, shared by `ram.vhd` and the board's `shared_ram.vhd` so there's one copy to keep in sync, not several. |
| `alu.vhd`, `amux.vhd`, `dmux.vhd` | Datapath: ALU, address mux, data mux (see `doc/dmux_alu_D_.jpg` for the original design sketch). |
| `reg.vhd`, `reg_R.vhd`, `ff.vhd`, `dff.vhd` | Register file and flip-flop primitives. |
| `cdp1802_pkg.vhd` | Shared state-machine and ALU-operation encodings. |
| `cdp18.vhd` | Example system: CDP1802 + RAM + simple I/O, driven directly by the datasheet pins (`nWAIT`, `nCLEAR`, `nINT`, `nDMA_IN`/`OUT`). |
| `cs1800.vhd`, `cs1800_cpu.vhd` | A second top-level wrapper around the same core, driven by simpler system control lines (`reset`/`halt`/`single`/`run`) instead of the raw datasheet handshake, and matching the real backplane in one more way: `cs1800.vhd`'s RAM is external (its own ports, not an internal instance), since on the real rack RAM lives on separate cards from the CPU card. This variant has already been run through Intel Quartus once, and is the one proven end-to-end on the Cora Z7-07S. |
| `ram.vhd` | Single-port RAM (used by `cdp18.vhd`, and externally by `cs1800`'s own testbenches), pre-loaded from `test_program_pkg.vhd`. |
| `io_inp.vhd`, `io_out.vhd` | Minimal input/output port models. |
| `cs1800_memory.vhd` | The real backplane's memory map: a read-only boot EPROM region plus plain RAM above it (content-agnostic -- see `doc/CS1800_HARDWARE.md`'s "Memory map"). |
| `cdp1854.vhd` | Register-level model of the SIO board's real CDP1854 UART (see `doc/CDP1854_UART.md`). |
| `cs1800_io_select.vhd` | The SIO board's `OUT 1` port/register-select latch (see `doc/PRCX18_ANALYSIS.md`). |
| `cs1800_console.vhd` | Wraps `cs1800` with the memory map and UART pair above into the full system that boots real PRCX-18 firmware -- see the milestone at the top of this file. |

### `tb/vhdl/`

- `tb_cdp1802.vhd`, `tb_reg_R.vhd` — unit-level testbenches.
- `tb_cdp18.vhd`, `tb_cs1800.vhd` — system-level testbenches: drive reset,
  run, pause, interrupt and DMA sequences against `cdp18` / `cs1800`
  (`tb_cs1800.vhd` wires up an external `ram.vhd` instance, matching how
  `cs1800.vhd`'s RAM is no longer internal).
- `tb_cdp18_dump.vhd`, `tb_cs1800_dump.vhd` — the same stimulus, plus a
  monitor that records `{ram_addr, data, nMRD, nMWR, Q, SC}` on every TPB
  pulse to a text file, without modifying any existing design or
  testbench file (VHDL-2008 external names reach into the DUT). Used by
  `sim/ghdl/` and `sim/xsim/` below.

### `boards/cora-z7-07s/`

The Zynq board bring-up: `hdl/cs1800_top.vhd` (the board-specific
top-level, wrapping `cs1800` with a control/status interface and the RAM
it now needs externally) and `hdl/shared_ram.vhd` (that RAM: one port for
the CPU, one for Linux to load programs through), `build_project.tcl` /
`program.tcl` (build and program the Vivado project), and its own
`sim/run.sh` regression. See its `README.md` for the full design
reference and `BRINGUP_LOG.md` for the hardware bring-up log, including
two real bugs found only by testing on real silicon.

## Implementation status

- The full CDP1802 instruction set is implemented (`instr_pkg.vhd` defines
  261 opcode constants, covering every mnemonic and its aliases); 74 of
  them are marked `-- tested` against `test_program_pkg.vhd`'s test
  program.
- The S0/S1/S2/S3 fetch/execute/DMA/interrupt cycle and TPA/TPB timing are
  implemented per the datasheet.
- Proven on real Zynq-7000 hardware (Cora Z7-07S): a program written from
  Linux userspace, not baked into the bitstream, has run correctly --
  see `boards/cora-z7-07s/BRINGUP_LOG.md`.
- Proven against real historical CDP1802 software, not just the
  synthetic test program: the real PRCX-18 v1.9.0 operating system
  boots to its prompt and runs interactive commands (`TSKL`, `DMP`) on
  the Cora Z7-07S, with the 50 Hz LC interrupt running, matching the
  real CS1800 -- see the milestone at the top of this file and
  `doc/PRCX18_ANALYSIS.md`.
- Running PRCX-18 found two real bugs in the core, both fixed: INP did
  not load D, and SHRC/SHLC ignored DF. It also found one remaining
  difference from the real chip (an S3 cycle with IE=0). An independent
  lockstep model now checks every instruction PRCX-18 executes. Details,
  open TODOs and the test plan are in `doc/CDP1802_CORE_REVIEW.md`.

## FPGA porting notes

### Removing internal tri-states

The original design used `std_logic`'s resolved-signal semantics to model
shared buses -- several drivers on one signal, each outputting `(others =>
'Z')` when not selected -- mirroring how the real CDP1802 die's internal
buses work. That simulates fine, but FPGA fabric (Xilinx 7-series/Zynq and
Intel alike) has no internal tri-state routing resource, only real chip
pins do. Every `'Z'` in `src/vhdl/` has been replaced with an explicit mux
or a defined `'0'` default, verified against the golden reference trace
(see `sim/ghdl/README.md`): the only change in either trace is `data`
going from `ZZ` to `00` on cycles where nothing was driving the bus --
every other field, on every other row, is byte-for-byte identical.

As part of this, `cdp1802`'s `DATA` port changed from a single `INOUT` pin
to an explicit `DATA_IN`/`DATA_OUT`/`DATA_OE` triplet -- the standard,
vendor-independent way to represent a bidirectional pin once it's purely
internal wiring. Neither `cdp18` nor `cs1800` ever expose `DATA` at their
own boundary, so this doesn't touch either system's external interface;
`cs1800_cpu.vhd`, which does re-expose `DATA`, carries the same triplet.

### Real hardware found real bugs simulation couldn't

Two of them, both only visible once actual silicon ran actual timing --
full waveform-level accounts in `boards/cora-z7-07s/BRINGUP_LOG.md`:

- `ram.vhd`'s original async-write logic synthesized as 2208 individual
  latches, which glitched on real hardware in a way RTL simulation can't
  expose (identical reset/run cycles landed at different bogus
  addresses). Fixed by making the write synchronous while keeping the
  read combinational -- the standard "distributed RAM" idiom.
- `cs1800_cpu.vhd`'s interrupt-request logic mixed an edge-detect and a
  level-check on the same signal (`LC`) -- illegal for synthesis ("a
  signal can't be both a clock and async data to the same flip-flop"),
  though GHDL/Vivado's VHDL-2008 simulation mode never objected.

Both fixes verified bit-for-bit identical against the golden reference
before being trusted on hardware again.

## Authorship

The CDP1802 core itself -- the reverse-engineered instruction-set logic
(opcode decode, state machine, ALU, register file) -- is entirely Leon
Hiemstra's own work, built instruction by instruction against the
datasheet in the original [cdp1802](https://github.com/leonhiem/cdp1802)
repo starting in 2021. The milestone at the top of this file is
independent proof that work is correct.

Everything in this FPGA port -- removing the internal tri-state ('Z')
buses and the two further synthesis fixes found only through real
hardware bring-up (see "FPGA porting notes" above), the golden-reference
testbench simulation methodology, the CDP1854 UART model and memory
split that made the PRCX-18 milestone possible, and the Cora Z7-07S
hardware bring-up -- was done by Claude (Anthropic), directed and
guided by Leon throughout.

## License

MIT

## Status

This is where active development happens. `cdp1802` stays as the frozen
pre-FPGA reference. The Cora Z7-07S bring-up (`boards/cora-z7-07s/`) has
gone from "does it synthesize" to "a program loaded from Linux runs
correctly on real hardware" to "the real PRCX-18 OS boots correctly in
simulation" in one sustained push. Next up: bring the CDP1854 UART model
and ROM/RAM memory split to the Cora Z7-07S hardware itself, with the
goal of seeing PRCX-18's actual interactive prompt live over serial from
within the Cora's PetaLinux environment -- and eventually swapping this
in for the CPU card in the real CS1800 backplane rack.
