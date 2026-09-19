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
--   domain, depth = 2**g_depth_bits.
--
--   head/avail are REGISTERED (both updated together, inside the same
--   clocked process, from the SAME pre-edge count/mem/rd_ptr) -- this
--   was always the intent (Block RAM, not LUTRAM, since nothing here
--   needs the CDP1802 bus's zero-wait-state combinational-read
--   timing), but an earlier version described head as a plain
--   concurrent (combinational) alias of mem(rd_ptr) instead, which is
--   what actually shipped in the first hardware bring-up of this file.
--   That version passed simulation cleanly (GHDL just executes the
--   VHDL as literally written) but real hardware showed a genuine,
--   reproducible bug on the very first push into an empty FIFO: avail
--   read '1' one cycle before head reflected the newly-written byte,
--   so a consumer that pops on the first cycle it sees avail (exactly
--   what uart_tx.vhd does) grabbed a stale value -- root-caused via a
--   value-triggered ILA capture, see BRINGUP_LOG.md's "isolating
--   cdp1854+UART" entry. Registering both signals together, from a
--   single process, makes them provably self-consistent regardless of
--   how the underlying RAM/mux ends up synthesized -- simulation can
--   no longer silently disagree with hardware here the way it did
--   before, because there's no combinational read path left for a
--   synthesis tool to treat differently than GHDL does.
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

    avail : OUT STD_LOGIC; -- '1' while count > 0

    -- '1' while fewer than 4 free slots remain. A writer that checks
    -- this before each push (with a few clocks of latency) never
    -- overflows. Unconnected by callers that don't need back-pressure.
    almost_full : OUT STD_LOGIC
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

  p_fifo : PROCESS(clk)
    VARIABLE do_push : BOOLEAN;
    VARIABLE do_pop   : BOOLEAN;
  BEGIN
    IF rising_edge(clk) THEN
      do_push := (push = '1') AND (count < c_depth);
      do_pop  := (pop = '1') AND (count > 0);

      -- head/avail reflect the state as it stood BEFORE this edge's
      -- push/pop (standard VHDL signal-read semantics -- every other
      -- read below is also of the pre-edge value), i.e. exactly what
      -- a caller polling avail/head, then issuing a pop, has been
      -- looking at since the last time this process ran. See the
      -- file header for why both are registered together.
      head <= mem(to_integer(rd_ptr));
      IF count = 0 THEN
        avail <= '0';
      ELSE
        avail <= '1';
      END IF;
      IF count >= c_depth - 4 THEN
        almost_full <= '1';
      ELSE
        almost_full <= '0';
      END IF;

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
