#
# Build the isolated cdp1854+UART bring-up project: no CDP1802, no
# ROM/RAM -- just cdp1854_uart_test_top (dummy_cpu_driver + cdp1854 +
# byte_fifo + uart_tx + fabric self-loopback + uart_rx + byte_fifo)
# behind two AXI GPIOs, so software (now over SSH+devmem, not the
# serial console) can trigger the built-in test message and drain the
# result. See BRINGUP_LOG.md's "isolating cdp1854+UART" entry for why.
#
# Same proven shape as build_project.tcl/build_project_prcx18.tcl --
# see those files' own comments for what's unchanged.
#
# Usage:
#   source /path/to/Vivado/2024.1/settings64.sh
#   vivado -mode batch -source build_project_uart_test.tcl
#
set proj_dir  "/mnt/hd/2/leon/fpga/cs1800_uart_test_bringup"
set proj_name "cs1800_uart_test_bringup"
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
  src/vhdl/cdp1854.vhd
  boards/cora-z7-07s/hdl/uart_test_msg_pkg.vhd
  boards/cora-z7-07s/hdl/byte_fifo.vhd
  boards/cora-z7-07s/hdl/uart_tx.vhd
  boards/cora-z7-07s/hdl/uart_rx.vhd
  boards/cora-z7-07s/hdl/dummy_cpu_driver.vhd
  boards/cora-z7-07s/hdl/cdp1854_uart_test_top.vhd
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
set_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {25} $processing_system7_0

set rst_ps7_0_100M [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps7_0_100M]
set axi_smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc]
set_property CONFIG.NUM_SI {1} $axi_smc
set_property CONFIG.NUM_MI {2} $axi_smc

# --- AXI GPIO 0: ctrl_in (out) / status_out (in), same convention as
# cs1800_prcx18_top.vhd/cs1800_top.vhd's control register.
set axi_gpio_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_0]
set_property -dict [list \
  CONFIG.C_GPIO_WIDTH {8} \
  CONFIG.C_ALL_OUTPUTS {1} \
  CONFIG.C_DOUT_DEFAULT {0x00000000} \
  CONFIG.C_IS_DUAL {1} \
  CONFIG.C_GPIO2_WIDTH {8} \
  CONFIG.C_ALL_INPUTS_2 {1} \
] $axi_gpio_0

# --- AXI GPIO 1: rx_data (in only) -- the drained receive FIFO's head byte.
set axi_gpio_1 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_1]
set_property -dict [list \
  CONFIG.C_GPIO_WIDTH {8} \
  CONFIG.C_ALL_INPUTS {1} \
] $axi_gpio_1

# --- cdp1854_uart_test_top: our RTL, as a module reference ---
set dut [create_bd_cell -type module -reference cdp1854_uart_test_top dut]
set_property CONFIG.g_clks_per_bit {4} $dut

# --- Debug: system_ila on the loopback serial line + the whole
# cdp1854 write path, to localize a byte-0 corruption bug found on
# real hardware (see BRINGUP_LOG.md).
set u_ila_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila:1.1 u_ila_0]
set_property CONFIG.C_MON_TYPE {NATIVE} $u_ila_0
set_property CONFIG.C_NUM_OF_PROBES {10} $u_ila_0
set_property -dict [list \
  CONFIG.C_DATA_DEPTH {4096} \
  CONFIG.C_PROBE0_WIDTH {1} \
  CONFIG.C_PROBE1_WIDTH {1} \
  CONFIG.C_PROBE2_WIDTH {1} \
  CONFIG.C_PROBE3_WIDTH {1} \
  CONFIG.C_PROBE4_WIDTH {8} \
  CONFIG.C_PROBE5_WIDTH {8} \
  CONFIG.C_PROBE6_WIDTH {1} \
  CONFIG.C_PROBE7_WIDTH {1} \
  CONFIG.C_PROBE8_WIDTH {8} \
  CONFIG.C_PROBE9_WIDTH {1} \
] $u_ila_0
# probe0=dbg_serial_loop probe1=dbg_tx_active probe2=dbg_drv_nCS
# probe3=dbg_drv_nWE probe4=dbg_drv_data probe5=dbg_cdp_tx_data
# probe6=dbg_cdp_tx_valid probe7=dbg_tx_fifo_pop probe8=dbg_tx_fifo_head
# probe9=dbg_tx_fifo_avail

# ---------------------------------------------------------------------
# Connections
# ---------------------------------------------------------------------
connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M01_AXI] [get_bd_intf_pins axi_gpio_1/S_AXI]

connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
  [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] \
  [get_bd_pins axi_smc/aclk] \
  [get_bd_pins axi_gpio_0/s_axi_aclk] \
  [get_bd_pins axi_gpio_1/s_axi_aclk] \
  [get_bd_pins rst_ps7_0_100M/slowest_sync_clk] \
  [get_bd_pins dut/CLOCK] \
  [get_bd_pins u_ila_0/clk]

connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins rst_ps7_0_100M/ext_reset_in]
connect_bd_net [get_bd_pins rst_ps7_0_100M/peripheral_aresetn] \
  [get_bd_pins axi_gpio_0/s_axi_aresetn] \
  [get_bd_pins axi_gpio_1/s_axi_aresetn] \
  [get_bd_pins axi_smc/aresetn]

connect_bd_net [get_bd_pins axi_gpio_0/gpio_io_o]  [get_bd_pins dut/ctrl_in]
connect_bd_net [get_bd_pins axi_gpio_0/gpio2_io_i] [get_bd_pins dut/status_out]
connect_bd_net [get_bd_pins axi_gpio_1/gpio_io_i]  [get_bd_pins dut/rx_data]

connect_bd_net [get_bd_pins dut/dbg_serial_loop] [get_bd_pins u_ila_0/probe0]
connect_bd_net [get_bd_pins dut/dbg_tx_active]   [get_bd_pins u_ila_0/probe1]
connect_bd_net [get_bd_pins dut/dbg_drv_nCS]     [get_bd_pins u_ila_0/probe2]
connect_bd_net [get_bd_pins dut/dbg_drv_nWE]     [get_bd_pins u_ila_0/probe3]
connect_bd_net [get_bd_pins dut/dbg_drv_data]    [get_bd_pins u_ila_0/probe4]
connect_bd_net [get_bd_pins dut/dbg_cdp_tx_data] [get_bd_pins u_ila_0/probe5]
connect_bd_net [get_bd_pins dut/dbg_cdp_tx_valid] [get_bd_pins u_ila_0/probe6]
connect_bd_net [get_bd_pins dut/dbg_tx_fifo_pop]  [get_bd_pins u_ila_0/probe7]
connect_bd_net [get_bd_pins dut/dbg_tx_fifo_head]  [get_bd_pins u_ila_0/probe8]
connect_bd_net [get_bd_pins dut/dbg_tx_fifo_avail] [get_bd_pins u_ila_0/probe9]

assign_bd_address -offset 0x41200000 -range 0x00001000 \
  -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
  [get_bd_addr_segs axi_gpio_0/S_AXI/Reg] -force

assign_bd_address -offset 0x41210000 -range 0x00001000 \
  -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
  [get_bd_addr_segs axi_gpio_1/S_AXI/Reg] -force

validate_bd_design

make_wrapper -files [get_files "$proj_dir/$proj_name.srcs/sources_1/bd/system/system.bd"] -top
add_files -norecurse "$proj_dir/$proj_name.gen/sources_1/bd/system/hdl/system_wrapper.vhd"
update_compile_order -fileset sources_1
set_property top system_wrapper [current_fileset]

puts "=== Block design created. Sources: ==="
foreach f [get_files -of [get_filesets sources_1]] { puts "  $f" }

puts "=== Running synth_design ==="
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
  error "synth_1 did not complete successfully -- see $proj_dir/$proj_name.runs/synth_1/runme.log"
}
puts "=== synth_1 complete ==="

puts "=== Running implementation through bitstream ==="
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  error "impl_1 did not complete successfully -- see $proj_dir/$proj_name.runs/impl_1/runme.log"
}
puts "=== impl_1 (incl. bitstream) complete ==="

open_run impl_1
write_debug_probes -force "$proj_dir/$proj_name.runs/impl_1/system_wrapper.ltx"
report_utilization -file "$proj_dir/$proj_name.runs/impl_1/post_route_util.rpt"
report_timing_summary -file "$proj_dir/$proj_name.runs/impl_1/post_route_timing.rpt"
puts "=== ALL DONE ==="
