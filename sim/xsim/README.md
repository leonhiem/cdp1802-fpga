# Vivado (xsim) cross-check

Runs the same `tb_cdp18_dump` / `tb_cs1800_dump` testbenches (see
`sim/ghdl/`) on Vivado's simulator instead of GHDL, and diffs the
resulting trace against the golden reference committed under
`sim/ghdl/reference/`. This is a cross-simulator check, not a second
source of truth — the golden reference stays the one GHDL produced.

## Running

```
source <Vivado install>/<version>/settings64.sh   # puts xvhdl/xelab/xsim on PATH
sim/xsim/run.sh             # both designs
sim/xsim/run.sh cdp18       # just tb_cdp18_dump
sim/xsim/run.sh cs1800      # just tb_cs1800_dump
```

Tested with Vivado Simulator v2024.1. Each target: `xvhdl --2008` compiles
the sources (order taken from `hdllib.cfg`) into the default `work`
library, `xelab` elaborates the `*_dump` testbench, `xsim -runall` runs it
to completion, and the script diffs the produced `tb_*_tpb.txt` against
`sim/ghdl/reference/`, printing `PASS`/`FAIL`.

Confirmed bit-for-bit identical to the GHDL reference on both designs.

`run/` (xvhdl/xelab/xsim build products and the freshly generated trace)
is scratch and gitignored.
