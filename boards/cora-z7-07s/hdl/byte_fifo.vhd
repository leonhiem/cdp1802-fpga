-------------------------------------------------------------------------------
--
-- File Name: byte_fifo.vhd
-- Author: Leon Hiemstra
--
-- Title: Small synchronous byte FIFO
--
-- License: MIT
--
-- Description:
--   Generic version of the ad-hoc 256-byte FIFO first written inline
--   inside cs1800_prcx18_top.vhd (see that file's git history) --
--   pulled out into its own reusable entity now that a second use case
--   (uart_tx.vhd's upstream buffer, uart_rx.vhd's downstream capture
--   buffer) showed up. Plain synchronous read/write, single clock
--   domain, depth = 2**g_depth_bits. Infers Block RAM (not LUTRAM),
--   same reasoning as before: both read and write are registered, no
--   combinational read path.
--
--   push and pop may both be asserted the same cycle (push a new byte
--   in while also draining the head byte out) -- count is adjusted for
--   exactly that case. push while full, or pop while empty, are both
--   silently ignored (no overflow/underflow signalling -- callers that
--   care should check avail/count first, same as any simple FIFO).
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

ENTITY byte_fifo IS
  GENERIC (
    g_depth_bits : POSITIVE := 8 -- depth = 2**g_depth_bits (default 256)
  );
  PORT (
    clk : IN STD_LOGIC;

    push      : IN  STD_LOGIC;
    push_data : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);

    pop      : IN  STD_LOGIC;
    head     : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);

    avail : OUT STD_LOGIC -- '1' while count > 0
  );
END byte_fifo;

ARCHITECTURE rtl OF byte_fifo IS

  CONSTANT c_depth : NATURAL := 2 ** g_depth_bits;

  TYPE t_mem IS ARRAY (0 TO c_depth - 1) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL mem : t_mem := (OTHERS => (OTHERS => '0'));

  SIGNAL wr_ptr : UNSIGNED(g_depth_bits - 1 DOWNTO 0) := (OTHERS => '0');
  SIGNAL rd_ptr : UNSIGNED(g_depth_bits - 1 DOWNTO 0) := (OTHERS => '0');
  SIGNAL count  : UNSIGNED(g_depth_bits DOWNTO 0)     := (OTHERS => '0');

BEGIN

  head  <= mem(to_integer(rd_ptr));
  avail <= '0' WHEN count = 0 ELSE '1';

  p_fifo : PROCESS(clk)
    VARIABLE do_push : BOOLEAN;
    VARIABLE do_pop   : BOOLEAN;
  BEGIN
    IF rising_edge(clk) THEN
      do_push := (push = '1') AND (count < c_depth);
      do_pop  := (pop = '1') AND (count > 0);

      IF do_push THEN
        mem(to_integer(wr_ptr)) <= push_data;
        wr_ptr <= wr_ptr + 1;
      END IF;

      IF do_pop THEN
        rd_ptr <= rd_ptr + 1;
      END IF;

      IF do_push AND NOT do_pop THEN
        count <= count + 1;
      ELSIF do_pop AND NOT do_push THEN
        count <= count - 1;
      END IF;
    END IF;
  END PROCESS;

END rtl;
