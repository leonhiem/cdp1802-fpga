-------------------------------------------------------------------------------
--
-- File Name: cs1800_top.vhd
-- Author: Leon Hiemstra
--
-- Title: CS1800 FPGA bring-up top-level (Cora Z7-07S)
--
-- License: MIT
--
-- Description:
--   Wraps cs1800 (src/vhdl/cs1800.vhd, untouched aside from its RAM
--   moving external -- see cs1800.vhd's own header) for instantiation
--   in the Zynq PL block design, as the AXI-GPIO-facing control/status
--   byte pair (see boards/cora-z7-07s/README.md):
--
--     ctrl_in(0)          -> reset
--     ctrl_in(1)          -> halt
--     ctrl_in(2)          -> single  (currently a no-op in cs1800_cpu.vhd)
--     ctrl_in(3)          -> run
--     ctrl_in(6 downto 4) -> nEF(2 downto 0)
--     ctrl_in(7)          -> unused
--
--     status_out(0)       <- Q
--     status_out(1)       <- LC (so a plain devmem poll can see something
--                                moving, independent of the ILA capture)
--     status_out(7 downto 2) <- "000000" reserved
--
--   LC ("line clock") itself is generated here by a free-running divider:
--   in tb_cs1800.vhd, LC is a non-synthesizable simulation-only oscillator
--   idiom (`sig <= not sig after <time>`), so this is genuinely new
--   hardware.
--
--   RAM (shared_ram.vhd) is instantiated here, not inside cs1800.vhd:
--   Port A is the CPU-facing side (matching the real backplane, where
--   RAM lives on separate cards from the CPU card, not on it), Port B
--   is exposed as this entity's own ports for the AXI side
--   (axi_bram_ctrl in the block design), so Linux can load a program
--   into it while cs1800 is held in reset. The two sides are never
--   accessed at once in practice (cs1800 is held in reset while
--   software writes a program), so this is a single-port-timing memory
--   with write access arbitrated by sel_ext -- see shared_ram.vhd's own
--   header for why (an earlier true-dual-port attempt, needing
--   genuinely synchronous Block RAM on both sides, broke a
--   timing-critical read inside cdp1802).
--
--   dbg_* ports are cs1800's own -- see cs1800.vhd -- passed straight
--   through so the board build script can wire them to a system_ila.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;


ENTITY cs1800_top IS
  GENERIC (
    g_lc_half_period : POSITIVE := 1_000_000 -- CLOCK cycles per LC half-period
  );
  PORT (
    CLOCK      : IN  STD_LOGIC;

    ctrl_in    : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
    status_out : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);

    dbg_ram_addr : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    dbg_data     : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    dbg_nmrd     : OUT STD_LOGIC;
    dbg_nmwr     : OUT STD_LOGIC;
    dbg_sc       : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    dbg_tpb      : OUT STD_LOGIC;

    -- shared_ram Port B: native BRAM-style port for axi_bram_ctrl.
    ram_b_addr : IN  STD_LOGIC_VECTOR(15 DOWNTO 0);
    ram_b_din  : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
    ram_b_dout : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    ram_b_we   : IN  STD_LOGIC;
    ram_b_en   : IN  STD_LOGIC
  );
END cs1800_top;


ARCHITECTURE str OF cs1800_top IS

  SIGNAL lc     : STD_LOGIC := '0';
  SIGNAL lc_cnt : UNSIGNED(31 DOWNTO 0) := (OTHERS => '0');
  SIGNAL Q      : STD_LOGIC;

  SIGNAL ram_addr  : STD_LOGIC_VECTOR(15 DOWNTO 0);
  SIGNAL ram_wdata : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL ram_rdata : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL ram_nmrd  : STD_LOGIC;
  SIGNAL ram_nmwr  : STD_LOGIC;

BEGIN

  -- Free-running LC divider: toggles every g_lc_half_period CLOCK
  -- cycles. On the real backplane this line comes from external
  -- (mains-derived) hardware; here it's just a plain counter.
  p_lc_gen : PROCESS(CLOCK)
  BEGIN
    IF rising_edge(CLOCK) THEN
      IF lc_cnt = to_unsigned(g_lc_half_period - 1, lc_cnt'length) THEN
        lc_cnt <= (OTHERS => '0');
        lc     <= NOT lc;
      ELSE
        lc_cnt <= lc_cnt + 1;
      END IF;
    END IF;
  END PROCESS;

  u_cs1800 : ENTITY work.cs1800
  PORT MAP (
    CLOCK  => CLOCK,
    LC     => lc,
    Q      => Q,
    nEF    => ctrl_in(6 DOWNTO 4),
    reset  => ctrl_in(0),
    halt   => ctrl_in(1),
    single => ctrl_in(2),
    run    => ctrl_in(3),

    dbg_ram_addr => ram_addr,
    dbg_data     => ram_wdata,
    dbg_nmrd     => ram_nmrd,
    dbg_nmwr     => ram_nmwr,
    dbg_sc       => dbg_sc,
    dbg_tpb      => dbg_tpb,
    ram_data_out_ext => ram_rdata
  );

  dbg_ram_addr <= ram_addr;
  dbg_data     <= ram_wdata;
  dbg_nmrd     <= ram_nmrd;
  dbg_nmwr     <= ram_nmwr;

  -- Write access goes to Port B (AXI/Linux) while cs1800 is held in
  -- reset, and to Port A (the CPU) once it's running -- matching the
  -- hold-in-reset-while-loading workflow, so the two sides are never
  -- actually contending for the write port.
  u_ram : ENTITY work.shared_ram
  PORT MAP (
    clk     => CLOCK,
    sel_ext => ctrl_in(0), -- '1' while reset is asserted

    a_address  => ram_addr,
    a_data_in  => ram_wdata,
    a_data_out => ram_rdata,
    a_nWE      => ram_nmwr,
    a_nCS      => '0',
    a_nOE      => ram_nmrd,

    b_addr => ram_b_addr,
    b_din  => ram_b_din,
    b_dout => ram_b_dout,
    b_we   => ram_b_we,
    b_en   => ram_b_en
  );

  status_out <= "000000" & lc & Q;

END str;
