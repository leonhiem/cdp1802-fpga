-------------------------------------------------------------------------------
--
-- File Name: tb_cdp18_dump.vhd
-- Author: Leon Hiemstra
--
-- Title: CDP18 GHDL reference-dump testbench
--
-- License: MIT
--
-- Description:
--   Runs the same stimulus as tb_cdp18.vhd and, on every TPB pulse,
--   writes {ram_addr, data, nMRD, nMWR, Q, SC} to a text file. This
--   is used to capture a golden reference trace of the current design
--   before it is ported to the FPGA repo.
--
--   VHDL-2008 external names are used to probe internal signals of
--   the DUT (ram_addr, data, nMRD, nMWR, TPB) so that cdp18.vhd and
--   cdp1802.vhd do not need to be touched.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.std_logic_1164.ALL;
USE IEEE.numeric_std.ALL;
USE STD.TEXTIO.ALL;


ENTITY tb_cdp18_dump IS
END tb_cdp18_dump;

ARCHITECTURE tb OF tb_cdp18_dump IS

  CONSTANT clk_period   : TIME := 250 ns; -- 4 MHz

  SIGNAL clk    : STD_LOGIC := '0';
  SIGNAL tb_end : STD_LOGIC := '0';
  SIGNAL nWAIT  : STD_LOGIC;
  SIGNAL nCLEAR : STD_LOGIC;
  SIGNAL Q      : STD_LOGIC;
  SIGNAL SC     : STD_LOGIC_VECTOR(1 DOWNTO 0);
  SIGNAL nEF    : STD_LOGIC_VECTOR(3 DOWNTO 0) := "1110";
  SIGNAL nINT   : STD_LOGIC := '1';
  SIGNAL nDMA_OUT : STD_LOGIC := '1';
  SIGNAL nDMA_IN  : STD_LOGIC := '1';
  SIGNAL io_output   : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL io_input_ptrn   : STD_LOGIC_VECTOR(7 DOWNTO 0) := "11000101"; -- something to put in
  SIGNAL dma_input_ptrn   : STD_LOGIC_VECTOR(7 DOWNTO 0) := "00001001"; -- something to put in

BEGIN

  clk <= NOT clk OR tb_end AFTER clk_period/2;

  p_in_stimuli : PROCESS
  BEGIN

    -- RESET:
    nCLEAR <= '0';
    nWAIT  <= '1';

    FOR I IN 0 TO 20 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    -- RUN:
    nCLEAR <= '1';
    nWAIT  <= '1';

    FOR I IN 0 TO 200 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    -- PAUSE:
    nCLEAR <= '1';
    nWAIT  <= '0';

    FOR I IN 0 TO 20 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    -- RUN:
    nCLEAR <= '1';
    nWAIT  <= '1';

    FOR I IN 0 TO 700 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    nINT <= '0';
    FOR I IN 0 TO 20 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;
    nINT <= '1';

    FOR I IN 0 TO 1000 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    nINT <= '0';
    FOR I IN 0 TO 20 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;
    nINT <= '1';

    FOR I IN 0 TO 800 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    nINT <= '0';
    FOR I IN 0 TO 20 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;
    nINT <= '1';

    FOR I IN 0 TO 1000 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;

    -- DMA out:
    nDMA_OUT  <= '0';
    FOR I IN 0 TO 1000 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;
    nDMA_OUT  <= '1';

    -- DMA in:
    nDMA_IN  <= '0';
    FOR I IN 0 TO 200 LOOP
      WAIT UNTIL rising_edge(clk);
    END LOOP;
    nDMA_IN  <= '1';

    tb_end <= '1';
    WAIT;
  END PROCESS;


  -- device under test
  u_dut : ENTITY work.cdp18
  PORT MAP (
    CLOCK    => clk,
    nWAIT    => nWAIT,
    nCLEAR   => nCLEAR,
    Q        => Q,
    SC       => SC,
    nEF      => nEF,
    nINT     => nINT,
    nDMA_OUT => nDMA_OUT,
    nDMA_IN  => nDMA_IN,
    io_output   => io_output,
    io_input_ptrn   => io_input_ptrn,
    dma_input_ptrn   => dma_input_ptrn
  );

  -- Reference dump: one line per TPB pulse. The alias declarations below
  -- reach into the DUT via VHDL-2008 external names, so cdp18.vhd and
  -- cdp1802.vhd do not need to be touched. They are placed in this block
  -- (after u_dut) since the external name path must already be elaborated.
  b_dump : BLOCK IS

    ALIAS ram_addr IS
      << SIGNAL .tb_cdp18_dump.u_dut.ram_addr : STD_LOGIC_VECTOR(15 DOWNTO 0) >>;
    ALIAS data IS
      << SIGNAL .tb_cdp18_dump.u_dut.data : STD_LOGIC_VECTOR(7 DOWNTO 0) >>;
    ALIAS nmrd IS
      << SIGNAL .tb_cdp18_dump.u_dut.nmrd : STD_LOGIC >>;
    ALIAS nmwr IS
      << SIGNAL .tb_cdp18_dump.u_dut.nmwr : STD_LOGIC >>;
    ALIAS tpb IS
      << SIGNAL .tb_cdp18_dump.u_dut.tpb : STD_LOGIC >>;

  BEGIN

    p_dump : PROCESS
      FILE     f_out : TEXT OPEN WRITE_MODE IS "tb_cdp18_tpb.txt";
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
          WRITE(l, to_hstring(ram_addr));
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
