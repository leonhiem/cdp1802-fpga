#
# Arm cs1800_prcx18_bringup's system_ila to trigger the moment the CPU
# takes an interrupt (SC == S3_INTERRUPT == "11" on probe4), THEN
# inject a keystroke (rx_data='D', rx_available=1, held) over SSH from
# inside this same script, then poll STATUS.CORE_STATUS (NOT
# wait_on_hw_ila -- its return value didn't reflect actual trigger
# state in testing here) until it reads "FULL" (uppercase; case-
# sensitive) or the timeout elapses.
#
# CAVEAT, found 2026-09-16 (see BRINGUP_LOG.md's "keystroke injection,
# second attempt"): the pre-existing LC/50Hz timer interrupt
# (cs1800_cpu.vhd's nINT_tmp, unrelated to any UART wiring) already
# fires every 10-20ms, so this triggers almost instantly REGARDLESS of
# whether a keystroke was actually injected -- it cannot by itself
# distinguish a receive-driven interrupt from a routine timer tick.
# Useful for confirming the timer-interrupt path itself works, and as
# a starting point for a better trigger condition (e.g. combined with
# an N-lines/rsel probe to catch specifically an INP4 status read),
# not yet useful as a standalone "did my keystroke cause an interrupt"
# test on its own.
#
# Assumes the board is already programmed, ROM already loaded, and the
# CPU already running (idling at the prompt) -- does NOT touch
# reset/run itself, just injects the keystroke. Always clears
# uart_rx_available at the end, even on a timeout -- but NOT if the
# script errors out before reaching that point (confirmed the hard
# way: an earlier bug here left rx_available stuck high across runs).
#
# Usage:
#   source /path/to/Vivado/2024.1/settings64.sh
#   vivado -mode batch -source capture_ila_on_interrupt.tcl \
#     -tclargs <proj_dir> <proj_name> <output_basename> <sshpw.py path> <board_password> <wait_seconds>
#
set proj_dir      [lindex $argv 0]
set proj_name     [lindex $argv 1]
set out           [lindex $argv 2]
set sshpw_path    [lindex $argv 3]
set board_pw      [lindex $argv 4]
set wait_seconds  [lindex $argv 5]
if {$wait_seconds eq ""} {
  set wait_seconds 30
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
set sc_probe ""
foreach p [get_hw_probes -of_objects $ila] {
  if {[string match "*probe4*" $p]} {
    set sc_probe $p
  }
}
if {$sc_probe eq ""} {
  error "Couldn't find probe4 (SC) among this ILA's probes"
}

# Trigger the moment SC == "11" (S3_INTERRUPT) -- see cdp1802_pkg.vhd's
# c_S3_INTERRUPT encoding and control.vhd's sc(1)/sc(0) derivation.
set_property TRIGGER_COMPARE_VALUE {eq'b11} $sc_probe
run_hw_ila $ila
puts "=== armed on SC=='11' (S3_INTERRUPT), injecting keystroke now ==="

exec python3 $sshpw_path $board_pw ssh \
  -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  -o StrictHostKeyChecking=no root@10.0.0.43 \
  "busybox devmem 0x41210000 32 0x144; echo INJECTED_AND_HELD"

puts "=== waiting up to ${wait_seconds}s for the interrupt trigger ==="
set elapsed 0
set core_status ""
while {$elapsed < $wait_seconds} {
  refresh_hw_device -update_hw_probes false [get_hw_devices xc7z007s_1]
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
  puts "=== TRIGGERED -- wrote $out.csv ==="
} else {
  puts "=== NOT TRIGGERED within ${wait_seconds}s -- no S3_INTERRUPT state observed (final status: $core_status) ==="
}

# Clear the injected rx_available so it doesn't stay stuck asserted
# forever (would otherwise leave DA permanently '1').
exec python3 $sshpw_path $board_pw ssh \
  -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  -o StrictHostKeyChecking=no root@10.0.0.43 \
  "busybox devmem 0x41210000 32 0x0; echo CLEARED"

close_hw_target
close_hw_manager
