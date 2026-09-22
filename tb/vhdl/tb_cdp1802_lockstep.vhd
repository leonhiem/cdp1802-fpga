-------------------------------------------------------------------------------
--
-- File Name: tb_cdp1802_lockstep.vhd
--
-- Title: bare CDP1802 core + flat 64 KB memory + loopback I/O, logged for
--        the lockstep ISA check
--
-- License: MIT
--
-- Description:
--   Runs any program on cdp1802.vhd alone: a flat 64 KB RAM preloaded from
--   g_prog_file (one hex byte per line, loaded at 0x0000; combinational
--   read and synchronous write on A_full), plus a small I/O world whose
--   behaviour boards/cora-z7-07s/lockstep1802.py (--flat) models exactly,
--   so every I/O, EF, Q and interrupt effect is checkable:
--
--     OUT n (n=1..7)  latches the bus byte into io_latch(n)
--     INP n (n=1..7)  reads io_latch(n) back (loopback: checks N lines)
--     EF1..EF4        = io_latch(7) bits 0..3 (1 = flag active, nEF low)
--     DMA             controlled by io_latch(7) bits 4..7 (see below), with
--                     the DMA-in data taken from io_latch(4)
--     INT             controlled by io_latch(6):
--                       bit 0 = request now,
--                       bit 1 = request g_int_delay clocks after the
--                               last OUT 6 (each OUT 6 restarts it),
--                       writing 0x00 withdraws the request
--
--   io_latch(7): bits 0..3 = EF1..EF4, bit 4 = request DMA-in, bit 5 =
--   request DMA-out, bit 6 = burst of 4 cycles (else 1), bit 7 = start
--   the request g_int_delay clocks later (so it can land inside an IDL or
--   in the middle of an instruction). The request drops once its cycles
--   have been served, so a burst cannot starve the CPU. A DMA-in writes
--   io_latch(4) to memory.
--
--   The run ends when the program writes any byte to 0xFFFF (the "done"
--   marker), or after g_max_clocks.
--
--   g_log_file, one line per event:
--     "C <sc> <addr> <data> <R|-> <Q> <N>"  at every TPB (one per machine cycle)
--     "W <addr> <data>"                     at the end of every nMWR pulse
--
--   Used by sim/ghdl/alu/run_alu_exhaustive.sh (TODO 2.1) and
--   sim/ghdl/isa/run_isa_coverage.sh (TODO 2.2); see
--   doc/CDP1802_CORE_REVIEW.md.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE STD.TEXTIO.ALL;

ENTITY tb_cdp1802_lockstep IS
  GENERIC (
    g_prog_file  : STRING  := "prog.hex";
    g_log_file   : STRING  := "cyc.log";
    g_max_clocks : NATURAL := 100_000_000;
    g_int_delay  : NATURAL := 200 -- clocks, for io_latch(6) bit 1
  );
END tb_cdp1802_lockstep;

ARCHITECTURE tb OF tb_cdp1802_lockstep IS

  CONSTANT clk_period : TIME := 250 ns;

  TYPE t_mem IS ARRAY (0 TO 65535) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
  TYPE t_io  IS ARRAY (0 TO 7) OF STD_LOGIC_VECTOR(7 DOWNTO 0); -- 0 unused

  IMPURE FUNCTION load_prog(fname : STRING) RETURN t_mem IS
    FILE f : TEXT OPEN READ_MODE IS fname;
    VARIABLE l : LINE;
    VARIABLE b : STD_LOGIC_VECTOR(7 DOWNTO 0);
    VARIABLE m : t_mem := (OTHERS => (OTHERS => '0'));
    VARIABLE a : NATURAL := 0;
  BEGIN
    WHILE NOT ENDFILE(f) LOOP
      READLINE(f, l);
      IF l'LENGTH > 0 THEN
        HREAD(l, b);
        m(a) := b;
        a := a + 1;
      END IF;
    END LOOP;
    RETURN m;
  END FUNCTION;

  SIGNAL mem : t_mem := load_prog(g_prog_file);
  SIGNAL io_latch : t_io := (OTHERS => (OTHERS => '0'));

  SIGNAL clk    : STD_LOGIC := '0';
  SIGNAL tb_end : STD_LOGIC := '0';
  SIGNAL nCLEAR : STD_LOGIC := '0';
  SIGNAL nWAIT  : STD_LOGIC := '1';

  SIGNAL sc       : STD_LOGIC_VECTOR(1 DOWNTO 0);
  SIGNAL q        : STD_LOGIC;
  SIGNAL n        : STD_LOGIC_VECTOR(2 DOWNTO 0);
  SIGNAL nmrd     : STD_LOGIC;
  SIGNAL nmwr     : STD_LOGIC;
  SIGNAL tpb      : STD_LOGIC;
  SIGNAL a_full   : STD_LOGIC_VECTOR(15 DOWNTO 0);
  SIGNAL cpu_dout : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL cpu_doe  : STD_LOGIC;
  SIGNAL mem_dout : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL io_dout  : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL io_read  : BOOLEAN;
  SIGNAL bus_data : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL nef      : STD_LOGIC_VECTOR(3 DOWNTO 0);
  SIGNAL nint     : STD_LOGIC := '1';
  SIGNAL int_restart : STD_LOGIC := '0';
  SIGNAL dma_restart : STD_LOGIC := '0';
  SIGNAL ndma_in  : STD_LOGIC := '1';
  SIGNAL ndma_out : STD_LOGIC := '1';
  SIGNAL dma_in_active : BOOLEAN;
  SIGNAL done     : BOOLEAN := FALSE;

BEGIN

  clk <= NOT clk OR tb_end AFTER clk_period / 2;

  u_cpu : ENTITY work.cdp1802
  PORT MAP (
    CLOCK    => clk,
    nWAIT    => nWAIT,
    nCLEAR   => nCLEAR,
    Q        => q,
    SC       => sc,
    nMRD     => nmrd,
    DATA_IN  => bus_data,
    DATA_OUT => cpu_dout,
    DATA_OE  => cpu_doe,
    N        => n,
    nEF      => nef,
    ADDR     => OPEN,
    A_full   => a_full,
    TPA      => OPEN,
    TPB      => tpb,
    nMWR     => nmwr,
    nINT     => nint,
    nDMA_OUT => ndma_out,
    nDMA_IN  => ndma_in
  );

  -- The DMA-in byte comes from io_latch(4); the CPU is writing M(R0) from
  -- the bus, exactly as for INP.
  -- The device drives its byte during any granted DMA cycle in which the
  -- CPU writes (sc = S2, no memory read), whatever the request line does
  -- meanwhile: once the CPU has started the cycle it carries it out.
  dma_in_active <= sc = "10";
  -- INP n: N /= 0 with no memory read (the CPU is writing M(R(X)) from the bus)
  io_read  <= n /= "000" AND nmrd = '1';
  io_dout  <= io_latch(to_integer(unsigned(n))) WHEN n /= "000" ELSE (OTHERS => '0');
  mem_dout <= mem(to_integer(unsigned(a_full))) WHEN nmrd = '0' ELSE (OTHERS => '0');
  bus_data <= cpu_dout WHEN cpu_doe = '1' ELSE
              io_latch(4) WHEN dma_in_active AND nmrd = '1' ELSE
              io_dout  WHEN io_read ELSE
              mem_dout;

  nef <= NOT io_latch(7)(3 DOWNTO 0);

  p_mem_write : PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      IF nmwr = '0' THEN
        mem(to_integer(unsigned(a_full))) <= bus_data;
        IF a_full = X"FFFF" THEN
          done <= TRUE;
        END IF;
      END IF;
    END IF;
  END PROCESS;

  -- OUT n: N /= 0 while the CPU reads M(R(X)) onto the bus; latch at TPB
  p_io_out : PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      int_restart <= '0';
      dma_restart <= '0';
      IF tpb = '1' AND sc = "01" AND n /= "000" AND nmrd = '0' THEN
        io_latch(to_integer(unsigned(n))) <= bus_data;
        IF n = "110" THEN
          int_restart <= '1';   -- every OUT 6 restarts the delay
        END IF;
        IF n = "111" THEN
          dma_restart <= '1';   -- every OUT 7 (re)arms the DMA request
        END IF;
      END IF;
    END IF;
  END PROCESS;

  -- DMA requests from io_latch(7) bits 4..7, dropped after the requested
  -- number of S2 cycles (1..4) so a burst cannot starve the CPU.
  p_dma : PROCESS (clk)
    VARIABLE left : NATURAL := 0;
    VARIABLE wait_cnt : NATURAL := 0;
    VARIABLE prev_tpb : STD_LOGIC := '0';
  BEGIN
    IF rising_edge(clk) THEN
      IF dma_restart = '1' THEN
        IF io_latch(7)(6) = '1' THEN left := 4; ELSE left := 1; END IF;
        IF io_latch(7)(7) = '1' THEN
          wait_cnt := g_int_delay;   -- delayed start
        ELSE
          wait_cnt := 0;
        END IF;
      ELSIF wait_cnt > 0 THEN
        wait_cnt := wait_cnt - 1;
      END IF;
      -- One DMA cycle served: drop the request at its TPB, like a real
      -- controller that releases the line once the cycle is granted (the
      -- CPU latches the direction at the start of the cycle).
      IF tpb = '1' AND prev_tpb = '0' AND sc = "10" AND left > 0 THEN
        left := left - 1;
      END IF;
      IF left > 0 AND wait_cnt = 0 AND io_latch(7)(4) = '1' THEN
        ndma_in <= '0';
      ELSE
        ndma_in <= '1';
      END IF;
      IF left > 0 AND wait_cnt = 0 AND io_latch(7)(5) = '1' THEN
        ndma_out <= '0';
      ELSE
        ndma_out <= '1';
      END IF;
      prev_tpb := tpb;
    END IF;
  END PROCESS;

  p_int : PROCESS (clk)
    VARIABLE cnt : NATURAL := 0;
  BEGIN
    IF rising_edge(clk) THEN
      IF io_latch(6)(0) = '1' THEN
        nint <= '0';
        cnt := 0;
      ELSIF io_latch(6)(1) = '1' THEN
        IF int_restart = '1' THEN      -- a new OUT 6: start the delay again
          nint <= '1';
          cnt := 0;
        ELSIF cnt >= g_int_delay THEN
          nint <= '0';
        ELSE
          cnt := cnt + 1;
        END IF;
      ELSE
        nint <= '1';
        cnt := 0;
      END IF;
    END IF;
  END PROCESS;

  p_test : PROCESS
  BEGIN
    nCLEAR <= '0';                  -- reset
    FOR i IN 0 TO 20 LOOP WAIT UNTIL rising_edge(clk); END LOOP;
    nCLEAR <= '1';                  -- run
    FOR i IN 0 TO g_max_clocks LOOP
      WAIT UNTIL rising_edge(clk);
      EXIT WHEN done;
    END LOOP;
    FOR i IN 0 TO 40 LOOP WAIT UNTIL rising_edge(clk); END LOOP;
    IF done THEN
      REPORT "DONE: program wrote the 0xFFFF end marker";
    ELSE
      REPORT "TIMEOUT: no end marker after g_max_clocks" SEVERITY ERROR;
    END IF;
    tb_end <= '1';
    WAIT;
  END PROCESS;

  p_log : PROCESS
    FILE f_out : TEXT OPEN WRITE_MODE IS g_log_file;
    VARIABLE l : LINE;
    VARIABLE rd : BOOLEAN := FALSE;
    VARIABLE wa : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0');
    VARIABLE wd : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    VARIABLE wr : BOOLEAN := FALSE;
    VARIABLE prev_tpb, prev_nmwr : STD_LOGIC := '0';
  BEGIN
    LOOP
      WAIT UNTIL rising_edge(clk);
      EXIT WHEN tb_end = '1';
      IF nmrd = '0' THEN rd := TRUE; END IF;
      -- A write belongs to the cycle in which its pulse STARTED: the tail
      -- of a pulse can reach into the next cycle, which must not count.
      IF nmwr = '0' AND (prev_nmwr = '1' OR wr) THEN
        wa := a_full; wd := bus_data; wr := TRUE;
      END IF;
      -- The W line is written just before the C line of the cycle the write
      -- belongs to, so a write is never ambiguous between two cycles (a
      -- pulse may end after its own TPB, and the next cycle can have the
      -- same address).
      IF tpb = '1' AND prev_tpb = '0' THEN
        IF wr THEN
          WRITE(l, STRING'("W "));
          WRITE(l, to_hstring(wa));
          WRITE(l, STRING'(" "));
          WRITE(l, to_hstring(wd));
          WRITELINE(f_out, l);
          wr := FALSE;
        END IF;
        WRITE(l, STRING'("C "));
        WRITE(l, to_hstring(sc));
        WRITE(l, STRING'(" "));
        WRITE(l, to_hstring(a_full));
        WRITE(l, STRING'(" "));
        WRITE(l, to_hstring(bus_data));
        IF rd THEN WRITE(l, STRING'(" R ")); ELSE WRITE(l, STRING'(" - ")); END IF;
        WRITE(l, q);
        WRITE(l, STRING'(" "));
        WRITE(l, to_hstring('0' & n));
        WRITELINE(f_out, l);
        rd := FALSE;
      END IF;
      prev_tpb  := tpb;
      prev_nmwr := nmwr;
    END LOOP;
    WAIT;
  END PROCESS;

END tb;
