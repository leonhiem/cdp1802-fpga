-------------------------------------------------------------------------------
--
-- File Name: tb_cdp1802_pin_timing.vhd
--
-- Title: pin-level timing of the CDP1802 core against the datasheet's timing waveforms
--
-- License: MIT
--
-- Description:
--   TODO 2.5, simulation half. Every other test in this project checks what
--   the CPU *computes*; this one checks when its pins move, because that is
--   all a real memory card or a real CDP1854 ever sees. It matters for the
--   DE0-Nano backplane module, where those parts are real chips: inside the
--   FPGA the surrounding logic is RTL and the tools time it for us, on the
--   backplane nothing does.
--
--   Everything here is measured from the pins only -- TPA, TPB, ADDR, nMRD,
--   nMWR, SC, N -- never from a signal inside the core, so a passing result
--   means the same thing an oscilloscope on the real backplane would.
--
--   Units are the datasheet's own: it numbers the two halves of each of the
--   8 CLOCK periods in a machine cycle 00 01 10 11 ... 70 71 (Figure 3 and
--   Figure 4, "Timing Waveforms"). This testbench counts those half-periods
--   from the rising edge of TPA, so "phase 0" is TPA's own rising edge and a
--   whole machine cycle is 16 phases. Datasheet state N0 = phase 2N-2,
--   N1 = phase 2N-1, since Figure 4 puts TPA's rise in state 1.
--
--   NOTE on that anchor: TPA is the only clean reference a pin-level test
--   has, but the machine cycle does not begin there -- state 0 starts two
--   phases EARLIER, and that is where SC changes and where the next cycle's
--   N lines come up. So phases 14 and 15 of one TPA-to-TPA window already
--   belong to the next machine cycle. The SC and N checks below account for
--   that; forgetting it makes a correct core look like it drives N a cycle
--   early, which is exactly the false finding this note exists to prevent.
--
--   What the datasheet's timing waveforms show, and what this checks
--   (Figure 5, "General Timing Waveforms", verified by rendering the page
--   as an image -- the PDF's text layer puts these columns nowhere useful,
--   and reading it there produced two false "deviations" first):
--     - TPA is one CLOCK period wide (rises in state 1, falls in state 2);
--     - TPB is one CLOCK period wide (rises in state 6, falls in state 7);
--     - TPA to TPB is 5 CLOCK periods, and a machine cycle is 8 (except the
--       initialization cycle, which is 9 -- bug 11);
--     - the memory address is the HIGH byte until TPA's trailing edge (which
--       is what the real memory board's 4042 latches on) and the LOW byte
--       afterwards, for the rest of the cycle;
--     - nMRD is asserted across the read window and nMWR only inside it.
--
--   The program it runs exercises a fetch, an execute with a memory read, an
--   execute with a memory write (nMWR), and an OUT (N lines), then idles.
--
--   Failures name the pin, the expected phase and the measured one. Run via
--   sim/ghdl/run.sh pintiming.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE STD.TEXTIO.ALL;

ENTITY tb_cdp1802_pin_timing IS
  GENERIC (
    -- Report every measured cycle, not just the failures. Useful when
    -- characterising a change; noisy in the regression.
    g_verbose : BOOLEAN := FALSE
    -- (There used to be a g_allow_tpb_half_clock here, for a "TPB rises
    -- half a clock late" deviation. It was not a deviation: the expectation
    -- had been read off the datasheet PDF's *text* layer, whose column
    -- positions are meaningless. Rendering Figure 5 as an image, and the
    -- 1976 User Manual MPM-201A p.86, both show TPA on falling clock edges
    -- and TPB on rising ones -- 5.5 CLOCK periods apart, which is what the
    -- core does. c_tpb_rise below is now that value and is a hard check.)
    -- (A g_allow_n_half_clock lived here too, for "the N lines are half a
    -- clock late". Same mistake as the TPB one: it measured N against a
    -- machine-cycle boundary inferred from TPA, which is not where the
    -- boundary is. The N check below now asks the question a real device
    -- actually cares about -- is N right at the moment TPB latches it --
    -- which needs no assumption about where the cycle starts.)
  );
END tb_cdp1802_pin_timing;

ARCHITECTURE tb OF tb_cdp1802_pin_timing IS

  CONSTANT clk_period : TIME := 250 ns; -- 4 MHz, the real CDP1802 clock

  -- Expected phases, in half-CLOCK periods from TPA's rising edge.
  CONSTANT c_tpa_width   : NATURAL := 2;  -- 1 CLOCK period
  -- 5.5 CLOCK periods after TPA, and that half is real, not a rounding:
  -- TPA's edges fall on the clock's FALLING edges and TPB's on its RISING
  -- edges. Figure 5 of the datasheet ("General Timing Waveforms", rendered
  -- as an image -- the PDF's text layer puts these columns nowhere useful)
  -- draws TPA rising at the falling edge of clock 1 and falling at the
  -- falling edge of clock 2, and TPB rising on the rising edge of clock 7.
  -- The 1976 User Manual MPM-201A p.86 says the same. Our core matches.
  CONSTANT c_tpb_rise    : NATURAL := 11;
  CONSTANT c_tpb_width   : NATURAL := 2;  -- 1 CLOCK period
  CONSTANT c_cycle_len   : NATURAL := 16; -- 8 CLOCK periods

  -- What the real chip GUARANTEES to the memory system, from the
  -- datasheet's "Timing Specifications as a function of T", at
  -- Vcc = Vdd = 5V. These are the numbers the real CS1800's memory cards
  -- and CDP1854 were designed against, so our core has to be at least as
  -- good or a real backplane will not work. T is one CLOCK period.
  --   High-order address byte, hold after TPA:  T/2 - 25 ns
  --   CPU data to bus, hold after WR:           T - 200 ns
  --   Low-order address byte, hold after WR:    T - 30 ns
  CONSTANT c_hi_addr_hold_min : TIME := clk_period / 2 - 25 ns;

  TYPE t_mem IS ARRAY (0 TO 255) OF STD_LOGIC_VECTOR(7 DOWNTO 0);

  -- 0000: F8 10  LDI 0x10      0005: 51     STR R1   -- a memory write
  -- 0002: A1     PLO R1        0006: E1     SEX 1
  -- 0003: F8 AA  LDI 0xAA      0007: 61     OUT 1    -- N lines + a read
  --                            0008: 00     IDL
  SIGNAL mem : t_mem := (
    16#00# => X"F8", 16#01# => X"10", 16#02# => X"A1",
    16#03# => X"F8", 16#04# => X"AA", 16#05# => X"51",
    16#06# => X"E1", 16#07# => X"61", 16#08# => X"00",
    OTHERS => X"00");

  SIGNAL clk    : STD_LOGIC := '0';
  SIGNAL tb_end : STD_LOGIC := '0';
  SIGNAL nCLEAR : STD_LOGIC := '0';
  SIGNAL nWAIT  : STD_LOGIC := '1';

  SIGNAL sc       : STD_LOGIC_VECTOR(1 DOWNTO 0);
  SIGNAL q        : STD_LOGIC;
  SIGNAL n        : STD_LOGIC_VECTOR(2 DOWNTO 0);
  SIGNAL nmrd     : STD_LOGIC;
  SIGNAL nmwr     : STD_LOGIC;
  SIGNAL tpa      : STD_LOGIC;
  SIGNAL tpb      : STD_LOGIC;
  SIGNAL addr     : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL a_full   : STD_LOGIC_VECTOR(15 DOWNTO 0);
  SIGNAL cpu_dout : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL cpu_doe  : STD_LOGIC;
  SIGNAL bus_data : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL nef      : STD_LOGIC_VECTOR(3 DOWNTO 0) := (OTHERS => '1');

  SIGNAL errors   : NATURAL := 0;
  SIGNAL cycles   : NATURAL := 0;

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
    ADDR     => addr,
    A_full   => a_full,
    TPA      => tpa,
    TPB      => tpb,
    nMWR     => nmwr,
    nINT     => '1',
    nDMA_OUT => '1',
    nDMA_IN  => '1'
  );

  -- Plain asynchronous memory, like the real board's: the CPU's own
  -- A_full addresses it, and it drives the bus whenever the CPU is not.
  bus_data <= cpu_dout WHEN cpu_doe = '1' ELSE mem(to_integer(unsigned(a_full(7 DOWNTO 0))));

  p_write : PROCESS(clk)
  BEGIN
    IF falling_edge(clk) THEN
      IF nmwr = '0' THEN
        mem(to_integer(unsigned(a_full(7 DOWNTO 0)))) <= cpu_dout;
      END IF;
    END IF;
  END PROCESS;

  p_run : PROCESS
  BEGIN
    nCLEAR <= '0';
    FOR i IN 0 TO 20 LOOP WAIT UNTIL rising_edge(clk); END LOOP;
    nCLEAR <= '1'; -- RESET -> RUN
    FOR i IN 0 TO 200 LOOP WAIT UNTIL rising_edge(clk); END LOOP;
    tb_end <= '1';
    WAIT;
  END PROCESS;

  -- The measurement. Counts half-CLOCK periods from TPA's rising edge --
  -- the datasheet's own 00/01/10/11 numbering -- and records the phase at
  -- which every other pin moves, then checks the completed cycle.
  p_measure : PROCESS
    VARIABLE phase        : INTEGER := -1; -- -1 = no TPA seen yet
    VARIABLE tpa_prev     : STD_LOGIC := '0';
    VARIABLE tpb_prev     : STD_LOGIC := '0';
    VARIABLE mrd_prev     : STD_LOGIC := '1';
    VARIABLE mwr_prev     : STD_LOGIC := '1';
    VARIABLE addr_prev    : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    VARIABLE tpa_fall     : INTEGER := -1;
    VARIABLE tpb_rise     : INTEGER := -1;
    VARIABLE tpb_fall     : INTEGER := -1;
    VARIABLE addr_change  : INTEGER := -1;
    VARIABLE mrd_low      : INTEGER := -1;
    VARIABLE mwr_low      : INTEGER := -1;
    VARIABLE mwr_high     : INTEGER := -1;
    VARIABLE hi_byte      : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    VARIABLE sc_at_start  : STD_LOGIC_VECTOR(1 DOWNTO 0) := "00";
    VARIABLE sc_moved     : BOOLEAN := FALSE; -- SC changed before TPA's trailing edge
    VARIABLE n_nonzero    : BOOLEAN := FALSE; -- N left 000 somewhere in this cycle
    VARIABLE n_first      : INTEGER := -1;    -- ... first at this phase
    VARIABLE n_last       : INTEGER := -1;    -- ... and last at this one
    -- N was non-zero while TPB was high, in a cycle SC did not call execute
    VARIABLE n_bad_at_tpb : BOOLEAN := FALSE;
    VARIABLE l            : LINE;
    VARIABLE err          : NATURAL := 0;
    -- Worst case over the whole run, in phases (1 phase = half a CLOCK).
    VARIABLE min_hi_hold  : INTEGER := 999; -- high address byte after TPA
    VARIABLE min_n_setup  : INTEGER := 999; -- N valid before TPB rises
    VARIABLE min_n_hold   : INTEGER := 999; -- N still valid after TPB falls
    VARIABLE min_wr_width : INTEGER := 999; -- nMWR low, i.e. the write pulse
    VARIABLE mrd_phases   : INTEGER := 0;   -- phases nMRD was low this cycle
    -- Bus contention: nMRD low means a real memory is driving the data bus
    -- (MRD is its output enable), and DATA_OE high means the CPU is driving
    -- it too. On the Cora nothing notices -- the memory is RTL and the
    -- testbenches mux the bus -- but on the backplane that is two drivers.
    VARIABLE contend      : INTEGER := 0;   -- phases both drove, this run
    VARIABLE max_mrd_low  : INTEGER := 0;   -- ... the most seen in any cycle
    VARIABLE min_d_setup  : INTEGER := 999; -- CPU data valid before nMWR rises
    VARIABLE min_d_hold   : INTEGER := 999; -- ... and still valid after
    VARIABLE dout_first   : INTEGER := -1;
    VARIABLE dout_last    : INTEGER := -1;

    PROCEDURE check(what : STRING; got : INTEGER; want : INTEGER) IS
      VARIABLE ll : LINE;
    BEGIN
      IF got /= want THEN
        WRITE(ll, STRING'("FAIL: cycle "));
        WRITE(ll, cycles);
        WRITE(ll, STRING'(": "));
        WRITE(ll, what);
        WRITE(ll, STRING'(" at phase "));
        WRITE(ll, got);
        WRITE(ll, STRING'(", the datasheet's timing waveforms says "));
        WRITE(ll, want);
        WRITELINE(OUTPUT, ll);
        err := err + 1;
      END IF;
    END PROCEDURE;
  BEGIN
    LOOP
      WAIT ON clk, tb_end;
      EXIT WHEN tb_end = '1';

      IF phase >= 0 THEN
        phase := phase + 1;
      END IF;

      -- TPA rising: close out the previous cycle and start a new one.
      IF tpa = '1' AND tpa_prev = '0' THEN
        IF phase >= 0 THEN
          -- A full cycle was measured. The initialization cycle is 9 CLOCK
          -- periods, not 8 (datasheet, "Run-Mode State Transitions"), so the
          -- first measured cycle after reset is allowed to be 2 phases long.
          IF cycles > 1 THEN
            check("machine cycle length", phase, c_cycle_len);
          END IF;
          check("TPA falling edge", tpa_fall, c_tpa_width);
          check("TPB rising edge", tpb_rise, c_tpb_rise);
          IF tpb_rise >= 0 AND tpb_fall >= 0 THEN
            check("TPB falling edge", tpb_fall - tpb_rise, c_tpb_width);
          END IF;
          -- The high-order byte must still be on the bus at TPA's trailing
          -- edge -- that edge is what the memory board latches it with.
          IF addr_change >= 0 AND addr_change < tpa_fall THEN
            WRITE(l, STRING'("FAIL: cycle "));
            WRITE(l, cycles);
            WRITE(l, STRING'(": address left the high byte at phase "));
            WRITE(l, addr_change);
            WRITE(l, STRING'(", before TPA's trailing edge at phase "));
            WRITE(l, tpa_fall);
            WRITELINE(OUTPUT, l);
            err := err + 1;
          END IF;
          -- "All states are valid at TPA" (datasheet, SC0/SC1 pin
          -- description): SC must not still be moving when the outside
          -- world samples it.
          IF sc_moved THEN
            WRITE(l, STRING'("FAIL: cycle "));
            WRITE(l, cycles);
            WRITE(l, STRING'(": SC changed before TPA's trailing edge; "));
            WRITE(l, STRING'("the datasheet says all states are valid at TPA"));
            WRITELINE(OUTPUT, l);
            err := err + 1;
          END IF;
          -- "The N bits are low at all times except when an I/O
          -- instruction is being executed" -- so never outside an execute
          -- cycle (S1 = SC "01").
          -- "The N bits are low at all times except when an I/O
          -- instruction is being executed" (datasheet, N0-N2 pin
          -- description). Checked where it matters and where no
          -- cycle-boundary assumption is needed: an I/O controller latches
          -- on TPB, so at every instant TPB is high, N non-zero must mean
          -- SC says execute. Both are read from the pins at the same
          -- moment.
          IF n_bad_at_tpb THEN
            WRITE(l, STRING'("FAIL: cycle "));
            WRITE(l, cycles);
            WRITE(l, STRING'(": N lines non-zero while TPB was high in a "));
            WRITE(l, STRING'("non-execute cycle"));
            WRITELINE(OUTPUT, l);
            err := err + 1;
          END IF;
          IF addr_change >= 0 AND tpa_fall >= 0
             AND addr_change - tpa_fall < min_hi_hold THEN
            min_hi_hold := addr_change - tpa_fall;
          END IF;
          IF n_first >= 0 AND tpb_rise >= 0 AND n_first <= tpb_rise
             AND tpb_rise - n_first < min_n_setup THEN
            min_n_setup := tpb_rise - n_first;
          END IF;
          IF n_last >= 0 AND tpb_fall >= 0 AND n_last >= tpb_fall
             AND n_last - tpb_fall < min_n_hold THEN
            min_n_hold := n_last - tpb_fall;
          END IF;
          IF mrd_phases > max_mrd_low THEN max_mrd_low := mrd_phases; END IF;
          IF mwr_low >= 0 AND mwr_high > mwr_low
             AND mwr_high - mwr_low < min_wr_width THEN
            min_wr_width := mwr_high - mwr_low;
          END IF;
          IF mwr_high > 0 AND dout_first >= 0 AND dout_first <= mwr_high
             AND mwr_high - dout_first < min_d_setup THEN
            min_d_setup := mwr_high - dout_first;
          END IF;
          IF mwr_high > 0 AND dout_last >= mwr_high
             AND dout_last - mwr_high < min_d_hold THEN
            min_d_hold := dout_last - mwr_high;
          END IF;
          IF g_verbose THEN
            WRITE(l, STRING'("cycle "));  WRITE(l, cycles);
            WRITE(l, STRING'(" SC="));    WRITE(l, to_bitvector(sc));
            WRITE(l, STRING'(" len="));   WRITE(l, phase);
            WRITE(l, STRING'(" TPA_fall="));  WRITE(l, tpa_fall);
            WRITE(l, STRING'(" TPB="));   WRITE(l, tpb_rise);
            WRITE(l, STRING'("..."));     WRITE(l, tpb_fall);
            WRITE(l, STRING'(" addr_sw="));   WRITE(l, addr_change);
            WRITE(l, STRING'(" MRD_lo="));    WRITE(l, mrd_low);
            WRITE(l, STRING'(" N!=0@"));   WRITE(l, n_first);
            WRITE(l, STRING'(".."));       WRITE(l, n_last);
            WRITE(l, STRING'(" MWR="));   WRITE(l, mwr_low);
            WRITE(l, STRING'("..."));     WRITE(l, mwr_high);
            WRITELINE(OUTPUT, l);
          END IF;
          cycles <= cycles + 1;
        END IF;
        phase := 0;
        tpa_fall := -1; tpb_rise := -1; tpb_fall := -1;
        addr_change := -1; mrd_low := -1; mwr_low := -1; mwr_high := -1;
        hi_byte := addr;
        mrd_phases := 0;
        sc_at_start := sc; sc_moved := FALSE; n_nonzero := FALSE;
        n_bad_at_tpb := FALSE;
        n_first := -1; n_last := -1;
        dout_first := -1; dout_last := -1;
      END IF;

      IF phase >= 0 THEN
        IF tpa = '0' AND tpa_prev = '1' AND tpa_fall < 0 THEN tpa_fall := phase; END IF;
        IF tpb = '1' AND tpb_prev = '0' AND tpb_rise < 0 THEN tpb_rise := phase; END IF;
        IF tpb = '0' AND tpb_prev = '1' AND tpb_fall < 0 THEN tpb_fall := phase; END IF;
        IF addr /= hi_byte AND addr_change < 0 THEN addr_change := phase; END IF;
        IF sc /= sc_at_start AND (tpa_fall < 0 OR phase <= tpa_fall) THEN sc_moved := TRUE; END IF;
        IF n /= "000" THEN
          n_nonzero := TRUE;
          IF n_first < 0 THEN n_first := phase; END IF;
          n_last := phase;
          IF tpb = '1' AND sc /= "01" THEN n_bad_at_tpb := TRUE; END IF;
        END IF;
        IF cpu_doe = '1' THEN
          IF dout_first < 0 THEN dout_first := phase; END IF;
          dout_last := phase;
        END IF;
        IF nmrd = '0' THEN mrd_phases := mrd_phases + 1; END IF;
        IF nmrd = '0' AND cpu_doe = '1' THEN contend := contend + 1; END IF;
        IF nmrd = '0' AND mrd_prev = '1' AND mrd_low < 0 THEN mrd_low := phase; END IF;
        IF nmwr = '0' AND mwr_prev = '1' AND mwr_low < 0 THEN mwr_low := phase; END IF;
        IF nmwr = '1' AND mwr_prev = '0' AND mwr_low >= 0 AND mwr_high < 0 THEN mwr_high := phase; END IF;
      END IF;

      tpa_prev := tpa; tpb_prev := tpb;
      mrd_prev := nmrd; mwr_prev := nmwr; addr_prev := addr;
    END LOOP;

    -- The margins a real memory card or CDP1854 actually sees. One phase
    -- is half a CLOCK period; at 4 MHz that is 125 ns.
    WRITE(l, STRING'("margins at T = "));
    WRITE(l, clk_period);
    WRITE(l, STRING'(":"));
    WRITELINE(OUTPUT, l);
    WRITE(l, STRING'("  high address byte held after TPA : "));
    WRITE(l, min_hi_hold * (clk_period / 2));
    WRITE(l, STRING'("  (datasheet guarantees T/2-25 = "));
    WRITE(l, c_hi_addr_hold_min);
    WRITE(l, STRING'(")"));
    WRITELINE(OUTPUT, l);
    IF contend > 0 THEN
      WRITE(l, STRING'("  BUS CONTENTION: nMRD low while the CPU drove "));
      WRITE(l, STRING'("the bus, for "));
      WRITE(l, contend * (clk_period / 2));
      WRITE(l, STRING'(" in this run"));
      WRITELINE(OUTPUT, l);
    ELSE
      WRITE(l, STRING'("  no bus contention: nMRD never low while the "));
      WRITE(l, STRING'("CPU drove the bus"));
      WRITELINE(OUTPUT, l);
    END IF;
    WRITE(l, STRING'("  nMRD low, longest in any cycle   : "));
    WRITE(l, max_mrd_low * (clk_period / 2));
    WRITE(l, STRING'(" of a "));
    WRITE(l, c_cycle_len * (clk_period / 2));
    WRITE(l, STRING'(" cycle"));
    WRITELINE(OUTPUT, l);
    IF min_wr_width < 999 THEN
      WRITE(l, STRING'("  nMWR write pulse width          : "));
      WRITE(l, min_wr_width * (clk_period / 2));
      WRITELINE(OUTPUT, l);
      WRITE(l, STRING'("  CPU data valid before nMWR rises: "));
      WRITE(l, min_d_setup * (clk_period / 2));
      WRITELINE(OUTPUT, l);
      WRITE(l, STRING'("  CPU data still valid after it   : "));
      WRITE(l, min_d_hold * (clk_period / 2));
      WRITE(l, STRING'("  (datasheet guarantees T-200 = "));
      WRITE(l, clk_period - 200 ns);
      WRITE(l, STRING'(")"));
      WRITELINE(OUTPUT, l);
    END IF;
    IF min_n_setup < 999 THEN
      WRITE(l, STRING'("  N valid before TPB rises        : "));
      WRITE(l, min_n_setup * (clk_period / 2));
      WRITELINE(OUTPUT, l);
      WRITE(l, STRING'("  N still valid after TPB falls   : "));
      WRITE(l, min_n_hold * (clk_period / 2));
      WRITELINE(OUTPUT, l);
    END IF;
    -- The one hard check here: a real memory board latches the high
    -- address byte on TPA's trailing edge, so falling short of the
    -- datasheet's own guarantee would break real hardware.
    IF min_hi_hold < 999
       AND min_hi_hold * (clk_period / 2) < c_hi_addr_hold_min THEN
      WRITE(l, STRING'("FAIL: high address byte hold after TPA is below "));
      WRITE(l, STRING'("the datasheet's guaranteed minimum"));
      WRITELINE(OUTPUT, l);
      err := err + 1;
    END IF;

    errors <= err;
    IF err = 0 THEN
      WRITE(l, STRING'("PASS: pin timing matches the datasheet's timing waveforms over "));
      WRITE(l, cycles);
      WRITE(l, STRING'(" machine cycles"));
    ELSE
      WRITE(l, STRING'("FAIL: "));
      WRITE(l, err);
      WRITE(l, STRING'(" pin-timing deviation(s) over "));
      WRITE(l, cycles);
      WRITE(l, STRING'(" machine cycles"));
    END IF;
    WRITELINE(OUTPUT, l);
    -- sim/ghdl/run.sh's run_check reports PASS unless the simulation stops,
    -- so failing has to be an assertion, not just a printed line.
    ASSERT err = 0
      REPORT "pin timing deviates from the datasheet's timing waveforms -- see the FAIL lines above"
      SEVERITY FAILURE;
    WAIT;
  END PROCESS;

END tb;
