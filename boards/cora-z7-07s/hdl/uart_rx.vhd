-------------------------------------------------------------------------------
--
-- File Name: uart_rx.vhd
-- Author: Leon Hiemstra
--
-- Title: Real bit-serial UART receiver
--
-- License: MIT
--
-- Description:
--   Companion to uart_tx.vhd: standard 8N1 framing, samples mid-bit
--   (g_clks_per_bit/2 after each edge) for noise margin, same as any
--   textbook UART receiver. serial_in is expected pre-synchronized to
--   clk by the caller if it ever crosses a clock domain -- for now
--   every use of this core in this project is same-clock-domain
--   (loopback tests, or fed from another same-CLOCK core), so no
--   double-flop synchronizer is included here; add one at the call
--   site first if that stops being true.
--
--   byte_out_valid pulses for exactly one clk cycle when a full frame
--   has been received; byte_out holds that value until the next frame
--   completes.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

ENTITY uart_rx IS
  GENERIC (
    g_clks_per_bit : POSITIVE := 4
  );
  PORT (
    clk : IN STD_LOGIC;

    serial_in : IN STD_LOGIC;

    byte_out       : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    byte_out_valid : OUT STD_LOGIC
  );
END uart_rx;

ARCHITECTURE rtl OF uart_rx IS

  TYPE t_state IS (IDLE, START, DATA, STOP);
  SIGNAL state    : t_state := IDLE;
  SIGNAL bit_cnt  : UNSIGNED(3 DOWNTO 0) := (OTHERS => '0');
  SIGNAL clk_cnt  : UNSIGNED(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL shift    : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL valid_i  : STD_LOGIC := '0';

  CONSTANT c_half : UNSIGNED(15 DOWNTO 0) :=
    to_unsigned(g_clks_per_bit / 2, 16);

BEGIN

  byte_out_valid <= valid_i;

  p_rx : PROCESS(clk)
  BEGIN
    IF rising_edge(clk) THEN
      valid_i <= '0'; -- default; pulses for exactly one cycle below

      CASE state IS

        WHEN IDLE =>
          IF serial_in = '0' THEN -- possible start bit
            clk_cnt <= (OTHERS => '0');
            state   <= START;
          END IF;

        WHEN START =>
          -- Sample mid-bit to confirm it's really a start bit, not a
          -- glitch.
          IF clk_cnt = c_half THEN
            IF serial_in = '0' THEN
              clk_cnt <= (OTHERS => '0');
              bit_cnt <= (OTHERS => '0');
              state   <= DATA;
            ELSE
              state <= IDLE; -- false start
            END IF;
          ELSE
            clk_cnt <= clk_cnt + 1;
          END IF;

        WHEN DATA =>
          -- Sample each data bit g_clks_per_bit after the previous
          -- sample point (i.e. mid-bit for every subsequent bit too,
          -- since START already consumed half a bit period getting
          -- here).
          IF clk_cnt = to_unsigned(g_clks_per_bit - 1, clk_cnt'length) THEN
            clk_cnt <= (OTHERS => '0');
            shift   <= serial_in & shift(7 DOWNTO 1);
            IF bit_cnt = 7 THEN
              state <= STOP;
            ELSE
              bit_cnt <= bit_cnt + 1;
            END IF;
          ELSE
            clk_cnt <= clk_cnt + 1;
          END IF;

        WHEN STOP =>
          IF clk_cnt = to_unsigned(g_clks_per_bit - 1, clk_cnt'length) THEN
            byte_out <= shift;
            valid_i  <= '1';
            clk_cnt  <= (OTHERS => '0');
            state    <= IDLE;
          ELSE
            clk_cnt <= clk_cnt + 1;
          END IF;

      END CASE;
    END IF;
  END PROCESS;

END rtl;
