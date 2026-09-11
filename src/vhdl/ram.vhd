-------------------------------------------------------------------------------
--
-- File Name: ram.vhd
-- Author: Leon Hiemstra
--
-- Title: CDP18 RAM including test program
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
USE work.instr_pkg.ALL;
USE work.test_program_pkg.ALL;


ENTITY ram IS
  PORT (
    -- FPGA note: writes used to be level-sensitive/asynchronous
    -- (PROCESS(address, nCS, nWE, nOE), no clock -- modeling a real
    -- async-write SRAM chip). That synthesized as 2208 individual
    -- latches (276 bytes x 8 bits), which real hardware bring-up
    -- showed glitching: nMRD/nMWR/address are held stable for several
    -- CLOCK cycles at a time (see control.vhd -- they're generated in
    -- the falling-edge-registered domain, so nMRD/nMWR only ever
    -- change right after a falling edge), so a clean rising-edge
    -- write lands well inside that stable window with no timing risk.
    -- Reads stay exactly as before -- plain combinational, zero
    -- latency -- which together with the now-clocked write is the
    -- standard "distributed RAM" (LUTRAM) idiom: a real synthesizable
    -- primitive, not a latch.
    clk     : IN STD_LOGIC;
    address : IN STD_LOGIC_VECTOR(15 DOWNTO 0);
    -- FPGA note: split from a single INOUT 'data' pin into separate
    -- write-data-in / read-data-out signals -- no internal 'Z'. The
    -- parent (cdp18.vhd/cs1800.vhd) merges data_out with whatever else
    -- shares the system bus.
    data_in  : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
    data_out : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    nWE, nCS, nOE: IN STD_LOGIC
  );
END ram;

ARCHITECTURE str OF ram IS

  -- Test program contents: see test_program_pkg.vhd (shared with any
  -- board-level memory, so there's one copy to keep in sync, not two).
  SIGNAL ram1 : t_mem_array(0 TO 275) := c_test_program;

BEGIN
  -- Synchronous write: address/data/nWE are all held stable for several
  -- CLOCK cycles per access (see the FPGA note above), so sampling them
  -- on one clean rising edge lands well inside that window.
  PROCESS (clk) IS
    BEGIN
      IF rising_edge(clk) THEN
        IF nCS = '0' AND nWE = '0' THEN
          ram1(to_integer(unsigned(address))) <= data_in;
        END IF;
      END IF;
  END PROCESS;

  -- Asynchronous read: unchanged from before, zero latency.
  PROCESS (address, nCS, nOE) IS
    BEGIN
      data_out <= (OTHERS => '0'); -- chip is not selected / not reading
      IF (nCS = '0' AND nOE = '0') THEN
        data_out <= ram1(to_integer(unsigned(address)));
      END IF;
  END PROCESS;
END str;
