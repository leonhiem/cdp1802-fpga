#
# Arm a board's system_ila to trigger on TPB's first rising edge, THEN
# release reset+run over SSH from inside this same script (so there's
# no cross-process race between arming and releasing), then capture.
#
# This is the correct way to check "does execution actually start out
# right" -- see BRINGUP_LOG.md's 2026-09-15 "milestone 3f" entry for
# why `run_hw_ila -trigger_now` (capture_ila_prcx18.tcl's approach) is
# the WRONG tool for that question: it grabs whatever's on the bus at
# whatever later moment Vivado happens to connect, not from the start,
# and can easily make a design that's working correctly look instantly
# hung if it's already moved on to wherever it goes next by the time
# you look.
#
# Requires the board already programmed and held in reset (ctrl_in's
# power-on default). Assumes the ILA's probe5 is TPB and ctrl_in is at
# 0x4120_0000 with `run=1,reset=0,nEF="110"` = 0x68 -- matches every
# design in this repo (cs1800_top, cs1800_prcx18_top). Needs
# sshpw.py (see BRINGUP_LOG.md/memory -- recreate locally, never commit
# it or the board's credentials).
#
# Usage:
#   source /path/to/Vivado/2024.1/settings64.sh
#   vivado -mode batch -source boards/cora-z7-07s/capture_ila_from_start.tcl \
#     -tclargs <proj_dir> <proj_name> <output_basename> <sshpw.py path> <board_password> [ctrl_value]
#
set proj_dir      [lindex $argv 0]
set proj_name     [lindex $argv 1]
set out           [lindex $argv 2]
set sshpw_path    [lindex $argv 3]
set board_pw      [lindex $argv 4]
set ctrl_value    [lindex $argv 5]
if {$ctrl_value eq ""} {
  set ctrl_value "0x68"
}
set probes "$proj_dir/$proj_name.runs/impl_1/system_wrapper.ltx"

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
set tpb_probe ""
foreach p [get_hw_probes -of_objects $ila] {
  if {[string match "*probe5*" $p]} {
    set tpb_probe $p
  }
}
if {$tpb_probe eq ""} {
  error "Couldn't find probe5 (TPB) among this ILA's probes"
}

set_property TRIGGER_COMPARE_VALUE {eq'b1} $tpb_probe
run_hw_ila $ila
puts "=== armed on TPB's first '1' sample, releasing run now ==="

exec python3 $sshpw_path $board_pw ssh \
  -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  -o StrictHostKeyChecking=no root@10.0.0.43 \
  "busybox devmem 0x41200000 32 $ctrl_value"

wait_on_hw_ila -timeout 30 $ila
write_hw_ila_data -force -csv_file $out [upload_hw_ila_data $ila]
puts "=== wrote $out.csv ==="

close_hw_target
close_hw_manager
