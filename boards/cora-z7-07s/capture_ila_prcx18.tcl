#
# Arm cs1800_prcx18_bringup's system_ila (u_ila_0: probe0=ram_addr[15:0],
# probe1=data[7:0], probe2=nMRD, probe3=nMWR, probe4=SC[1:0],
# probe5=TPB) with an immediate trigger and dump whatever it captures
# to a CSV -- the fastest way to answer "is the CPU actually advancing,
# or stuck?" without setting up a real trigger condition first.
#
# Requires the board already programmed (program_prcx18.tcl) and
# running. Load_features labtools is needed because hw_ila commands
# are lazily autoloaded and current_hw_device/refresh_hw_device alone
# won't pull them in.
#
# Usage:
#   source /path/to/Vivado/2024.1/settings64.sh
#   vivado -mode batch -source boards/cora-z7-07s/capture_ila_prcx18.tcl \
#     -tclargs /path/to/output_basename
#
set proj_dir "/mnt/hd/2/leon/fpga/cs1800_prcx18_bringup"
set proj_name "cs1800_prcx18_bringup"
set probes "$proj_dir/$proj_name.runs/impl_1/system_wrapper.ltx"
set out [lindex $argv 0]
if {$out eq ""} {
  set out "/tmp/ila_capture"
}

load_features labtools
open_hw_manager
connect_hw_server
open_hw_target

set dev [lindex [get_hw_devices xc7z007s_1] 0]
if {$dev eq ""} {
  error "No xc7z007s_1 device found -- is the board connected and powered on?"
}
current_hw_device $dev
set_property PROBES.FILE $probes $dev
refresh_hw_device $dev

set ila [get_hw_ilas -of_objects $dev]
run_hw_ila -trigger_now $ila
wait_on_hw_ila -timeout 30 $ila
write_hw_ila_data -force -csv_file $out [upload_hw_ila_data $ila]
puts "=== wrote $out.csv ==="

close_hw_target
close_hw_manager
