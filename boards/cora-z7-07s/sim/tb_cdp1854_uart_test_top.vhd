-------------------------------------------------------------------------------
--
-- File Name: tb_cdp1854_uart_test_top.vhd
-- Author: Leon Hiemstra
--
-- Title: cdp1854 + FIFO + UART (self-loopback) correctness testbench
--
-- License: MIT
--
-- Description:
--   Drives cdp1854_uart_test_top's ctrl_in(0) exactly like software
--   would over devmem (a rising edge to start), waits for the sticky
--   "done" status bit, then drains the receive FIFO via ctrl_in(1)
--   pulses and checks every byte against uart_test_msg_pkg.c_msg, in
--   order, byte for byte -- the same message dummy_cpu_driver.vhd
--   actually sent, having travelled the complete real path: cdp1854's
--   write-side latch -> tx byte_fifo -> uart_tx's bit-serial framing
--   -> fabric loopback -> uart_rx's bit-serial decode -> rx byte_fifo.
--   A mismatch or a FIFO that never reports enough bytes both fail via
--   REPORT ... SEVERITY FAILURE, same convention as this repo's other
--   ALL-CHECKS-PASSED testbenches.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE work.uart_test_msg_pkg.ALL;

ENTITY tb_cdp1854_uart_test_top IS
END tb_cdp1854_uart_test_top;

ARCHITECTURE tb OF tb_cdp1854_uart_test_top IS

  CONSTANT clk_period : TIME := 40 ns; -- 25 MHz, matching real hardware

  SIGNAL clk : STD_LOGIC := '0';
  SIGNAL tb_end : STD_LOGIC := '0';

  SIGNAL ctrl_in    : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL status_out : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL rx_data    : STD_LOGIC_VECTOR(7 DOWNTO 0);

BEGIN

  clk <= NOT clk OR tb_end AFTER clk_period / 2;

  u_dut : ENTITY work.cdp1854_uart_test_top
  GENERIC MAP ( g_clks_per_bit => 4 ) -- fast, simulation/bring-up baud
  PORT MAP (
    CLOCK      => clk,
    ctrl_in    => ctrl_in,
    status_out => status_out,
    rx_data    => rx_data,

    dbg_serial_loop => OPEN,
    dbg_tx_active   => OPEN
  );

  p_test : PROCESS
    VARIABLE errors : INTEGER := 0;
  BEGIN
    -- Start: rising edge on ctrl_in(0).
    ctrl_in(0) <= '0';
    WAIT UNTIL rising_edge(clk);
    ctrl_in(0) <= '1';
    WAIT UNTIL rising_edge(clk);
    ctrl_in(0) <= '0';

    -- Wait for the sticky done bit (status_out(1)), with a generous
    -- timeout so a real hang fails loudly instead of running forever.
    FOR i IN 0 TO 200000 LOOP
      WAIT UNTIL rising_edge(clk);
      EXIT WHEN status_out(1) = '1';
      IF i = 200000 THEN
        REPORT "TIMEOUT waiting for done_latched -- driver never finished"
          SEVERITY FAILURE;
      END IF;
    END LOOP;

    -- Give the last byte's UART frame (start+8+stop = 10 bit periods)
    -- time to finish shifting out and back through uart_rx before we
    -- start draining -- "done" only means the driver handed the last
    -- byte to cdp1854/the TX FIFO, not that it has been transmitted
    -- yet.
    FOR i IN 0 TO 200 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    -- Drain the RX FIFO and check every byte, in order.
    FOR i IN c_msg'RANGE LOOP
      -- Wait for avail, then pop (rising edge on ctrl_in(1)).
      FOR w IN 0 TO 2000 LOOP
        EXIT WHEN status_out(2) = '1';
        WAIT UNTIL rising_edge(clk);
        IF w = 2000 THEN
          REPORT "TIMEOUT waiting for rx_fifo avail at byte index "
            & INTEGER'image(i) SEVERITY FAILURE;
        END IF;
      END LOOP;

      IF rx_data /= c_msg(i) THEN
        REPORT "MISMATCH at byte index " & INTEGER'image(i) &
               ": expected " & to_hstring(c_msg(i)) &
               " got " & to_hstring(rx_data)
          SEVERITY ERROR;
        errors := errors + 1;
      END IF;

      ctrl_in(1) <= '1';
      WAIT UNTIL rising_edge(clk);
      ctrl_in(1) <= '0';
      WAIT UNTIL rising_edge(clk);
      -- Two more full cycles so byte_fifo's now-registered head/avail
      -- (see its own header for why both are registered, not just
      -- one) have settled after the just-issued pop, before the next
      -- iteration reads rx_data -- real software (a devmem read,
      -- milliseconds after the write that popped) never races this;
      -- this is purely to keep the testbench's own sampling honest.
      WAIT UNTIL rising_edge(clk);
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    -- The FIFO should now be empty -- exactly c_msg'length bytes, no
    -- more, no fewer.
    IF status_out(2) = '1' THEN
      REPORT "rx_fifo still reports avail after draining exactly " &
             INTEGER'image(c_msg'length) & " bytes -- extra byte(s) present"
        SEVERITY ERROR;
      errors := errors + 1;
    END IF;

    IF errors = 0 THEN
      REPORT "ALL CHECKS PASSED";
    ELSE
      REPORT INTEGER'image(errors) & " CHECK(S) FAILED" SEVERITY FAILURE;
    END IF;

    tb_end <= '1';
    WAIT;
  END PROCESS;

END tb;
