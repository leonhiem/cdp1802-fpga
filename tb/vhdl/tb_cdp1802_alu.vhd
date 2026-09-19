-------------------------------------------------------------------------------
--
-- File Name: tb_cdp1802_alu.vhd
--
-- Title: bare CDP1802 core + flat 64 KB memory, logged for lockstep checks
--
-- License: MIT
--
-- Description:
--   Runs any program on cdp1802.vhd alone (no system around it): a flat
--   64 KB RAM, preloaded from g_prog_file (one hex byte per line, loaded
--   at 0x0000), combinational read and synchronous write on A_full.
--   No interrupts, no DMA, EF lines inactive.
--
--   The run ends when the program writes any byte to 0xFFFF (the "done"
--   marker), or after g_max_clocks.
--
--   Writes g_log_file in the format boards/cora-z7-07s/lockstep1802.py
--   reads (--flat mode):
--     "C <sc> <addr> <data> <R|->"  at every TPB (one per machine cycle)
--     "W <addr> <data>"             at the end of every nMWR pulse
--
--   Used by sim/ghdl/alu/run_alu_exhaustive.sh (TODO 2.1 in
--   doc/CDP1802_CORE_REVIEW.md): one generated program per ALU
--   instruction, all 256 x 256 x DF operand combinations.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE STD.TEXTIO.ALL;

ENTITY tb_cdp1802_alu IS
  GENERIC (
    g_prog_file  : STRING  := "prog.hex";
    g_log_file   : STRING  := "cyc.log";
    g_max_clocks : NATURAL := 100_000_000
  );
END tb_cdp1802_alu;

ARCHITECTURE tb OF tb_cdp1802_alu IS

  CONSTANT clk_period : TIME := 250 ns;

  TYPE t_mem IS ARRAY (0 TO 65535) OF STD_LOGIC_VECTOR(7 DOWNTO 0);

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

  SIGNAL clk    : STD_LOGIC := '0';
  SIGNAL tb_end : STD_LOGIC := '0';
  SIGNAL nCLEAR : STD_LOGIC := '0';
  SIGNAL nWAIT  : STD_LOGIC := '1';

  SIGNAL sc       : STD_LOGIC_VECTOR(1 DOWNTO 0);
  SIGNAL nmrd     : STD_LOGIC;
  SIGNAL nmwr     : STD_LOGIC;
  SIGNAL tpb      : STD_LOGIC;
  SIGNAL a_full   : STD_LOGIC_VECTOR(15 DOWNTO 0);
  SIGNAL cpu_dout : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL cpu_doe  : STD_LOGIC;
  SIGNAL mem_dout : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL bus_data : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL done     : BOOLEAN := FALSE;

BEGIN

  clk <= NOT clk OR tb_end AFTER clk_period / 2;

  u_cpu : ENTITY work.cdp1802
  PORT MAP (
    CLOCK    => clk,
    nWAIT    => nWAIT,
    nCLEAR   => nCLEAR,
    Q        => OPEN,
    SC       => sc,
    nMRD     => nmrd,
    DATA_IN  => bus_data,
    DATA_OUT => cpu_dout,
    DATA_OE  => cpu_doe,
    N        => OPEN,
    nEF      => "1111",
    ADDR     => OPEN,
    A_full   => a_full,
    TPA      => OPEN,
    TPB      => tpb,
    nMWR     => nmwr,
    nINT     => '1',
    nDMA_OUT => '1',
    nDMA_IN  => '1'
  );

  mem_dout <= mem(to_integer(unsigned(a_full))) WHEN nmrd = '0' ELSE (OTHERS => '0');
  bus_data <= cpu_dout WHEN cpu_doe = '1' ELSE mem_dout;

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
    VARIABLE prev_tpb, prev_nmwr : STD_LOGIC := '0';
  BEGIN
    LOOP
      WAIT UNTIL rising_edge(clk);
      EXIT WHEN tb_end = '1';
      IF nmrd = '0' THEN rd := TRUE; END IF;
      IF nmwr = '0' THEN wa := a_full; wd := bus_data; END IF;
      IF nmwr = '1' AND prev_nmwr = '0' THEN
        WRITE(l, STRING'("W "));
        WRITE(l, to_hstring(wa));
        WRITE(l, STRING'(" "));
        WRITE(l, to_hstring(wd));
        WRITELINE(f_out, l);
      END IF;
      IF tpb = '1' AND prev_tpb = '0' THEN
        WRITE(l, STRING'("C "));
        WRITE(l, to_hstring(sc));
        WRITE(l, STRING'(" "));
        WRITE(l, to_hstring(a_full));
        WRITE(l, STRING'(" "));
        WRITE(l, to_hstring(bus_data));
        IF rd THEN WRITE(l, STRING'(" R")); ELSE WRITE(l, STRING'(" -")); END IF;
        WRITELINE(f_out, l);
        rd := FALSE;
      END IF;
      prev_tpb  := tpb;
      prev_nmwr := nmwr;
    END LOOP;
    WAIT;
  END PROCESS;

END tb;
