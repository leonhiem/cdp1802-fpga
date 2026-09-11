# Cora Z7-07S bring-up

Goal: run `cs1800` (the CDP1802 core + backplane wrapper) on real silicon,
loading arbitrary programs from PetaLinux over AXI. Proven end to end: a
program written from Linux userspace (`devmem`, not baked into the
bitstream) has run correctly on the board -- see `BRINGUP_LOG.md` for the
full account, including two real bugs found and fixed only by actually
building and testing on hardware (not assumed away in simulation).

## What's here

- `hdl/cs1800_top.vhd` -- wraps `cs1800` (untouched) with a byte-wide
  control/status interface sized for a single AXI GPIO channel pair, a
  free-running `LC` ("line clock") divider defaulting to 50 Hz (the real
  backplane's rate) at `CLOCK` = 25 MHz (see "Clock frequency" below), and
  `shared_ram` for the RAM `cs1800.vhd` no longer carries internally (see
  `src/vhdl/cs1800.vhd`'s own header -- RAM moved external, matching the
  real backplane where RAM lives on separate cards from the CPU card). In
  `tb_cs1800.vhd`, `LC` is a non-synthesizable simulation-only oscillator
  idiom, so the divider here is genuinely new hardware, not a reuse of
  testbench code.
- `hdl/shared_ram.vhd` -- the 4KB memory itself: one port for `cs1800`
  (zero-latency, matching `src/vhdl/ram.vhd`'s proven timing exactly),
  one for the AXI side (`axi_bram_ctrl`'s native BRAM port shape). See
  its own header for why it's sized 4KB and shaped the way it is --
  both are real synthesis constraints found by building it, not
  stylistic choices.
- `sim/tb_cs1800_top.vhd`, `sim/tb_shared_ram.vhd`, `sim/run.sh` -- the
  board-level regression: `tb_cs1800_top` diffs the whole design (through
  `shared_ram`) against the same golden reference `tb_cs1800.vhd` is
  checked against, byte for byte, interrupt choreography included;
  `tb_shared_ram` exercises `shared_ram`'s Port B (AXI-facing) byte-lane
  logic directly, since nothing else does.
- `ps7_config.tcl` -- the `processing_system7` configuration, extracted
  verbatim from `~/fpga/cora_project_bram` (same board, same DDR/clock
  tuning, already proven to boot the 2017.4 PetaLinux image on the SD
  card).
- `build_project.tcl` -- builds the whole project + block design from
  scratch and runs synthesis through bitstream. Run with:
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
reset) for both AXI peripherals:

```
                                         --M00_AXI--> axi_gpio_0
                                        /                gpio_io_o (out, 8b)  -> cs1800_top_0.ctrl_in
processing_system7_0 --M_AXI_GP0--> axi_smc             gpio2_io_i (in, 8b)  <- cs1800_top_0.status_out
                                        \
                                         --M01_AXI--> axi_bram_ctrl_0 --BRAM_PORTA (plain pins)--> cs1800_top_0's shared_ram Port B

FCLK_CLK0 (25 MHz) -> cs1800_top_0.CLOCK (and all the AXI infra's aclk, and axi_bram_ctrl's bram_clk_a implicitly)
```

`axi_gpio_0` at `0x4120_0000` (channel 1 = `GPIO`, control, offset `0x00`;
channel 2 = `GPIO2`, status, offset `0x08`). `axi_bram_ctrl_0` at
`0x4000_0000`, range `0x1_0000` (64KB, matching the real backplane's
2x32K cards) even though `shared_ram` only decodes the low 4KB --
addresses `0x1000`-`0xFFFF` alias onto that same 4KB window (see
`shared_ram.vhd`'s own header for why 4KB).

Control byte (`ctrl_in`, == GPIO channel 1, write):
| bit | meaning |
|---|---|
| 0 | `reset` -- also selects which side may write `shared_ram` (see below) |
| 1 | `halt` |
| 2 | `single` (currently a no-op in `cs1800_cpu.vhd`) |
| 3 | `run` |
| 6:4 | `nEF(2:0)` |
| 7 | unused |

Default output value `0x01` (`reset` asserted) so `cs1800` stays held in
reset from power-up, and `shared_ram`'s AXI side (not `cs1800`) has write
access -- exactly the state a fresh boot needs to load a program before
ever releasing `cs1800` to run.

Status byte (`status_out`, == GPIO channel 2, read):
| bit | meaning |
|---|---|
| 0 | `Q` |
| 1 | `LC` (so a plain `devmem` poll shows something moving, independent of the ILA) |
| 7:2 | reserved (0) |

## Loading a program

While `reset` is asserted (the power-on default), `shared_ram`'s AXI side
has write access. Write words (little-endian, matching AXI byte-lane
order: byte 0 = bits 7:0 = lowest address) into `0x4000_0000` onward,
then release reset and set `run`:

```
devmem 0x40000000 32 0x0001307B   # e.g. addr0=SEQ(0x7B) addr1=BR(0x30) addr2=0x01
devmem 0x41200000 32 0x68         # reset=0, run=1, nEF="110" -- see the control byte table
devmem 0x41200008                 # read status: bit0 = Q
```

## Debug visibility

`ram_addr`/`data`/`nMRD`/`nMWR`/`SC`/`TPB` -- the same six signals
`sim/ghdl/reference/tb_cs1800_tpb.txt` records per TPB pulse -- are
exposed as `dbg_*` output ports on `cs1800.vhd` (see its own header: they
double as the real interface `shared_ram` needs -- address, write-data,
strobes -- so they're not purely a debug-only addition) and wired to a
`system_ila` in the block design, so a captured hardware waveform can be
compared line-for-line against that golden reference.

## Clock frequency

`FCLK_CLK0` runs at 25 MHz here, not `cora_project_bram`'s 100 MHz: this
reverse-engineered gate-level logic was only ever validated at 4 MHz in
simulation and has real dual-edge (TPA/TPB-style) paths needing far more
than a 5 ns half-period budget at 100 MHz (measured ~9.3 ns / 13 logic
levels on the worst path) -- found by actually synthesizing and checking
timing, not assumed. 25 MHz closes cleanly with comfortable margin
(WNS +5.6ns as of the last full build).

## Fixes that came out of building and testing this on real hardware

Two real, reproducible bugs were found this way, neither visible in
simulation -- see `BRINGUP_LOG.md` for the full waveform-level account of
each:

- **`LC`'s edge-detect**: `cs1800_cpu.vhd`'s original interrupt-request
  logic used `falling_edge(LC)` while also reading `LC` as a plain level
  in the same `IF`/`ELSIF` -- synthesis rejects this outright ("clock
  expression not supported"): a signal can't be both an edge-triggered
  clock and an asynchronous data input to the same flip-flop. Rewritten
  as a fully `CLOCK`-synchronous process (register `LC` one cycle,
  compare against the current value). Verified bit-for-bit identical
  against the golden reference.
- **`ram.vhd`'s async-write latches**: synthesized as 2208 individual
  latches (see `src/vhdl/ram.vhd`'s own header), which glitched on real
  silicon in a way RTL simulation can't expose -- two identical
  reset/run cycles landed at two different bogus addresses. Fixed by
  making the write synchronous while keeping the read combinational
  (the standard "distributed RAM" idiom) -- confirmed on hardware:
  address stays within the program's own range, no corruption, 46
  consecutive bus transactions matching the golden reference exactly
  (limited only by `LC` timing not being synchronized between hardware
  and simulation, not by any remaining bug).
