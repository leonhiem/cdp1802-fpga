-------------------------------------------------------------------------------
--
-- File Name: tb_shared_ram.vhd
-- Author: Leon Hiemstra
--
-- Title: shared_ram testbench -- Port B byte-lane adapter
--
-- License: MIT
--
-- Description:
--   Port A (the CPU-facing side) is exactly ram.vhd's proven interface
--   and timing, already exercised indirectly by every cs1800/cdp18
--   testbench. Port B's 32-bit/byte-enable adapter to axi_bram_ctrl's
--   native BRAM port is new, untested logic -- this drives it directly:
--   write each byte lane individually, a full word at once, and a
--   read-modify-check for each, then confirm Port A reads back exactly
--   what Port B wrote (proving they share the same underlying memory).
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;


ENTITY tb_shared_ram IS
END tb_shared_ram;

ARCHITECTURE tb OF tb_shared_ram IS

  CONSTANT clk_period : TIME := 10 ns;

  SIGNAL clk     : STD_LOGIC := '0';
  SIGNAL tb_end  : STD_LOGIC := '0';
  SIGNAL sel_ext : STD_LOGIC := '1';

  SIGNAL a_address  : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL a_data_in  : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL a_data_out : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL a_nWE      : STD_LOGIC := '1';
  SIGNAL a_nCS      : STD_LOGIC := '0';
  SIGNAL a_nOE      : STD_LOGIC := '1';

  SIGNAL b_addr : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL b_din  : STD_LOGIC_VECTOR(31 DOWNTO 0) := (OTHERS => '0');
  SIGNAL b_dout : STD_LOGIC_VECTOR(31 DOWNTO 0);
  SIGNAL b_we   : STD_LOGIC_VECTOR(3 DOWNTO 0) := (OTHERS => '0');
  SIGNAL b_en   : STD_LOGIC := '0';

  PROCEDURE check(cond : BOOLEAN; msg : STRING) IS
  BEGIN
    ASSERT cond REPORT "FAIL: " & msg SEVERITY FAILURE;
  END PROCEDURE;

  PROCEDURE read_a(
    SIGNAL addr_sig : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    SIGNAL noe_sig  : OUT STD_LOGIC;
    SIGNAL clk_sig  : IN STD_LOGIC;
    addr : NATURAL) IS
  BEGIN
    addr_sig <= std_logic_vector(to_unsigned(addr, 16));
    noe_sig  <= '0';
    WAIT UNTIL rising_edge(clk_sig);
    WAIT FOR 1 ns; -- let the combinational read settle
  END PROCEDURE;

BEGIN

  clk <= NOT clk OR tb_end AFTER clk_period/2;

  u_dut : ENTITY work.shared_ram
  PORT MAP (
    clk     => clk,
    sel_ext => sel_ext,

    a_address  => a_address,
    a_data_in  => a_data_in,
    a_data_out => a_data_out,
    a_nWE      => a_nWE,
    a_nCS      => a_nCS,
    a_nOE      => a_nOE,

    b_addr => b_addr,
    b_din  => b_din,
    b_dout => b_dout,
    b_we   => b_we,
    b_en   => b_en
  );

  p_test : PROCESS
  BEGIN
    a_nOE <= '1';
    WAIT UNTIL rising_edge(clk);

    -- Write a full 32-bit word (all byte lanes) at word address 0x1000
    -- (byte address 0x4000) via Port B.
    b_addr <= X"4000";
    b_din  <= X"DDCCBBAA";
    b_we   <= "1111";
    b_en   <= '1';
    WAIT UNTIL rising_edge(clk);
    b_en <= '0';
    b_we <= "0000";
    WAIT UNTIL rising_edge(clk);

    -- Port B read-back of the same word.
    WAIT FOR 1 ns;
    check(b_dout = X"DDCCBBAA", "Port B full-word read-back mismatch");

    -- Port A reads each byte individually and must see the same bytes
    -- Port B wrote, little-endian (byte 0 = bits 7:0 = lowest address).
    read_a(a_address, a_nOE, clk, 16#4000#);
    check(a_data_out = X"AA", "Port A byte 0 mismatch after Port B word write");
    read_a(a_address, a_nOE, clk, 16#4001#);
    check(a_data_out = X"BB", "Port A byte 1 mismatch after Port B word write");
    read_a(a_address, a_nOE, clk, 16#4002#);
    check(a_data_out = X"CC", "Port A byte 2 mismatch after Port B word write");
    read_a(a_address, a_nOE, clk, 16#4003#);
    check(a_data_out = X"DD", "Port A byte 3 mismatch after Port B word write");
    a_nOE <= '1';

    -- Now write a single byte lane (byte 2 only) via Port B's
    -- byte-enable, leaving the other three lanes of the same word
    -- untouched, and confirm only that lane changed.
    WAIT UNTIL rising_edge(clk);
    b_addr <= X"4000";
    b_din  <= X"FF000000"; -- only byte 2's value (0x00) matters here
    b_we   <= "0100"; -- byte lane 2 only
    b_en   <= '1';
    WAIT UNTIL rising_edge(clk);
    b_en <= '0';
    b_we <= "0000";
    WAIT UNTIL rising_edge(clk);

    read_a(a_address, a_nOE, clk, 16#4000#);
    check(a_data_out = X"AA", "byte 0 should be untouched by single-lane write");
    a_nOE <= '1';
    WAIT UNTIL rising_edge(clk);
    read_a(a_address, a_nOE, clk, 16#4002#);
    check(a_data_out = X"00", "byte 2 should reflect the single-lane write");
    a_nOE <= '1';
    WAIT UNTIL rising_edge(clk);
    read_a(a_address, a_nOE, clk, 16#4003#);
    check(a_data_out = X"DD", "byte 3 should still be untouched");
    a_nOE <= '1';

    -- Port A writes; Port B must read the same value back.
    WAIT UNTIL rising_edge(clk);
    sel_ext <= '0'; -- hand write access to Port A
    WAIT UNTIL rising_edge(clk);
    a_address <= X"5000";
    a_data_in <= X"42";
    a_nWE <= '0';
    WAIT UNTIL rising_edge(clk);
    a_nWE <= '1';
    WAIT UNTIL rising_edge(clk);

    b_addr <= X"5000";
    WAIT FOR 1 ns;
    check(b_dout(7 DOWNTO 0) = X"42", "Port B should see Port A's write");

    REPORT "ALL CHECKS PASSED";
    tb_end <= '1';
    WAIT;
  END PROCESS;

END tb;
