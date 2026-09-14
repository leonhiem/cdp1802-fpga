-------------------------------------------------------------------------------
--
-- File Name: uart_tx.vhd
-- Author: Leon Hiemstra
--
-- Title: Real bit-serial UART transmitter, FIFO-fed
--
-- License: MIT
--
-- Description:
--   Replaces the earlier ad-hoc "expose a raw parallel byte + software-
--   timed pop" bridge (cs1800_prcx18_top.vhd's first TX FIFO attempt)
--   with an actual UART: a start bit, 8 data bits LSB-first, and a stop
--   bit, each held for g_clks_per_bit CLOCK cycles -- standard 8N1
--   framing, idle high. Drains fifo_data/fifo_avail on its own
--   whenever idle and a byte is waiting (fifo_pop pulses for exactly
--   one CLOCK cycle at the moment it latches a byte) -- no software
--   involvement in pacing at all, unlike the previous ctrl_in(7)-driven
--   pop. That also means a burst of back-to-back cdp1854 writes (its
--   THRE is modeled as always empty, so firmware can write faster than
--   any real UART could ever drain) now degrades exactly like a real
--   UART would: the upstream byte FIFO absorbs the burst and this core
--   paces it out one bit at a time, rather than silently only being
--   readable if software wins a race against a 320ns pulse.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

ENTITY uart_tx IS
  GENERIC (
    g_clks_per_bit : POSITIVE := 4 -- CLOCK cycles per bit period
  );
  PORT (
    clk : IN STD_LOGIC;

    -- Upstream byte FIFO, read-only from this core's point of view.
    fifo_data  : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
    fifo_avail : IN  STD_LOGIC;
    fifo_pop   : OUT STD_LOGIC;

    serial_out : OUT STD_LOGIC; -- idle '1'
    tx_active  : OUT STD_LOGIC  -- debug: '1' while a frame is in flight
  );
END uart_tx;

ARCHITECTURE rtl OF uart_tx IS

  TYPE t_state IS (IDLE, START, DATA, STOP);
  SIGNAL state    : t_state := IDLE;
  SIGNAL bit_cnt  : UNSIGNED(3 DOWNTO 0) := (OTHERS => '0');
  SIGNAL clk_cnt  : UNSIGNED(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL shift    : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL serial_i : STD_LOGIC := '1';

BEGIN

  serial_out <= serial_i;
  tx_active  <= '0' WHEN state = IDLE ELSE '1';

  p_tx : PROCESS(clk)
  BEGIN
    IF rising_edge(clk) THEN
      fifo_pop <= '0'; -- default; pulses for exactly one cycle below

      CASE state IS

        WHEN IDLE =>
          serial_i <= '1';
          IF fifo_avail = '1' THEN
            shift    <= fifo_data;
            fifo_pop <= '1';
            clk_cnt  <= (OTHERS => '0');
            state    <= START;
          END IF;

        WHEN START =>
          serial_i <= '0';
          IF clk_cnt = to_unsigned(g_clks_per_bit - 1, clk_cnt'length) THEN
            clk_cnt <= (OTHERS => '0');
            bit_cnt <= (OTHERS => '0');
            state   <= DATA;
          ELSE
            clk_cnt <= clk_cnt + 1;
          END IF;

        WHEN DATA =>
          serial_i <= shift(0);
          IF clk_cnt = to_unsigned(g_clks_per_bit - 1, clk_cnt'length) THEN
            clk_cnt <= (OTHERS => '0');
            shift   <= '0' & shift(7 DOWNTO 1);
            IF bit_cnt = 7 THEN
              state <= STOP;
            ELSE
              bit_cnt <= bit_cnt + 1;
            END IF;
          ELSE
            clk_cnt <= clk_cnt + 1;
          END IF;

        WHEN STOP =>
          serial_i <= '1';
          IF clk_cnt = to_unsigned(g_clks_per_bit - 1, clk_cnt'length) THEN
            clk_cnt <= (OTHERS => '0');
            state   <= IDLE;
          ELSE
            clk_cnt <= clk_cnt + 1;
          END IF;

      END CASE;
    END IF;
  END PROCESS;

END rtl;
