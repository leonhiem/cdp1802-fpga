-------------------------------------------------------------------------------
--
-- File Name: cs1800_cpu.vhd
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


ENTITY cs1800_cpu IS
  PORT (
    CLOCK    : IN    STD_LOGIC;

    LC       : IN    STD_LOGIC;
    Q        : OUT   STD_LOGIC;
    nINT     : IN    STD_LOGIC;
    nEF      : IN    STD_LOGIC_VECTOR(2 DOWNTO 0);
    ADDR     : OUT   STD_LOGIC_VECTOR(7 DOWNTO 0);
    -- FPGA note: see cdp1802.vhd -- split from INOUT into an explicit
    -- in/out/output-enable triplet, passed straight through here.
    DATA_IN  : IN    STD_LOGIC_VECTOR(7 DOWNTO 0);
    DATA_OUT : OUT   STD_LOGIC_VECTOR(7 DOWNTO 0);
    DATA_OE  : OUT   STD_LOGIC;
    N        : OUT   STD_LOGIC_VECTOR(2 DOWNTO 0);
    TPA      : OUT   STD_LOGIC;
    TPB      : OUT   STD_LOGIC;
    nMRD     : OUT   STD_LOGIC;
    nMWR     : OUT   STD_LOGIC;
    -- Debug visibility only (see boards/cora-z7-07s/): promoted from an
    -- internal signal, no behavior change.
    SC        : OUT   STD_LOGIC_VECTOR(1 DOWNTO 0);

    led_Q     : OUT   STD_LOGIC;
    led_fetch : OUT   STD_LOGIC;
    led_exec  : OUT   STD_LOGIC;
    led_dma_ack   : OUT   STD_LOGIC;
    led_int_ack   : OUT   STD_LOGIC;

    reset : IN STD_LOGIC;
    halt  : IN STD_LOGIC;
    single : IN STD_LOGIC;
    run : IN STD_LOGIC;

    -- FPGA note (board-level use, see boards/cora-z7-07s/): a real
    -- memory-ready wait-state input, using the CDP1802's own nWAIT/
    -- PAUSE mechanism (control.vhd: "IF r.mode = c_PAUSE THEN --
    -- pause" -- the state machine simply doesn't advance while
    -- paused, same mechanism a real 1802 uses for slow memory) rather
    -- than the halt bit above, which is a permanent system-level
    -- pause, not a per-access one. Defaults to '0' (never wait), so
    -- every existing instantiation (cs1800.vhd, and everything built
    -- on it) is completely unaffected unless a board wires this to a
    -- real "memory not ready yet" signal.
    mem_wait : IN STD_LOGIC := '0';

    -- Exploratory debug taps, 2026-09-15 (see cdp1802.vhd's own note
    -- and boards/cora-z7-07s/BRINGUP_LOG.md's "milestone 3i") --
    -- promoted straight through from cdp1802.vhd, no behavior change.
    dbg_tmp_page : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    dbg_R_in     : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    dbg_forceS1  : OUT STD_LOGIC;
    dbg_extraS1  : OUT STD_LOGIC
  );
END cs1800_cpu;


ARCHITECTURE str OF cs1800_cpu IS

  SIGNAL  nWAIT    : STD_LOGIC;
  SIGNAL  nCLEAR   : STD_LOGIC;
  SIGNAL  nDMA_OUT : STD_LOGIC;
  SIGNAL  nDMA_IN  : STD_LOGIC;
  SIGNAL  Q_i  : STD_LOGIC;
  SIGNAL  TPA_i  : STD_LOGIC;
  SIGNAL  nINT_i  : STD_LOGIC;
  SIGNAL  nINT_tmp  : STD_LOGIC;
  SIGNAL  nEF4_tmp  : STD_LOGIC;
  SIGNAL  lc_d1     : STD_LOGIC := '0'; -- LC, registered one CLOCK cycle,
                                        -- for a synchronous falling-edge
                                        -- detect (see p_lc_int below)
  SIGNAL  nEF_i  : STD_LOGIC_VECTOR(3 DOWNTO 0);

  SIGNAL int_ack : STD_LOGIC;
  SIGNAL int_ack_start : STD_LOGIC := '0';
  SIGNAL int_ack_stop : STD_LOGIC := '0';
  SIGNAL int_ack_counter : STD_LOGIC_vector(15 downto 0) := (OTHERS => '0');
  -- Reading the SC output port directly (VHDL-2008) is what GHDL/xsim
  -- validate against, but Vivado's synthesizer defaults .vhd files to
  -- VHDL-93, where an OUT port can't be read from inside its own
  -- architecture. Keep the internal signal and drive the port from it
  -- instead -- portable, no toolchain flag needed.
  SIGNAL sc_i : STD_LOGIC_VECTOR(1 DOWNTO 0);

BEGIN

  Q <= Q_i;
  led_Q <= Q_i;
  SC <= sc_i;

  led_fetch <= '1' WHEN sc_i="00" ELSE '0';
  led_exec  <= '1' WHEN sc_i="01" ELSE '0';
  led_dma_ack <= '1' WHEN sc_i="10" ELSE '0';

  int_ack <= '1' WHEN sc_i="11" ELSE '0';

  nDMA_OUT <= '1';
  nDMA_IN <= '1';

  TPA <= TPA_i;


  p_int_ack_extend : PROCESS(CLOCK, int_ack_start, int_ack_stop, reset)
  BEGIN
    IF reset = '1' OR int_ack_stop = '1' THEN
      int_ack_counter <= (OTHERS => '0');
    ELSIF rising_edge(CLOCK) THEN
      IF int_ack_start = '1' THEN
        int_ack_counter <= std_logic_vector(unsigned(int_ack_counter) + 1);
      END IF;
    END IF;
  END PROCESS;

  p_led_int_ack : PROCESS(CLOCK, int_ack, int_ack_counter)
  BEGIN
    IF rising_edge(CLOCK) THEN
      --IF int_ack_counter(15) = '1' THEN
      IF int_ack_counter(2) = '1' THEN
        int_ack_stop <= '1';
        int_ack_start <= '0';
      ELSIF int_ack = '1' THEN
        int_ack_start <= '1';
        int_ack_stop <= '0';
      END IF;
    END IF;
  END PROCESS;

  led_int_ack <= int_ack_start;



  -- FPGA note: the original process used falling_edge(LC) while also
  -- reading LC as a plain level in the same IF/ELSIF -- synthesis
  -- rejects that (a signal can't be both a clock and an async data
  -- input to the same flip-flop: "clock expression not supported").
  -- Rewritten as a fully CLOCK-synchronous process: lc_d1 registers LC
  -- one CLOCK cycle behind, so "lc_d1='1' and LC='0'" is a synchronous
  -- falling-edge detect instead of an asynchronous one.
  p_lc_int : PROCESS(CLOCK)
  BEGIN
    IF rising_edge(CLOCK) THEN
      lc_d1 <= LC;
      IF reset = '1' OR LC = '1' OR int_ack = '1' THEN
        nINT_tmp <= '1';
      ELSIF lc_d1 = '1' AND LC = '0' THEN
        nINT_tmp <= '0';
      END IF;
    END IF;
  END PROCESS;

  nEF4_tmp <= NOT Q_i;

  nINT_i <= '0' WHEN (nINT_tmp = '0' OR nINT = '0') ELSE '1';

  nEF_i(2 DOWNTO 0) <= nEF;
  nEF_i(3) <= nEF4_tmp;


  p_mode : PROCESS(single, halt, reset, run, TPA_i, mem_wait)
  BEGIN
    IF run = '1' THEN
      nWAIT <= NOT mem_wait; -- '1' (no wait) when mem_wait='0', its default
      nCLEAR <= '1';
    ELSIF halt = '1' THEN
      nWAIT <= '0';
      nCLEAR <= '1';
    ELSE -- reset
      nWAIT <= '1';
      nCLEAR <= '0';
--      IF single = '1' THEN
--        nWAIT <= '1';
--        nCLEAR <= '1';
--        IF falling_edge(TPA_i) THEN
--          nWAIT <= '0';
--          nCLEAR <= '1';
--        END IF;
    END IF;
  END PROCESS;
  
  u_cdp1802 : ENTITY work.cdp1802
  PORT MAP (
    CLOCK    => CLOCK,
    nWAIT    => nWAIT,
    nCLEAR   => nCLEAR,
    Q        => Q_i,
    SC       => sc_i,
    nMRD     => nMRD,
    DATA_IN  => DATA_IN,
    DATA_OUT => DATA_OUT,
    DATA_OE  => DATA_OE,
    N        => N,
    nEF      => nEF_i,
    ADDR     => ADDR,
    TPA      => TPA_i,
    TPB      => TPB,
    nMWR     => nMWR,
    nINT     => nINT_i,
    nDMA_OUT => nDMA_OUT,
    nDMA_IN  => nDMA_IN,
    dbg_tmp_page => dbg_tmp_page,
    dbg_R_in     => dbg_R_in,
    dbg_forceS1  => dbg_forceS1,
    dbg_extraS1  => dbg_extraS1
  );


END str;
