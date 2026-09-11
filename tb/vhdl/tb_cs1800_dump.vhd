-------------------------------------------------------------------------------
--
-- File Name: tb_cs1800_dump.vhd
-- Author: Leon Hiemstra
--
-- Title: CS1800 GHDL reference-dump testbench
--
-- License: MIT
--
-- Description:
--   Runs the same stimulus as tb_cs1800.vhd and, on every TPB pulse,
--   writes {ram_addr, data, nMRD, nMWR, Q, SC} to a text file. This
--   is used to capture a golden reference trace of the current design
--   before it is ported to the FPGA repo.
--
--   VHDL-2008 external names are used to probe internal signals of
--   the DUT (ram_addr, data, nMRD, nMWR, TPB and, one level deeper,
--   the SC state code inside cs1800_cpu) so that cs1800.vhd and
--   cs1800_cpu.vhd do not need to be touched.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.std_logic_1164.ALL;
USE IEEE.numeric_std.ALL;
USE STD.TEXTIO.ALL;


ENTITY tb_cs1800_dump IS
END tb_cs1800_dump;

ARCHITECTURE tb OF tb_cs1800_dump IS

  CONSTANT clk_period   : TIME := 250 ns; -- 4 MHz

  SIGNAL clk    : STD_LOGIC := '0';
  SIGNAL tb_end : STD_LOGIC := '0';
  SIGNAL reset  : STD_LOGIC := '1';
  SIGNAL halt : STD_LOGIC := '0';
  SIGNAL single : STD_LOGIC := '0';
  SIGNAL run : STD_LOGIC := '0';
  SIGNAL LC      : STD_LOGIC := '0';
  SIGNAL Q      : STD_LOGIC;
  SIGNAL nEF    : STD_LOGIC_VECTOR(2 DOWNTO 0) := "110";

  -- cs1800's RAM is external (matching the real backplane: RAM lives on
  -- separate cards, not on the CPU card) -- wire up the same ram.vhd it
  -- used to instantiate internally.
  SIGNAL tb_ram_addr  : STD_LOGIC_VECTOR(15 DOWNTO 0);
  SIGNAL tb_ram_wdata : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL tb_ram_rdata : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL tb_ram_nmrd  : STD_LOGIC;
  SIGNAL tb_ram_nmwr  : STD_LOGIC;

BEGIN

  clk <= NOT clk OR tb_end AFTER clk_period/2;
  LC <= NOT LC OR tb_end AFTER clk_period*200;

  p_in_stimuli : PROCESS
  BEGIN

    -- RESET:
    reset <= '1';

    FOR I IN 0 TO 20 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    -- RUN:
    reset <= '0';
    run  <= '1';

    FOR I IN 0 TO 200 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    -- PAUSE:
    run <= '0';
    halt  <= '1';

    FOR I IN 0 TO 20 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    -- RUN:
    halt <= '0';
    run  <= '1';

    FOR I IN 0 TO 4000 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    tb_end <= '1';
    WAIT;
  END PROCESS;


  -- device under test
  u_dut : ENTITY work.cs1800
  PORT MAP (
    CLOCK    => clk,
    LC       => LC,
    Q        => Q,
    nEF      => nEF,

    reset => reset,
    halt  => halt,
    single => single,
    run => run,

    dbg_ram_addr => tb_ram_addr,
    dbg_data     => tb_ram_wdata,
    dbg_nmrd     => tb_ram_nmrd,
    dbg_nmwr     => tb_ram_nmwr,
    ram_data_out_ext => tb_ram_rdata
  );

  u_ram : ENTITY work.ram
  PORT MAP (
    clk      => clk,
    address  => tb_ram_addr,
    data_in  => tb_ram_wdata,
    data_out => tb_ram_rdata,
    nWE      => tb_ram_nmwr,
    nCS      => '0',
    nOE      => tb_ram_nmrd
  );

  -- Reference dump: one line per TPB pulse. The alias declarations below
  -- reach into the DUT via VHDL-2008 external names, so cs1800.vhd and
  -- cs1800_cpu.vhd do not need to be touched. They are placed in this block
  -- (after u_dut) since the external name path must already be elaborated.
  b_dump : BLOCK IS

    ALIAS dut_ram_addr IS
      << SIGNAL .tb_cs1800_dump.u_dut.ram_addr : STD_LOGIC_VECTOR(15 DOWNTO 0) >>;
    ALIAS data IS
      << SIGNAL .tb_cs1800_dump.u_dut.data : STD_LOGIC_VECTOR(7 DOWNTO 0) >>;
    ALIAS nmrd IS
      << SIGNAL .tb_cs1800_dump.u_dut.nmrd : STD_LOGIC >>;
    ALIAS nmwr IS
      << SIGNAL .tb_cs1800_dump.u_dut.nmwr : STD_LOGIC >>;
    ALIAS tpb IS
      << SIGNAL .tb_cs1800_dump.u_dut.tpb : STD_LOGIC >>;
    ALIAS SC IS
      << SIGNAL .tb_cs1800_dump.u_dut.u_cs1800_cpu.SC : STD_LOGIC_VECTOR(1 DOWNTO 0) >>;

  BEGIN

    p_dump : PROCESS
      FILE     f_out : TEXT OPEN WRITE_MODE IS "tb_cs1800_tpb.txt";
      VARIABLE l : LINE;
    BEGIN
      WRITE(l, STRING'("# time_ns ram_addr data nMRD nMWR Q SC"));
      WRITELINE(f_out, l);

      LOOP
        WAIT UNTIL rising_edge(clk);
        EXIT WHEN tb_end = '1';

        IF tpb = '1' THEN
          WRITE(l, NOW / 1 ns);
          WRITE(l, STRING'(" "));
          WRITE(l, to_hstring(dut_ram_addr));
          WRITE(l, STRING'(" "));
          WRITE(l, to_hstring(data));
          WRITE(l, STRING'(" "));
          WRITE(l, to_string(nmrd));
          WRITE(l, STRING'(" "));
          WRITE(l, to_string(nmwr));
          WRITE(l, STRING'(" "));
          WRITE(l, to_string(Q));
          WRITE(l, STRING'(" "));
          WRITE(l, to_string(SC));
          WRITELINE(f_out, l);
        END IF;
      END LOOP;

      WAIT;
    END PROCESS;

  END BLOCK b_dump;

END tb;
