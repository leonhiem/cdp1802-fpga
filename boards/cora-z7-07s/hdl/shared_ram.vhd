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
--   64KB memory shared between cs1800 (Port A) and the AXI side (Port
--   B, via axi_bram_ctrl), so Linux can load a program while cs1800 is
--   held in reset.
--
--   The two sides are never accessed at once in practice: cs1800 is
--   held in reset while software writes a program, then released to
--   run. So this isn't true dual-port memory (which real Block RAM
--   would require, but only synchronously -- see the design log for
--   why a first attempt at that broke real timing-critical reads
--   inside cdp1802). Instead: two independent, zero-latency
--   combinational reads (real distributed RAM natively supports this
--   -- one write port, two read ports) and ONE arbitrated write,
--   selected by sel_ext (driven from cs1800's own reset bit: '1' while
--   held in reset hands write access to Port B, '0' while running
--   hands it back to Port A). Port A's read/write timing is exactly
--   src/vhdl/ram.vhd's (see its own header for why that's synthesis-
--   safe), so cs1800's own behavior is provably unchanged from before.
--
--   Pre-filled from test_program_pkg (the same contents src/vhdl/
--   ram.vhd carries), so a freshly-programmed board behaves exactly
--   like today's even before software writes anything.
--
--   Port B is 32 bits wide with a 4-bit byte-enable, not 8 bits: on
--   axi_bram_ctrl, the native BRAM port stays 32-bit regardless of the
--   configured AXI data width (C_S_AXI_DATA_WIDTH only affects the
--   AXI-facing side) -- checked directly against the IP rather than
--   assumed. b_addr is still a plain 16-bit byte address (matching
--   axi_bram_ctrl's bram_addr_a exactly), with its low 2 bits selecting
--   the byte lane -- the standard little-endian AXI byte-lane
--   convention (byte 0 = bits 7:0 = lowest address).
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

    -- Port A: CPU-facing, same signature and timing as src/vhdl/ram.vhd's.
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

  SIGNAL mem : t_mem_array(0 TO 65535) := (
    0 TO 275   => c_test_program,
    OTHERS     => X"00"
  );

  SIGNAL b_word_base : NATURAL RANGE 0 TO 65535;

BEGIN

  -- Word-aligned base byte address for Port B (low 2 bits of b_addr
  -- select the byte lane within b_din/b_dout/b_we, not a memory index
  -- of their own).
  b_word_base <= to_integer(unsigned(b_addr(15 DOWNTO 2))) * 4;

  -- One arbitrated write, synchronous -- same timing as src/vhdl/ram.vhd's
  -- (nCS/nWE held stable for several CLOCK cycles per access, so landing
  -- on one clean rising edge is safe; see that file's own header note).
  PROCESS (clk) IS
  BEGIN
    IF rising_edge(clk) THEN
      IF sel_ext = '1' THEN
        IF b_en = '1' THEN
          FOR i IN 0 TO 3 LOOP
            IF b_we(i) = '1' THEN
              mem(b_word_base + i) <= b_din(8*i+7 DOWNTO 8*i);
            END IF;
          END LOOP;
        END IF;
      ELSE
        IF a_nCS = '0' AND a_nWE = '0' THEN
          mem(to_integer(unsigned(a_address))) <= a_data_in;
        END IF;
      END IF;
    END IF;
  END PROCESS;

  -- Two independent, zero-latency combinational reads -- real distributed
  -- RAM natively supports one write port plus multiple read ports.
  PROCESS (a_address, a_nCS, a_nOE, mem) IS
  BEGIN
    a_data_out <= (OTHERS => '0'); -- chip is not selected / not reading
    IF (a_nCS = '0' AND a_nOE = '0') THEN
      a_data_out <= mem(to_integer(unsigned(a_address)));
    END IF;
  END PROCESS;

  b_dout <= mem(b_word_base + 3) & mem(b_word_base + 2) &
            mem(b_word_base + 1) & mem(b_word_base + 0);

END str;
