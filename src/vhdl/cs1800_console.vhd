-------------------------------------------------------------------------------
--
-- File Name: cs1800_console.vhd
-- Author: Leon Hiemstra
--
-- Title: CS1800 system with real memory map and dual-CDP1854 SIO board
--
-- License: MIT
--
-- Description:
--   Wraps the unmodified cs1800 core with the real backplane's memory
--   map (cs1800_memory.vhd: a ROM+RAM split, not a single flat RAM) and
--   a model of the real SIO board's two CDP1854 UARTs (cdp1854.vhd) plus
--   its port/register-select latch (cs1800_io_select.vhd) -- see
--   doc/CS1800_HARDWARE.md and doc/PRCX18_ANALYSIS.md for the real
--   hardware and firmware behavior this decode is built from.
--
--   IO device decode (schematic- and ROM-confirmed, see
--   doc/CS1800_HARDWARE.md's "This unit's actual jumper settings" and
--   doc/PRCX18_ANALYSIS.md):
--     N=1            -> cs1800_io_select (port/register-select latch),
--                       independent of Q
--     N=4, Q='1'     -> the CDP1854 pair, split by the latch's own
--                       bit 2 (0=port A, 1=port B); the latch's bit 1
--                       is each CDP1854's rsel (0=Data, 1=Status/Control)
--
--   uart_a_tx_data/valid and uart_b_tx_data/valid expose each port's
--   transmitted bytes for a testbench to capture -- see cdp1854.vhd's
--   header for why this needs no real serial-bit timing to be useful.
--
--   This entity holds no ROM content of its own -- rom_init is a
--   generic, supplied by whoever instantiates it (see
--   cs1800_memory.vhd's header).
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.std_logic_1164.ALL;
USE work.test_program_pkg.ALL; -- t_mem_array


ENTITY cs1800_console IS
  GENERIC (
    rom_size : INTEGER := 8192;
    rom_init : t_mem_array
  );
  PORT (
    CLOCK  : IN  STD_LOGIC;
    LC     : IN  STD_LOGIC;
    Q      : OUT STD_LOGIC;
    nEF    : IN  STD_LOGIC_VECTOR(2 DOWNTO 0);

    reset  : IN STD_LOGIC;
    halt   : IN STD_LOGIC;
    single : IN STD_LOGIC;
    run    : IN STD_LOGIC;

    -- Debug/observation, mirroring cs1800.vhd's own dbg_* ports.
    dbg_ram_addr : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    dbg_data     : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    dbg_nmrd     : OUT STD_LOGIC;
    dbg_nmwr     : OUT STD_LOGIC;
    dbg_tpb      : OUT STD_LOGIC;

    uart_a_tx_data  : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    uart_a_tx_valid : OUT STD_LOGIC;
    uart_b_tx_data  : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    uart_b_tx_valid : OUT STD_LOGIC
  );
END cs1800_console;

ARCHITECTURE str OF cs1800_console IS

  SIGNAL n_i    : STD_LOGIC_VECTOR(2 DOWNTO 0);
  SIGNAL q_i    : STD_LOGIC;
  SIGNAL tpb_i  : STD_LOGIC;
  SIGNAL nmrd_i : STD_LOGIC;
  SIGNAL nmwr_i : STD_LOGIC;
  SIGNAL data_i : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL ram_addr_i : STD_LOGIC_VECTOR(15 DOWNTO 0);
  SIGNAL ram_dout_i : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL io_din_i    : STD_LOGIC_VECTOR(7 DOWNTO 0);

  SIGNAL sel1_n : STD_LOGIC; -- N=1, active low
  SIGNAL sel4_n : STD_LOGIC; -- N=4 and Q='1', active low
  SIGNAL io_sel_reg : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL uart_a_nsel : STD_LOGIC;
  SIGNAL uart_b_nsel : STD_LOGIC;
  SIGNAL uart_a_dout : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL uart_b_dout : STD_LOGIC_VECTOR(7 DOWNTO 0);

BEGIN

  Q <= q_i;

  sel1_n <= '0' WHEN n_i = "001" ELSE '1';
  sel4_n <= '0' WHEN (n_i = "100" AND q_i = '1') ELSE '1';

  uart_a_nsel <= '0' WHEN (sel4_n = '0' AND io_sel_reg(2) = '0') ELSE '1';
  uart_b_nsel <= '0' WHEN (sel4_n = '0' AND io_sel_reg(2) = '1') ELSE '1';

  io_din_i <= uart_a_dout OR uart_b_dout;

  u_cs1800 : ENTITY work.cs1800
  PORT MAP (
    CLOCK => CLOCK,
    LC    => LC,
    Q     => q_i,
    nEF   => nEF,

    reset  => reset,
    halt   => halt,
    single => single,
    run    => run,

    dbg_ram_addr => ram_addr_i,
    dbg_data     => data_i,
    dbg_nmrd     => nmrd_i,
    dbg_nmwr     => nmwr_i,
    dbg_tpb      => tpb_i,
    dbg_n        => n_i,
    ram_data_out_ext => ram_dout_i,
    io_data_in_ext   => io_din_i
  );

  u_mem : ENTITY work.cs1800_memory
  GENERIC MAP (
    rom_size => rom_size,
    rom_init => rom_init
  )
  PORT MAP (
    clk      => CLOCK,
    address  => ram_addr_i,
    data_in  => data_i,
    data_out => ram_dout_i,
    nWE => nmwr_i,
    nCS => '0',
    nOE => nmrd_i
  );

  -- FPGA/1802 note: for IO (N/=0), the roles of nMRD/nMWR invert relative
  -- to a plain memory access -- OUT is mechanically "read M(R(X)) into D"
  -- (asserts Do_MRD, i.e. nmrd_i), so an IO device's *write* (capture)
  -- strobe is driven by nmrd_i here, not nmwr_i; INP is mechanically
  -- "write BUS into M(R(X))" (asserts Do_MWR, i.e. nmwr_i), so an IO
  -- device's *read* (drive-the-bus) strobe is driven by nmwr_i. Confirmed
  -- directly against instr.vhd's OUT/INP cycles (Do_MRD/Do_MWR) and
  -- matching cs1800.vhd's own existing io_out.vhd wiring (nWE => nmrd).
  -- u_mem above is a real memory device, not IO, so it keeps the
  -- ordinary, non-inverted mapping.
  u_io_select : ENTITY work.cs1800_io_select
  PORT MAP (
    clk     => tpb_i,
    data_in => data_i,
    nCS     => sel1_n,
    nWE     => nmrd_i,
    sel_out => io_sel_reg
  );

  u_uart_a : ENTITY work.cdp1854
  PORT MAP (
    clk      => tpb_i,
    data_in  => data_i,
    data_out => uart_a_dout,
    nCS  => uart_a_nsel,
    rsel => io_sel_reg(1),
    nWE  => nmrd_i,
    nOE  => nmwr_i,
    tx_data       => uart_a_tx_data,
    tx_data_valid => uart_a_tx_valid
  );

  u_uart_b : ENTITY work.cdp1854
  PORT MAP (
    clk      => tpb_i,
    data_in  => data_i,
    data_out => uart_b_dout,
    nCS  => uart_b_nsel,
    rsel => io_sel_reg(1),
    nWE  => nmrd_i,
    nOE  => nmwr_i,
    tx_data       => uart_b_tx_data,
    tx_data_valid => uart_b_tx_valid
  );

  dbg_ram_addr <= ram_addr_i;
  dbg_data     <= data_i;
  dbg_nmrd     <= nmrd_i;
  dbg_nmwr     <= nmwr_i;
  dbg_tpb      <= tpb_i;

END str;
