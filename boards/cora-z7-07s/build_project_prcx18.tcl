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

# See build_project.tcl's own comment: 25 MHz for this reverse-
# engineered core's comfortable timing margin, not chasing max speed.
set_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {25} $processing_system7_0

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
# 50 Hz LC at CLOCK = 25 MHz -- see build_project.tcl's own comment.
set_property CONFIG.g_lc_half_period {250000} $cs1800_prcx18_top_0
# g_ram_words left at its entity default (256 = 1KB) -- see
# cs1800_prcx18_memory.vhd's header for the full story: the original
# 384-word (1.5KB, non-power-of-two) choice caused a real hardware-only
# address-decode bug (a modulo divider glitching the combinational read
# path); fixed by requiring a power of two, which also drops capacity
# a bit. Still functionally short of what PRCX-18 needs to fully start
# its Console Task (2KB does, but doesn't fit the ~6000-LUT budget --
# ~102%). Building at 1KB anyway, deliberately, now that it's at least
# deterministic, to watch the real boot behavior on actual hardware.

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
set_property CONFIG.C_NUM_OF_PROBES {17} $u_ila_0
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

assign_bd_address -offset 0x41200000 -range 0x00001000 \
  -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
  [get_bd_addr_segs axi_gpio_0/S_AXI/Reg] -force

assign_bd_address -offset 0x41210000 -range 0x00001000 \
  -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
  [get_bd_addr_segs axi_gpio_1/S_AXI/Reg] -force

# 16KB range (matching this design's real 8KB ROM + 4KB RAM, rounded up
# to a clean power of two) -- addresses beyond that alias.
assign_bd_address -offset 0x40000000 -range 0x00004000 \
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
