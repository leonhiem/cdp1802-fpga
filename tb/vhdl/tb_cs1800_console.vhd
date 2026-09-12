-------------------------------------------------------------------------------
--
-- File Name: tb_cs1800_console.vhd
-- Author: Leon Hiemstra
--
-- Title: cs1800_console testbench -- IO device decode integration
--
-- License: MIT
--
-- Description:
--   Runs a small, synthetic, hand-assembled program (not real firmware --
--   see doc/PRCX18_ANALYSIS.md for why the real ROM can't live in this
--   public repo) through the real CDP1802 core to exercise the new IO
--   decode end to end, exactly the way real firmware does it:
--
--     SEQ                  ; Q:=1 -- required for the N=4 decode below
--     OUT 1, 0x00           ; select port A, Data register
--     OUT 4, 0x41 ('A')     ; -> should appear on uart_a_tx_data
--     OUT 1, 0x02           ; select port A, Status/Control register
--     OUT 4, 0x1B           ; control byte (8N1) -- latched, not observed here
--     OUT 1, 0x04           ; select port B, Data register
--     OUT 4, 0x42 ('B')     ; -> should appear on uart_b_tx_data
--     OUT 1, 0x02           ; select port A, Status register
--     SEX R2 (via R2=0x0050): so the following INP doesn't clobber the
--     INP 4                 ; read port A's status (exercises the read path)
--     SEX R0                ; restore X
--     BR self               ; infinite loop
--
--   This deliberately mirrors the address/register-select pattern found
--   in the real PRCX-18 ROM (OUT 1 before every OUT 4/INP 4 -- see
--   doc/PRCX18_ANALYSIS.md), including the SEX-to-a-scratch-register
--   trick before INP: an INP instruction stores its result at M(R(X)),
--   and X still equals P (0) at this point in a straight-line program,
--   so without redirecting X first, INP would silently overwrite the
--   very next instruction.
--
--   LC is tied low (no interrupts) -- this test is about IO/memory
--   decode, not interrupt timing, and the real CDP1802 reset leaves
--   IE='1' with R1 undefined, so an interrupt here would just add noise.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE work.test_program_pkg.ALL;
USE work.instr_pkg.ALL;


ENTITY tb_cs1800_console IS
END tb_cs1800_console;

ARCHITECTURE tb OF tb_cs1800_console IS

  CONSTANT clk_period : TIME := 250 ns; -- 4 MHz, matching tb_cs1800_dump.vhd
  CONSTANT c_rom_size : INTEGER := 64;

  CONSTANT c_rom_init : t_mem_array(0 TO c_rom_size - 1) := (
    0  => c_SEQ,
    1  => c_OUT_1, 2  => X"00",
    3  => c_OUT_4, 4  => X"41", -- 'A'
    5  => c_OUT_1, 6  => X"02",
    7  => c_OUT_4, 8  => X"1B", -- 8N1 control byte
    9  => c_OUT_1, 10 => X"04",
    11 => c_OUT_4, 12 => X"42", -- 'B'
    13 => c_OUT_1, 14 => X"02",
    15 => c_LDI,   16 => X"00",
    17 => c_PHI_2,
    18 => c_LDI,   19 => X"50",
    20 => c_PLO_2,
    21 => c_SEX_2,
    22 => c_INP_C, -- INP 4
    23 => c_SEX_0,
    24 => c_BR,    25 => X"18",
    OTHERS => X"00"
  );

  SIGNAL clk    : STD_LOGIC := '0';
  SIGNAL tb_end : STD_LOGIC := '0';
  SIGNAL reset  : STD_LOGIC := '1';
  SIGNAL halt   : STD_LOGIC := '0';
  SIGNAL single : STD_LOGIC := '0';
  SIGNAL run    : STD_LOGIC := '0';
  SIGNAL LC     : STD_LOGIC := '0';
  SIGNAL Q      : STD_LOGIC;
  SIGNAL nEF    : STD_LOGIC_VECTOR(2 DOWNTO 0) := "110";

  SIGNAL dbg_ram_addr : STD_LOGIC_VECTOR(15 DOWNTO 0);
  SIGNAL dbg_tpb      : STD_LOGIC;

  SIGNAL uart_a_tx_data  : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL uart_a_tx_valid : STD_LOGIC;
  SIGNAL uart_b_tx_data  : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL uart_b_tx_valid : STD_LOGIC;

  SIGNAL uart_a_captured : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL uart_a_got      : STD_LOGIC := '0';
  SIGNAL uart_b_captured : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL uart_b_got      : STD_LOGIC := '0';

  PROCEDURE check(cond : BOOLEAN; msg : STRING) IS
  BEGIN
    ASSERT cond REPORT "FAIL: " & msg SEVERITY FAILURE;
  END PROCEDURE;

BEGIN

  clk <= NOT clk OR tb_end AFTER clk_period/2;

  u_dut : ENTITY work.cs1800_console
  GENERIC MAP (
    rom_size => c_rom_size,
    rom_init => c_rom_init
  )
  PORT MAP (
    CLOCK => clk,
    LC    => LC,
    Q     => Q,
    nEF   => nEF,

    reset  => reset,
    halt   => halt,
    single => single,
    run    => run,

    dbg_ram_addr => dbg_ram_addr,
    dbg_tpb      => dbg_tpb,

    uart_a_tx_data  => uart_a_tx_data,
    uart_a_tx_valid => uart_a_tx_valid,
    uart_b_tx_data  => uart_b_tx_data,
    uart_b_tx_valid => uart_b_tx_valid
  );

  -- Latch the first byte transmitted on each port -- the real DUT clocks
  -- tx_data_valid off TPB, so a plain clocked capture on the system clock
  -- catches it exactly once per pulse.
  p_capture : PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      IF uart_a_tx_valid = '1' AND uart_a_got = '0' THEN
        uart_a_captured <= uart_a_tx_data;
        uart_a_got <= '1';
      END IF;
      IF uart_b_tx_valid = '1' AND uart_b_got = '0' THEN
        uart_b_captured <= uart_b_tx_data;
        uart_b_got <= '1';
      END IF;
    END IF;
  END PROCESS;

  p_test : PROCESS
  BEGIN
    reset <= '1';
    FOR I IN 0 TO 20 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    reset <= '0';
    run   <= '1';

    -- Run long enough for the whole program to complete and settle into
    -- its final BR-self loop (address 0x18): 16 instructions, each 2
    -- machine cycles of 8 CLOCK periods (standard CDP1802 timing) = 256
    -- CLOCK periods minimum, plus margin to land solidly inside the loop.
    FOR I IN 0 TO 400 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    check(uart_a_got = '1', "port A never saw a transmitted byte");
    check(uart_a_captured = X"41", "port A should have received 'A' (0x41)");
    check(uart_b_got = '1', "port B never saw a transmitted byte");
    check(uart_b_captured = X"42", "port B should have received 'B' (0x42)");

    -- ram_addr is only meaningful right at a TPB pulse (see
    -- sim/ghdl/README.md's dump-trace convention) -- sync to one before
    -- checking, rather than sampling at an arbitrary point mid-cycle.
    LOOP
      WAIT UNTIL rising_edge(clk);
      EXIT WHEN dbg_tpb = '1';
    END LOOP;
    -- BR-self alternates between the branch opcode's own address (0x18)
    -- and its target byte's address (0x19) every machine cycle, so
    -- either is valid evidence of having reached and stayed in the loop.
    check(dbg_ram_addr = X"0018" OR dbg_ram_addr = X"0019",
          "program should have settled into its final BR-self loop");

    REPORT "ALL CHECKS PASSED";
    tb_end <= '1';
    WAIT;
  END PROCESS;

END tb;
