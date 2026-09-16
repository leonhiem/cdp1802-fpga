#
# Improved keystroke-injection ILA test, 2026-09-16 (per the user's own
# suggestions): freezes the LC/50Hz timer interrupt first (ctrl_in(5)
# repurposed as a freeze bit -- see cs1800_prcx18_top.vhd's own note)
# so an SC=='11' (S3_INTERRUPT) trigger can ONLY mean the UART-driven
# interrupt this time, not the routine timer tick that made
# capture_ila_on_interrupt.tcl's own SC-based trigger useless on its
# own (see BRINGUP_LOG.md's "keystroke injection, second attempt").
# Injects a single brief keystroke pulse (not held for seconds -- one
# quick set-then-clear already spans thousands of CPU cycles at
# 25MHz). Requires the probe12/13/14 (Q/nEF2/R1) added to
# build_project_prcx18.tcl on 2026-09-16.
#
# Assumes the board is already programmed (with THIS updated
# bitstream, probe12-14 included), ROM already loaded (see
# gen_load_prcx18_rom.py), and the CPU already running (idling at the
# prompt).
#
# Usage:
#   source /path/to/Vivado/2024.1/settings64.sh
#   vivado -mode batch -source capture_ila_on_interrupt_v2.tcl \
#     -tclargs <proj_dir> <proj_name> <output_basename> <sshpw.py path> <board_password> <wait_seconds> <base_ctrl_hex>
#
set proj_dir      [lindex $argv 0]
set proj_name     [lindex $argv 1]
set out           [lindex $argv 2]
set sshpw_path    [lindex $argv 3]
set board_pw      [lindex $argv 4]
set wait_seconds  [lindex $argv 5]
if {$wait_seconds eq ""} {
  set wait_seconds 15
}
set base_ctrl     [lindex $argv 6]
if {$base_ctrl eq ""} {
  set base_ctrl "0x68"
}
# Clear bit 5 (0x20) to freeze LC -- see cs1800_prcx18_top.vhd's note.
set frozen_ctrl [format "0x%02x" [expr { $base_ctrl & ~0x20 }]]
set probes "$proj_dir/$proj_name.runs/impl_1/system_wrapper.ltx"

proc ssh_run {sshpw_path board_pw cmd} {
  return [exec python3 $sshpw_path $board_pw ssh \
    -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
    -o StrictHostKeyChecking=no root@10.0.0.43 $cmd]
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
set sc_probe ""
foreach p [get_hw_probes -of_objects $ila] {
  if {[string match "*probe4*" $p]} {
    set sc_probe $p
  }
}
if {$sc_probe eq ""} {
  error "Couldn't find probe4 (SC) among this ILA's probes"
}
set_property TRIGGER_COMPARE_VALUE {eq'b11} $sc_probe

puts "=== freezing LC (ctrl_in=$frozen_ctrl) ==="
ssh_run $sshpw_path $board_pw "busybox devmem 0x41200000 32 $frozen_ctrl"

puts "=== arming ILA on SC=='11' (now unambiguous -- LC frozen) ==="
run_hw_ila $ila

puts "=== injecting a single brief keystroke pulse ('D') ==="
ssh_run $sshpw_path $board_pw "busybox devmem 0x41210000 32 0x144; busybox devmem 0x41210000 32 0x0"

puts "=== waiting up to ${wait_seconds}s for the trigger ==="
set elapsed 0
set core_status ""
while {$elapsed < $wait_seconds} {
  refresh_hw_device -update_hw_probes false $dev
  set core_status [get_property STATUS.CORE_STATUS $ila]
  puts "=== t=${elapsed}s CORE_STATUS: $core_status ==="
  if {$core_status eq "FULL"} {
    break
  }
  after 1000
  incr elapsed
}

if {$core_status eq "FULL"} {
  write_hw_ila_data -force -csv_file $out [upload_hw_ila_data $ila]
  puts "=== TRIGGERED (real interrupt, LC was frozen) -- wrote $out.csv ==="
} else {
  puts "=== NOT TRIGGERED within ${wait_seconds}s -- no interrupt at all with LC frozen ==="
  puts "=== taking an immediate trigger_now snapshot to see Q/nEF2/R1's static state ==="
  run_hw_ila -trigger_now $ila
  wait_on_hw_ila -timeout 10 $ila
  write_hw_ila_data -force -csv_file "${out}_notrig" [upload_hw_ila_data $ila]
  puts "=== wrote ${out}_notrig.csv ==="
}

puts "=== restoring LC (ctrl_in=$base_ctrl) and clearing rx ==="
ssh_run $sshpw_path $board_pw "busybox devmem 0x41200000 32 $base_ctrl; busybox devmem 0x41210000 32 0x0"

close_hw_target
close_hw_manager
