#
# Build the CS1800 hardware bring-up project: PS7 + AXI GPIO (control/
# status) + cs1800_top (cs1800, unmodified, plus the LC divider).
#
# Reuses the exact proven IP set and PS7 configuration from
# ~/fpga/cora_project_bram (processing_system7 -> smartconnect ->
# <AXI peripheral>, proc_sys_reset for the AXI-side reset), swapping
# axi_bram_ctrl for axi_gpio.
#
# Usage:
#   source /path/to/Vivado/2024.1/settings64.sh
#   vivado -mode batch -source build_project.tcl
#
set proj_dir  "/mnt/hd/2/leon/fpga/cs1800_bringup"
set proj_name "cs1800_bringup"
set part      "xc7z007sclg400-1"
set board     "digilentinc.com:cora-z7-07s:part0:1.1"

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize "$script_dir/../.."]

create_project $proj_name $proj_dir -part $part -force
set_property board_part $board [current_project]
set_property target_language VHDL [current_project]

# ---------------------------------------------------------------------
# Sources: the cdp1802 library (only what cs1800 actually needs) plus
# the board-specific top-level wrapper.
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
  boards/cora-z7-07s/hdl/cs1800_top.vhd
}
set add_paths {}
foreach f $src_files { lappend add_paths "$repo_root/$f" }
add_files -norecurse $add_paths
update_compile_order -fileset sources_1

# ---------------------------------------------------------------------
# Block design
# ---------------------------------------------------------------------
create_bd_design "system"

# --- processing_system7: exact config proven in cora_project_bram ---
set processing_system7_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
source "$script_dir/ps7_config.tcl"

# cora_project_bram runs FCLK_CLK0 at 100 MHz, fine for its simple BRAM
# access. cs1800's dual-edge (TPA/TPB-style) paths need much more than
# a 5 ns half-period budget: reverse-engineered gate-level logic, never
# optimized for high clock rates, only ever validated at 4 MHz in
# simulation. Drop to 25 MHz for this bring-up (proving functional
# correctness, not chasing timing closure) -- comfortable margin over
# the ~9.3 ns / 13-logic-level critical path measured at 100 MHz.
set_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {25} $processing_system7_0

# --- AXI infrastructure: same shape as cora_project_bram ---
set rst_ps7_0_100M [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps7_0_100M]
set axi_smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc]
set_property CONFIG.NUM_SI {1} $axi_smc
set_property CONFIG.NUM_MI {1} $axi_smc

# --- AXI GPIO: dual channel, 8 bits each ---
#   channel 1 (all outputs) -> cs1800_top.ctrl_in
#     bit0=reset bit1=halt bit2=single bit3=run bit6:4=nEF(2:0) bit7=unused
#     default 0x01: reset asserted until software releases it
#   channel 2 (all inputs)  <- cs1800_top.status_out
#     bit0=Q bit1=LC bit7:2=reserved(0)
set axi_gpio_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_0]
set_property -dict [list \
  CONFIG.C_GPIO_WIDTH {8} \
  CONFIG.C_ALL_OUTPUTS {1} \
  CONFIG.C_DOUT_DEFAULT {0x00000001} \
  CONFIG.C_IS_DUAL {1} \
  CONFIG.C_GPIO2_WIDTH {8} \
  CONFIG.C_ALL_INPUTS_2 {1} \
] $axi_gpio_0

# --- cs1800_top: our RTL, as a module reference ---
set cs1800_top_0 [create_bd_cell -type module -reference cs1800_top cs1800_top_0]
# 50 Hz LC at CLOCK = 25 MHz (this build's FCLK_CLK0, see above):
# 1 / (2 * 50 Hz) = 10 ms = 250,000 cycles @ 25 MHz. (The VHDL default,
# 1,000,000, assumes the more common 100 MHz -- overridden here to
# match what this particular build actually clocks it at.)
set_property CONFIG.g_lc_half_period {250000} $cs1800_top_0

# --- Debug: system_ila on ram_addr/data/nMRD/nMWR/SC/TPB ---
# The same six signals sim/ghdl/reference/tb_cs1800_tpb.txt records per
# TPB pulse, wired here to cs1800_top_0's dbg_* ports (see cs1800.vhd)
# so a captured hardware waveform can be compared line-for-line against
# that golden reference.
set u_ila_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila:1.1 u_ila_0]
# C_NUM_OF_PROBES must be applied (its own set_property call) before the
# per-probe width properties become settable -- setting them all in one
# -dict silently drops the width changes (IP parameter enable ordering).
set_property CONFIG.C_MON_TYPE {NATIVE} $u_ila_0
set_property CONFIG.C_NUM_OF_PROBES {6} $u_ila_0
set_property -dict [list \
  CONFIG.C_DATA_DEPTH {4096} \
  CONFIG.C_PROBE0_WIDTH {16} \
  CONFIG.C_PROBE1_WIDTH {8} \
  CONFIG.C_PROBE2_WIDTH {1} \
  CONFIG.C_PROBE3_WIDTH {1} \
  CONFIG.C_PROBE4_WIDTH {2} \
  CONFIG.C_PROBE5_WIDTH {1} \
] $u_ila_0
# probe0=ram_addr probe1=data probe2=nMRD probe3=nMWR probe4=SC probe5=TPB

# ---------------------------------------------------------------------
# Connections
# ---------------------------------------------------------------------
connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]

connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
  [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] \
  [get_bd_pins axi_smc/aclk] \
  [get_bd_pins axi_gpio_0/s_axi_aclk] \
  [get_bd_pins rst_ps7_0_100M/slowest_sync_clk] \
  [get_bd_pins cs1800_top_0/CLOCK]

connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins rst_ps7_0_100M/ext_reset_in]
connect_bd_net [get_bd_pins rst_ps7_0_100M/peripheral_aresetn] \
  [get_bd_pins axi_gpio_0/s_axi_aresetn] \
  [get_bd_pins axi_smc/aresetn]

connect_bd_net [get_bd_pins axi_gpio_0/gpio_io_o] [get_bd_pins cs1800_top_0/ctrl_in]
connect_bd_net [get_bd_pins axi_gpio_0/gpio2_io_i] [get_bd_pins cs1800_top_0/status_out]

connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins u_ila_0/clk]
connect_bd_net [get_bd_pins cs1800_top_0/dbg_ram_addr] [get_bd_pins u_ila_0/probe0]
connect_bd_net [get_bd_pins cs1800_top_0/dbg_data]     [get_bd_pins u_ila_0/probe1]
connect_bd_net [get_bd_pins cs1800_top_0/dbg_nmrd]     [get_bd_pins u_ila_0/probe2]
connect_bd_net [get_bd_pins cs1800_top_0/dbg_nmwr]     [get_bd_pins u_ila_0/probe3]
connect_bd_net [get_bd_pins cs1800_top_0/dbg_sc]       [get_bd_pins u_ila_0/probe4]
connect_bd_net [get_bd_pins cs1800_top_0/dbg_tpb]      [get_bd_pins u_ila_0/probe5]

assign_bd_address -offset 0x41200000 -range 0x00001000 \
  -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
  [get_bd_addr_segs axi_gpio_0/S_AXI/Reg] -force

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
