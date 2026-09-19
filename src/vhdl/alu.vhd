-------------------------------------------------------------------------------
--
-- File Name: alu.vhd
-- Author: Leon Hiemstra
--
-- Title: Implementation of the CDP1802 ALU
--
-- License: MIT
--
-- Description: 
--
--
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.std_logic_1164.ALL;
USE IEEE.numeric_std.ALL;
USE work.cdp1802_pkg.ALL;


ENTITY alu IS
  PORT (
    oper    : IN  STD_LOGIC_vector(3 DOWNTO 0);
   
    alu_in  : IN    STD_LOGIC_VECTOR(7 DOWNTO 0);
    alu_out : OUT   STD_LOGIC_VECTOR(7 DOWNTO 0);

    d_in    : IN    STD_LOGIC_VECTOR(7 DOWNTO 0);
    d_out   : OUT   STD_LOGIC_VECTOR(7 DOWNTO 0);

    carry_out : OUT STD_LOGIC;
    carry_in  : IN  STD_LOGIC
  );
END alu;


ARCHITECTURE str OF alu IS

  SIGNAL tmp : STD_LOGIC_VECTOR(8 DOWNTO 0);

BEGIN

  p_alu : PROCESS(oper, alu_in, d_in, carry_in)
  BEGIN

    --d_out <= (OTHERS => 'Z');
	 d_out <= alu_in;

    CASE oper IS
      -- logic operations:
      WHEN c_ALU_OR =>
        tmp <= "0" & (d_in OR alu_in);
      WHEN c_ALU_XOR =>
        tmp <= "0" & (d_in XOR alu_in);
      WHEN c_ALU_AND =>
        tmp <= "0" & (d_in AND alu_in);
      WHEN c_ALU_SHR => -- >>
        tmp <= alu_in(0) & "0" & alu_in(7 DOWNTO 1);
      WHEN c_ALU_SHL => -- <<
        tmp <= alu_in & "0";
      -- Shift through carry (SHRC/SHLC): DF shifts in, the bit shifted out
      -- goes to DF. These used to rotate D's own bit back in, ignoring DF --
      -- which broke PRCX-18's interrupt handler (it saves DF with SHRC and
      -- restores it with SHLC), so every interrupted task resumed with DF=0.
      WHEN c_ALU_RSHR => -- >>
        tmp <= alu_in(0) & carry_in & alu_in(7 DOWNTO 1);
      WHEN c_ALU_RSHL => -- <<
        tmp <= alu_in & carry_in;

      -- arithmetic operations:
      WHEN c_ALU_U_ADD => -- unsigned addition
        tmp <= std_logic_vector(unsigned('0' & d_in) + unsigned('0' & alu_in));
      WHEN c_ALU_U_ADC => -- unsigned addition with carry
        tmp <= std_logic_vector(unsigned('0' & d_in) + unsigned('0' & alu_in) + unsigned'('0' & carry_in));

      WHEN c_ALU_S_SUB => -- signed subtract (2 complement)
        tmp <= std_logic_vector(unsigned('0' & d_in) + unsigned('0' & NOT(alu_in)) + unsigned'('0' & '1'));
      WHEN c_ALU_S_SUBB => -- signed subtract with borrow (2 complement)
        --tmp <= std_logic_vector(unsigned('0' & d_in) + unsigned('0' & NOT(alu_in)) + unsigned'('0' & NOT(carry_in)));
        tmp <= std_logic_vector(unsigned('0' & d_in) + unsigned('0' & NOT(alu_in)) + unsigned'('0' & carry_in));

      WHEN c_ALU_S_SUB_REV => -- signed subtract (2 complement) reverse
        tmp <= std_logic_vector(unsigned('0' & alu_in) + unsigned('0' & NOT(d_in)) + unsigned'('0' & '1'));
      WHEN c_ALU_S_SUBB_REV => -- signed subtract with borrow (2 complement) reverse
        --tmp <= std_logic_vector(unsigned('0' & d_in) + unsigned('0' & NOT(alu_in)) + unsigned'('0' & NOT(carry_in)));
        tmp <= std_logic_vector(unsigned('0' & alu_in) + unsigned('0' & NOT(d_in)) + unsigned'('0' & carry_in));

      WHEN OTHERS => -- c_ALU_NOP
        tmp <= "0" & d_in;
        --d_out <= alu_in;
    END CASE;

  END PROCESS;

  alu_out   <= tmp(7 DOWNTO 0);
  carry_out <= tmp(8);

END str;

        --tmp <= std_logic_vector(resize(signed(d_in), tmp'length) - resize(signed(alu_in), tmp'length)); -- can't use for the 1802
        --tmp <= std_logic_vector(resize(signed(d_in), tmp'length) - resize(signed(alu_in), tmp'length) - signed'('0' & NOT(carry_in)));
