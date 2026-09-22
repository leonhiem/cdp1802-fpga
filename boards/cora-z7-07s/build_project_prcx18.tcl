#
# Build the CS1800+PRCX-18 hardware bring-up project: PS7 + AXI GPIO
# (control/status, and a second one for the CDP1854 console's TX/RX) +
# AXI BRAM Controller (ROM+RAM loading, via cs1800_prcx18_memory's
# Port B) + cs1800_prcx18_top (cs1800, unmodified, plus the LC divider,
# the real ROM+RAM split, and one CDP1854 on port A).
#
# Extends build_project.tcl's exact proven shape (same PS7 config,
# same AXI infrastructure) -- see that file's own comments for what's
# unchanged. The differences: cs1800_prcx18_top instead of cs1800_top,
# cs1800_prcx18_memory.vhd instead of shared_ram.vhd, and a second AXI
# GPIO (axi_gpio_1) for the UART's TX/RX bytes.
#
# Usage:
#   source /path/to/Vivado/2024.1/settings64.sh
#   vivado -mode batch -source build_project_prcx18.tcl
#
set proj_dir  "/mnt/hd/2/leon/fpga/cs1800_prcx18_bringup"
set proj_name "cs1800_prcx18_bringup"
set part      "xc7z007sclg400-1"
set board     "digilentinc.com:cora-z7-07s:part0:1.1"

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize "$script_dir/../.."]

create_project $proj_name $proj_dir -part $part -force
set_property board_part $board [current_project]
set_property target_language VHDL [current_project]

# ---------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------
set src_files {
  src/vhdl/cdp1802_pkg.vhd
  src/vhdl/instr_pkg.vhd
  src/vhdl/test_program_pkg.vhd
  src/vhdl/dff.vhd
  src/vhdl/ff.vhd
  src/vhdl/reg.vhd
  src/vhdl/amux.vhd
  src/vhdl/dmux.vhd
  src/vhdl/alu.vhd
  src/vhdl/reg_R.vhd
  src/vhdl/control.vhd
  src/vhdl/instr.vhd
  src/vhdl/cdp1802.vhd
  src/vhdl/ram.vhd
  src/vhdl/io_out.vhd
  src/vhdl/io_inp.vhd
  src/vhdl/cs1800_cpu.vhd
  src/vhdl/cs1800.vhd
  src/vhdl/cdp1854.vhd
  src/vhdl/cs1800_io_select.vhd
  boards/cora-z7-07s/hdl/byte_fifo.vhd
  boards/cora-z7-07s/hdl/cs1800_prcx18_memory.vhd
  boards/cora-z7-07s/hdl/cs1800_prcx18_top.vhd
}
set add_paths {}
foreach f $src_files { lappend add_paths "$repo_root/$f" }
add_files -norecurse $add_paths
update_compile_order -fileset sources_1

# ---------------------------------------------------------------------
# Block design
# ---------------------------------------------------------------------
create_bd_design "system"

set processing_system7_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
source "$script_dir/ps7_config.tcl"

# Real CS1800 CPU clock confirmed by the user directly (2026-09-17):
# 4MHz, not 25MHz -- testing whether PRCX-18's receive-polling logic
# depends on real elapsed-time-calibrated software delay loops (not
# just the CDP1854's own DA flag), which would desync at 6.25x the
# real speed regardless of how correct the electrical DA/RSEL/nINT
# modeling is otherwise. See BRINGUP_LOG.md's "keystroke injection"
# entries for the full investigation that led here.
set_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {4} $processing_system7_0

set rst_ps7_0_100M [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps7_0_100M]
set axi_smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc]
set_property CONFIG.NUM_SI {1} $axi_smc
set_property CONFIG.NUM_MI {3} $axi_smc

# --- AXI GPIO 0: control/status, exactly as build_project.tcl's ---
set axi_gpio_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_0]
set_property -dict [list \
  CONFIG.C_GPIO_WIDTH {8} \
  CONFIG.C_ALL_OUTPUTS {1} \
  CONFIG.C_DOUT_DEFAULT {0x00000001} \
  CONFIG.C_IS_DUAL {1} \
  CONFIG.C_GPIO2_WIDTH {8} \
  CONFIG.C_ALL_INPUTS_2 {1} \
] $axi_gpio_0

# --- AXI GPIO 1: CDP1854 port A TX/RX ---
#   channel 1 (all outputs) -> cs1800_prcx18_top's uart_rx_data/available
#     bit 7:0 = rx_data, bit 8 = rx_available
#   channel 2 (all inputs)  <- cs1800_prcx18_top's uart_tx_data/valid
#     bit 7:0 = tx_data, bit 8 = tx_valid
set axi_gpio_1 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_1]
set_property -dict [list \
  CONFIG.C_GPIO_WIDTH {9} \
  CONFIG.C_ALL_OUTPUTS {1} \
  CONFIG.C_DOUT_DEFAULT {0x00000000} \
  CONFIG.C_IS_DUAL {1} \
  CONFIG.C_GPIO2_WIDTH {9} \
  CONFIG.C_ALL_INPUTS_2 {1} \
] $axi_gpio_1

# --- AXI BRAM Controller: cs1800_prcx18_memory's Port B ---
set axi_bram_ctrl_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 axi_bram_ctrl_0]
set_property CONFIG.SINGLE_PORT_BRAM {1} $axi_bram_ctrl_0

# --- cs1800_prcx18_top: our RTL, as a module reference ---
set cs1800_prcx18_top_0 [create_bd_cell -type module -reference cs1800_prcx18_top cs1800_prcx18_top_0]
# 50 Hz LC at CLOCK = 4 MHz (real speed, see the CLOCK freq change
# above) -- half period = 4,000,000 * 0.01s = 40,000 cycles.
set_property CONFIG.g_lc_half_period {40000} $cs1800_prcx18_top_0
# g_ram_words bumped to 16384 (64KB) 2026-09-18 -- see
# cs1800_prcx18_memory.vhd's header for the RAM-aliasing story this
# fixes: with the previous 2048-word (8KB) size, only address bits
# [12:2] were used to index RAM, so 0x2000/0x6000/0xA000/0xE000-based
# addresses sharing the same low bits (e.g. 0x3BD0/0x7BD0/0xBBD0/0xFBD0)
# all aliased onto the same physical byte -- a real, confirmed bug: the
# real PRCX-18 ROM uses high memory addresses (e.g. 0xFBD0, apparently
# a per-task "is this task already running" flag) as if it had the
# real machine's full, distinct 64KB address space, and unrelated code
# writing to an aliased low address was silently clobbering it,
# spuriously re-triggering "-SYS-Starting Console Task-" respawns. This
# note above is now stale re: a LUT-budget concern from an earlier
# session (milestone 3m) that predates this design's move to real
# Block RAM inference -- BRAM capacity on this device is not remotely
# the constraint an 8-16KB choice was earlier. 16384 words = 64KB is
# the smallest power of two that keeps address bit 15 significant in
# the RAM index, eliminating this class of aliasing entirely (matches
# Port B's own native 16-bit ram_b_addr width exactly, so no address
# is left unreachable either way).
#
# UPDATE 2026-09-18, same day: 16384 words (64KB) does NOT fit this
# device -- place_design failed with "RAMB36/FIFO over-utilized...
# requires 80 of such cell types but only 50 compatible sites are
# available" (XC7Z007S only has 50 RAMB36 tiles total). Tried 8192
# words (32KB) next -- that fits and synthesizes/implements cleanly
# (0 errors, timing closes with WNS=26.983ns), and the real ROM content
# verified correct after loading -- but the real CPU (Port A, native,
# bypasses axi_bram_ctrl entirely) hangs at a fixed address on real
# hardware after 90+ seconds, while GHDL simulation at the exact same
# g_ram_words=8192 runs the full 5ms boot cleanly with zero issues -- a
# real-hardware-only symptom (most likely a genuine BRAM-primitive-
# cascading glitch specific to this size, not caught by behavioral
# simulation) that wasn't root-caused before the user asked to step
# back to the real machine's own documented minimal configuration
# instead: 8KB ROM + 8KB RAM (2048 words), the exact size this whole
# port already used successfully for the entire rest of this session.
# The 0xFBD0-class RAM aliasing bug this size still has is a known,
# real, currently-unfixed issue -- revisit if a way to safely grow RAM
# is found (e.g. freeing BRAM elsewhere, like the ILA's DATA_DEPTH, or
# understanding/avoiding whatever the 32KB hang's real cause is).
set_property CONFIG.g_ram_base_addr {8192} $cs1800_prcx18_top_0
set_property CONFIG.g_ram_words {6144} $cs1800_prcx18_top_0

# --- Bit-slice/concat glue for axi_gpio_1's two 9-bit channels: get_bd_pins'
# own [n:m] bit-range syntax collides with Tcl's own bracket parsing when
# nested inside another [get_bd_pins ...] call, so use the standard
# xlslice/xlconcat utility IP instead (guaranteed to work regardless).
set u_rx_data_slice [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 u_rx_data_slice]
set_property -dict [list CONFIG.DIN_WIDTH {9} CONFIG.DIN_FROM {7} CONFIG.DIN_TO {0} CONFIG.DOUT_WIDTH {8}] $u_rx_data_slice
set u_rx_avail_slice [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 u_rx_avail_slice]
set_property -dict [list CONFIG.DIN_WIDTH {9} CONFIG.DIN_FROM {8} CONFIG.DIN_TO {8} CONFIG.DOUT_WIDTH {1}] $u_rx_avail_slice
set u_tx_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 u_tx_concat]
set_property -dict [list CONFIG.NUM_PORTS {2} CONFIG.IN0_WIDTH {8} CONFIG.IN1_WIDTH {1}] $u_tx_concat

# --- Debug: system_ila on ram_addr/data/nMRD/nMWR/SC/TPB ---
set u_ila_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila:1.1 u_ila_0]
set_property CONFIG.C_MON_TYPE {NATIVE} $u_ila_0
set_property CONFIG.C_NUM_OF_PROBES {21} $u_ila_0
set_property -dict [list \
  CONFIG.C_DATA_DEPTH {4096} \
  CONFIG.C_PROBE0_WIDTH {16} \
  CONFIG.C_PROBE1_WIDTH {8} \
  CONFIG.C_PROBE2_WIDTH {1} \
  CONFIG.C_PROBE3_WIDTH {1} \
  CONFIG.C_PROBE4_WIDTH {2} \
  CONFIG.C_PROBE5_WIDTH {1} \
  CONFIG.C_PROBE6_WIDTH {8} \
  CONFIG.C_PROBE7_WIDTH {16} \
  CONFIG.C_PROBE8_WIDTH {1} \
  CONFIG.C_PROBE9_WIDTH {1} \
  CONFIG.C_PROBE10_WIDTH {16} \
  CONFIG.C_PROBE11_WIDTH {16} \
  CONFIG.C_PROBE12_WIDTH {1} \
  CONFIG.C_PROBE13_WIDTH {1} \
  CONFIG.C_PROBE14_WIDTH {16} \
  CONFIG.C_PROBE15_WIDTH {8} \
  CONFIG.C_PROBE16_WIDTH {8} \
  CONFIG.C_PROBE17_WIDTH {1} \
  CONFIG.C_PROBE18_WIDTH {16} \
  CONFIG.C_PROBE19_WIDTH {8} \
  CONFIG.C_PROBE20_WIDTH {8} \
] $u_ila_0
# probe0=ram_addr probe1=data probe2=nMRD probe3=nMWR probe4=SC probe5=TPB
# probe6=tmp_page probe7=R_in probe8=forceS1 probe9=extraS1 probe10=R(A)
# probe11=R(B) -- added 2026-09-15 (BRINGUP_LOG.md's "milestone 3n") to
# chase a real-hardware-only hang in PRCX-18's own ROM checksum/RAM-
# sizing loop; see cs1800_prcx18_top.vhd's/reg_R.vhd's own notes on
# these dbg_* ports.
# probe12=Q probe13=nEF2 probe14=R(1) -- added 2026-09-16 (BRINGUP_LOG.md's
# "keystroke injection, third attempt", per the user's own request) to
# directly confirm whether an injected keystroke's DA condition reaches
# EF2 (gated on Q) and whether the CPU actually takes the interrupt
# (jumps through R(1), the CDP1802's fixed interrupt-vector register).
# probe15=cdp1854 control_reg probe16=cdp1854 status_reg -- added
# 2026-09-16 ("keystroke injection, fourth attempt") to measure IE
# (probe15 bit5) and DA (probe16 bit0) directly on real hardware,
# rather than continuing to infer IE's value from disassembly alone.
# probe17=RSEL -- added 2026-09-17, per the user's own oscilloscope
# measurement on the real backplane finding RSEL dips correlated with
# real keystrokes while nINT never pulses (a real, polling-based
# receive-path access) -- checks whether this design's own software
# reaches the same code path.
# probe18=A_full (the CPU's real internal address, not the old
# TPA-multiplexed dbg_ram_addr/probe0 reconstruction) -- added
# 2026-09-18: address-based ILA triggers/traces (hunting for the real
# receive handler around 0x1000/0x1017) need reliable addressing;
# probe0 has known multiplexing artifacts (see
# cs1800_prcx18_memory.vhd's header).
# probe19=D (the CPU's internal accumulator, cdp1802.vhd's D_out) --
# added 2026-09-18: chasing why ANI 01 / BZ 0x29 at 0x100D/0x100F still
# takes the "skip" branch even though INP4's own M(R(X)) write
# side-effect and dbg_uart_status both show 0xC1 (DA=1) right after
# 0x1008 -- D itself has never been observed directly before this,
# only inferred.
# probe20=io_sel_reg (the full CD4076 latch at OUT 11) -- added
# 2026-09-18. Bit 7 = CDP1854 Master Reset trigger (pulsed once by
# PRCX-18 via OUT 1,0x80 at ROM 0x0023), bits 1/2 = RSEL / port select.
# Note for reading probe16 (uart status): THRE/TSRE are hard-wired 1 in
# cdp1854.vhd, so 0xC0 = idle (DA=0) and 0xC1 = DA=1.

# ---------------------------------------------------------------------
# Connections
# ---------------------------------------------------------------------
connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M01_AXI] [get_bd_intf_pins axi_bram_ctrl_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M02_AXI] [get_bd_intf_pins axi_gpio_1/S_AXI]

connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
  [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] \
  [get_bd_pins axi_smc/aclk] \
  [get_bd_pins axi_gpio_0/s_axi_aclk] \
  [get_bd_pins axi_gpio_1/s_axi_aclk] \
  [get_bd_pins axi_bram_ctrl_0/s_axi_aclk] \
  [get_bd_pins rst_ps7_0_100M/slowest_sync_clk] \
  [get_bd_pins cs1800_prcx18_top_0/CLOCK]

connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins rst_ps7_0_100M/ext_reset_in]
connect_bd_net [get_bd_pins rst_ps7_0_100M/peripheral_aresetn] \
  [get_bd_pins axi_gpio_0/s_axi_aresetn] \
  [get_bd_pins axi_gpio_1/s_axi_aresetn] \
  [get_bd_pins axi_bram_ctrl_0/s_axi_aresetn] \
  [get_bd_pins axi_smc/aresetn]

connect_bd_net [get_bd_pins axi_gpio_0/gpio_io_o] [get_bd_pins cs1800_prcx18_top_0/ctrl_in]
connect_bd_net [get_bd_pins axi_gpio_0/gpio2_io_i] [get_bd_pins cs1800_prcx18_top_0/status_out]

# axi_gpio_1 channel 1 (output, 9 bits) -> uart_rx_data/available, via
# the two xlslice cells above.
connect_bd_net [get_bd_pins axi_gpio_1/gpio_io_o] [get_bd_pins u_rx_data_slice/Din]
connect_bd_net [get_bd_pins axi_gpio_1/gpio_io_o] [get_bd_pins u_rx_avail_slice/Din]
connect_bd_net [get_bd_pins u_rx_data_slice/Dout]  [get_bd_pins cs1800_prcx18_top_0/uart_rx_data]
connect_bd_net [get_bd_pins u_rx_avail_slice/Dout] [get_bd_pins cs1800_prcx18_top_0/uart_rx_available]
# axi_gpio_1 channel 2 (input, 9 bits) <- the software-drainable TX
# FIFO (uart_tx_fifo_data/avail), NOT the raw uart_tx_data/valid pulse
# -- see cs1800_prcx18_top.vhd's header for why the raw pulse (one
# machine cycle, ~320ns) can't be caught by a devmem poll loop, while
# the FIFO's head byte + non-empty flag are stable until software pops
# them via ctrl_in(7). Via the xlconcat cell above
# (In0=fifo_data[7:0], In1=fifo_avail -> Dout[8:0]).
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/uart_tx_fifo_data]  [get_bd_pins u_tx_concat/In0]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/uart_tx_fifo_avail] [get_bd_pins u_tx_concat/In1]
connect_bd_net [get_bd_pins u_tx_concat/dout] [get_bd_pins axi_gpio_1/gpio2_io_i]

# axi_bram_ctrl's BRAM_PORTA -> cs1800_prcx18_top's memory Port B.
connect_bd_net [get_bd_pins axi_bram_ctrl_0/bram_addr_a]   [get_bd_pins cs1800_prcx18_top_0/ram_b_addr]
connect_bd_net [get_bd_pins axi_bram_ctrl_0/bram_wrdata_a] [get_bd_pins cs1800_prcx18_top_0/ram_b_din]
connect_bd_net [get_bd_pins axi_bram_ctrl_0/bram_rddata_a] [get_bd_pins cs1800_prcx18_top_0/ram_b_dout]
connect_bd_net [get_bd_pins axi_bram_ctrl_0/bram_we_a]     [get_bd_pins cs1800_prcx18_top_0/ram_b_we]
connect_bd_net [get_bd_pins axi_bram_ctrl_0/bram_en_a]     [get_bd_pins cs1800_prcx18_top_0/ram_b_en]

connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins u_ila_0/clk]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_ram_addr] [get_bd_pins u_ila_0/probe0]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_data]     [get_bd_pins u_ila_0/probe1]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_nmrd]     [get_bd_pins u_ila_0/probe2]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_nmwr]     [get_bd_pins u_ila_0/probe3]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_sc]       [get_bd_pins u_ila_0/probe4]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_tpb]      [get_bd_pins u_ila_0/probe5]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_tmp_page] [get_bd_pins u_ila_0/probe6]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_R_in]     [get_bd_pins u_ila_0/probe7]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_forceS1]  [get_bd_pins u_ila_0/probe8]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_extraS1]  [get_bd_pins u_ila_0/probe9]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_R_A]      [get_bd_pins u_ila_0/probe10]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_R_B]      [get_bd_pins u_ila_0/probe11]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_Q]        [get_bd_pins u_ila_0/probe12]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_nEF2]     [get_bd_pins u_ila_0/probe13]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_R1]       [get_bd_pins u_ila_0/probe14]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_uart_control] [get_bd_pins u_ila_0/probe15]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_uart_status]  [get_bd_pins u_ila_0/probe16]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_rsel]         [get_bd_pins u_ila_0/probe17]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_a_full]       [get_bd_pins u_ila_0/probe18]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_D]            [get_bd_pins u_ila_0/probe19]
connect_bd_net [get_bd_pins cs1800_prcx18_top_0/dbg_io_sel_reg]   [get_bd_pins u_ila_0/probe20]

assign_bd_address -offset 0x41200000 -range 0x00001000 \
  -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
  [get_bd_addr_segs axi_gpio_0/S_AXI/Reg] -force

assign_bd_address -offset 0x41210000 -range 0x00001000 \
  -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
  [get_bd_addr_segs axi_gpio_1/S_AXI/Reg] -force

# 16KB range, matching the real minimal 8KB ROM + 8KB RAM config (see
# g_ram_words note above -- stepped back from the 64KB/32KB attempts
# after the 32KB size hit a real-hardware-only hang).
assign_bd_address -offset 0x40000000 -range 0x00008000 \
  -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
  [get_bd_addr_segs axi_bram_ctrl_0/S_AXI/Mem0] -force

validate_bd_design

make_wrapper -files [get_files "$proj_dir/$proj_name.srcs/sources_1/bd/system/system.bd"] -top
add_files -norecurse "$proj_dir/$proj_name.gen/sources_1/bd/system/hdl/system_wrapper.vhd"
update_compile_order -fileset sources_1
set_property top system_wrapper [current_fileset]

puts "=== Block design created. Sources: ==="
foreach f [get_files -of [get_filesets sources_1]] { puts "  $f" }

puts "=== Running synth_design (out-of-context IP already elaborated via project mode) ==="
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
  error "synth_1 did not complete successfully -- see $proj_dir/$proj_name.runs/synth_1/runme.log"
}
puts "=== synth_1 complete ==="

open_run synth_1
report_utilization -file "$proj_dir/$proj_name.runs/synth_1/post_synth_util.rpt"
puts "=== wrote $proj_dir/$proj_name.runs/synth_1/post_synth_util.rpt ==="

puts "=== Running implementation through bitstream ==="
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  error "impl_1 did not complete successfully -- see $proj_dir/$proj_name.runs/impl_1/runme.log"
}
puts "=== impl_1 (incl. bitstream) complete ==="

open_run impl_1
write_debug_probes -force "$proj_dir/$proj_name.runs/impl_1/system_wrapper.ltx"
puts "=== wrote debug probes file: $proj_dir/$proj_name.runs/impl_1/system_wrapper.ltx ==="

report_utilization -file "$proj_dir/$proj_name.runs/impl_1/post_route_util.rpt"
puts "=== ALL DONE ==="
