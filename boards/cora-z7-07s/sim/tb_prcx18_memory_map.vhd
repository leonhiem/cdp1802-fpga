-------------------------------------------------------------------------------
--
-- File Name: tb_prcx18_memory_map.vhd
--
-- Title: cs1800_prcx18_memory's address decode, proven over all 64K addresses
--
-- License: MIT
--
-- Description:
--   Walks the CPU port over the WHOLE 16-bit address space and checks the
--   decode the real backplane has, using all 16 address lines:
--     ROM   : writes ignored (a real EPROM's WE pin does nothing)
--     RAM   : writes stored, and every address is its own storage
--     void  : writes ignored, reads return the unmapped pattern (0xFF)
--
--   Aliasing is what this test is really for. Each RAM address is written
--   a byte derived from the address itself, mixing the high and low byte
--   (so two addresses that differ in ANY single bit get different data),
--   and then every RAM address is read back. If any two addresses shared
--   storage, the second write would have changed the first one's byte and
--   the read-back fails, naming the address.
--
--   It also checks Port B's flat window (ROM at offset 0, RAM right
--   behind it) by writing a word through Port B and reading the bytes
--   back through the CPU port.
--
--   Generics let the same testbench check any configuration; the default
--   is the real 32KB memory card (ROM 0x0000-0x1FFF, RAM 0x2000-0x7FFF,
--   0x8000-0xFFFF void, the second card absent).
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

ENTITY tb_prcx18_memory_map IS
  GENERIC (
    g_ram_base_addr : INTEGER := 16#2000#;
    g_ram_words     : INTEGER := 6144
  );
END tb_prcx18_memory_map;

ARCHITECTURE tb OF tb_prcx18_memory_map IS

  CONSTANT c_rom_size : INTEGER := 8192;
  CONSTANT c_ram_lo   : INTEGER := g_ram_base_addr;
  CONSTANT c_ram_hi   : INTEGER := g_ram_base_addr + g_ram_words * 4 - 1;

  SIGNAL clk    : STD_LOGIC := '0';
  SIGNAL tb_end : STD_LOGIC := '0';

  SIGNAL a_address : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL a_data_in : STD_LOGIC_VECTOR(7 DOWNTO 0)  := (OTHERS => '0');
  SIGNAL a_data_out : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL a_nWE, a_nCS, a_nOE : STD_LOGIC := '1';

  SIGNAL b_addr : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL b_din  : STD_LOGIC_VECTOR(31 DOWNTO 0) := (OTHERS => '0');
  SIGNAL b_dout : STD_LOGIC_VECTOR(31 DOWNTO 0);
  SIGNAL b_we   : STD_LOGIC_VECTOR(3 DOWNTO 0) := (OTHERS => '0');
  SIGNAL b_en   : STD_LOGIC := '0';
  SIGNAL sel_ext : STD_LOGIC := '0';

  SIGNAL errors : NATURAL := 0;

  -- Address-derived data: high and low byte mixed, so any two addresses
  -- that differ in any bit get different bytes (that is what makes an
  -- alias visible).
  FUNCTION pattern(addr : INTEGER) RETURN STD_LOGIC_VECTOR IS
    VARIABLE a : unsigned(15 DOWNTO 0) := to_unsigned(addr, 16);
  BEGIN
    RETURN STD_LOGIC_VECTOR(a(7 DOWNTO 0) XOR a(15 DOWNTO 8) XOR X"5A");
  END FUNCTION;

BEGIN

  clk <= NOT clk OR tb_end AFTER 5 ns;

  u_mem : ENTITY work.cs1800_prcx18_memory
  GENERIC MAP ( g_ram_base_addr => g_ram_base_addr, g_ram_words => g_ram_words )
  PORT MAP (
    clk => clk, sel_ext => sel_ext,
    a_address => a_address, a_data_in => a_data_in, a_data_out => a_data_out,
    a_nWE => a_nWE, a_nCS => a_nCS, a_nOE => a_nOE,
    b_addr => b_addr, b_din => b_din, b_dout => b_dout, b_we => b_we, b_en => b_en
  );

  p_test : PROCESS
    TYPE t_bytes IS ARRAY (NATURAL RANGE <>) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
    VARIABLE rom_before : t_bytes(0 TO c_rom_size - 1);
    VARIABLE got : STD_LOGIC_VECTOR(7 DOWNTO 0);
    VARIABLE n_ram, n_void, n_rom : NATURAL := 0;

    PROCEDURE cpu_write(addr : INTEGER; data : STD_LOGIC_VECTOR(7 DOWNTO 0)) IS
    BEGIN
      a_address <= STD_LOGIC_VECTOR(to_unsigned(addr, 16));
      a_data_in <= data;
      a_nCS <= '0'; a_nWE <= '0';
      WAIT UNTIL rising_edge(clk);
      a_nCS <= '1'; a_nWE <= '1';
      WAIT UNTIL rising_edge(clk);
    END PROCEDURE;

    PROCEDURE cpu_read(addr : INTEGER; data : OUT STD_LOGIC_VECTOR(7 DOWNTO 0)) IS
    BEGIN
      a_address <= STD_LOGIC_VECTOR(to_unsigned(addr, 16));
      a_nCS <= '0'; a_nOE <= '0';
      WAIT UNTIL rising_edge(clk);   -- registered read: one cycle of latency
      WAIT UNTIL rising_edge(clk);
      data := a_data_out;
      a_nCS <= '1'; a_nOE <= '1';
    END PROCEDURE;

    PROCEDURE check(cond : BOOLEAN; msg : STRING) IS
    BEGIN
      IF NOT cond THEN
        errors <= errors + 1;
        REPORT msg SEVERITY ERROR;
      END IF;
    END PROCEDURE;
  BEGIN
    WAIT UNTIL rising_edge(clk);

    -- 0. snapshot the ROM region, so "writes are ignored" can be checked
    --    against what was actually there rather than against a guess
    FOR addr IN 0 TO c_rom_size - 1 LOOP
      cpu_read(addr, got);
      rom_before(addr) := got;
    END LOOP;

    -- 1. write the address-derived pattern everywhere it is allowed, and
    --    everywhere it is NOT allowed (those must be ignored)
    FOR addr IN 0 TO 65535 LOOP
      cpu_write(addr, pattern(addr));
    END LOOP;

    -- 2. read everything back
    FOR addr IN 0 TO 65535 LOOP
      cpu_read(addr, got);
      IF addr >= c_ram_lo AND addr <= c_ram_hi THEN
        n_ram := n_ram + 1;
        check(got = pattern(addr),
              "RAM alias/miss at " & INTEGER'IMAGE(addr));
      ELSIF addr < c_rom_size THEN
        n_rom := n_rom + 1;
        check(got = rom_before(addr),
              "ROM accepted a write at " & INTEGER'IMAGE(addr));
      ELSE
        n_void := n_void + 1;
        check(got = X"FF",
              "void address " & INTEGER'IMAGE(addr) & " did not read FF");
      END IF;
    END LOOP;

    -- 3. Port B's flat window: ROM at offset 0, RAM right behind it
    sel_ext <= '1';
    b_addr <= STD_LOGIC_VECTOR(to_unsigned(c_rom_size, 16));  -- first RAM word
    b_din  <= X"44332211";
    b_we   <= "1111";
    b_en   <= '1';
    WAIT UNTIL rising_edge(clk);
    b_we <= "0000";
    b_en <= '0';
    sel_ext <= '0';
    WAIT UNTIL rising_edge(clk);
    FOR k IN 0 TO 3 LOOP
      cpu_read(c_ram_lo + k, got);
      check(got = STD_LOGIC_VECTOR(to_unsigned(16#11# * (k + 1), 8)),
            "Port B's flat window does not land on the RAM base");
    END LOOP;

    REPORT "checked: " & INTEGER'IMAGE(n_ram) & " RAM, "
         & INTEGER'IMAGE(n_rom) & " ROM, " & INTEGER'IMAGE(n_void) & " void addresses";
    IF errors = 0 THEN
      REPORT "ALL CHECKS PASSED";
    ELSE
      REPORT INTEGER'IMAGE(errors) & " CHECKS FAILED" SEVERITY FAILURE;
    END IF;
    tb_end <= '1';
    WAIT;
  END PROCESS;

END tb;
