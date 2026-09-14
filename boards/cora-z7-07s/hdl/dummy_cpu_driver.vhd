-------------------------------------------------------------------------------
--
-- File Name: dummy_cpu_driver.vhd
-- Author: Leon Hiemstra
--
-- Title: Stand-in for the CDP1802 CPU, for isolating cdp1854+UART tests
--
-- License: MIT
--
-- Description:
--   Drives cdp1854's write-side bus exactly the way a real 1802 OUT
--   instruction would (nCS/nWE pulse, rsel held '0' for the data
--   register, data_in valid across the pulse), but from a fixed
--   built-in test message instead of real CDP1802 fetch/execute --
--   see boards/cora-z7-07s/BRINGUP_LOG.md's "isolating cdp1854+UART"
--   entry for why: real hardware showed a CPU/RAM-aliasing problem
--   downstream of cdp1854, and before trusting or chasing that further
--   this rules cdp1854+its UART chain in or out as a confound, using
--   nothing but this tiny, fully-understood driver in its place.
--
--   One byte per c_gap_cycles CLOCK cycles (nWE low for exactly one
--   cycle, then idle) -- fast enough to keep simulation/bring-up short,
--   slow enough that it's obviously not trying to race cdp1854's own
--   one-cycle write latch. Pulses `done` for one cycle after the last
--   byte's write cycle completes; asserting `start` again re-sends the
--   whole message from the top (ignored while already busy).
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE work.uart_test_msg_pkg.ALL;

ENTITY dummy_cpu_driver IS
  GENERIC (
    c_gap_cycles : POSITIVE := 8 -- CLOCK cycles between successive OUT pulses
  );
  PORT (
    clk   : IN  STD_LOGIC;
    start : IN  STD_LOGIC;
    busy  : OUT STD_LOGIC;
    done  : OUT STD_LOGIC;

    nCS      : OUT STD_LOGIC;
    nWE      : OUT STD_LOGIC;
    rsel     : OUT STD_LOGIC;
    data_out : OUT STD_LOGIC_VECTOR(7 DOWNTO 0)
  );
END dummy_cpu_driver;

ARCHITECTURE rtl OF dummy_cpu_driver IS

  TYPE t_state IS (IDLE, ASSERT_CS, PULSE_WE, GAP, DONE_PULSE);
  SIGNAL state    : t_state := IDLE;
  SIGNAL idx      : NATURAL RANGE 0 TO c_msg'length := 0;
  SIGNAL gap_cnt  : UNSIGNED(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL nCS_i    : STD_LOGIC := '1';
  SIGNAL nWE_i    : STD_LOGIC := '1';

BEGIN

  nCS  <= nCS_i;
  nWE  <= nWE_i;
  rsel <= '0'; -- always the data register, never the control register
  busy <= '0' WHEN state = IDLE ELSE '1';

  p_driver : PROCESS(clk)
  BEGIN
    IF rising_edge(clk) THEN
      done <= '0'; -- default; pulses for exactly one cycle below

      CASE state IS

        WHEN IDLE =>
          nCS_i <= '1';
          nWE_i <= '1';
          IF start = '1' THEN
            idx   <= 0;
            state <= ASSERT_CS;
          END IF;

        WHEN ASSERT_CS =>
          -- One cycle with the address/data decoded and stable before
          -- pulsing nWE, same shape as a real bus cycle.
          data_out <= c_msg(idx);
          nCS_i    <= '0';
          state    <= PULSE_WE;

        WHEN PULSE_WE =>
          nWE_i   <= '0';
          gap_cnt <= (OTHERS => '0');
          state   <= GAP;

        WHEN GAP =>
          nWE_i <= '1';
          nCS_i <= '1';
          IF gap_cnt = to_unsigned(c_gap_cycles - 1, gap_cnt'length) THEN
            IF idx = c_msg'length - 1 THEN
              state <= DONE_PULSE;
            ELSE
              idx   <= idx + 1;
              state <= ASSERT_CS;
            END IF;
          ELSE
            gap_cnt <= gap_cnt + 1;
          END IF;

        WHEN DONE_PULSE =>
          done  <= '1';
          state <= IDLE;

      END CASE;
    END IF;
  END PROCESS;

END rtl;
