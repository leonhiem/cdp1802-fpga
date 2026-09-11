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
    run : IN STD_LOGIC;

    -- RAM is external (see boards/cora-z7-07s/dp_ram.vhd): dbg_ram_addr/
    -- dbg_data/dbg_nmrd/dbg_nmwr double as the real interface an
    -- external memory needs (address, write-data, strobes) as well as
    -- ILA debug visibility -- ram_data_out_ext feeds its read result
    -- back into the system bus merge below. dbg_sc/dbg_tpb are
    -- debug-only, no external memory needs them. No effect on cs1800's
    -- own functional behavior beyond the RAM itself moving outside it.
    dbg_ram_addr : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    dbg_data     : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    dbg_nmrd     : OUT STD_LOGIC;
    dbg_nmwr     : OUT STD_LOGIC;
    dbg_sc       : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    dbg_tpb      : OUT STD_LOGIC;
    ram_data_out_ext : IN STD_LOGIC_VECTOR(7 DOWNTO 0)
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
  SIGNAL io_input_data : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL sc_i  : STD_LOGIC_VECTOR(1 DOWNTO 0);
  SIGNAL addr  : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL addr_high  : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL ram_addr  : STD_LOGIC_VECTOR(15 DOWNTO 0);

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
    SC       => sc_i,
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

  data <= cpu_data_out OR ram_data_out_ext OR io_input_data;

  dbg_ram_addr <= ram_addr;
  dbg_data     <= data;
  dbg_nmrd     <= nmrd;
  dbg_nmwr     <= nmwr;
  dbg_sc       <= sc_i;
  dbg_tpb      <= tpb;

END str;
