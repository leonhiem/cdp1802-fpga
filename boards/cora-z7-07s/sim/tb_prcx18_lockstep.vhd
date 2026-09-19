-------------------------------------------------------------------------------
--
-- File Name: tb_prcx18_lockstep.vhd
--
-- Title: real PRCX-18 boot + DMP, logged for the lockstep ISA check
--
-- License: MIT
--
-- Description:
--   Boots the real PRCX-18 v1.9.0 ROM on cs1800_prcx18_top (the Cora
--   design: ROM 0x0000-0x1FFF, RAM 0x4000-0x5FFF, CDP1854 console, LC at
--   50 Hz), waits for the "_08> " prompt, types DMP<CR> and drains the
--   TX FIFO slowly (one byte per 1000 clocks, like the devmem bridge on
--   the board), so TX back-pressure (THRE) gets exercised too.
--
--   The ROM itself is NOT in this repo: work.prcx18_rom_pkg is generated
--   locally from your own EPROM dump by gen_rom_pkg.py. See README.md
--   ("Testing") and run_prcx18_lockstep.sh, which does all of it.
--
--   Output files (in the working directory):
--     cyc.log   : "C <sc> <addr> <data> <R|->" at every TPB (one line per
--                 machine cycle) and "W <addr> <data>" per nMWR pulse --
--                 the input for boards/cora-z7-07s/lockstep1802.py
--     drain.log : every byte drained from the TX FIFO (hex, one per line)
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE STD.TEXTIO.ALL;
USE work.prcx18_rom_pkg.ALL;

ENTITY tb_prcx18_lockstep IS
  GENERIC (
    g_max_cycles : NATURAL := 4_000_000 -- CLOCK cycles after reset release (1 s at 4 MHz)
  );
END tb_prcx18_lockstep;

ARCHITECTURE tb OF tb_prcx18_lockstep IS

  CONSTANT clk_period : TIME := 250 ns; -- 4 MHz, the real CDP1802 clock

  -- ctrl_in: bit0 reset, bit3..1 nEF, bit5 LC run, bit6 run, bit7 FIFO pop
  CONSTANT c_ctrl_reset : STD_LOGIC_VECTOR(7 DOWNTO 0) := "01100001";
  CONSTANT c_ctrl_run   : STD_LOGIC_VECTOR(7 DOWNTO 0) := "01101000";

  SIGNAL clk        : STD_LOGIC := '0';
  SIGNAL tb_end     : STD_LOGIC := '0';
  SIGNAL ctrl_base  : STD_LOGIC_VECTOR(7 DOWNTO 0) := c_ctrl_reset;
  SIGNAL pop        : STD_LOGIC := '0';
  SIGNAL ctrl_in    : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL status_out : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL running    : BOOLEAN := FALSE;

  SIGNAL a_full : STD_LOGIC_VECTOR(15 DOWNTO 0);
  SIGNAL data   : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL nmrd   : STD_LOGIC;
  SIGNAL nmwr   : STD_LOGIC;
  SIGNAL sc     : STD_LOGIC_VECTOR(1 DOWNTO 0);
  SIGNAL tpb    : STD_LOGIC;

  SIGNAL ram_b_addr : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL ram_b_din  : STD_LOGIC_VECTOR(31 DOWNTO 0) := (OTHERS => '0');
  SIGNAL ram_b_we   : STD_LOGIC_VECTOR(3 DOWNTO 0)  := (OTHERS => '0');
  SIGNAL ram_b_en   : STD_LOGIC := '0';

  SIGNAL uart_rx_data      : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL uart_rx_available : STD_LOGIC := '0';
  SIGNAL fifo_data         : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL fifo_avail        : STD_LOGIC;

  -- Prompt counter, from the drained byte stream (">" characters)
  SIGNAL prompts : NATURAL := 0;

BEGIN

  clk <= NOT clk OR tb_end AFTER clk_period/2;
  ctrl_in <= (pop OR ctrl_base(7)) & ctrl_base(6 DOWNTO 0);

  p_test : PROCESS
    TYPE t_keys IS ARRAY (0 TO 3) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
    CONSTANT c_keys : t_keys := (X"44", X"4D", X"50", X"0D"); -- "DMP" <CR>
  BEGIN
    ctrl_base <= c_ctrl_reset;
    FOR i IN 0 TO 20 LOOP WAIT UNTIL rising_edge(clk); END LOOP;

    -- Load the ROM through Port B, CPU held in reset (as on the board)
    FOR i IN 0 TO (c_prcx18_rom'LENGTH / 4) - 1 LOOP
      ram_b_addr <= STD_LOGIC_VECTOR(TO_UNSIGNED(i * 4, 16));
      ram_b_din  <= c_prcx18_rom(i*4 + 3) & c_prcx18_rom(i*4 + 2)
                  & c_prcx18_rom(i*4 + 1) & c_prcx18_rom(i*4 + 0);
      ram_b_we   <= "1111";
      ram_b_en   <= '1';
      WAIT UNTIL rising_edge(clk);
    END LOOP;
    ram_b_en <= '0';
    ram_b_we <= "0000";
    FOR i IN 0 TO 20 LOOP WAIT UNTIL rising_edge(clk); END LOOP;

    ctrl_base <= c_ctrl_run;
    running   <= TRUE;

    WAIT UNTIL prompts >= 1 FOR g_max_cycles * clk_period;
    IF prompts >= 1 THEN
      FOR i IN 0 TO 40000 LOOP WAIT UNTIL rising_edge(clk); END LOOP;
      FOR k IN c_keys'RANGE LOOP
        uart_rx_data      <= c_keys(k);
        uart_rx_available <= '1';
        FOR i IN 0 TO 2000 LOOP WAIT UNTIL rising_edge(clk); END LOOP;
        uart_rx_available <= '0';
        FOR i IN 0 TO 50000 LOOP WAIT UNTIL rising_edge(clk); END LOOP;
      END LOOP;
      -- until the prompt after the dump, or the time limit
      WAIT UNTIL prompts >= 2 FOR g_max_cycles * clk_period;
      FOR i IN 0 TO 20000 LOOP WAIT UNTIL rising_edge(clk); END LOOP;
    END IF;

    REPORT "DONE, prompts seen: " & INTEGER'IMAGE(prompts);
    tb_end <= '1';
    WAIT;
  END PROCESS;

  -- Slow software-style TX FIFO drain: one byte per 1000 clocks.
  p_drain : PROCESS
    FILE f_drain : TEXT OPEN WRITE_MODE IS "drain.log";
    VARIABLE l : LINE;
  BEGIN
    WAIT UNTIL running;
    LOOP
      FOR i IN 0 TO 1000 LOOP
        WAIT UNTIL rising_edge(clk);
        EXIT WHEN tb_end = '1';
      END LOOP;
      EXIT WHEN tb_end = '1';
      IF fifo_avail = '1' THEN
        WRITE(l, to_hstring(fifo_data));
        WRITELINE(f_drain, l);
        IF fifo_data = X"3E" THEN
          prompts <= prompts + 1;
        END IF;
        pop <= '1';
        WAIT UNTIL rising_edge(clk);
        WAIT UNTIL rising_edge(clk);
        pop <= '0';
      END IF;
    END LOOP;
    WAIT;
  END PROCESS;

  u_dut : ENTITY work.cs1800_prcx18_top
  GENERIC MAP ( g_lc_half_period => 40000, g_ram_words => 2048 )
  PORT MAP (
    CLOCK      => clk,
    ctrl_in    => ctrl_in,
    status_out => status_out,

    dbg_data   => data,
    dbg_nmrd   => nmrd,
    dbg_nmwr   => nmwr,
    dbg_sc     => sc,
    dbg_tpb    => tpb,
    dbg_a_full => a_full,

    ram_b_addr => ram_b_addr,
    ram_b_din  => ram_b_din,
    ram_b_we   => ram_b_we,
    ram_b_en   => ram_b_en,

    uart_rx_data       => uart_rx_data,
    uart_rx_available  => uart_rx_available,
    uart_tx_fifo_data  => fifo_data,
    uart_tx_fifo_avail => fifo_avail
  );

  -- Machine-cycle log for lockstep1802.py
  p_cyc : PROCESS
    FILE f_out : TEXT OPEN WRITE_MODE IS "cyc.log";
    VARIABLE l : LINE;
    VARIABLE rd : BOOLEAN := FALSE;
    VARIABLE wa : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0');
    VARIABLE wd : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    VARIABLE prev_tpb, prev_nmwr : STD_LOGIC := '0';
  BEGIN
    WAIT UNTIL running;
    LOOP
      WAIT UNTIL rising_edge(clk);
      EXIT WHEN tb_end = '1';
      IF nmrd = '0' THEN rd := TRUE; END IF;
      IF nmwr = '0' THEN wa := a_full; wd := data; END IF;
      IF nmwr = '1' AND prev_nmwr = '0' THEN
        WRITE(l, STRING'("W "));
        WRITE(l, to_hstring(wa));
        WRITE(l, STRING'(" "));
        WRITE(l, to_hstring(wd));
        WRITELINE(f_out, l);
      END IF;
      IF tpb = '1' AND prev_tpb = '0' THEN
        WRITE(l, STRING'("C "));
        WRITE(l, to_hstring(sc));
        WRITE(l, STRING'(" "));
        WRITE(l, to_hstring(a_full));
        WRITE(l, STRING'(" "));
        WRITE(l, to_hstring(data));
        IF rd THEN WRITE(l, STRING'(" R")); ELSE WRITE(l, STRING'(" -")); END IF;
        WRITELINE(f_out, l);
        rd := FALSE;
      END IF;
      prev_tpb  := tpb;
      prev_nmwr := nmwr;
    END LOOP;
    WAIT;
  END PROCESS;

END tb;
