-------------------------------------------------------------------------------
--
-- File Name: cs1800_memory.vhd
-- Author: Leon Hiemstra
--
-- Title: CS1800 ROM+RAM memory, matching the real backplane's memory map
--
-- License: MIT
--
-- Description:
--   The full 64KB CDP1802 address space as the real CS1800 backplane
--   actually populates it (see doc/CS1800_HARDWARE.md's "Memory map"):
--   a read-only boot EPROM in the low rom_size bytes, plain writable RAM
--   above it. Real EPROM sockets ignore their WE pin entirely, so on
--   real hardware a write into the EPROM range is a silent no-op, not
--   corruption -- this model matches that: writes below rom_size are
--   simply discarded.
--
--   rom_init supplies the EPROM's contents (e.g. a real ROM dump,
--   generated into a local, gitignored VHDL package by
--   tools/hex_to_vhdl_rom.py -- see that script's header. This entity
--   itself is content-agnostic and holds no copyrighted material). RAM
--   above rom_size always starts out zeroed; real hardware RAM contents
--   at power-up are arbitrary anyway, so there's nothing meaningful to
--   model there.
--
--   Same interface and timing as ram.vhd (synchronous write on the full
--   system clock, qualified by nCS/nWE; asynchronous zero-latency read
--   qualified by nCS/nOE) -- see ram.vhd's own header for why that
--   particular split is the real hardware's proven, synthesizable async-
--   read/sync-write idiom, not just a simulation convenience.
--
--   GHDL-simulation-first (per this project's current testing sequence,
--   see doc/PRCX18_ANALYSIS.md): a flat 65536-entry array read
--   combinationally is fine for simulation, but porting this to real
--   FPGA hardware would need the same Block-RAM-inference care already
--   worked out for boards/cora-z7-07s/hdl/shared_ram.vhd (async read
--   forces distributed RAM, which is why that RAM is only 4KB) -- not
--   solved here, out of scope for this entity.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.std_logic_1164.ALL;
USE IEEE.numeric_std.ALL;
USE work.test_program_pkg.ALL; -- t_mem_array


ENTITY cs1800_memory IS
  GENERIC (
    rom_size : INTEGER := 8192; -- bytes 0 .. rom_size-1 are read-only
    rom_init : t_mem_array      -- exactly rom_size bytes; no default --
                                 -- every instance must say what its ROM holds
  );
  PORT (
    clk      : IN  STD_LOGIC;
    address  : IN  STD_LOGIC_VECTOR(15 DOWNTO 0);
    data_in  : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
    data_out : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    nWE, nCS, nOE : IN STD_LOGIC
  );
END cs1800_memory;

ARCHITECTURE str OF cs1800_memory IS

  FUNCTION f_init_mem(rom_contents : t_mem_array) RETURN t_mem_array IS
    VARIABLE result : t_mem_array(0 TO 65535) := (OTHERS => (OTHERS => '0'));
  BEGIN
    result(0 TO rom_contents'LENGTH - 1) := rom_contents;
    RETURN result;
  END FUNCTION;

  SIGNAL mem : t_mem_array(0 TO 65535) := f_init_mem(rom_init);

BEGIN

  -- Synchronous write, RAM region only -- see file header.
  PROCESS (clk) IS
  BEGIN
    IF rising_edge(clk) THEN
      -- Nested (rather than one AND'd condition) so address is only
      -- ever converted once actually selected for a write -- otherwise
      -- it's evaluated (and, before reset settles it, warns about
      -- being a metavalue) every cycle regardless of nCS/nWE, since
      -- VHDL doesn't short-circuit AND.
      IF nCS = '0' AND nWE = '0' THEN
        IF to_integer(unsigned(address)) >= rom_size THEN
          mem(to_integer(unsigned(address))) <= data_in;
        END IF;
      END IF;
    END IF;
  END PROCESS;

  -- Asynchronous read, zero latency, full address space (ROM and RAM
  -- alike) -- see file header.
  PROCESS (address, nCS, nOE, mem) IS
  BEGIN
    data_out <= (OTHERS => '0'); -- chip is not selected / not reading
    IF nCS = '0' AND nOE = '0' THEN
      data_out <= mem(to_integer(unsigned(address)));
    END IF;
  END PROCESS;

END str;
