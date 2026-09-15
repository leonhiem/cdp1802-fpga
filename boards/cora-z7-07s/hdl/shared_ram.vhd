-------------------------------------------------------------------------------
--
-- File Name: shared_ram.vhd
-- Author: Leon Hiemstra
--
-- Title: CPU/AXI-shared RAM for the CS1800 board bring-up
--
-- License: MIT
--
-- Description:
--   4KB memory shared between cs1800 (Port A) and the AXI side (Port
--   B, via axi_bram_ctrl), so Linux can load a program while cs1800 is
--   held in reset.
--
--   The two sides are never accessed at once in practice: cs1800 is
--   held in reset while software writes a program, then released to
--   run, so this isn't true dual-port memory, just ONE arbitrated
--   write, selected by sel_ext ('1' while held in reset hands write
--   access to Port B, '0' while running hands it back to Port A).
--
--   Port A's read is now registered (1-cycle latency, real Block-RAM
--   shape), 2026-09-15 (see boards/cora-z7-07s/BRINGUP_LOG.md's
--   "milestone 3l"), fed by a_address = A_full (cdp1802.vhd's own
--   internal, already-settled 16-bit address -- see its and
--   cs1800.vhd's own notes on that new port) rather than the older
--   combinational-read design this file carried before, which is what
--   a real hardware-only bug traced back to (milestone 3j: a single
--   bit flipped reading address 0x00B3, non-deterministic across
--   rebuilds -- see git history for that design). An even earlier
--   registered-read attempt, fed by the CPU's *externally*-
--   reconstructed, TPA-latched address instead of A_full, also failed
--   (milestone 3k, GHDL-proven internal corruption) -- see
--   cs1800_prcx18_memory.vhd's header for the full account of why
--   A_full specifically is what makes this safe.
--
--   4KB, not the real backplane's 64KB -- real Block RAM has far more
--   capacity than that on this part; this size was never the
--   constraint, just never revisited. a_address/b_addr both stay full
--   16-bit ports (matching cs1800's real 16-bit address bus and
--   axi_bram_ctrl's bram_addr_a exactly); only the low 12 bits actually
--   address memory, the top 4 are ignored -- exactly how a real
--   smaller-than-the-full-address-space RAM chip behaves electrically.
--
--   Pre-filled from test_program_pkg (the same contents src/vhdl/
--   ram.vhd carries), so a freshly-programmed board behaves exactly
--   like today's even before software writes anything.
--
--   Underlying storage is an array of 32-bit words, not bytes: on
--   axi_bram_ctrl, the native BRAM port stays 32-bit with a 4-bit
--   byte-enable regardless of the configured AXI data width (checked
--   directly against the IP, not assumed), and a byte-indexed array
--   read as "four elements concatenated together" for Port B is
--   exactly the memory shape Vivado's inference doesn't recognize
--   (confirmed by trying it: "memory pattern...not supported", falling
--   back to individual flip-flops). One word-addressed array with
--   byte-lane slices -- all locally static, no dynamic-bound slicing --
--   is the standard, tool-recognized byte-enabled-BRAM shape. The low 2
--   of the 12 used address bits select the byte lane -- the standard
--   little-endian AXI convention (byte 0 = bits 7:0 = lowest address).
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.std_logic_1164.ALL;
USE IEEE.numeric_std.ALL;
USE work.test_program_pkg.ALL;


ENTITY shared_ram IS
  PORT (
    clk     : IN STD_LOGIC;
    sel_ext : IN STD_LOGIC; -- '1': Port B may write. '0': Port A may write.

    -- Port A: CPU-facing. a_address must be A_full (cdp1802.vhd's own
    -- internal, already-settled 16-bit address) -- see this file's
    -- header for why.
    a_address  : IN  STD_LOGIC_VECTOR(15 DOWNTO 0);
    a_data_in  : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
    a_data_out : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    a_nWE, a_nCS, a_nOE : IN STD_LOGIC;

    -- Port B: axi_bram_ctrl's native BRAM_PORTA signature (32-bit data,
    -- byte address, 4-bit byte-enable).
    b_addr : IN  STD_LOGIC_VECTOR(15 DOWNTO 0);
    b_din  : IN  STD_LOGIC_VECTOR(31 DOWNTO 0);
    b_dout : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    b_we   : IN  STD_LOGIC_VECTOR(3 DOWNTO 0);
    b_en   : IN  STD_LOGIC
  );
END shared_ram;


ARCHITECTURE str OF shared_ram IS

  TYPE t_word_array IS ARRAY (NATURAL RANGE <>) OF STD_LOGIC_VECTOR(31 DOWNTO 0);

  -- Packs test_program_pkg's byte array into 32-bit words, little-endian
  -- (byte 0 -> word 0 bits 7:0, byte 1 -> word 0 bits 15:8, ...).
  FUNCTION init_mem RETURN t_word_array IS
    VARIABLE result : t_word_array(0 TO 1023) := (OTHERS => X"00000000");
  BEGIN
    FOR i IN c_test_program'RANGE LOOP
      CASE (i MOD 4) IS
        WHEN 0 => result(i/4)(7 DOWNTO 0)   := c_test_program(i);
        WHEN 1 => result(i/4)(15 DOWNTO 8)  := c_test_program(i);
        WHEN 2 => result(i/4)(23 DOWNTO 16) := c_test_program(i);
        WHEN OTHERS => result(i/4)(31 DOWNTO 24) := c_test_program(i);
      END CASE;
    END LOOP;
    RETURN result;
  END FUNCTION;

  SIGNAL mem : t_word_array(0 TO 1023) := init_mem;

  -- Port A's write, expressed in Port B's own "word index + 4-lane
  -- byte-enable" shape (a_data_in replicated across all four lanes;
  -- only the one lane a_address actually selects ever has its
  -- write-enable bit set). One canonical write pattern with the
  -- Port A/B muxing done in plain signal assignments outside the
  -- process, rather than two structurally different patterns
  -- arbitrated inside it.
  SIGNAL eff_word_idx : NATURAL RANGE 0 TO 1023;
  SIGNAL eff_data      : STD_LOGIC_VECTOR(31 DOWNTO 0);
  SIGNAL eff_we        : STD_LOGIC_VECTOR(3 DOWNTO 0);
  SIGNAL eff_en        : STD_LOGIC;

  -- Port A's registered read state -- see the read process below.
  SIGNAL a_word_reg : STD_LOGIC_VECTOR(31 DOWNTO 0);
  SIGNAL a_lane_reg : STD_LOGIC_VECTOR(1 DOWNTO 0);
  SIGNAL a_sel_reg  : STD_LOGIC;

  -- Port B's registered read state -- see the read process below.
  SIGNAL b_dout_reg : STD_LOGIC_VECTOR(31 DOWNTO 0);

BEGIN

  -- Only the low 12 address bits are used (4KB) -- see the FPGA note above.
  eff_word_idx <= to_integer(unsigned(b_addr(11 DOWNTO 2))) WHEN sel_ext = '1'
                  ELSE to_integer(unsigned(a_address(11 DOWNTO 2)));

  eff_data <= b_din WHEN sel_ext = '1' ELSE a_data_in & a_data_in & a_data_in & a_data_in;

  eff_we <= b_we WHEN sel_ext = '1' ELSE
            "0001" WHEN (a_nCS = '0' AND a_nWE = '0' AND a_address(1 DOWNTO 0) = "00") ELSE
            "0010" WHEN (a_nCS = '0' AND a_nWE = '0' AND a_address(1 DOWNTO 0) = "01") ELSE
            "0100" WHEN (a_nCS = '0' AND a_nWE = '0' AND a_address(1 DOWNTO 0) = "10") ELSE
            "1000" WHEN (a_nCS = '0' AND a_nWE = '0' AND a_address(1 DOWNTO 0) = "11") ELSE
            "0000";

  eff_en <= b_en WHEN sel_ext = '1' ELSE '1';

  -- The one canonical byte-enabled write, synchronous -- same timing as
  -- src/vhdl/ram.vhd's Port A write (nCS/nWE held stable for several
  -- CLOCK cycles per access, so landing on one clean rising edge is
  -- safe; see that file's own header note). Four static-slice lane
  -- writes, not a loop over a variable-bound slice -- the standard
  -- inferable shape.
  PROCESS (clk) IS
  BEGIN
    IF rising_edge(clk) THEN
      IF eff_en = '1' THEN
        IF eff_we(0) = '1' THEN mem(eff_word_idx)(7 DOWNTO 0)   <= eff_data(7 DOWNTO 0);   END IF;
        IF eff_we(1) = '1' THEN mem(eff_word_idx)(15 DOWNTO 8)  <= eff_data(15 DOWNTO 8);  END IF;
        IF eff_we(2) = '1' THEN mem(eff_word_idx)(23 DOWNTO 16) <= eff_data(23 DOWNTO 16); END IF;
        IF eff_we(3) = '1' THEN mem(eff_word_idx)(31 DOWNTO 24) <= eff_data(31 DOWNTO 24); END IF;
      END IF;
    END IF;
  END PROCESS;

  -- Port A read: registered (1-cycle latency, real Block-RAM shape),
  -- one static-slice lane. Registers the whole word + which byte lane
  -- + whether this access was even selected together, in lockstep, so
  -- a_data_out (below, purely combinational) only ever derives from
  -- one self-consistent, already-settled snapshot. See file header for
  -- why this is only safe with a_address = A_full.
  PROCESS (clk) IS
    VARIABLE word_idx : NATURAL RANGE 0 TO 1023;
  BEGIN
    IF rising_edge(clk) THEN
      IF (a_nCS = '0' AND a_nOE = '0') THEN
        word_idx := to_integer(unsigned(a_address(11 DOWNTO 2)));
        a_word_reg <= mem(word_idx);
        a_lane_reg <= a_address(1 DOWNTO 0);
        a_sel_reg  <= '1';
      ELSE
        a_sel_reg <= '0'; -- chip not selected / not reading
      END IF;
    END IF;
  END PROCESS;

  a_data_out <= (OTHERS => '0') WHEN a_sel_reg = '0' ELSE
                a_word_reg(7 DOWNTO 0)   WHEN a_lane_reg = "00" ELSE
                a_word_reg(15 DOWNTO 8)  WHEN a_lane_reg = "01" ELSE
                a_word_reg(23 DOWNTO 16) WHEN a_lane_reg = "10" ELSE
                a_word_reg(31 DOWNTO 24);

  -- Port B read: registered too, 2026-09-15 (see
  -- cs1800_prcx18_memory.vhd's header for why a single VHDL array
  -- with one port async and the other synchronous can't map to one
  -- real Block RAM primitive at all -- confirmed directly by Vivado
  -- falling back to distributed RAM for the whole array otherwise).
  PROCESS (clk) IS
  BEGIN
    IF rising_edge(clk) THEN
      IF b_en = '1' THEN
        b_dout_reg <= mem(to_integer(unsigned(b_addr(11 DOWNTO 2))));
      END IF;
    END IF;
  END PROCESS;

  b_dout <= b_dout_reg;

END str;
