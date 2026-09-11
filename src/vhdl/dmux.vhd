-------------------------------------------------------------------------------
--
-- File Name: dmux.vhd
-- Author: Leon Hiemstra
--
-- Title: Databus multiplexer
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


ENTITY dmux IS
  PORT (
    float0 : IN  STD_LOGIC;
    float1 : IN  STD_LOGIC;
    rst    : IN  STD_LOGIC;

    d_src0 : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
    d_src1 : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);

    d_snk  : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);

    -- FPGA note: this used to be a single INOUT 'data' pin, resolved
    -- internally between d0/d1 (driving) and d_snk (listening) via a
    -- tri-state 'Z'. Split into an explicit in/out/output-enable
    -- triplet -- the standard, vendor-independent way to represent a
    -- bidirectional pin once it's purely internal (no real chip pin at
    -- the far end): the parent (cdp1802.vhd, then cdp18.vhd/cs1800.vhd)
    -- does the actual merge with whatever else shares this bus.
    data_in  : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
    data_out : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    data_oe  : OUT STD_LOGIC
  );
END dmux;


ARCHITECTURE str OF dmux IS

  SIGNAL d0 : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL d1 : STD_LOGIC_VECTOR(7 DOWNTO 0);

BEGIN

  data_oe  <= '1' WHEN (float0 = '0' AND float1 = '1') OR
                       (float0 = '1' AND float1 = '0') ELSE '0';

  data_out <= d0 WHEN (float0 = '0' AND float1 = '1') ELSE
              d1 WHEN (float0 = '1' AND float1 = '0') ELSE
              (OTHERS => '0'); -- don't-care: data_oe='0' here

  -- Always forward the bus inward; only meaningful to the reader when
  -- data_oe='0' (i.e. we're listening rather than driving) -- same
  -- condition under which d_snk mattered before.
  d_snk <= data_in;

  d0 <= (OTHERS => '0') WHEN rst = '1' ELSE d_src0;
  d1 <= (OTHERS => '0') WHEN rst = '1' ELSE d_src1;

END str;
