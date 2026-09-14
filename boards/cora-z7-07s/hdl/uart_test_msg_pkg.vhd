-------------------------------------------------------------------------------
--
-- File Name: uart_test_msg_pkg.vhd
-- Author: Leon Hiemstra
--
-- Title: Shared test message for dummy_cpu_driver.vhd and its testbench
--
-- License: MIT
--
-- Description:
--   Single source of truth for the fixed byte sequence
--   dummy_cpu_driver.vhd sends -- so the testbench checks against the
--   exact same data it's actually driving, not a hand-copied second
--   version that could quietly drift out of sync.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;

PACKAGE uart_test_msg_pkg IS

  TYPE t_msg IS ARRAY (NATURAL RANGE <>) OF STD_LOGIC_VECTOR(7 DOWNTO 0);

  CONSTANT c_msg : t_msg := (
    X"48", X"65", X"6C", X"6C", X"6F", X"2C", X"20", X"43", X"53", X"31",
    X"38", X"30", X"30", X"20", X"55", X"41", X"52", X"54", X"20", X"6C",
    X"6F", X"6F", X"70", X"62", X"61", X"63", X"6B", X"21", X"0D", X"0A"
  ); -- "Hello, CS1800 UART loopback!\r\n"

END PACKAGE uart_test_msg_pkg;
