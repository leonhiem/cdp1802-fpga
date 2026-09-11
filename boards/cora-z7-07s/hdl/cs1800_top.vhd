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
--   Wraps cs1800 (src/vhdl/cs1800.vhd, untouched) for instantiation in
--   the Zynq PL block design, as the AXI-GPIO-facing control/status
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
--   idiom (`sig <= not sig after <time>`), so it can't be reused as-is --
--   this is genuinely new hardware.
--
--   ram_addr/data/nMRD/nMWR/SC/TPB are the same six signals
--   sim/ghdl/reference/tb_cs1800_tpb.txt records per TPB pulse; cs1800
--   exposes them as dbg_* debug-only ports (see cs1800.vhd), passed
--   straight through here so the board build script can wire them to a
--   system_ila in the block design.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;


ENTITY cs1800_top IS
  GENERIC (
    -- CLOCK cycles per LC half-period. Default is 50 Hz (the real
    -- backplane's line-clock rate) at CLOCK = 100 MHz:
    --   1 / (2 * 50 Hz) = 10 ms = 1,000,000 cycles @ 100 MHz
    g_lc_half_period : POSITIVE := 1_000_000
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
    dbg_tpb      : OUT STD_LOGIC
  );
END cs1800_top;


ARCHITECTURE str OF cs1800_top IS

  SIGNAL lc     : STD_LOGIC := '0';
  SIGNAL lc_cnt : UNSIGNED(31 DOWNTO 0) := (OTHERS => '0');
  SIGNAL Q      : STD_LOGIC;

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

    dbg_ram_addr => dbg_ram_addr,
    dbg_data     => dbg_data,
    dbg_nmrd     => dbg_nmrd,
    dbg_nmwr     => dbg_nmwr,
    dbg_sc       => dbg_sc,
    dbg_tpb      => dbg_tpb
  );

  status_out <= "000000" & lc & Q;

END str;
