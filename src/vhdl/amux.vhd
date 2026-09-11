-------------------------------------------------------------------------------
--
-- File Name: amux.vhd
-- Author: Leon Hiemstra
--
-- Title: Address multiplexer
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


ENTITY amux IS
  PORT (
    input   : IN  STD_LOGIC_VECTOR(15 DOWNTO 0);

    selA    : IN  STD_LOGIC;
    outputA : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);

    selD    : IN  STD_LOGIC_VECTOR(1 DOWNTO 0);
    outputD : OUT STD_LOGIC_VECTOR(7 DOWNTO 0)
  );
END amux;


ARCHITECTURE str OF amux IS

BEGIN

  -- Connection to Addressbus:
  -- selA is a plain 2-valued select, so this is already an exhaustive
  -- 2-way mux -- no default/'Z' branch needed.
  outputA <= input(7 DOWNTO 0) WHEN selA = '0' ELSE
             input(15 DOWNTO 8);

  -- Connection to Databus:
  -- outputD only matters to the caller when selD selects one of these
  -- two cases (see cdp1802.vhd's D_in mux); the default is a defined
  -- don't-care rather than a float.
  outputD <= input(7 DOWNTO 0) WHEN selD = "01" ELSE
             input(15 DOWNTO 8) WHEN selD = "10" ELSE
             (OTHERS => '0');

END str;
