# Cora Z7-07S bring-up

Goal: prove `cs1800` (the CDP1802 core + backplane wrapper) runs correctly
on real silicon, using its own built-in `ram.vhd` test program -- no
program-loading path needed yet. That comes later (swap `ram.vhd` for a
real dual-port BRAM behind `axi_bram_ctrl`, same shape as
`~/fpga/cora_project_bram`, so PetaLinux can load arbitrary programs).

## What's here

- `hdl/cs1800_top.vhd` -- the only new RTL. Wraps `cs1800` (untouched)
  with a byte-wide control/status interface sized for a single AXI GPIO
  channel pair, and a free-running `LC` ("line clock") divider defaulting
  to 50 Hz (the real backplane's rate) at `CLOCK` = 100 MHz. In
  `tb_cs1800.vhd`, `LC` is a non-synthesizable simulation-only oscillator
  idiom, so this is genuinely new hardware, not a reuse of testbench code.
- `ps7_config.tcl` -- the `processing_system7` configuration, extracted
  verbatim from `~/fpga/cora_project_bram` (same board, same DDR/clock
  tuning, already proven to boot the 2017.4 PetaLinux image on the SD
  card).
- `build_project.tcl` -- builds the whole project + block design from
  scratch and runs synthesis. Run with:
  ```
  source <Vivado install>/2024.1/settings64.sh
  vivado -mode batch -source boards/cora-z7-07s/build_project.tcl
  ```
  Creates the actual Vivado project at `~/fpga/cs1800_bringup` (a sibling
  of `cora_project_bram`, not inside this git repo -- Vivado project trees
  are build output, regenerated from this script, not version-controlled).

## Block design

Same proven shape as `cora_project_bram` (`processing_system7 ->
smartconnect -> <AXI peripheral>`, `proc_sys_reset` for the AXI-side
reset), with `axi_gpio` (dual 8-bit channel) standing in for
`axi_bram_ctrl`, and `cs1800_top` added as an RTL module reference:

```
processing_system7_0 --M_AXI_GP0--> axi_smc --M00_AXI--> axi_gpio_0
                                                             |  gpio_io_o (out, 8b)  -> cs1800_top_0.ctrl_in
                                                             |  gpio2_io_i (in, 8b)  <- cs1800_top_0.status_out
FCLK_CLK0 -> cs1800_top_0.CLOCK (and all the AXI infra's aclk)
```

`axi_gpio_0` at `0x4120_0000` (channel 1 = `GPIO`, control, offset
`0x00`; channel 2 = `GPIO2`, status, offset `0x08`), same `devmem`
workflow as the BRAM project.

Control byte (`ctrl_in`, ==GPIO channel 1, write):
| bit | meaning |
|---|---|
| 0 | `reset` |
| 1 | `halt` |
| 2 | `single` (currently a no-op in `cs1800_cpu.vhd`) |
| 3 | `run` |
| 6:4 | `nEF(2:0)` |
| 7 | unused |

Default output value `0x01` (`reset` asserted) so `cs1800` stays held in
reset from power-up until software explicitly writes a different value --
matching the plan to hold it in reset while (eventually) loading RAM, then
release it to run.

Status byte (`status_out`, == GPIO channel 2, read):
| bit | meaning |
|---|---|
| 0 | `Q` |
| 1 | `LC` (so a plain `devmem` poll shows something moving, independent of the ILA) |
| 7:2 | reserved (0) |

## Debug visibility

No debug ports were added to `cs1800.vhd`/`cs1800_cpu.vhd` -- they stay
exactly "a complete testable microprocessor system" with no board-bring-up
concerns baked in. Instead, `ram_addr`, `data`, `nMRD`, `nMWR`, `TPB` (and
`SC`, inside `cs1800_cpu`) are probed directly by hierarchical path with
Vivado's `mark_debug`/ILA-insertion flow after synthesis -- the same six
signals `sim/ghdl/reference/tb_cs1800_tpb.txt` already records per TPB
pulse, so a captured hardware waveform can be compared line-for-line
against that golden reference.

## A fix that came out of this: LC's edge-detect

`cs1800_cpu.vhd`'s original interrupt-request logic used
`falling_edge(LC)` while also reading `LC` as a plain level in the same
`IF`/`ELSIF` -- synthesis rejects this outright ("clock expression not
supported"): a signal can't be both an edge-triggered clock and an
asynchronous data input to the same flip-flop. Rewritten as a fully
`CLOCK`-synchronous process (register `LC` one cycle, compare against the
current value for a synchronous falling-edge detect). Verified against
the golden reference: bit-for-bit identical, no timing shift at all.
