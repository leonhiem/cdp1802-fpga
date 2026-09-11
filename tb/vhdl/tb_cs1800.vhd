-------------------------------------------------------------------------------
--
-- File Name: tb_cs1800.vhd
-- Author: Leon Hiemstra
--
-- Title: CDP18 testbench
--
-- License: MIT
--
-- Description: 
--
--
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.std_logic_1164.ALL;
USE IEEE.numeric_std.ALL;


ENTITY tb_cs1800 IS
END tb_cs1800; 

ARCHITECTURE tb OF tb_cs1800 IS

  CONSTANT clk_period   : TIME := 250 ns; -- 4 MHz

  SIGNAL clk    : STD_LOGIC := '0';
  SIGNAL tb_end : STD_LOGIC := '0';
  SIGNAL reset  : STD_LOGIC := '1';
  SIGNAL halt : STD_LOGIC := '0';
  SIGNAL single : STD_LOGIC := '0';
  SIGNAL run : STD_LOGIC := '0';
  SIGNAL LC      : STD_LOGIC := '0';
  SIGNAL Q      : STD_LOGIC;
  SIGNAL nEF    : STD_LOGIC_VECTOR(2 DOWNTO 0) := "110";

  -- cs1800's RAM is external (matching the real backplane: RAM lives on
  -- separate cards, not on the CPU card) -- wire up the same ram.vhd it
  -- used to instantiate internally.
  SIGNAL tb_ram_addr  : STD_LOGIC_VECTOR(15 DOWNTO 0);
  SIGNAL tb_ram_wdata : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL tb_ram_rdata : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL tb_ram_nmrd  : STD_LOGIC;
  SIGNAL tb_ram_nmwr  : STD_LOGIC;

BEGIN

  clk <= NOT clk OR tb_end AFTER clk_period/2;
  LC <= NOT LC OR tb_end AFTER clk_period*200;

  p_in_stimuli : PROCESS
  BEGIN


    -- RESET:
    reset <= '1';

    FOR I IN 0 TO 20 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    -- RUN:
    reset <= '0';
    run  <= '1';

    FOR I IN 0 TO 200 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    -- PAUSE:
    run <= '0';
    halt  <= '1';

    FOR I IN 0 TO 20 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    -- RUN:
    halt <= '0';
    run  <= '1';

    FOR I IN 0 TO 4000 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    tb_end <= '1';
    WAIT;
  END PROCESS;


  -- device under test
  u_dut : ENTITY work.cs1800
  PORT MAP (
    CLOCK    => clk,
    LC       => LC,
    Q        => Q,
    nEF      => nEF,

    reset => reset,
    halt  => halt,
    single => single,
    run => run,

    dbg_ram_addr => tb_ram_addr,
    dbg_data     => tb_ram_wdata,
    dbg_nmrd     => tb_ram_nmrd,
    dbg_nmwr     => tb_ram_nmwr,
    ram_data_out_ext => tb_ram_rdata
  );

  u_ram : ENTITY work.ram
  PORT MAP (
    clk      => clk,
    address  => tb_ram_addr,
    data_in  => tb_ram_wdata,
    data_out => tb_ram_rdata,
    nWE      => tb_ram_nmwr,
    nCS      => '0',
    nOE      => tb_ram_nmrd
  );

END tb;

