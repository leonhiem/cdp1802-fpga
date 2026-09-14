-------------------------------------------------------------------------------
--
-- File Name: cdp1854_uart_test_top.vhd
-- Author: Leon Hiemstra
--
-- Title: Isolated cdp1854 + TX FIFO + UART (self-loopback) bring-up
--
-- License: MIT
--
-- Description:
--   Step 2 of the isolation plan in BRINGUP_LOG.md's "isolating
--   cdp1854+UART" entry: prove cdp1854 + its byte FIFOs + the new real
--   bit-serial uart_tx/uart_rx cores are reliable on their own, driven
--   by dummy_cpu_driver instead of the full CDP1802, before trusting
--   any further observation about the CPU/RAM subsystem. uart_tx's
--   serial_out is wired directly to uart_rx's serial_in in fabric
--   (self-loopback) -- there is no physical UART pin involved yet.
--
--   Same ctrl_in/status_out 8-bit AXI-GPIO convention as
--   cs1800_prcx18_top.vhd, so build_project_prcx18_uart_test.tcl can
--   reuse the exact same two-axi_gpio block-design shape:
--     ctrl_in(0)  : edge-detected "start" -- (re-)send the built-in
--                   test message (dummy_cpu_driver.vhd's c_msg).
--     ctrl_in(1)  : edge-detected "rx_pop" -- dequeue one byte from
--                   the receive FIFO (rx_data/status_out(2) below).
--     status_out(0) : driver busy
--     status_out(1) : sticky "done" (set when the driver finishes
--                     sending, cleared by the next start)
--     status_out(2) : rx_fifo avail (rx_data holds its head byte)
--   rx_data (8 bits) : the receive FIFO's head byte, a second GPIO
--                       channel exactly like cs1800_prcx18_top.vhd's
--                       uart_tx_fifo_data.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

ENTITY cdp1854_uart_test_top IS
  GENERIC (
    g_clks_per_bit : POSITIVE := 4 -- uart_tx/uart_rx bit period, in CLOCK cycles
  );
  PORT (
    CLOCK : IN STD_LOGIC;

    ctrl_in    : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
    status_out : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    rx_data    : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);

    -- Debug taps, harmless to leave unconnected.
    dbg_serial_loop : OUT STD_LOGIC;
    dbg_tx_active   : OUT STD_LOGIC
  );
END cdp1854_uart_test_top;

ARCHITECTURE str OF cdp1854_uart_test_top IS

  SIGNAL start_prev : STD_LOGIC := '0';
  SIGNAL start_i     : STD_LOGIC := '0';
  SIGNAL rxpop_prev  : STD_LOGIC := '0';
  SIGNAL rxpop_i      : STD_LOGIC := '0';

  SIGNAL drv_busy : STD_LOGIC;
  SIGNAL drv_done : STD_LOGIC;
  SIGNAL done_latched : STD_LOGIC := '0';

  SIGNAL drv_nCS  : STD_LOGIC;
  SIGNAL drv_nWE  : STD_LOGIC;
  SIGNAL drv_rsel : STD_LOGIC;
  SIGNAL drv_data : STD_LOGIC_VECTOR(7 DOWNTO 0);

  SIGNAL cdp_tx_data  : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL cdp_tx_valid : STD_LOGIC;
  SIGNAL cdp_data_out : STD_LOGIC_VECTOR(7 DOWNTO 0);

  SIGNAL tx_fifo_avail : STD_LOGIC;
  SIGNAL tx_fifo_head  : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL tx_fifo_pop   : STD_LOGIC;

  SIGNAL serial_loop : STD_LOGIC;

  SIGNAL rx_byte       : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL rx_byte_valid : STD_LOGIC;

  SIGNAL rx_fifo_avail : STD_LOGIC;
  SIGNAL rx_fifo_head  : STD_LOGIC_VECTOR(7 DOWNTO 0);

BEGIN

  -- Edge-detect the two software-driven control bits (same idiom as
  -- cs1800_prcx18_top.vhd's earlier ctrl_in(7) pop).
  p_edges : PROCESS(CLOCK)
  BEGIN
    IF rising_edge(CLOCK) THEN
      start_prev <= ctrl_in(0);
      start_i    <= ctrl_in(0) AND NOT start_prev;

      rxpop_prev <= ctrl_in(1);
      rxpop_i    <= ctrl_in(1) AND NOT rxpop_prev;

      IF start_i = '1' THEN
        done_latched <= '0';
      ELSIF drv_done = '1' THEN
        done_latched <= '1';
      END IF;
    END IF;
  END PROCESS;

  u_driver : ENTITY work.dummy_cpu_driver
  PORT MAP (
    clk      => CLOCK,
    start    => start_i,
    busy     => drv_busy,
    done     => drv_done,
    nCS      => drv_nCS,
    nWE      => drv_nWE,
    rsel     => drv_rsel,
    data_out => drv_data
  );

  u_cdp1854 : ENTITY work.cdp1854
  PORT MAP (
    clk      => CLOCK,
    data_in  => drv_data,
    data_out => cdp_data_out,
    nCS      => drv_nCS,
    rsel     => drv_rsel,
    nWE      => drv_nWE,
    nOE      => '1', -- not exercising the read side in this test
    rx_data           => (OTHERS => '0'),
    rx_data_available => '0',
    tx_data       => cdp_tx_data,
    tx_data_valid => cdp_tx_valid
  );

  u_tx_fifo : ENTITY work.byte_fifo
  GENERIC MAP ( g_depth_bits => 8 )
  PORT MAP (
    clk       => CLOCK,
    push      => cdp_tx_valid,
    push_data => cdp_tx_data,
    pop       => tx_fifo_pop,
    head      => tx_fifo_head,
    avail     => tx_fifo_avail
  );

  u_uart_tx : ENTITY work.uart_tx
  GENERIC MAP ( g_clks_per_bit => g_clks_per_bit )
  PORT MAP (
    clk        => CLOCK,
    fifo_data  => tx_fifo_head,
    fifo_avail => tx_fifo_avail,
    fifo_pop   => tx_fifo_pop,
    serial_out => serial_loop,
    tx_active  => dbg_tx_active
  );

  dbg_serial_loop <= serial_loop;

  u_uart_rx : ENTITY work.uart_rx
  GENERIC MAP ( g_clks_per_bit => g_clks_per_bit )
  PORT MAP (
    clk            => CLOCK,
    serial_in      => serial_loop, -- fabric self-loopback, no physical pin
    byte_out       => rx_byte,
    byte_out_valid => rx_byte_valid
  );

  u_rx_fifo : ENTITY work.byte_fifo
  GENERIC MAP ( g_depth_bits => 8 )
  PORT MAP (
    clk       => CLOCK,
    push      => rx_byte_valid,
    push_data => rx_byte,
    pop       => rxpop_i,
    head      => rx_fifo_head,
    avail     => rx_fifo_avail
  );

  rx_data <= rx_fifo_head;
  status_out <= "00000" & rx_fifo_avail & done_latched & drv_busy;

END str;
