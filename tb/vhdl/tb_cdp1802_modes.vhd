-------------------------------------------------------------------------------
--
-- File Name: tb_cdp1802_modes.vhd
--
-- Title: the CDP1802's four control modes (CLEAR/WAIT), checked per clock
--
-- License: MIT
--
-- Description:
--   TODO 2.6 (doc/CDP1802_CORE_REVIEW.md). The CLEAR and WAIT pins select
--   four modes, of which only RESET and RUN were ever exercised:
--
--     CLEAR WAIT  mode
--       L    L    LOAD   idle; DMA-IN fills memory with no bootstrap, and
--                        does NOT force execution of the next instruction
--       L    H    RESET  I, N, Q reset, IE set, 0s on the data bus,
--                        TPA/TPB suppressed while held
--       H    L    PAUSE  timing generator stops; state is preserved
--       H    H    RUN
--
--   The first machine cycle after reset is the initialization cycle, which
--   the datasheet says takes **9 clock pulses** where every other cycle
--   takes 8, and during which X, P and R(0) are reset.
--
--   This testbench drives the modes directly and checks, per clock:
--     - no TPA/TPB while reset is held;
--     - LOAD: a 12-byte program is loaded purely by DMA-IN, the CPU never
--       fetches while loading, and TPA stays suppressed;
--     - the initialization cycle is 9 clocks (measured TPB to TPB);
--     - the first fetch after reset is at 0x0000 and the loaded program
--       runs (it sets Q and writes a marker);
--     - PAUSE: no machine cycles pass while WAIT is low, and execution
--       continues afterwards;
--     - reset in the middle of an instruction: Q clears, and the CPU
--       starts again from 0x0000 through another 9-clock init cycle.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

ENTITY tb_cdp1802_modes IS
END tb_cdp1802_modes;

ARCHITECTURE tb OF tb_cdp1802_modes IS

  CONSTANT clk_period : TIME := 250 ns;

  TYPE t_mem IS ARRAY (0 TO 65535) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL mem : t_mem := (OTHERS => (OTHERS => '0'));

  -- Loaded into memory by DMA-IN while the CPU is held in LOAD mode:
  --   SEQ ; RF = 0xFF00 ; M(RF) = 0x5A ; loop forever
  TYPE t_prog IS ARRAY (0 TO 12) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
  CONSTANT c_prog : t_prog := (X"7B",                    -- SEQ (Q=1)
                               X"F8", X"FF", X"BF",      -- LDI FF ; PHI RF
                               X"F8", X"00", X"AF",      -- LDI 00 ; PLO RF
                               X"F8", X"5A", X"5F",      -- LDI 5A ; STR RF
                               X"00",                    -- IDL
                               X"30", X"0A");            -- BR 0A (idle again)
  CONSTANT c_marker_addr : INTEGER := 16#FF00#;

  SIGNAL clk    : STD_LOGIC := '0';
  SIGNAL tb_end : STD_LOGIC := '0';
  SIGNAL nCLEAR : STD_LOGIC := '0';
  SIGNAL nWAIT  : STD_LOGIC := '1';

  SIGNAL sc       : STD_LOGIC_VECTOR(1 DOWNTO 0);
  SIGNAL q        : STD_LOGIC;
  SIGNAL nmrd, nmwr, tpa, tpb : STD_LOGIC;
  SIGNAL a_full   : STD_LOGIC_VECTOR(15 DOWNTO 0);
  SIGNAL cpu_dout : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL cpu_doe  : STD_LOGIC;
  SIGNAL bus_data : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL mem_dout : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL ndma_in  : STD_LOGIC := '1';
  SIGNAL nint     : STD_LOGIC := '1';
  -- the test process must not drive mem itself (a second driver would
  -- resolve against the memory process and corrupt the whole array)
  SIGNAL clr_marker : STD_LOGIC := '0';
  SIGNAL dma_byte : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');

  -- counters the checking process keeps, sampled by the test process
  SIGNAL n_tpa, n_tpb, n_fetch, n_s3 : NATURAL := 0;
  SIGNAL last_fetch_addr : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL clk_count : NATURAL := 0;      -- free-running clock counter
  SIGNAL last_tpb_clk, prev_tpb_clk : NATURAL := 0;
  SIGNAL n0_tpa : NATURAL := 0;
  SIGNAL errors : NATURAL := 0;

BEGIN

  clk <= NOT clk OR tb_end AFTER clk_period / 2;

  u_cpu : ENTITY work.cdp1802
  PORT MAP (
    CLOCK => clk, nWAIT => nWAIT, nCLEAR => nCLEAR,
    Q => q, SC => sc, nMRD => nmrd,
    DATA_IN => bus_data, DATA_OUT => cpu_dout, DATA_OE => cpu_doe,
    N => OPEN, nEF => "1111", ADDR => OPEN, A_full => a_full,
    TPA => tpa, TPB => tpb, nMWR => nmwr,
    nINT => nint, nDMA_OUT => '1', nDMA_IN => ndma_in
  );

  mem_dout <= mem(to_integer(unsigned(a_full))) WHEN nmrd = '0' ELSE (OTHERS => '0');
  bus_data <= cpu_dout WHEN cpu_doe = '1' ELSE
              dma_byte WHEN sc = "10" ELSE      -- the loading device, during S2
              mem_dout;

  p_mem_write : PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      IF clr_marker = '1' THEN
        mem(c_marker_addr) <= X"00";
      ELSIF nmwr = '0' THEN
        mem(to_integer(unsigned(a_full))) <= bus_data;
      END IF;
    END IF;
  END PROCESS;

  -- Per-clock observation: pulse counts, machine cycles, TPB spacing.
  p_watch : PROCESS (clk)
    VARIABLE prev_tpa, prev_tpb_l : STD_LOGIC := '0';
  BEGIN
    IF rising_edge(clk) THEN
      clk_count <= clk_count + 1;
      IF tpa = '1' AND prev_tpa = '0' THEN
        n_tpa <= n_tpa + 1;
      END IF;
      IF tpb = '1' AND prev_tpb_l = '0' THEN
        n_tpb <= n_tpb + 1;
        prev_tpb_clk <= last_tpb_clk;
        last_tpb_clk <= clk_count;
        IF sc = "00" THEN
          n_fetch <= n_fetch + 1;
          last_fetch_addr <= a_full;
        ELSIF sc = "11" THEN
          n_s3 <= n_s3 + 1;
        END IF;
      END IF;
      prev_tpa := tpa;
      prev_tpb_l := tpb;
    END IF;
  END PROCESS;

  p_test : PROCESS
    VARIABLE t0 : NATURAL;

    PROCEDURE wait_clk(n : NATURAL) IS
    BEGIN
      FOR i IN 1 TO n LOOP WAIT UNTIL rising_edge(clk); END LOOP;
    END PROCEDURE;

    PROCEDURE check(cond : BOOLEAN; msg : STRING) IS
    BEGIN
      IF NOT cond THEN
        errors <= errors + 1;
        REPORT msg SEVERITY ERROR;
      END IF;
    END PROCEDURE;

    -- one DMA-IN transfer: hold the request until an S2 cycle has passed
    PROCEDURE dma_in_byte(b : STD_LOGIC_VECTOR(7 DOWNTO 0)) IS
    BEGIN
      dma_byte <= b;
      ndma_in  <= '0';
      WAIT UNTIL rising_edge(clk) AND sc = "10" AND tpb = '1';
      ndma_in <= '1';
      wait_clk(8);
    END PROCEDURE;
  BEGIN
    -- ---- RESET -------------------------------------------------------
    nCLEAR <= '0'; nWAIT <= '1';
    wait_clk(20);
    check(n_tpa = 0, "TPA pulsed while reset was held");
    check(n_tpb = 0, "TPB pulsed while reset was held");

    -- ---- LOAD: fill memory by DMA, with no program running ------------
    nCLEAR <= '0'; nWAIT <= '0';
    wait_clk(4);
    -- TPA is suppressed in the IDLE cycles of LOAD mode (datasheet); the
    -- DMA cycles themselves are ordinary memory cycles and do have TPA, so
    -- this window deliberately contains no DMA request.
    t0 := n_tpa;
    wait_clk(40);
    check(n_tpa = t0, "TPA was not suppressed in LOAD mode's idle cycles");
    FOR i IN c_prog'RANGE LOOP
      dma_in_byte(c_prog(i));
    END LOOP;
    wait_clk(20);
    check(n_fetch = 0, "the CPU fetched an instruction while in LOAD mode");
    FOR i IN c_prog'RANGE LOOP
      check(mem(i) = c_prog(i),
            "LOAD: memory byte " & INTEGER'IMAGE(i) & " is wrong");
    END LOOP;

    -- ---- RESET, then RUN ---------------------------------------------
    -- The datasheet: "Run may be initiated from the Pause or Reset mode
    -- functions", so the documented path out of LOAD is through RESET --
    -- which is also what a front panel does (load, reset, run).
    clr_marker <= '1'; wait_clk(2); clr_marker <= '0';
    nCLEAR <= '0'; nWAIT <= '1';
    wait_clk(10);
    nCLEAR <= '1'; nWAIT <= '1';
    t0 := n_tpb;
    WAIT UNTIL rising_edge(clk) AND n_tpb > t0;      -- the initialization cycle
    WAIT UNTIL rising_edge(clk) AND n_tpb > t0 + 1;  -- ... and the cycle after it
    check(last_tpb_clk - prev_tpb_clk = 9,
          "the initialization cycle is " & INTEGER'IMAGE(last_tpb_clk - prev_tpb_clk)
          & " clocks, the datasheet says 9");
    WAIT UNTIL rising_edge(clk) AND n_fetch > 0;
    check(last_fetch_addr = X"0000", "the first fetch after reset is not at 0x0000");
    wait_clk(200);
    check(mem(c_marker_addr) = X"5A", "the program loaded in LOAD mode did not run");
    check(q = '1', "SEQ did not set Q");

    -- ---- the IDL instruction: idle cycles, but NOT LOAD mode ---------
    -- The program ends in IDL, so the CPU is idling now. Unlike LOAD's
    -- idle, these are ordinary memory read cycles and do have TPA.
    t0 := n_fetch;
    wait_clk(4);
    n0_tpa <= n_tpa;
    wait_clk(40);
    check(n_tpa > n0_tpa, "TPA is missing during the IDL instruction's idle cycles");
    check(n_fetch = t0, "the CPU left IDL on its own");

    -- ---- PAUSE: the timing generator stops ---------------------------
    t0 := n_tpb;
    nWAIT <= '0';
    wait_clk(37);
    check(n_tpb = t0, "machine cycles continued while WAIT was low (PAUSE)");
    nWAIT <= '1';
    wait_clk(40);
    check(n_tpb > t0, "the CPU did not resume after PAUSE");

    -- ---- an interrupt wakes the IDL ----------------------------------
    -- R(1) is still 0 after reset, so the "handler" is the program itself:
    -- it runs again from 0x0000 and rewrites the marker.
    clr_marker <= '1'; wait_clk(2); clr_marker <= '0';
    t0 := n_s3;
    nint <= '0';
    WAIT UNTIL rising_edge(clk) AND n_s3 > t0 FOR 40 * clk_period;
    nint <= '1';
    check(n_s3 > t0, "the interrupt did not wake the IDL");
    wait_clk(250);
    check(mem(c_marker_addr) = X"5A", "the program did not run after the IDL woke");

    -- ---- reset in the middle of an instruction ------------------------
    clr_marker <= '1'; wait_clk(2); clr_marker <= '0';
    wait_clk(3);                       -- land somewhere inside a cycle
    nCLEAR <= '0'; nWAIT <= '1';
    wait_clk(2);
    t0 := n_tpa;
    wait_clk(12);
    check(n_tpa = t0, "TPA pulsed while reset was held (mid-instruction)");
    check(q = '0', "reset did not clear Q");
    nCLEAR <= '1';
    t0 := n_tpb;
    WAIT UNTIL rising_edge(clk) AND n_tpb > t0;
    WAIT UNTIL rising_edge(clk) AND n_tpb > t0 + 1;
    check(last_tpb_clk - prev_tpb_clk = 9,
          "after a mid-instruction reset the init cycle is "
          & INTEGER'IMAGE(last_tpb_clk - prev_tpb_clk) & " clocks, not 9");
    wait_clk(300);
    check(mem(c_marker_addr) = X"5A", "the program did not run again after reset");

    IF errors = 0 THEN
      REPORT "ALL CHECKS PASSED";
    ELSE
      REPORT INTEGER'IMAGE(errors) & " CHECKS FAILED" SEVERITY FAILURE;
    END IF;
    tb_end <= '1';
    WAIT;
  END PROCESS;

END tb;
