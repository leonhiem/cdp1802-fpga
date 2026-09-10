# cdp1802-fpga

An FPGA port of [cdp1802](https://github.com/leonhiem/cdp1802), a
reverse-engineered VHDL model of the RCA CDP1802 COSMAC microprocessor.

This repo starts as a straight import of `cdp1802` (full history carried
over) at the point where its bus behavior was captured as a golden
reference trace (`sim/ghdl/reference/`, cross-checked against Vivado
xsim). That reference is the regression baseline for this port: any
FPGA-driven change here should still reproduce it, verified with
`sim/ghdl/run.sh` / `sim/xsim/run.sh`.

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

## Repository layout

```
src/vhdl/     the CPU and example systems around it
tb/vhdl/      testbenches
sim/ghdl/     GHDL simulation flow + committed golden reference trace
sim/xsim/     Vivado xsim cross-check against that same golden trace
doc/          original design sketches and simulation screenshots
```

### `src/vhdl/`

| File | Role |
|---|---|
| `cdp1802.vhd` | Top-level CDP1802 entity: every datasheet pin. |
| `control.vhd` | Main state machine: fetch/execute/DMA/interrupt sequencing, TPA/TPB. |
| `instr.vhd` | Instruction decoder/micro-sequencer for the full opcode map. |
| `instr_pkg.vhd` | Opcode encodings for every CDP1802 mnemonic (incl. aliases like `BDF`/`BGE`/`BPZ`). |
| `alu.vhd`, `amux.vhd`, `dmux.vhd` | Datapath: ALU, address mux, data mux (see `doc/dmux_alu_D_.jpg` for the original design sketch). |
| `reg.vhd`, `reg_R.vhd`, `ff.vhd`, `dff.vhd` | Register file and flip-flop primitives. |
| `cdp1802_pkg.vhd` | Shared state-machine and ALU-operation encodings. |
| `cdp18.vhd` | Example system: CDP1802 + RAM + simple I/O, driven directly by the datasheet pins (`nWAIT`, `nCLEAR`, `nINT`, `nDMA_IN`/`OUT`). |
| `cs1800.vhd`, `cs1800_cpu.vhd` | A second top-level wrapper around the same core, driven by simpler system control lines (`reset`/`halt`/`single`/`run`) instead of the raw datasheet handshake; this variant has already been run through Intel Quartus once. |
| `ram.vhd` | RAM containing a small embedded test program that exercises most instructions. |
| `io_inp.vhd`, `io_out.vhd` | Minimal input/output port models. |

### `tb/vhdl/`

- `tb_cdp1802.vhd`, `tb_reg_R.vhd` — unit-level testbenches.
- `tb_cdp18.vhd`, `tb_cs1800.vhd` — system-level testbenches: drive reset,
  run, pause, interrupt and DMA sequences against `cdp18` / `cs1800`.
- `tb_cdp18_dump.vhd`, `tb_cs1800_dump.vhd` — the same stimulus, plus a
  monitor that records `{ram_addr, data, nMRD, nMWR, Q, SC}` on every TPB
  pulse to a text file, without modifying any existing design or
  testbench file (VHDL-2008 external names reach into the DUT). Used by
  `sim/ghdl/` and `sim/xsim/` below.

## Implementation status

- The full CDP1802 instruction set is implemented (`instr_pkg.vhd` defines
  261 opcode constants, covering every mnemonic and its aliases); 74 of
  them are marked `-- tested` against the `ram.vhd` test program.
- The S0/S1/S2/S3 fetch/execute/DMA/interrupt cycle and TPA/TPB timing are
  implemented per the datasheet.
- No outstanding `TODO`/`FIXME` markers in the source.

## Simulating

### ModelSim (original workflow)

```
modelsim_config unb2c -v1
run_modelsim unb2c
```
In ModelSim:
```
lp cdp1802
mk clean
mk all
```
Double click testbench `tb_cdp18.vhd` or `tb_cs1800.vhd`, then:
```
as 10
run 1200us
```
Exit with `quit -sim`.

### GHDL

```
sim/ghdl/run.sh            # both designs
sim/ghdl/run.sh cdp18      # just tb_cdp18_dump
sim/ghdl/run.sh cs1800     # just tb_cs1800_dump
```
Analyzes/elaborates/runs `tb_cdp18_dump` and `tb_cs1800_dump` with GHDL
(`--std=08`) and writes their TPB traces into `sim/ghdl/reference/`, which
is committed as the golden reference for the current design. See
`sim/ghdl/README.md` for the trace format.

### Vivado xsim

```
source <Vivado install>/<version>/settings64.sh   # puts xvhdl/xelab/xsim on PATH
sim/xsim/run.sh
```
Runs the same testbenches on Vivado's simulator and diffs the result
against `sim/ghdl/reference/` — confirmed bit-for-bit identical on both
designs (Vivado 2024.1). See `sim/xsim/README.md`.

## License

MIT

## Status

This is where active development now happens. `cdp1802` stays as the
frozen pre-FPGA reference; FPGA-specific work (board top-levels,
constraints, synthesis/implementation flows) lands here as it's added.
