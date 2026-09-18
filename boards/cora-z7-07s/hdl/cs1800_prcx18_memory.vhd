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
--   Why Port B is 32-bit/14-bit while the CDP1802 itself is 8-bit/
--   16-bit (question asked directly while reviewing this in the
--   Vivado GUI, 2026-09-16): Port A and Port B are two genuinely
--   different-width ports on the same dual-port Block RAM (a real,
--   supported primitive feature -- the underlying array is just N
--   total bits, and each port independently picks how many bits per
--   address it exposes). Port A matches the CDP1802 exactly (8-bit
--   data, and -- via A_full, see above -- the CPU's real, full 16-bit
--   address, completely unrestricted). Port B is a second, separate
--   interface that exists ONLY so Linux can bulk-load the ROM image
--   over AXI (which is natively 32-bit on this Zynq part) -- 32-bit
--   words let gen_load_prcx18_rom.py write 4 ROM bytes per `devmem`
--   call instead of 1, a genuine 4x speedup, not incidental. Its
--   14-bit address is simply g_ram_words+ROM's actual combined size
--   (8KB+8KB=16KB) expressed as a BYTE address (2^14=16384, matching
--   build_project_prcx18.tcl's own `-range 0x00004000`) -- `ram_b_addr`
--   is still declared a full 16 bits for generality, but only the
--   lower 14 are ever wired to real memory (Vivado's own build log
--   already flags this, benignly: "Width mismatch...ram_b_addr(16) to
--   bram_addr_a(14) -- only lower order bits will be connected").
--
--   Real full 16-bit chip-select decode, 2026-09-18 (see
--   boards/cora-z7-07s/BRINGUP_LOG.md's RAM-aliasing investigation):
--   this used to be a minimal 2-region decode (only bits 15:13 checked,
--   just enough to pick ROM vs "everything else is RAM, indexed by the
--   low bits alone") -- meaning ANY address with bits 15:13 not all
--   zero (0x2000, 0x4000, 0x8000, 0xC000, etc.) aliased onto the exact
--   same physical RAM bytes. That was a real, confirmed bug, not a
--   harmless simplification: PRCX-18's own boot-time RAM-sizing sweep
--   (a classic write-then-readback probe) is fooled by aliasing into
--   believing it has the full 64KB the real machine can have, then
--   allocates its own real, distinct-looking data structures (task
--   control blocks, buffers) across that whole believed range --
--   silently corrupting each other whenever two such allocations
--   shared the same low address bits (confirmed directly: a per-task
--   "already running" flag at 0xFBD0 was being clobbered by unrelated
--   writes to 0x3BD0/0x7BD0/0xBBD0, all the same physical byte,
--   spuriously respawning PRCX-18's own Console Task over and over).
--
--   Per the user (who owns the real backplane and confirmed this from
--   the real memory board schematic): the real hardware works
--   correctly even in this same minimal 8KB ROM + 8KB RAM
--   configuration, because its address decode uses all 16 address
--   lines properly -- a chip's chip-select is only ever active within
--   its own actual installed range; every other address is genuinely
--   unmapped (no chip drives the bus at all), never aliased onto a
--   populated chip. `eff_is_rom`/`a_is_rom` (ROM, 0x0000-0x1FFF) now
--   has a sibling `eff_is_ram_valid`/`a_is_ram_valid` (RAM, exactly
--   `c_rom_size` to `c_rom_size + g_ram_words*4 - 1` -- i.e. starting
--   right after ROM, sized to whatever g_ram_words actually is, not a
--   moment longer). Anything in neither range is genuinely unmapped:
--   Port A writes there are silently discarded (same as a real EPROM's
--   WE pin doing nothing) and reads return a fixed `c_unmapped_byte`
--   pattern instead of real memory content -- not a guess at any
--   *specific* real open-bus value (that would depend on the real
--   bus's actual pull-up/pull-down/capacitive behavior, not modeled
--   here), just a fixed, non-aliasing placeholder that reliably fails
--   PRCX-18's own write-then-readback RAM-sizing probe at the correct,
--   real boundary instead of always succeeding.
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

  -- Real chip-select range for RAM: starts right after ROM, sized to
  -- whatever g_ram_words actually is -- see this file's header. A
  -- plain range compare (not a bit-pattern match) so this stays
  -- correct for any power-of-two g_ram_words without further changes.
  CONSTANT c_ram_base  : unsigned(15 DOWNTO 0) := to_unsigned(c_rom_size, 16);
  CONSTANT c_ram_top   : unsigned(15 DOWNTO 0) := to_unsigned(c_rom_size + g_ram_words*4 - 1, 16);

  -- Fixed value returned for a genuinely unmapped Port A read -- see
  -- this file's header for why this is a placeholder, not a claim
  -- about the real bus's actual open-bus voltage.
  CONSTANT c_unmapped_byte : STD_LOGIC_VECTOR(7 DOWNTO 0) := X"FF";

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

  SIGNAL a_is_rom       : STD_LOGIC;
  SIGNAL a_is_ram_valid : STD_LOGIC;

  -- Port A's registered read state -- see the read process below.
  SIGNAL a_word_reg     : STD_LOGIC_VECTOR(31 DOWNTO 0);
  SIGNAL a_lane_reg     : STD_LOGIC_VECTOR(1 DOWNTO 0);
  SIGNAL a_sel_reg      : STD_LOGIC;
  SIGNAL a_unmapped_reg : STD_LOGIC;

  -- Port B's registered read state -- see the read process below.
  SIGNAL b_dout_reg : STD_LOGIC_VECTOR(31 DOWNTO 0);

BEGIN

  -- Real full 16-bit chip-select decode -- see this file's header.
  -- Port B (our own runtime ROM-loading path from Linux, not a real
  -- chip) is left unrestricted -- eff_is_rom/eff_ram_idx below only
  -- matter for Port B in the sense that they still correctly place a
  -- byte within ROM vs RAM; Port B never needs the "genuinely
  -- unmapped" concept since it doesn't model a real bus device.
  eff_addr    <= b_addr WHEN sel_ext = '1' ELSE a_address;
  eff_is_rom  <= '1' WHEN eff_addr(15 DOWNTO 13) = "000" ELSE '0';
  eff_rom_idx <= to_integer(unsigned(eff_addr(12 DOWNTO 2)));
  eff_ram_idx <= to_integer(unsigned(eff_addr(c_ram_addr_bits + 1 DOWNTO 2)));
  -- Single index mux -- a small constant-offset add over an 8-bit
  -- range (g_ram_words), nothing like bug #1's runtime divider, and
  -- feeding only ONE array read downstream, never two.
  eff_idx     <= eff_rom_idx WHEN eff_is_rom = '1' ELSE c_rom_words + eff_ram_idx;

  eff_data <= b_din WHEN sel_ext = '1' ELSE a_data_in & a_data_in & a_data_in & a_data_in;

  -- Port A may only ever write its own real, in-range RAM -- neither
  -- ROM (a real EPROM's WE pin does nothing) nor anything genuinely
  -- unmapped (no real chip there to write to either). Port B may write
  -- either region (that's how the ROM image gets loaded) -- it doesn't
  -- model a real bus device, see above.
  a_is_rom       <= '1' WHEN a_address(15 DOWNTO 13) = "000" ELSE '0';
  a_is_ram_valid <= '1' WHEN (unsigned(a_address) >= c_ram_base AND unsigned(a_address) <= c_ram_top) ELSE '0';

  eff_we <= b_we WHEN sel_ext = '1' ELSE
            "0000" WHEN a_is_ram_valid = '0' ELSE
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
  BEGIN
    IF rising_edge(clk) THEN
      IF (a_nCS = '0' AND a_nOE = '0') THEN
        a_sel_reg  <= '1';
        a_lane_reg <= a_address(1 DOWNTO 0);
        IF a_is_rom = '1' THEN
          rom_idx        := to_integer(unsigned(a_address(12 DOWNTO 2)));
          a_word_reg     <= mem(rom_idx);
          a_unmapped_reg <= '0';
        ELSIF a_is_ram_valid = '1' THEN
          ram_idx        := to_integer(unsigned(a_address(c_ram_addr_bits + 1 DOWNTO 2)));
          a_word_reg     <= mem(c_rom_words + ram_idx);
          a_unmapped_reg <= '0';
        ELSE
          -- Genuinely unmapped -- see this file's header. a_word_reg's
          -- own value doesn't matter here (a_unmapped_reg overrides it
          -- in a_data_out below), so it's simply left unchanged.
          a_unmapped_reg <= '1';
        END IF;
      ELSE
        a_sel_reg <= '0'; -- chip not selected / not reading
      END IF;
    END IF;
  END PROCESS;

  a_data_out <= (OTHERS => '0') WHEN a_sel_reg = '0' ELSE
                c_unmapped_byte          WHEN a_unmapped_reg = '1' ELSE
                a_word_reg(7 DOWNTO 0)   WHEN a_lane_reg = "00" ELSE
                a_word_reg(15 DOWNTO 8)  WHEN a_lane_reg = "01" ELSE
                a_word_reg(23 DOWNTO 16) WHEN a_lane_reg = "10" ELSE
                a_word_reg(31 DOWNTO 24);

  -- Port B read: registered too, 2026-09-15 -- see this file's header.
  -- A single VHDL array with one port reading async and the other
  -- synchronous cannot map to one real Block RAM primitive at all (a
  -- real BRAM's read ports are always registered); left as
  -- combinational at first because "axi_bram_ctrl already tolerates
  -- it," this alone was enough to force Vivado to infer the *whole*
  -- 4K x 32 array as distributed RAM again (confirmed directly in the
  -- synthesis log's own RAM mapping report) and fail the LUTRAM
  -- budget DRC check outright at this size. Registering this port too
  -- is also the more correct choice on its own terms:
  -- axi_bram_ctrl's native BRAM_PORTA interface (SINGLE_PORT_BRAM mode,
  -- see build_project_prcx18.tcl) is designed against a real,
  -- registered Block RAM's actual 1-cycle latency already, not
  -- assuming zero.
  PROCESS (clk) IS
  BEGIN
    IF rising_edge(clk) THEN
      IF b_en = '1' THEN
        IF b_addr(15 DOWNTO 13) /= "000" THEN
          b_dout_reg <= mem(c_rom_words + to_integer(unsigned(b_addr(c_ram_addr_bits + 1 DOWNTO 2))));
        ELSE
          b_dout_reg <= mem(to_integer(unsigned(b_addr(12 DOWNTO 2))));
        END IF;
      END IF;
    END IF;
  END PROCESS;

  b_dout <= b_dout_reg;

END str;
