# GHDL reference dump

Purpose: keep a golden trace of the design's bus activity as a regression
baseline for the FPGA port -- when internal logic changes (e.g. removing
tri-state buses -- see below), regenerate this trace and diff it against
the previous one to confirm nothing but the intended thing changed.

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
as `00` on cycles where nobody is driving the bus (nMRD='1', e.g. an
execute-phase cycle with no memory read) -- a defined don't-care, not a
float; see "Removing internal tri-states" below. Nothing in the design ever
legitimately reads `data` on those cycles.

The testbenches themselves reach into the DUT with VHDL-2008 external names
(`<< signal ... >>`) to probe `ram_addr`, `data`, `nMRD`, `nMWR`, `TPB` (and,
for cs1800, `SC` inside `cs1800_cpu`), declared in a `block` placed after the
DUT instantiation (GHDL requires the referenced instance to already be
elaborated at that point in the architecture).

`reference/*.txt` is the committed golden output, regenerated (and
re-committed, with the diff checked) whenever the design intentionally
changes. `run/` is scratch (GHDL work library + fresh copies of the dump)
and is gitignored.

## Removing internal tri-states

The design originally used `std_logic`'s resolved-signal semantics to model
shared buses: several drivers on one signal, each outputting `(others =>
'Z')` when not selected. That's how the real CDP1802 die's internal buses
work, and it simulates fine, but 7-series/Zynq (and Intel) FPGA fabric has
no internal tri-state routing resource -- only real chip pins do. Every
`'Z'` assignment in `src/vhdl/` has been replaced with an explicit mux or
a defined `'0'` default, checked against this reference trace: the only
change anywhere in either trace is `data` going from `ZZ` to `00` on the
155 (cdp18) / 244 (cs1800) cycles where nothing was driving the bus --
every other field, on every other row, is byte-for-byte identical.

`cdp1802`'s `DATA` port changed from a single `INOUT` pin to an explicit
`DATA_IN`/`DATA_OUT`/`DATA_OE` triplet -- the standard, vendor-independent
way to represent a bidirectional pin once it's purely internal wiring
(neither `cdp18` nor `cs1800` ever expose `DATA` at their own boundary, so
this doesn't touch either system's external interface). `cs1800_cpu.vhd`
re-exposes the same triplet since it does expose `DATA` externally.
