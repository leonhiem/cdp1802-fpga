-------------------------------------------------------------------------------
--
-- File Name: tb_cs1800_top.vhd
-- Author: Leon Hiemstra
--
-- Title: cs1800_top reference-dump testbench
--
-- License: MIT
--
-- Description:
--   Drives cs1800_top's ctrl_in the same way tb_cs1800.vhd drives
--   cs1800 directly (same reset/run/halt/run cycle counts, same
--   nEF="110"), with g_lc_half_period overridden to 200 CLOCK cycles
--   to match tb_cs1800.vhd's LC exactly -- letting this compare against
--   the *entire* sim/ghdl/reference/tb_cs1800_tpb.txt, interrupt
--   choreography included, not just the pre-interrupt segment (LC
--   can't be synchronized like this against real hardware, but it can
--   here).
--
--   This is the empirical check for whether dp_ram's one CLOCK cycle
--   of read latency (real Block RAM, needed for independent dual-port
--   access -- see dp_ram.vhd) is absorbed by the design's existing
--   timing margin (nMRD/nMWR stay asserted for several CLOCK cycles
--   per access) with no other changes needed.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE STD.TEXTIO.ALL;


ENTITY tb_cs1800_top IS
END tb_cs1800_top;

ARCHITECTURE tb OF tb_cs1800_top IS

  CONSTANT clk_period : TIME := 250 ns; -- 4 MHz

  SIGNAL clk        : STD_LOGIC := '0';
  SIGNAL tb_end      : STD_LOGIC := '0';
  SIGNAL ctrl_in     : STD_LOGIC_VECTOR(7 DOWNTO 0) := "01100001"; -- reset=1, nEF="110"
  SIGNAL status_out  : STD_LOGIC_VECTOR(7 DOWNTO 0);

  SIGNAL ram_addr : STD_LOGIC_VECTOR(15 DOWNTO 0);
  SIGNAL data     : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL nmrd     : STD_LOGIC;
  SIGNAL nmwr     : STD_LOGIC;
  SIGNAL sc       : STD_LOGIC_VECTOR(1 DOWNTO 0);
  SIGNAL tpb      : STD_LOGIC;

BEGIN

  clk <= NOT clk OR tb_end AFTER clk_period/2;

  p_in_stimuli : PROCESS
  BEGIN
    -- RESET: (matches tb_cs1800.vhd)
    ctrl_in <= "01100001"; -- reset=1
    FOR i IN 0 TO 20 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    -- RUN:
    ctrl_in <= "01101000"; -- run=1
    FOR i IN 0 TO 200 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    -- PAUSE:
    ctrl_in <= "01100010"; -- halt=1
    FOR i IN 0 TO 20 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    -- RUN:
    ctrl_in <= "01101000"; -- run=1
    FOR i IN 0 TO 4000 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    tb_end <= '1';
    WAIT;
  END PROCESS;

  u_dut : ENTITY work.cs1800_top
  GENERIC MAP ( g_lc_half_period => 200 )
  PORT MAP (
    CLOCK      => clk,
    ctrl_in    => ctrl_in,
    status_out => status_out,

    dbg_ram_addr => ram_addr,
    dbg_data     => data,
    dbg_nmrd     => nmrd,
    dbg_nmwr     => nmwr,
    dbg_sc       => sc,
    dbg_tpb      => tpb,

    ram_b_addr => (OTHERS => '0'),
    ram_b_din  => (OTHERS => '0'),
    ram_b_we   => '0',
    ram_b_en   => '0'
  );

  -- Reference dump: one line per TPB pulse, same format as
  -- sim/ghdl/reference/tb_cs1800_tpb.txt.
  p_dump : PROCESS
    FILE     f_out : TEXT OPEN WRITE_MODE IS "tb_cs1800_top_tpb.txt";
    VARIABLE l : LINE;
  BEGIN
    WRITE(l, STRING'("# time_ns ram_addr data nMRD nMWR Q SC"));
    WRITELINE(f_out, l);

    LOOP
      WAIT UNTIL rising_edge(clk);
      EXIT WHEN tb_end = '1';

      IF tpb = '1' THEN
        WRITE(l, NOW / 1 ns);
        WRITE(l, STRING'(" "));
        WRITE(l, to_hstring(ram_addr));
        WRITE(l, STRING'(" "));
        WRITE(l, to_hstring(data));
        WRITE(l, STRING'(" "));
        WRITE(l, to_string(nmrd));
        WRITE(l, STRING'(" "));
        WRITE(l, to_string(nmwr));
        WRITE(l, STRING'(" "));
        WRITE(l, to_string(status_out(0))); -- Q
        WRITE(l, STRING'(" "));
        WRITE(l, to_string(sc));
        WRITELINE(f_out, l);
      END IF;
    END LOOP;

    WAIT;
  END PROCESS;

END tb;
