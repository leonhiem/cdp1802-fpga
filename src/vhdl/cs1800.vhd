-------------------------------------------------------------------------------
--
-- File Name: cs1800.vhd
-- Author: Leon Hiemstra
--
-- Title: CS1800 Microprocessor System
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
USE work.cdp1802_pkg.ALL;


ENTITY cs1800 IS
  PORT (
    CLOCK    : IN    STD_LOGIC;

    LC       : IN    STD_LOGIC;
    Q       : OUT    STD_LOGIC;
    nEF      : IN    STD_LOGIC_VECTOR(2 DOWNTO 0);

    reset : IN STD_LOGIC;
    halt  : IN STD_LOGIC;
    single : IN STD_LOGIC;
    run : IN STD_LOGIC
  );
END cs1800;


ARCHITECTURE str OF cs1800 IS

  SIGNAL  tpa  : STD_LOGIC;
  SIGNAL  tpb  : STD_LOGIC;
  SIGNAL  nmrd  : STD_LOGIC;
  SIGNAL  nmwr  : STD_LOGIC;
  SIGNAL  nINT  : STD_LOGIC := '1';

  SIGNAL n  : STD_LOGIC_VECTOR(2 DOWNTO 0);
  -- FPGA note: see cdp18.vhd -- 'data' is now an explicit OR-merge of
  -- drivers that are each '0' when not selected, instead of a
  -- tri-state-resolved net. No internal 'Z'.
  SIGNAL data  : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL cpu_data_out : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL cpu_data_oe  : STD_LOGIC; -- unused here; useful for a future AXI/BRAM bridge
  SIGNAL ram_data_out : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL io_input_data : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL addr  : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL addr_high  : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL ram_addr  : STD_LOGIC_VECTOR(15 DOWNTO 0);

  SIGNAL n_memsel   : STD_LOGIC;
  SIGNAL n_io_out_sel : STD_LOGIC;
  SIGNAL n_io_in_sel : STD_LOGIC;
  SIGNAL io_output   : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL io_input_ptrn   : STD_LOGIC_VECTOR(7 DOWNTO 0) := "11000101"; -- something to put in

BEGIN


  u_cs1800_cpu : ENTITY work.cs1800_cpu
  PORT MAP (
    CLOCK    => CLOCK,
    LC    => LC,
    Q        => Q,
    nEF      => nEF,
    ADDR     => addr,
    DATA_IN  => data,
    DATA_OUT => cpu_data_out,
    DATA_OE  => cpu_data_oe,
    N        => n,
    TPA      => tpa,
    TPB      => tpb,
    nMRD     => nmrd,
    nMWR     => nmwr,
    nINT     => nINT,
    reset => reset,
    halt => halt,
    single => single,
    run => run
  );

  p_reg_high_addr : PROCESS(tpa, addr)
  BEGIN
    IF rising_edge(tpa) THEN
      addr_high <= addr;
    END IF;
  END PROCESS;

  ram_addr(7 DOWNTO 0) <= addr;
  ram_addr(15 DOWNTO 8) <= addr_high;

  n_memsel <= '0';


  u_ram : ENTITY work.ram
  PORT MAP (
    address  => ram_addr,
    data_in  => data,
    data_out => ram_data_out,
    nWE      => nmwr,
    nCS      => n_memsel,
    nOE      => nmrd
  );

  n_io_out_sel <= '0' WHEN n = "101" ELSE '1';
  n_io_in_sel <= '0' WHEN (n = "101" AND nmrd = '1') ELSE '1';

  u_io_out : ENTITY work.io_out
  PORT MAP (
    clk => tpb,
    data => data,
    output => io_output,
    nWE => nmrd,
    nCS => n_io_out_sel
  );

  u_io_inp : ENTITY work.io_inp
  PORT MAP (
    data => io_input_data,
    input => io_input_ptrn,
    nCS => n_io_in_sel
  );

  data <= cpu_data_out OR ram_data_out OR io_input_data;

END str;
