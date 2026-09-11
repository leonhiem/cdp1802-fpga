-------------------------------------------------------------------------------
--
-- File Name: ff.vhd
-- Author: Leon Hiemstra
--
-- Title: flipflop
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


ENTITY ff IS
  GENERIC (
    g_init   : STD_LOGIC := '0';
    g_preset : STD_LOGIC := '0' 
  );
  PORT (
    clk    : IN  STD_LOGIC;
    rst    : IN  STD_LOGIC := '0';
    preset : IN  STD_LOGIC := '0';

    wr     : IN  STD_LOGIC; 
    rd     : IN  STD_LOGIC := '1';

    d      : IN  STD_LOGIC;
    q      : OUT STD_LOGIC
  );
END ff;


ARCHITECTURE str OF ff IS

TYPE t_reg IS RECORD
    ff : STD_LOGIC;
END RECORD;

SIGNAL r, nxt_r : t_reg;



BEGIN
  p_ff_comb : PROCESS(rst, r, wr, d, preset)
    VARIABLE v : t_reg;
  BEGIN
      v := r;

      IF wr = '1' THEN
          v.ff := d;
      END IF;

      IF preset = '1' THEN
          v.ff := g_preset;
      END IF;

      IF rst = '1' THEN
          v.ff := g_init;
      END IF;

      nxt_r <= v; -- update

  END PROCESS;

  p_ff : PROCESS(clk)
  BEGIN
      IF rising_edge(clk) THEN
          r <= nxt_r;
      END IF;
  END PROCESS;

  -- connect
  -- FPGA note: 'rd' is never driven low anywhere this is instantiated
  -- (no other driver ever shares q), so this stays a plain
  -- single-driver mux rather than a tri-state -- no internal 'Z'.
  q <= r.ff WHEN rd = '1' ELSE '0';

END str;
