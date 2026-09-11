-------------------------------------------------------------------------------
--
-- File Name: io_inp.vhd
-- Author: Leon Hiemstra
--
-- Title: CDP18 IO input
--
-- License: MIT
--
-- Description: 
--
--
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.std_logic_1164.ALL;
USE IEEE.numeric_std.ALL;


ENTITY io_inp IS
  PORT (
    data    : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    input   : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
    nCS     : IN STD_LOGIC
  );
END io_inp;

ARCHITECTURE str OF io_inp IS

BEGIN
  -- FPGA note: driven value is 0 when not selected, so the parent that
  -- shares this bus (cdp18.vhd/cs1800.vhd) can OR-merge it with the
  -- other drivers instead of relying on tri-state resolution.
  data <= input WHEN nCS = '0' ELSE (OTHERS => '0');
END str;
