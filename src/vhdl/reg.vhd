-------------------------------------------------------------------------------
--
-- File Name: reg.vhd
-- Author: Leon Hiemstra
--
-- Title: Register implementation 
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


ENTITY reg IS
  GENERIC (
    g_width  : INTEGER := 16;
    g_preset : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0')
  );
  PORT (
    clk    : IN  STD_LOGIC;
    rst    : IN  STD_LOGIC := '0';
    preset : IN  STD_LOGIC := '0';

    wr    : IN  STD_LOGIC; 
    rd    : IN  STD_LOGIC := '1';

    d_in  : IN  STD_LOGIC_VECTOR(g_width-1 DOWNTO 0);
    d_out : OUT STD_LOGIC_VECTOR(g_width-1 DOWNTO 0)
  );
END reg;


ARCHITECTURE str OF reg IS

TYPE t_reg IS RECORD
    reg : STD_LOGIC_VECTOR(g_width-1 DOWNTO 0);
END RECORD;

SIGNAL r, nxt_r : t_reg;



BEGIN
  p_reg_comb : PROCESS(rst, r, wr, d_in, preset)
    VARIABLE v : t_reg;
  BEGIN
      v := r;

      IF wr = '1' THEN
          v.reg := d_in;
      END IF;

      IF preset = '1' THEN
          v.reg := g_preset(g_width-1 DOWNTO 0);
      END IF;

      IF rst = '1' THEN
          v.reg := (OTHERS => '0');
      END IF;

      nxt_r <= v; -- update

  END PROCESS;

  p_reg : PROCESS(clk)
  BEGIN
      IF rising_edge(clk) THEN
          r <= nxt_r;
      END IF;
  END PROCESS;

  -- connect
  -- FPGA note: 'rd' is never driven low anywhere this is instantiated
  -- (no other driver ever shares d_out), so this stays a plain
  -- single-driver mux rather than a tri-state -- no internal 'Z'.
  d_out <= r.reg WHEN rd = '1' ELSE (OTHERS => '0');

END str;
