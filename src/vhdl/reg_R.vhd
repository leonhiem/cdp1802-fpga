-------------------------------------------------------------------------------
--
-- File Name: reg_R.vhd
-- Author: Leon Hiemstra
--
-- Title: CDP1802 General purpose registerbank
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


ENTITY reg_R IS
  PORT (
    clk  : IN  STD_LOGIC;
    rst  : IN  STD_LOGIC;

    d_out : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    d_in  : IN  STD_LOGIC_VECTOR(15 DOWNTO 0);

    addr  : IN  STD_LOGIC_VECTOR(3 DOWNTO 0);
    mask  : IN  STD_LOGIC_VECTOR(1 DOWNTO 0);

    wr    : IN  STD_LOGIC;
    rd    : IN  STD_LOGIC := '1';

    -- Exploratory debug taps, 2026-09-15 (see boards/cora-z7-07s/
    -- BRINGUP_LOG.md's "milestone 3n"): R(A)/R(B) direct, live values
    -- -- unlike d_out above (which only ever shows whatever register
    -- the CPU's *own* current instruction happens to be addressing),
    -- these are unconditional taps into two fixed slots of the
    -- register file, to watch a specific register's real value across
    -- many machine cycles regardless of what else is being accessed.
    -- No real chip pin -- purely additive.
    dbg_R_A : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    dbg_R_B : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);

    -- Same idea, 2026-09-16 (see BRINGUP_LOG.md's "keystroke injection"
    -- entries): R(1) is the CDP1802's fixed interrupt-vector register
    -- (X<-2, P<-1 on interrupt, so the next fetch comes from R(1)) --
    -- watching it directly is the most unambiguous way to confirm
    -- whether the CPU genuinely took an interrupt and jumped through
    -- it, versus something else entirely.
    dbg_R1 : OUT STD_LOGIC_VECTOR(15 DOWNTO 0)
  );
END reg_R;


ARCHITECTURE str OF reg_R IS

type t_reg_arr is array (0 to 15) of std_logic_vector(15 downto 0);

TYPE t_reg IS RECORD
    reg : t_reg_arr;
END RECORD;

SIGNAL r, nxt_r : t_reg;

BEGIN

  p_regR_comb : PROCESS(rst, r, wr, addr, mask, d_in)
    VARIABLE v : t_reg;
    VARIABLE addr_natural : NATURAL RANGE 0 TO 15;
  BEGIN
      v   := r;
      addr_natural := to_integer(unsigned(addr));

      IF wr = '1' THEN
          IF mask = "01" THEN
              v.reg(addr_natural)(7 DOWNTO 0) := d_in(7 DOWNTO 0);
          ELSIF mask = "10" THEN
              v.reg(addr_natural)(15 DOWNTO 8) := d_in(15 DOWNTO 8);
          ELSIF mask = "11" THEN
              v.reg(addr_natural) := d_in;
          END IF;
      END IF;

      IF rst = '1' THEN
          v.reg(0) := (OTHERS => '0'); -- R(0) = "0000" starting point Program Counter
                                       -- The other registers will not reset
      END IF;

      nxt_r <= v; -- update

  END PROCESS;

  p_regR : PROCESS(clk)
  BEGIN
      IF rising_edge(clk) THEN
          r <= nxt_r;
      END IF;
  END PROCESS;



  -- FPGA note: 'rd' is never driven low in this design (no other driver
  -- ever shares d_out), so this stays a plain address-indexed mux rather
  -- than a tri-state -- no internal 'Z'.
  p_regR_rd : PROCESS(rd, addr, r)
      VARIABLE addr_natural : NATURAL RANGE 0 TO 15;
  BEGIN
      addr_natural := to_integer(unsigned(addr));
      IF rd = '1' THEN
          d_out <= r.reg(addr_natural);
      ELSE
          d_out <= (OTHERS => '0');
      END IF;
  END PROCESS;

  dbg_R_A <= r.reg(10);
  dbg_R_B <= r.reg(11);
  dbg_R1  <= r.reg(1);

END str;
