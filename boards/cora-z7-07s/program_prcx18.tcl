#
# Program the Cora Z7-07S over JTAG with the bitstream
# build_project_prcx18.tcl produced, and load its debug probes file so
# the ILA shows real signal names in Hardware Manager.
#
# Same shape as program.tcl -- see its own comments -- just pointed at
# the separate cs1800_prcx18_bringup project instead of cs1800_bringup.
#
# Usage:
#   source /path/to/Vivado/2024.1/settings64.sh
#   vivado -mode batch -source boards/cora-z7-07s/program_prcx18.tcl
#
# Requires the board connected over USB (JTAG + UART) and hw_server able
# to see it (this script starts one itself via connect_hw_server).
#
set proj_dir  "/mnt/hd/2/leon/fpga/cs1800_prcx18_bringup"
set proj_name "cs1800_prcx18_bringup"
set bitstream "$proj_dir/$proj_name.runs/impl_1/system_wrapper.bit"
set probes    "$proj_dir/$proj_name.runs/impl_1/system_wrapper.ltx"

if {![file exists $bitstream]} {
  error "No bitstream at $bitstream -- run build_project_prcx18.tcl first"
}

open_hw_manager
connect_hw_server
open_hw_target

set dev [lindex [get_hw_devices xc7z007s_1] 0]
if {$dev eq ""} {
  error "No xc7z007s_1 device found -- is the board connected and powered on?"
}
current_hw_device $dev

set_property PROGRAM.FILE $bitstream $dev
if {[file exists $probes]} {
  set_property PROBES.FILE $probes $dev
  set_property FULL_PROBES.FILE $probes $dev
}

program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev

puts "=== Programmed $bitstream ==="
close_hw_target
close_hw_manager
