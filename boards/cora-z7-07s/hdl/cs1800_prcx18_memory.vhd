-------------------------------------------------------------------------------
--
-- File Name: cs1800_prcx18_memory.vhd
-- Author: Leon Hiemstra
--
-- Title: Real ROM+RAM memory for the CS1800 board bring-up (Block RAM)
--
-- License: MIT
--
-- Description:
--   Real Block-RAM-based, synchronous-read memory, 2026-09-15 (see
--   boards/cora-z7-07s/BRINGUP_LOG.md's "milestone 3l") -- replaces
--   this file's earlier LUTRAM/async-read design. LUTRAM on this part
--   is capped at ~6000 LUTs, nowhere near the real 16KB minimum (8KB
--   ROM + 8KB RAM) the user proved by pulling chips from the actual
--   rack, let alone the real backplane's full 48-56KB -- that ceiling,
--   not this design's own logic, was the reason RAM had to be
--   undersized (1KB) at all, and undersized RAM is what left PRCX-18
--   stuck retrying its Console Task instead of reaching a real prompt
--   (see the size/tradeoff table this header used to carry -- now in
--   git history). Block RAM on this part has orders of magnitude more
--   capacity, so this isn't a tradeoff anymore: default size below now
--   matches the real minimum config directly (8KB ROM + 8KB RAM =
--   16KB), well above the 4KB already proven sufficient in simulation
--   (`doc/PRCX18_ANALYSIS.md`).
--
--   A first synchronous-memory attempt (this file's own earlier
--   header) was tried and abandoned: it used the CDP1802's real
--   `nWAIT`/PAUSE dynamic wait-state mechanism and found "an address
--   register went undefined on the third machine cycle." A second
--   attempt (`BRINGUP_LOG.md`'s "milestone 3k") tried a plain
--   registered read fed by this design's *externally-reconstructed*
--   address (`ram_addr` = `TPA`-latched high byte + live low byte,
--   mirroring the real memory board's 4042 latch ICs) and also failed
--   -- proven via GHDL's own metavalue tracking, not just a bad-
--   looking trace -- because that reconstruction is only valid during
--   part of each machine cycle by construction (the real chip's `ADDR`
--   pin is only 8 bits, time-multiplexed between address bytes; see
--   `doc/CDP1802_MEMORY_TIMING.md`, distilled from the real CDP1802
--   datasheet's own timing diagram). Registering a read on every
--   `CLOCK` edge sometimes captured it mid-transition.
--
--   This design sidesteps that reconstruction problem entirely instead
--   of solving it: `cdp1802.vhd`/`cs1800.vhd` gained a new `A_full`
--   port (2026-09-15, additive, no behavior change to anything already
--   using them) exposing the CPU's *own* internal 16-bit address
--   register directly -- the same value `ADDR`/`TPA` eventually
--   multiplex out to 8 pins, just one step earlier and never split up,
--   genuinely stable for a whole access, no external latch needed at
--   all. `a_address` below is fed from that, not from a `ram_addr`-
--   style reconstruction. Verified byte-for-byte identical against the
--   golden reference this way, with zero GHDL metavalue warnings,
--   before ever touching hardware -- see BRINGUP_LOG.md's "milestone
--   3l" for the simulation experiment that proved this out
--   (`ram_sync.vhd`/`cdp18_sync.vhd`, `src/vhdl/`).
--
--   Real hardware-only bugs #1 and #2 (non-power-of-two modulo
--   divider; two-array data-level mux hazard), found and fixed
--   2026-09-14 in the old LUTRAM design, don't apply to the shape here
--   (still one array, one muxed index, power-of-two RAM window -- see
--   git history for the full account) but the underlying lesson
--   (single array, single index, no unregistered mux combining two
--   live values) is exactly what this design continues to follow.
--
--   Port A: CPU-facing. Write timing unchanged from before (already
--   synchronous). Read is now registered (1-cycle latency) instead of
--   async/combinational -- the real Block-RAM shape, safe here
--   specifically because `a_address` is fed from `A_full` (see above),
--   not a time-multiplexed reconstruction. Writes to the ROM region
--   from Port A are silently ignored, matching a real EPROM's WE pin
--   doing nothing.
--   Port B: axi_bram_ctrl's native BRAM_PORTA shape (32-bit, 4-bit
--   byte-enable -- fixed regardless of AXI data width, see
--   shared_ram.vhd's header), used to load the real ROM image at
--   runtime -- never embedded here. Port B can write anywhere,
--   including the ROM region -- that's how the real ROM image actually
--   gets loaded. Port B's read stays combinational/unregistered
--   (unchanged) -- axi_bram_ctrl already tolerates that today, and
--   this fix only ever targeted Port A's real-time hazard.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.std_logic_1164.ALL;
USE IEEE.numeric_std.ALL;
USE IEEE.math_real.ALL;
USE work.test_program_pkg.ALL;


ENTITY cs1800_prcx18_memory IS
  GENERIC (
    g_ram_words : INTEGER := 2048 -- 32-bit words of RAM above the 8KB ROM (2048 = 8KB, matching the real minimum config the user pulled from the rack -- MUST be a power of two, see this file's header's "bug #1" note; cs1800_prcx18_top.vhd always passes its own generic through anyway)
  );
  PORT (
    clk     : IN STD_LOGIC;
    sel_ext : IN STD_LOGIC; -- '1': Port B may write. '0': Port A may write.

    -- Port A: CPU-facing. a_address must be A_full (cdp1802.vhd's own
    -- internal, already-settled 16-bit address) -- see this file's
    -- header for why the older TPA-latched-reconstruction idiom
    -- (ram_addr elsewhere in this repo) isn't safe to feed a
    -- registered read.
    a_address  : IN  STD_LOGIC_VECTOR(15 DOWNTO 0);
    a_data_in  : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
    a_data_out : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    a_nWE, a_nCS, a_nOE : IN STD_LOGIC;

    -- Port B: axi_bram_ctrl's native BRAM_PORTA signature.
    b_addr : IN  STD_LOGIC_VECTOR(15 DOWNTO 0);
    b_din  : IN  STD_LOGIC_VECTOR(31 DOWNTO 0);
    b_dout : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    b_we   : IN  STD_LOGIC_VECTOR(3 DOWNTO 0);
    b_en   : IN  STD_LOGIC
  );
END cs1800_prcx18_memory;


ARCHITECTURE str OF cs1800_prcx18_memory IS

  CONSTANT c_rom_size  : INTEGER := 8192; -- bytes -- fixed, matches the real 2764
  CONSTANT c_rom_words : INTEGER := c_rom_size / 4; -- 2048
  CONSTANT c_mem_words : INTEGER := c_rom_words + g_ram_words; -- one unified array

  -- g_ram_words MUST be a power of two -- see this file's header's
  -- "bug #1" note. c_ram_addr_bits is how many low address bits (above
  -- the byte-lane's low 2) actually index the RAM's own local offset
  -- within its window; every bit above that is simply ignored
  -- (aliased), the exact same zero-arithmetic bit-slice idiom
  -- shared_ram.vhd/ram.vhd use -- no subtract, no modulo, nothing that
  -- needs a real divider.
  CONSTANT c_ram_addr_bits : INTEGER := integer(round(log2(real(g_ram_words))));

  TYPE t_word_array IS ARRAY (NATURAL RANGE <>) OF STD_LOGIC_VECTOR(31 DOWNTO 0);

  -- Packs test_program_pkg's byte array into 32-bit words, little-
  -- endian, purely so a from-scratch simulation build has *something*
  -- sensible at address 0 -- the real ROM is loaded via Port B at
  -- runtime (see file header), never embedded here.
  FUNCTION init_mem RETURN t_word_array IS
    VARIABLE result : t_word_array(0 TO c_mem_words - 1) := (OTHERS => X"00000000");
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

  -- ONE array covering both regions -- see this file's header's "bug
  -- #2" note for why this replaced two separate (rom, ram) arrays.
  -- Indices 0 TO c_rom_words-1 are the (write-protected) ROM region;
  -- c_rom_words TO c_mem_words-1 is RAM.
  SIGNAL mem : t_word_array(0 TO c_mem_words - 1) := init_mem;

  -- Effective (arbitrated) access, in the same "word index + 4-lane
  -- byte-enable" shape shared_ram.vhd uses -- see its own header for
  -- why this one-canonical-write-pattern shape is what Vivado's
  -- inference actually recognizes. eff_idx is a single, muxed INDEX
  -- into the one mem array -- never two independently-read arrays
  -- combined by a data-level mux (that was bug #2).
  SIGNAL eff_addr    : STD_LOGIC_VECTOR(15 DOWNTO 0);
  SIGNAL eff_is_rom  : STD_LOGIC;
  SIGNAL eff_data    : STD_LOGIC_VECTOR(31 DOWNTO 0);
  SIGNAL eff_we      : STD_LOGIC_VECTOR(3 DOWNTO 0);
  SIGNAL eff_en      : STD_LOGIC;
  SIGNAL eff_rom_idx : NATURAL RANGE 0 TO c_rom_words - 1;
  SIGNAL eff_ram_idx : NATURAL RANGE 0 TO g_ram_words - 1;
  SIGNAL eff_idx     : NATURAL RANGE 0 TO c_mem_words - 1;

  SIGNAL a_is_rom : STD_LOGIC;

  -- Port A's registered read state -- see the read process below.
  SIGNAL a_word_reg : STD_LOGIC_VECTOR(31 DOWNTO 0);
  SIGNAL a_lane_reg : STD_LOGIC_VECTOR(1 DOWNTO 0);
  SIGNAL a_sel_reg  : STD_LOGIC;

BEGIN

  eff_addr    <= b_addr WHEN sel_ext = '1' ELSE a_address;
  eff_is_rom  <= '1' WHEN eff_addr(15 DOWNTO 13) = "000" ELSE '0';
  eff_rom_idx <= to_integer(unsigned(eff_addr(12 DOWNTO 2)));
  eff_ram_idx <= to_integer(unsigned(eff_addr(c_ram_addr_bits + 1 DOWNTO 2)));
  -- Single index mux -- a small constant-offset add over an 8-bit
  -- range (g_ram_words), nothing like bug #1's runtime divider, and
  -- feeding only ONE array read downstream, never two.
  eff_idx     <= eff_rom_idx WHEN eff_is_rom = '1' ELSE c_rom_words + eff_ram_idx;

  eff_data <= b_din WHEN sel_ext = '1' ELSE a_data_in & a_data_in & a_data_in & a_data_in;

  -- Port A may only ever write RAM (a_is_rom below gates that); Port B
  -- may write either region (that's how the ROM image gets loaded).
  a_is_rom <= '1' WHEN a_address(15 DOWNTO 13) = "000" ELSE '0';

  eff_we <= b_we WHEN sel_ext = '1' ELSE
            "0000" WHEN a_is_rom = '1' ELSE
            "0001" WHEN (a_nCS = '0' AND a_nWE = '0' AND a_address(1 DOWNTO 0) = "00") ELSE
            "0010" WHEN (a_nCS = '0' AND a_nWE = '0' AND a_address(1 DOWNTO 0) = "01") ELSE
            "0100" WHEN (a_nCS = '0' AND a_nWE = '0' AND a_address(1 DOWNTO 0) = "10") ELSE
            "1000" WHEN (a_nCS = '0' AND a_nWE = '0' AND a_address(1 DOWNTO 0) = "11") ELSE
            "0000";

  eff_en <= b_en WHEN sel_ext = '1' ELSE '1';

  -- The one canonical byte-enabled write, synchronous -- same timing as
  -- ram.vhd/shared_ram.vhd's Port A write. Four static-slice lane
  -- writes into the one mem array, not a loop over a variable-bound
  -- slice, and not two separately-selected arrays.
  PROCESS (clk) IS
  BEGIN
    IF rising_edge(clk) THEN
      IF eff_en = '1' THEN
        IF eff_we(0) = '1' THEN mem(eff_idx)(7 DOWNTO 0)   <= eff_data(7 DOWNTO 0);   END IF;
        IF eff_we(1) = '1' THEN mem(eff_idx)(15 DOWNTO 8)  <= eff_data(15 DOWNTO 8);  END IF;
        IF eff_we(2) = '1' THEN mem(eff_idx)(23 DOWNTO 16) <= eff_data(23 DOWNTO 16); END IF;
        IF eff_we(3) = '1' THEN mem(eff_idx)(31 DOWNTO 24) <= eff_data(31 DOWNTO 24); END IF;
      END IF;
    END IF;
  END PROCESS;

  -- Port A read: registered (1-cycle latency, real Block-RAM shape),
  -- off ONE array read using a single muxed index. Registers the whole
  -- word + which byte lane + whether this access was even selected
  -- together, in lockstep, so a_data_out (below, purely combinational)
  -- only ever derives from one self-consistent, already-settled
  -- snapshot -- never mixes a freshly-changing address with a
  -- previous cycle's word the way an unregistered post-read mux would
  -- (see this file's "bug #2" history for exactly that hazard shape).
  PROCESS (clk) IS
    VARIABLE rom_idx : NATURAL RANGE 0 TO c_rom_words - 1;
    VARIABLE ram_idx : NATURAL RANGE 0 TO g_ram_words - 1;
    VARIABLE idx     : NATURAL RANGE 0 TO c_mem_words - 1;
  BEGIN
    IF rising_edge(clk) THEN
      IF (a_nCS = '0' AND a_nOE = '0') THEN
        rom_idx := to_integer(unsigned(a_address(12 DOWNTO 2)));
        ram_idx := to_integer(unsigned(a_address(c_ram_addr_bits + 1 DOWNTO 2)));
        IF a_is_rom = '1' THEN
          idx := rom_idx;
        ELSE
          idx := c_rom_words + ram_idx;
        END IF;
        a_word_reg <= mem(idx);
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

  -- Port B read: the whole word, one array read off the same single
  -- muxed index, no concatenation of separate elements. Left
  -- combinational/unregistered -- see file header.
  b_dout <= mem(c_rom_words + to_integer(unsigned(b_addr(c_ram_addr_bits + 1 DOWNTO 2))))
              WHEN b_addr(15 DOWNTO 13) /= "000" ELSE
            mem(to_integer(unsigned(b_addr(12 DOWNTO 2))));

END str;
