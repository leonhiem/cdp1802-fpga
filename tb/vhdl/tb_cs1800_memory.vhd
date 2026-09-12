-------------------------------------------------------------------------------
--
-- File Name: tb_cs1800_memory.vhd
-- Author: Leon Hiemstra
--
-- Title: cs1800_memory testbench -- ROM/RAM split
--
-- License: MIT
--
-- Description:
--   Drives cs1800_memory directly (no CPU involved) to check the one
--   subtle, easy-to-get-wrong behavior this entity adds over a plain
--   RAM: the ROM region must read back its initial contents and must
--   silently ignore writes, while the RAM region above it must be
--   ordinary read/write memory -- matching a real EPROM socket's WE pin
--   doing nothing (see cs1800_memory.vhd's own header).
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE work.test_program_pkg.ALL;


ENTITY tb_cs1800_memory IS
END tb_cs1800_memory;

ARCHITECTURE tb OF tb_cs1800_memory IS

  CONSTANT clk_period : TIME := 10 ns;
  CONSTANT c_rom_size : INTEGER := 8;

  CONSTANT c_rom_init : t_mem_array(0 TO c_rom_size - 1) :=
    (X"11", X"22", X"33", X"44", X"55", X"66", X"77", X"88");

  SIGNAL clk      : STD_LOGIC := '0';
  SIGNAL tb_end   : STD_LOGIC := '0';
  SIGNAL address  : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL data_in  : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL data_out : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL nWE : STD_LOGIC := '1';
  SIGNAL nCS : STD_LOGIC := '0';
  SIGNAL nOE : STD_LOGIC := '1';

  PROCEDURE check(cond : BOOLEAN; msg : STRING) IS
  BEGIN
    ASSERT cond REPORT "FAIL: " & msg SEVERITY FAILURE;
  END PROCEDURE;

  PROCEDURE do_read(
    SIGNAL address_sig : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    SIGNAL nOE_sig      : OUT STD_LOGIC;
    SIGNAL clk_sig      : IN STD_LOGIC;
    addr : NATURAL) IS
  BEGIN
    address_sig <= std_logic_vector(to_unsigned(addr, 16));
    nOE_sig <= '0';
    WAIT UNTIL rising_edge(clk_sig);
    WAIT FOR 1 ns; -- let the combinational read settle
  END PROCEDURE;

  PROCEDURE do_write(
    SIGNAL address_sig : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    SIGNAL data_sig     : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    SIGNAL nWE_sig      : OUT STD_LOGIC;
    SIGNAL clk_sig      : IN STD_LOGIC;
    addr : NATURAL;
    data : STD_LOGIC_VECTOR(7 DOWNTO 0)) IS
  BEGIN
    address_sig <= std_logic_vector(to_unsigned(addr, 16));
    data_sig <= data;
    nWE_sig <= '0';
    WAIT UNTIL rising_edge(clk_sig);
    nWE_sig <= '1';
    WAIT UNTIL rising_edge(clk_sig);
  END PROCEDURE;

BEGIN

  clk <= NOT clk OR tb_end AFTER clk_period/2;

  u_dut : ENTITY work.cs1800_memory
  GENERIC MAP (
    rom_size => c_rom_size,
    rom_init => c_rom_init
  )
  PORT MAP (
    clk      => clk,
    address  => address,
    data_in  => data_in,
    data_out => data_out,
    nWE => nWE,
    nCS => nCS,
    nOE => nOE
  );

  p_test : PROCESS
  BEGIN
    WAIT UNTIL rising_edge(clk);

    -- ROM contents readable as initialized.
    do_read(address, nOE, clk, 3);
    check(data_out = X"44", "ROM byte 3 mismatch before any write attempt");
    nOE <= '1';

    -- A write into the ROM region must be silently ignored.
    WAIT UNTIL rising_edge(clk);
    do_write(address, data_in, nWE, clk, 3, X"AA");
    do_read(address, nOE, clk, 3);
    check(data_out = X"44", "write into ROM range must be a no-op");
    nOE <= '1';

    -- RAM above rom_size starts zeroed...
    WAIT UNTIL rising_edge(clk);
    do_read(address, nOE, clk, 9);
    check(data_out = X"00", "RAM byte should start zeroed");
    nOE <= '1';

    -- ...and is ordinary read/write memory.
    WAIT UNTIL rising_edge(clk);
    do_write(address, data_in, nWE, clk, 10, X"AA");
    do_read(address, nOE, clk, 10);
    check(data_out = X"AA", "write into RAM range should take effect");
    nOE <= '1';

    -- The RAM write above must not have disturbed the ROM.
    WAIT UNTIL rising_edge(clk);
    do_read(address, nOE, clk, 0);
    check(data_out = X"11", "ROM byte 0 disturbed by an unrelated RAM write");
    nOE <= '1';
    WAIT UNTIL rising_edge(clk);
    do_read(address, nOE, clk, 7);
    check(data_out = X"88", "ROM byte 7 (last ROM byte) disturbed");
    nOE <= '1';

    REPORT "ALL CHECKS PASSED";
    tb_end <= '1';
    WAIT;
  END PROCESS;

END tb;
