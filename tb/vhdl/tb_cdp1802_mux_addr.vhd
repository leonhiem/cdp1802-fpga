-------------------------------------------------------------------------------
--
-- File Name: tb_cdp1802_mux_addr.vhd
--
-- Title: the core against a REAL multiplexed-address memory card
--
-- License: MIT
--
-- Description:
--   TODO 2.5/6. Every other memory in this project is fed `A_full`, the
--   core's own settled 16-bit address -- including the Cora's
--   (`cs1800_prcx18_memory.vhd` says so in its header, deliberately). A real
--   CS1800 memory card has no such signal. It sees only:
--
--     - the 8-bit multiplexed ADDR bus, which carries the HIGH byte early in
--       the cycle and the LOW byte for the rest of it, and
--     - TPA, whose trailing edge it latches the high byte with (4042s on the
--       real card -- see doc/CDP1802_MEMORY_TIMING.md).
--
--   So the card's full address is only complete once the LOW byte appears.
--   This testbench builds exactly that memory -- 4042 latch on TPA, live low
--   byte, asynchronous access time as a generic -- and runs a program whose
--   correctness depends on a read landing in D. If the core samples the data
--   before the card can present it, D is wrong and the program's result byte
--   is wrong with it.
--
--   g_access_time is the memory's own address-to-data delay. Run it at 0 ns
--   first: a failure even there is not an access-time problem at all, it
--   means the core sampled before the address was complete.
--
--   Real parts, from the user's own datasheets (timings.txt):
--     FCB61C65L-70   t_AA  70 ns
--     LC3664BL-10    t_AA 100 ns
--     2764 EPROM     t_ACC 250 ns, t_CE 450 ns
--
--   The program (self-checking -- the testbench reads the result out of the
--   memory array afterwards):
--     0000: F8 20 A1    LDI 0x20 ; PLO R1     R1 = 0x0020
--     0003: F8 00 B1    LDI 0x00 ; PHI R1
--     0006: F8 30 A2    LDI 0x30 ; PLO R2     R2 = 0x0030
--     0009: F8 00 B2    LDI 0x00 ; PHI R2
--     000C: 01          LDN R1                D = M(0x0020) = 0x5A
--     000D: 52          STR R2                M(0x0030) = D
--     000E: 00          IDL
--     0020: 5A          the byte LDN must fetch
--
--   LDN is one of the five instructions that sample at clk_cnt = 2 (with
--   LDX, OR, AND, XOR); the other 21 sample at clk_cnt = 4.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE STD.TEXTIO.ALL;

ENTITY tb_cdp1802_mux_addr IS
  GENERIC (
    -- The memory's address-to-data access time, in nanoseconds (an integer
    -- because GHDL cannot override a TIME generic from the command line).
    -- 0 = an impossibly perfect part, which isolates the address-
    -- multiplexing question from access time.
    -- Default: 100 ns, the slowest of the user's own RAM parts
    -- (LC3664BL-10). It passes -- just. 125 ns already fails, and the
    -- 2764 EPROM's 250 ns fails badly: see TODO 2.5 in
    -- doc/CDP1802_CORE_REVIEW.md. Sweep it to find the limit:
    --   for t in 70 100 120 125 250; do ghdl -r ... -gg_access_ns=$t; done
    g_access_ns : NATURAL := 100
  );
END tb_cdp1802_mux_addr;

ARCHITECTURE tb OF tb_cdp1802_mux_addr IS

  CONSTANT clk_period : TIME := 250 ns; -- 4 MHz

  CONSTANT c_expect      : STD_LOGIC_VECTOR(7 DOWNTO 0) := X"5A";
  CONSTANT g_access_time : TIME := g_access_ns * 1 ns;

  TYPE t_mem IS ARRAY (0 TO 255) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL mem : t_mem := (
    16#00# => X"F8", 16#01# => X"20", 16#02# => X"A1",
    16#03# => X"F8", 16#04# => X"00", 16#05# => X"B1",
    16#06# => X"F8", 16#07# => X"30", 16#08# => X"A2",
    16#09# => X"F8", 16#0A# => X"00", 16#0B# => X"B2",
    16#0C# => X"01",                       -- LDN R1
    16#0D# => X"52",                       -- STR R2
    16#0E# => X"00",                       -- IDL
    16#20# => c_expect,
    OTHERS => X"00");

  SIGNAL clk    : STD_LOGIC := '0';
  SIGNAL tb_end : STD_LOGIC := '0';
  SIGNAL nCLEAR : STD_LOGIC := '0';

  SIGNAL sc       : STD_LOGIC_VECTOR(1 DOWNTO 0);
  SIGNAL q        : STD_LOGIC;
  SIGNAL n        : STD_LOGIC_VECTOR(2 DOWNTO 0);
  SIGNAL nmrd     : STD_LOGIC;
  SIGNAL nmwr     : STD_LOGIC;
  SIGNAL tpa      : STD_LOGIC;
  SIGNAL tpb      : STD_LOGIC;
  SIGNAL addr     : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL a_full   : STD_LOGIC_VECTOR(15 DOWNTO 0); -- watched, never used
  SIGNAL cpu_dout : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL cpu_doe  : STD_LOGIC;
  SIGNAL bus_data : STD_LOGIC_VECTOR(7 DOWNTO 0);

  -- The card: a 4042 latch for the high byte and the live low byte.
  SIGNAL card_hi   : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL card_addr : STD_LOGIC_VECTOR(15 DOWNTO 0);
  SIGNAL card_data : STD_LOGIC_VECTOR(7 DOWNTO 0);

BEGIN

  clk <= NOT clk OR tb_end AFTER clk_period / 2;

  u_cpu : ENTITY work.cdp1802
  PORT MAP (
    CLOCK => clk, nWAIT => '1', nCLEAR => nCLEAR,
    Q => q, SC => sc, nMRD => nmrd, nMWR => nmwr,
    DATA_IN => bus_data, DATA_OUT => cpu_dout, DATA_OE => cpu_doe,
    N => n, nEF => "1111", ADDR => addr, A_full => a_full,
    TPA => tpa, TPB => tpb,
    nINT => '1', nDMA_OUT => '1', nDMA_IN => '1'
  );

  -- The real card's 4042: the high byte is latched by TPA's TRAILING edge
  -- ("The trailing edge of TPA is used by the memory system to latch the
  -- higher-order byte", datasheet TPA pin description).
  p_4042 : PROCESS(tpa)
  BEGIN
    IF falling_edge(tpa) THEN
      card_hi <= addr;
    END IF;
  END PROCESS;

  card_addr <= card_hi & addr; -- low byte straight off the bus, live

  -- Asynchronous memory: data appears g_access_time after the address
  -- settles. TRANSPORT, not the default inertial delay, so a short-lived
  -- address (which is exactly what the multiplexing produces) still
  -- propagates instead of being swallowed.
  card_data <= TRANSPORT mem(to_integer(unsigned(card_addr(7 DOWNTO 0))))
               AFTER g_access_time;

  bus_data <= cpu_dout WHEN cpu_doe = '1' ELSE card_data;

  p_write : PROCESS(nmwr)
  BEGIN
    -- A real RAM captures on the trailing edge of WE.
    IF rising_edge(nmwr) THEN
      mem(to_integer(unsigned(card_addr(7 DOWNTO 0)))) <= cpu_dout;
    END IF;
  END PROCESS;

  p_test : PROCESS
    VARIABLE l : LINE;
  BEGIN
    nCLEAR <= '0';
    FOR i IN 0 TO 20 LOOP WAIT UNTIL rising_edge(clk); END LOOP;
    nCLEAR <= '1';
    FOR i IN 0 TO 300 LOOP WAIT UNTIL rising_edge(clk); END LOOP;

    WRITE(l, STRING'("memory access time "));
    WRITE(l, g_access_time);
    WRITE(l, STRING'(": M(0x30) = "));
    WRITE(l, to_hstring(mem(16#30#)));
    WRITE(l, STRING'(", expected "));
    WRITE(l, to_hstring(c_expect));
    WRITELINE(OUTPUT, l);

    IF mem(16#30#) = c_expect THEN
      WRITE(l, STRING'("PASS: LDN read correctly through a real "));
      WRITE(l, STRING'("multiplexed-address memory card"));
      WRITELINE(OUTPUT, l);
    ELSE
      WRITE(l, STRING'("FAIL: LDN got the wrong byte through a real "));
      WRITE(l, STRING'("multiplexed-address card -- the core sampled the "));
      WRITE(l, STRING'("data bus before the card had the full address"));
      WRITELINE(OUTPUT, l);
    END IF;
    ASSERT mem(16#30#) = c_expect
      REPORT "multiplexed-address memory read failed" SEVERITY FAILURE;
    tb_end <= '1';
    WAIT;
  END PROCESS;

END tb;
