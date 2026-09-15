-------------------------------------------------------------------------------
--
-- File Name: cs1800_prcx18_memory.vhd
-- Author: Leon Hiemstra
--
-- Title: Real ROM+RAM memory for the CS1800 board bring-up (LUTRAM)
--
-- License: MIT
--
-- Description:
--   A real Block-RAM-based, wait-stated version of this entity was
--   tried first and abandoned: synchronous reads need the CPU held via
--   its mem_wait/PAUSE input while they settle, and that genuinely
--   corrupted execution a few instructions in (root-caused down to
--   cycle level: an address register went undefined on the third
--   machine cycle, reproducible, not yet fully explained) -- exactly
--   the kind of deep core-timing risk not worth taking here. Back to
--   the proven, zero-timing-risk approach instead: async read, the
--   exact same timing as ram.vhd/shared_ram.vhd (both already
--   hardware-proven), which forces distributed RAM (LUTRAM) -- and
--   LUTRAM on this part is capped at ~6000 LUTs total (shared_ram.vhd's
--   own header), nowhere near enough for the real 16KB minimum (8KB
--   ROM + 8KB RAM) the user proved by pulling chips from the actual
--   rack.
--
--   So: the full 8KB ROM (fixed -- that's the real firmware) plus as
--   much RAM as comfortably fits underneath that LUTRAM ceiling.
--
--   How much RAM PRCX-18 actually needs vs. how much fits (both found
--   empirically, in simulation for function and in real Vivado
--   synthesis for the LUTRAM budget):
--     1KB  (256 words)  -- functionally FAILS: boots the banner but
--                          loops forever repeating
--                          "-SYS-Starting Console Task-", never reaching
--                          the prompt (almost certainly the Console
--                          Task failing to allocate memory and retrying
--                          -- matches the PRCX-18 v1.9.0 error strings,
--                          E2?/PSIZE=00, which suggest it's designed to
--                          detect available RAM and degrade gracefully
--                          rather than require a fixed amount).
--     1.5KB (384 words) -- functionally FAILS, same symptom as 1KB.
--     1.75KB (448 words) -- also functionally FAILS (same symptom),
--                          confirmed but not fully bisected past this.
--     2KB  (512 words)  -- functionally SUCCEEDS: reaches a real
--                          prompt ("_00>", a smaller-RAM variant of the
--                          same "_08>" prompt 4KB gives -- both are
--                          full, non-stuck successes). Does NOT fit the
--                          LUTRAM budget: 6134/6000 (102.23%).
--     4KB  (1024 words) -- functionally SUCCEEDS, byte-for-byte
--                          identical to the full run against real
--                          hardware (see doc/PRCX18_ANALYSIS.md). Badly
--                          overshoots the LUTRAM budget: 7158/6000
--                          (119.30%).
--   So within the tested range, no single size fits the resource
--   budget AND fully boots PRCX-18 -- the threshold for "fits" sits
--   somewhere below 1.75KB and the threshold for "boots" sits somewhere
--   above 1.75KB, i.e. they don't overlap. A real fix (e.g. a corrected
--   wait-state/Block-RAM approach) is future work, not attempted here.
--
--   Real hardware-only bug #1 found and fixed, 2026-09-14: the original
--   384-word (1.5KB) choice -- not a power of two, picked purely to
--   hit the LUTRAM budget as closely as possible -- forced the RAM
--   index's address decode to compute a genuine subtract-then-MOD-384
--   (a non-power-of-two modulo needs a real combinational divider, not
--   a bit-slice) on *every* read, unconditionally, even ROM ones. Fixed
--   by requiring a power of two there (256 words) -- a real, verified
--   improvement (the CPU ran measurably further before the next hang),
--   but not sufficient on its own -- see bug #2.
--
--   Real hardware-only bug #2 found and fixed, 2026-09-14: even with
--   bug #1's fix, this file still kept ROM and RAM as two *separate*
--   arrays, each read unconditionally on every access, combined via a
--   data-level 2:1 mux (selecting between rom(rom_idx) and ram(ram_idx)
--   -- see git history for the exact prior shape). That's a shape no
--   previously-proven design here (ram.vhd, shared_ram.vhd) ever uses.
--   The hazard: even while a_is_rom's *value* stays constant (e.g. the
--   whole time execution stays inside ROM), the mux's other input
--   (ram(ram_idx)) is still a live signal changing on every address
--   transition -- an unregistered 2:1 mux with a constantly-changing
--   "losing" input is a textbook static-hazard setup, independent of
--   how simple that input's own address decode is. On real hardware
--   this looked like the CPU hanging in a tight 2-address loop, stuck
--   in the execute state (SC never returning to fetch) -- confirmed via
--   ILA, GHDL again saw nothing (zero-delay simulation can't model this
--   at all). Fixed by merging rom and ram into one array (mem) and
--   muxing the *index* once before a single read, never the data after
--   two independent reads -- exactly the same safe idiom the write side
--   (and shared_ram.vhd generally) already used. Now there is exactly
--   one array, one read, matching shared_ram.vhd's proven shape as
--   closely as a write-protected ROM region allows.
--
--   Separate, real hazard worth remembering (not what either bug above
--   was, but inherent to ANY undersized RAM window here): PRCX-18 was
--   written assuming the real backplane's full, non-aliased 48-56KB of
--   SRAM. Whatever fraction of that we can't fit gets aliased -- two
--   pages the firmware believes are completely distinct can be the
--   same physical bytes here. That's silent cross-page corruption, not
--   just a capacity shortfall, and it doesn't go away by picking a
--   power of two -- only by eventually fitting enough real, non-aliased
--   RAM to match what the firmware assumes.
--
--   Port A: CPU-facing, same signature and timing as ram.vhd/
--   shared_ram.vhd's (async read, synchronous write, single-port
--   timing arbitrated by sel_ext). Writes to the ROM region from Port A
--   are silently ignored, matching a real EPROM's WE pin doing nothing.
--   Port B: axi_bram_ctrl's native BRAM_PORTA shape (32-bit, 4-bit
--   byte-enable -- fixed regardless of AXI data width, see
--   shared_ram.vhd's header), used to load the real ROM image at
--   runtime -- never embedded here. Port B can write anywhere,
--   including the ROM region -- that's how the real ROM image actually
--   gets loaded, exactly like shared_ram.vhd's Port B loads a program.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.std_logic_1164.ALL;
USE IEEE.numeric_std.ALL;
USE IEEE.math_real.ALL;
USE work.test_program_pkg.ALL;


ENTITY cs1800_prcx18_memory IS
  GENERIC (
    g_ram_words : INTEGER := 256 -- 32-bit words of RAM above the 8KB ROM (256 = 1KB, 4 full CDP1802 pages -- MUST be a power of two, see this file's header's "bug #1" note; cs1800_prcx18_top.vhd always passes its own generic through anyway)
  );
  PORT (
    clk     : IN STD_LOGIC;
    sel_ext : IN STD_LOGIC; -- '1': Port B may write. '0': Port A may write.

    -- Port A: CPU-facing, ram.vhd/shared_ram.vhd's exact timing.
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

  -- Port A read: zero-latency combinational, one static-slice lane
  -- selected via a case on the address's low 2 bits, off ONE array
  -- read using a single muxed index (see "bug #2" above -- this used
  -- to be two independent array reads combined by a data-level mux).
  PROCESS (a_address, a_nCS, a_nOE, a_is_rom, mem) IS
    VARIABLE rom_idx : NATURAL RANGE 0 TO c_rom_words - 1;
    VARIABLE ram_idx : NATURAL RANGE 0 TO g_ram_words - 1;
    VARIABLE idx     : NATURAL RANGE 0 TO c_mem_words - 1;
    VARIABLE word    : STD_LOGIC_VECTOR(31 DOWNTO 0);
  BEGIN
    a_data_out <= (OTHERS => '0'); -- chip is not selected / not reading
    IF (a_nCS = '0' AND a_nOE = '0') THEN
      rom_idx := to_integer(unsigned(a_address(12 DOWNTO 2)));
      ram_idx := to_integer(unsigned(a_address(c_ram_addr_bits + 1 DOWNTO 2)));
      IF a_is_rom = '1' THEN
        idx := rom_idx;
      ELSE
        idx := c_rom_words + ram_idx;
      END IF;
      word := mem(idx);
      CASE a_address(1 DOWNTO 0) IS
        WHEN "00"   => a_data_out <= word(7 DOWNTO 0);
        WHEN "01"   => a_data_out <= word(15 DOWNTO 8);
        WHEN "10"   => a_data_out <= word(23 DOWNTO 16);
        WHEN OTHERS => a_data_out <= word(31 DOWNTO 24);
      END CASE;
    END IF;
  END PROCESS;

  -- Port B read: the whole word, one array read off the same single
  -- muxed index, no concatenation of separate elements.
  b_dout <= mem(c_rom_words + to_integer(unsigned(b_addr(c_ram_addr_bits + 1 DOWNTO 2))))
              WHEN b_addr(15 DOWNTO 13) /= "000" ELSE
            mem(to_integer(unsigned(b_addr(12 DOWNTO 2))));

END str;
