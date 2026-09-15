-------------------------------------------------------------------------------
--
-- File Name: ram_sync.vhd
-- Author: Leon Hiemstra
--
-- Title: CDP18 RAM including test program -- synchronous-read experiment v2
--
-- License: MIT
--
-- Description:
--   Exploratory sibling of ram.vhd, 2026-09-15 (see boards/cora-z7-07s/
--   BRINGUP_LOG.md's "milestone 3l"): same interface and same write
--   timing, but the READ is now registered (1-cycle synchronous
--   latency) instead of combinational/async -- a real Block-RAM-
--   compatible shape.
--
--   v1 of this same idea (milestone 3k) tried this against the CPU's
--   externally-multiplexed, TPA-latched `ADDR`/`ram_addr`
--   reconstruction and failed (real, GHDL-proven internal corruption):
--   that signal is only valid during part of each machine cycle by
--   construction (real chip pin-count limitation), so registering a
--   read on every CLOCK edge sometimes captured it mid-transition.
--   v2 fixes this by having the caller (cdp18_sync.vhd) feed this
--   entity `cdp1802.vhd`'s new `A_full` port instead -- the CPU's own
--   internal, already-16-bit, already-settled address register, valid
--   for an entire access with no multiplexing artifact at all. This
--   file itself is otherwise identical to v1/ram.vhd.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.std_logic_1164.ALL;
USE IEEE.numeric_std.ALL;
USE work.instr_pkg.ALL;
USE work.test_program_pkg.ALL;


ENTITY ram_sync IS
  PORT (
    clk     : IN STD_LOGIC;
    address : IN STD_LOGIC_VECTOR(15 DOWNTO 0);
    data_in  : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
    data_out : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    nWE, nCS, nOE: IN STD_LOGIC
  );
END ram_sync;

ARCHITECTURE str OF ram_sync IS

  SIGNAL ram1 : t_mem_array(0 TO 275) := c_test_program;

BEGIN
  -- Synchronous write: unchanged from ram.vhd.
  PROCESS (clk) IS
    BEGIN
      IF rising_edge(clk) THEN
        IF nCS = '0' AND nWE = '0' THEN
          ram1(to_integer(unsigned(address))) <= data_in;
        END IF;
      END IF;
  END PROCESS;

  -- Synchronous read: registered, 1-cycle latency. Safe now that
  -- `address` (fed from A_full, see header) is genuinely stable for
  -- the whole access rather than time-multiplexed.
  PROCESS (clk) IS
    BEGIN
      IF rising_edge(clk) THEN
        IF (nCS = '0' AND nOE = '0') THEN
          data_out <= ram1(to_integer(unsigned(address)));
        ELSE
          data_out <= (OTHERS => '0');
        END IF;
      END IF;
  END PROCESS;
END str;
