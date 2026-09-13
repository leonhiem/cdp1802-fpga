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
--   much RAM as comfortably fits underneath that LUTRAM ceiling. Two
--   separate power-of-two arrays (not one combined array), so both
--   stay simple bit-sliced/masked address decodes: ROM covers
--   0x0000-0x1FFF exactly, RAM starts at 0x2000 and aliases within its
--   own (much smaller) window above that, the same "smaller-than-the-
--   full-address-space" idiom shared_ram.vhd already uses.
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
--                          Fits the LUTRAM budget: 5878/6000 LUT-as-
--                          Memory (97.97%). THIS IS THE CURRENT DEFAULT
--                          -- chosen deliberately even though it's
--                          functionally short, to bring up real
--                          hardware and watch the partial-boot behavior
--                          live before spending more time on a proper
--                          fix (see cs1800_prcx18_top.vhd's header and
--                          the project README for the plan).
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
--   above 1.75KB, i.e. they don't overlap. Deliberately shipping at
--   1.5KB for now (fits, partial boot) rather than continuing to
--   bisect; a real fix (e.g. a corrected wait-state/Block-RAM approach)
--   is future work, not attempted here.
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
USE work.test_program_pkg.ALL;


ENTITY cs1800_prcx18_memory IS
  GENERIC (
    g_ram_words : INTEGER := 384 -- 32-bit words of RAM above the 8KB ROM (384 = 1.5KB, fits this part's LUTRAM budget but functionally short -- see this file's header for the full size/tradeoff table; cs1800_prcx18_top.vhd always passes its own generic through anyway)
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

  TYPE t_word_array IS ARRAY (NATURAL RANGE <>) OF STD_LOGIC_VECTOR(31 DOWNTO 0);

  -- Packs test_program_pkg's byte array into 32-bit words, little-
  -- endian, purely so a from-scratch simulation build has *something*
  -- sensible at address 0 -- the real ROM is loaded via Port B at
  -- runtime (see file header), never embedded here.
  FUNCTION init_rom RETURN t_word_array IS
    VARIABLE result : t_word_array(0 TO c_rom_words - 1) := (OTHERS => X"00000000");
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

  SIGNAL rom : t_word_array(0 TO c_rom_words - 1) := init_rom;
  SIGNAL ram : t_word_array(0 TO g_ram_words - 1) := (OTHERS => X"00000000");

  -- Effective (arbitrated) access, in the same "word index + 4-lane
  -- byte-enable" shape shared_ram.vhd uses -- see its own header for
  -- why this one-canonical-write-pattern shape is what Vivado's
  -- inference actually recognizes.
  SIGNAL eff_addr    : STD_LOGIC_VECTOR(15 DOWNTO 0);
  SIGNAL eff_is_rom  : STD_LOGIC;
  SIGNAL eff_data    : STD_LOGIC_VECTOR(31 DOWNTO 0);
  SIGNAL eff_we      : STD_LOGIC_VECTOR(3 DOWNTO 0);
  SIGNAL eff_en      : STD_LOGIC;
  SIGNAL eff_rom_idx : NATURAL RANGE 0 TO c_rom_words - 1;
  SIGNAL eff_ram_idx : NATURAL RANGE 0 TO g_ram_words - 1;

  SIGNAL a_is_rom : STD_LOGIC;

BEGIN

  eff_addr   <= b_addr WHEN sel_ext = '1' ELSE a_address;
  eff_is_rom <= '1' WHEN eff_addr(15 DOWNTO 13) = "000" ELSE '0';
  eff_rom_idx <= to_integer(unsigned(eff_addr(12 DOWNTO 2)));
  eff_ram_idx <= (to_integer(unsigned(eff_addr(15 DOWNTO 2))) - c_rom_words) MOD g_ram_words;

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
  -- writes, not a loop over a variable-bound slice.
  PROCESS (clk) IS
  BEGIN
    IF rising_edge(clk) THEN
      IF eff_en = '1' THEN
        IF eff_is_rom = '1' THEN
          IF eff_we(0) = '1' THEN rom(eff_rom_idx)(7 DOWNTO 0)   <= eff_data(7 DOWNTO 0);   END IF;
          IF eff_we(1) = '1' THEN rom(eff_rom_idx)(15 DOWNTO 8)  <= eff_data(15 DOWNTO 8);  END IF;
          IF eff_we(2) = '1' THEN rom(eff_rom_idx)(23 DOWNTO 16) <= eff_data(23 DOWNTO 16); END IF;
          IF eff_we(3) = '1' THEN rom(eff_rom_idx)(31 DOWNTO 24) <= eff_data(31 DOWNTO 24); END IF;
        ELSE
          IF eff_we(0) = '1' THEN ram(eff_ram_idx)(7 DOWNTO 0)   <= eff_data(7 DOWNTO 0);   END IF;
          IF eff_we(1) = '1' THEN ram(eff_ram_idx)(15 DOWNTO 8)  <= eff_data(15 DOWNTO 8);  END IF;
          IF eff_we(2) = '1' THEN ram(eff_ram_idx)(23 DOWNTO 16) <= eff_data(23 DOWNTO 16); END IF;
          IF eff_we(3) = '1' THEN ram(eff_ram_idx)(31 DOWNTO 24) <= eff_data(31 DOWNTO 24); END IF;
        END IF;
      END IF;
    END IF;
  END PROCESS;

  -- Port A read: zero-latency combinational, one static-slice lane
  -- selected via a case on the address's low 2 bits.
  PROCESS (a_address, a_nCS, a_nOE, a_is_rom, rom, ram) IS
    VARIABLE rom_idx : NATURAL RANGE 0 TO c_rom_words - 1;
    VARIABLE ram_idx : NATURAL RANGE 0 TO g_ram_words - 1;
    VARIABLE word    : STD_LOGIC_VECTOR(31 DOWNTO 0);
  BEGIN
    a_data_out <= (OTHERS => '0'); -- chip is not selected / not reading
    IF (a_nCS = '0' AND a_nOE = '0') THEN
      rom_idx := to_integer(unsigned(a_address(12 DOWNTO 2)));
      ram_idx := (to_integer(unsigned(a_address(15 DOWNTO 2))) - c_rom_words) MOD g_ram_words;
      IF a_is_rom = '1' THEN
        word := rom(rom_idx);
      ELSE
        word := ram(ram_idx);
      END IF;
      CASE a_address(1 DOWNTO 0) IS
        WHEN "00"   => a_data_out <= word(7 DOWNTO 0);
        WHEN "01"   => a_data_out <= word(15 DOWNTO 8);
        WHEN "10"   => a_data_out <= word(23 DOWNTO 16);
        WHEN OTHERS => a_data_out <= word(31 DOWNTO 24);
      END CASE;
    END IF;
  END PROCESS;

  -- Port B read: the whole word, one array read, no concatenation of
  -- separate elements.
  b_dout <= rom(to_integer(unsigned(b_addr(12 DOWNTO 2))))
              WHEN b_addr(15 DOWNTO 13) = "000" ELSE
            ram((to_integer(unsigned(b_addr(15 DOWNTO 2))) - c_rom_words) MOD g_ram_words);

END str;
