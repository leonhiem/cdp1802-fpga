# GHDL reference dump

Purpose: capture a golden trace of the current (pre-FPGA-port) design's bus
activity, so behavior can be diffed against it after the move to the
`cdp1802-fpga` repo.

## Running

```
sim/ghdl/run.sh            # both designs
sim/ghdl/run.sh cdp18      # just tb_cdp18_dump
sim/ghdl/run.sh cs1800     # just tb_cs1800_dump
```

Requires GHDL with the mcode backend (tested with GHDL 4.1.0, `--std=08`).
Analysis order follows `hdllib.cfg`'s `synth_files` list at the repo root.

## What gets dumped

`tb/vhdl/tb_cdp18_dump.vhd` and `tb/vhdl/tb_cs1800_dump.vhd` are standalone
testbenches: same stimulus as `tb_cdp18.vhd` / `tb_cs1800.vhd`, plus a monitor
that writes one line per TPB pulse (sampled at the rising CLOCK edge on which
TPB is high) to `reference/tb_cdp18_tpb.txt` / `reference/tb_cs1800_tpb.txt`:

```
time_ns ram_addr data nMRD nMWR Q SC
```

`ram_addr` and `data` are hex, `nMRD`/`nMWR`/`Q` are '0'/'1', `SC` is a 2-bit
binary state code (00=fetch, 01=execute, 10=DMA, 11=interrupt). `data` reads
as `ZZ` on cycles where the bus isn't being driven (nMRD='1', e.g. an
execute-phase cycle with no memory read).

None of the existing design or testbench files were modified: the internal
signals `ram_addr`, `data`, `nMRD`, `nMWR`, `TPB` (and, for cs1800, `SC`
inside `cs1800_cpu`) are reached from the new testbenches with VHDL-2008
external names (`<< signal ... >>`), declared in a `block` placed after the
DUT instantiation (GHDL requires the referenced instance to already be
elaborated at that point in the architecture).

`reference/*.txt` is the committed golden output. `run/` is scratch
(GHDL work library + fresh copies of the dump) and is gitignored.
