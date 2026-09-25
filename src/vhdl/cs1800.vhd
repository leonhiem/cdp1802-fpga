-------------------------------------------------------------------------------
--
-- File Name: cs1800.vhd
-- Author: Leon Hiemstra
--
-- Title: CS1800 Microprocessor System
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


ENTITY cs1800 IS
  PORT (
    CLOCK    : IN    STD_LOGIC;

    LC       : IN    STD_LOGIC;
    Q       : OUT    STD_LOGIC;
    nEF      : IN    STD_LOGIC_VECTOR(2 DOWNTO 0);

    -- Real backplane INT line (active low), 2026-09-15: previously a
    -- hardcoded-inactive internal signal -- see BRINGUP_LOG.md's
    -- interrupt-wiring entry. Defaults to '1' (inactive) so every
    -- existing instantiation (cs1800_top.vhd, every testbench) keeps
    -- its exact prior behavior unless it's deliberately wired up, same
    -- convention as io_data_in_ext's default below. Only the LC/timer
    -- interrupt (cs1800_cpu.vhd's own nINT_tmp) already worked before
    -- this; this port adds a second, external source, ORed with it.
    nINT     : IN    STD_LOGIC := '1';

    reset : IN STD_LOGIC;
    halt  : IN STD_LOGIC;
    single : IN STD_LOGIC;
    run : IN STD_LOGIC;

    -- RAM is external (see boards/cora-z7-07s/dp_ram.vhd): dbg_ram_addr/
    -- dbg_data/dbg_nmrd/dbg_nmwr double as the real interface an
    -- external memory needs (address, write-data, strobes) as well as
    -- ILA debug visibility -- ram_data_out_ext feeds its read result
    -- back into the system bus merge below. dbg_sc/dbg_tpb are
    -- debug-only, no external memory needs them. No effect on cs1800's
    -- own functional behavior beyond the RAM itself moving outside it.
    dbg_ram_addr : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    dbg_data     : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    dbg_nmrd     : OUT STD_LOGIC;
    dbg_nmwr     : OUT STD_LOGIC;
    dbg_sc       : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    dbg_tpb      : OUT STD_LOGIC;
    ram_data_out_ext : IN STD_LOGIC_VECTOR(7 DOWNTO 0);

    -- IO is external too (see src/vhdl/cs1800_console.vhd and
    -- doc/CS1800_HARDWARE.md/doc/PRCX18_ANALYSIS.md): dbg_n exposes the
    -- device-select field an external IO decoder needs (Q is already an
    -- output above; TPB/nMRD/nMWR/the data bus are already exposed via
    -- the dbg_* ports above -- the same strobes serve both memory and
    -- IO on a real CDP1802). io_data_in_ext merges into the system bus
    -- the same way ram_data_out_ext does. Defaults to a no-op (all
    -- zeros OR'd in) so this doesn't require touching any existing
    -- instantiation.
    dbg_n        : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
    io_data_in_ext : IN STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');

    -- FPGA note (board-level use, see boards/cora-z7-07s/): dbg_tpa
    -- exposes the CDP1802's TPA pulse (already used internally above
    -- to latch the address's high byte) so an external memory can tell
    -- exactly when a new machine cycle -- and thus a new address --
    -- starts. mem_wait is a straight pass-through to cs1800_cpu's own
    -- mem_wait (see its header for what it does); defaults to '0'
    -- (never wait), so this doesn't affect any existing instantiation.
    dbg_tpa  : OUT STD_LOGIC;
    mem_wait : IN STD_LOGIC := '0';

    -- Exploratory debug taps, 2026-09-15 (see cs1800_cpu.vhd/
    -- cdp1802.vhd's own notes and boards/cora-z7-07s/BRINGUP_LOG.md's
    -- "milestone 3i") -- promoted straight through, no behavior change.
    dbg_tmp_page : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    dbg_R_in     : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    dbg_forceS1  : OUT STD_LOGIC;
    dbg_extraS1  : OUT STD_LOGIC;

    -- FPGA note, 2026-09-15 (see cdp1802.vhd's own note,
    -- boards/cora-z7-07s/BRINGUP_LOG.md's "milestone 3l"): the CPU's
    -- own internal, already-settled 16-bit address, one machine cycle
    -- ahead of ADDR/TPA's external, time-multiplexed reconstruction
    -- (ram_addr below) -- meant to drive a real synchronous (Block
    -- RAM) external memory directly, sidestepping the reconstruction's
    -- inherent "only valid part of each cycle" limitation entirely.
    -- Purely additive.
    A_full : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);

    -- Exploratory debug taps, 2026-09-15 (see reg_R.vhd's own note and
    -- BRINGUP_LOG.md's "milestone 3n") -- promoted straight through.
    dbg_R_A : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    dbg_R_B : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    dbg_R1  : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    dbg_D   : OUT STD_LOGIC_VECTOR(7 DOWNTO 0)
  );
END cs1800;


ARCHITECTURE str OF cs1800 IS

  SIGNAL  tpa  : STD_LOGIC;
  SIGNAL  tpb  : STD_LOGIC;
  SIGNAL  nmrd  : STD_LOGIC;
  SIGNAL  nmwr  : STD_LOGIC;

  SIGNAL n  : STD_LOGIC_VECTOR(2 DOWNTO 0);
  -- FPGA note: see cdp18.vhd -- 'data' is now an explicit OR-merge of
  -- drivers that are each '0' when not selected, instead of a
  -- tri-state-resolved net. No internal 'Z'.
  SIGNAL data  : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL cpu_data_out : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL cpu_data_oe  : STD_LOGIC; -- now also gates the data OR-merge below
  SIGNAL io_input_data : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL sc_i  : STD_LOGIC_VECTOR(1 DOWNTO 0);
  SIGNAL addr  : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL addr_high  : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL ram_addr  : STD_LOGIC_VECTOR(15 DOWNTO 0);

  SIGNAL n_io_out_sel : STD_LOGIC;
  SIGNAL n_io_in_sel : STD_LOGIC;
  SIGNAL io_output   : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL io_input_ptrn   : STD_LOGIC_VECTOR(7 DOWNTO 0) := "11000101"; -- something to put in

BEGIN


  u_cs1800_cpu : ENTITY work.cs1800_cpu
  PORT MAP (
    CLOCK    => CLOCK,
    LC    => LC,
    Q        => Q,
    nEF      => nEF,
    ADDR     => addr,
    DATA_IN  => data,
    DATA_OUT => cpu_data_out,
    DATA_OE  => cpu_data_oe,
    SC       => sc_i,
    N        => n,
    TPA      => tpa,
    TPB      => tpb,
    nMRD     => nmrd,
    nMWR     => nmwr,
    nINT     => nINT,
    reset => reset,
    halt => halt,
    single => single,
    run => run,
    mem_wait => mem_wait,
    dbg_tmp_page => dbg_tmp_page,
    dbg_R_in     => dbg_R_in,
    dbg_forceS1  => dbg_forceS1,
    dbg_extraS1  => dbg_extraS1,
    A_full       => A_full,
    dbg_R_A      => dbg_R_A,
    dbg_R_B      => dbg_R_B,
    dbg_R1       => dbg_R1,
    dbg_D        => dbg_D
  );

  -- The high address byte, latched at TPA the way a real memory card's
  -- 4042 does -- but clocked by CLOCK with TPA as an enable, not by TPA
  -- itself. TPA comes out of control.vhd's own register, so using it as
  -- a clock puts these flip-flops on a logic-generated net that no
  -- timing tool analyses (Vivado reported 8 register pins here "with no
  -- clock"). TPA is high for exactly one CLOCK period, so this samples
  -- the same address, one CLOCK later, in the constrained domain.
  p_reg_high_addr : PROCESS(CLOCK)
  BEGIN
    IF rising_edge(CLOCK) THEN
      IF tpa = '1' THEN
        addr_high <= addr;
      END IF;
    END IF;
  END PROCESS;

  ram_addr(7 DOWNTO 0) <= addr;
  ram_addr(15 DOWNTO 8) <= addr_high;

  n_io_out_sel <= '0' WHEN n = "101" ELSE '1';
  n_io_in_sel <= '0' WHEN (n = "101" AND nmrd = '1') ELSE '1';

  -- Same reasoning as p_reg_high_addr above: CLOCK with TPB as the
  -- enable, instead of TPB as the clock.
  u_io_out : ENTITY work.io_out
  PORT MAP (
    clk => CLOCK,
    ce  => tpb,
    data => data,
    output => io_output,
    nWE => nmrd,
    nCS => n_io_out_sel
  );

  u_io_inp : ENTITY work.io_inp
  PORT MAP (
    data => io_input_data,
    input => io_input_ptrn,
    nCS => n_io_in_sel
  );

  -- Real hardware-only bug found 2026-09-15 (see boards/cora-z7-07s/
  -- BRINGUP_LOG.md's "milestone 3g"/"3h"): this used to be a flat
  -- `cpu_data_out OR ram_data_out_ext OR io_input_data OR
  -- io_data_in_ext` -- correct in principle (each source's own module
  -- already zeros itself when not selected, so the OR should reduce to
  -- whichever one is actually driving), but on real hardware a stray
  -- bit from `cpu_data_out` (the CPU's own bus-drive path, correctly
  -- zero *most* of the time but not proven zero at the exact instant a
  -- real memory read is being sampled) corrupted a real-time memory
  -- read: a single bit leaked through the OR into an otherwise-correct
  -- byte. `cpu_data_out`/`io_input_data` both already have an explicit,
  -- always-available "am I actually driving" signal at this level
  -- (`cpu_data_oe`, `n_io_in_sel`) -- gating them out structurally
  -- (excluded entirely, not just relying on their own self-zeroing)
  -- removes that specific hazard instead of merely trusting it away.
  -- `ram_data_out_ext`/`io_data_in_ext` are left OR'd together: they're
  -- mutually exclusive by construction (nMRD-gated vs nMWR-gated reads
  -- can never both be active in the same machine cycle on a real 1802),
  -- and neither has its own "active" signal exposed at this level to
  -- gate on instead.
  data <= cpu_data_out WHEN cpu_data_oe = '1' ELSE
          io_input_data WHEN n_io_in_sel = '0' ELSE
          ram_data_out_ext OR io_data_in_ext;

  dbg_ram_addr <= ram_addr;
  dbg_data     <= data;
  dbg_nmrd     <= nmrd;
  dbg_nmwr     <= nmwr;
  dbg_sc       <= sc_i;
  dbg_tpb      <= tpb;
  dbg_n        <= n;
  dbg_tpa      <= tpa;

END str;
