-------------------------------------------------------------------------------
--
-- File Name: cs1800_prcx18_top.vhd
-- Author: Leon Hiemstra
--
-- Title: CS1800+PRCX-18 FPGA bring-up top-level (Cora Z7-07S)
--
-- License: MIT
--
-- Description:
--   The real-hardware counterpart to src/vhdl/cs1800_console.vhd (the
--   simulation-only top that already booted the real PRCX-18 ROM to
--   its login prompt -- see doc/PRCX18_ANALYSIS.md): wraps cs1800
--   (untouched) with cs1800_prcx18_memory.vhd (real 8KB ROM + a small
--   RAM, LUTRAM -- see its own header for why that split and size)
--   instead of shared_ram.vhd, plus one CDP1854 (cdp1854.vhd) on port A
--   (the real, confirmed console -- see doc/CS1800_HARDWARE.md) and its
--   OUT-1 port/register-select latch (cs1800_io_select.vhd). Port B's
--   UART isn't implemented here -- real firmware configures it
--   defensively at boot but doesn't require it to work.
--
--   Same async-read, single-port-arbitrated-write timing as
--   cs1800_top.vhd's shared_ram -- no wait-states, no cs1800/
--   cs1800_cpu.vhd mem_wait usage (an earlier real-Block-RAM attempt
--   needed that and hit a genuine, reproducible CPU-timing corruption
--   a few instructions in -- see cs1800_prcx18_memory.vhd's header;
--   this design sidesteps that entirely by keeping the exact same
--   timing every existing testbench already proves correct).
--
--   uart_tx_data/valid and uart_rx_data/available are meant for two
--   AXI GPIO channels, so Linux can read transmitted bytes and inject
--   received ones via devmem -- see boards/cora-z7-07s/README.md.
--
--   uart_tx_fifo_data/avail: cdp1854's raw tx_data_valid only pulses
--   for one machine cycle (one TPB, ~320ns at this design's real 25MHz
--   CLOCK -- confirmed empirically: 2000 back-to-back devmem polls of
--   the raw signal via AXI GPIO caught nothing but 0, exactly as
--   expected -- a Linux devmem round trip costs low-single-digit
--   milliseconds, ~4 orders of magnitude too slow). work.byte_fifo
--   (256 bytes -- infers Block RAM, not LUTRAM, so it doesn't compete
--   with cs1800_prcx18_memory's budget at all) latches every byte
--   cdp1854 transmits and holds it for software to drain at its own
--   pace: uart_tx_fifo_avail is a level
--   ('1' while the FIFO is non-empty), uart_tx_fifo_data is the head
--   byte, and ctrl_in(7) (unused otherwise -- see the entity's other
--   ctrl_in bits above) is edge-detected as a "pop" request. Purely
--   additive: uart_tx_data/valid keep their original raw-pulse meaning
--   unchanged, so tb_prcx18_lutram.vhd's/tb_cs1800_prcx18_top.vhd's use
--   of those two ports is completely unaffected by this.
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;


ENTITY cs1800_prcx18_top IS
  GENERIC (
    g_lc_half_period : POSITIVE := 1_000_000; -- CLOCK cycles per LC half-period
    g_ram_words      : INTEGER := 2048 -- 32-bit words of RAM above the 8KB ROM (2048 = 8KB, the real minimum config -- MUST be a power of two, see cs1800_prcx18_memory.vhd's header for why)
  );
  PORT (
    CLOCK      : IN  STD_LOGIC;

    ctrl_in    : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
    status_out : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);

    dbg_ram_addr : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    dbg_data     : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    dbg_nmrd     : OUT STD_LOGIC;
    dbg_nmwr     : OUT STD_LOGIC;
    dbg_sc       : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    dbg_tpb      : OUT STD_LOGIC;

    -- Exploratory debug taps, 2026-09-15 (see cs1800.vhd's own notes
    -- and BRINGUP_LOG.md's "milestone 3n") -- promoted straight
    -- through, no behavior change.
    dbg_tmp_page : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    dbg_R_in     : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    dbg_forceS1  : OUT STD_LOGIC;
    dbg_extraS1  : OUT STD_LOGIC;
    dbg_R_A      : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    dbg_R_B      : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);

    -- Added 2026-09-16 (see BRINGUP_LOG.md's "keystroke injection,
    -- third attempt"): Q and EF2 weren't visible to the ILA at all
    -- before (Q was purely an internal signal here; EF2 only existed
    -- as nEF_i(1), also internal) -- both needed to directly confirm
    -- whether an injected keystroke's DA condition ever reaches EF2
    -- (gated on Q, per the SIO board schematic) and whether the CPU
    -- actually takes the interrupt (see dbg_R1 below). No real chip
    -- pin beyond Q itself -- EF2 is a backplane signal but this taps
    -- it before the board-level inversion, same convention as nEF
    -- elsewhere in this codebase (asserted = '0').
    dbg_Q        : OUT STD_LOGIC;
    dbg_nEF2     : OUT STD_LOGIC;
    dbg_R1       : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);

    -- Direct cdp1854 control/status register visibility, 2026-09-16 --
    -- see cdp1854.vhd's own note: settles whether IE (bit 5 of
    -- dbg_uart_control) is actually set on real hardware, rather than
    -- continuing to infer it.
    dbg_uart_control : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    dbg_uart_status  : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);

    -- cs1800_prcx18_memory Port B: native BRAM-style port for axi_bram_ctrl.
    ram_b_addr : IN  STD_LOGIC_VECTOR(15 DOWNTO 0);
    ram_b_din  : IN  STD_LOGIC_VECTOR(31 DOWNTO 0);
    ram_b_dout : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    ram_b_we   : IN  STD_LOGIC_VECTOR(3 DOWNTO 0);
    ram_b_en   : IN  STD_LOGIC;

    -- CDP1854 port A, AXI-GPIO-facing. uart_rx_available is a plain
    -- level (not a pulse), same convention as ctrl_in's bits -- Linux
    -- sets it and clears it itself via devmem; no receive-side
    -- handshake logic here yet (deferred until interactive input is
    -- actually attempted -- tonight's goal is TX/the boot banner only).
    uart_tx_data      : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    uart_tx_valid     : OUT STD_LOGIC;
    uart_rx_data      : IN  STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    uart_rx_available : IN  STD_LOGIC := '0';

    -- Software-drainable TX byte FIFO -- see header comment above for why
    -- this exists alongside the raw uart_tx_data/valid pulse.
    uart_tx_fifo_data  : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    uart_tx_fifo_avail : OUT STD_LOGIC
  );
END cs1800_prcx18_top;


ARCHITECTURE str OF cs1800_prcx18_top IS

  SIGNAL lc     : STD_LOGIC := '0';
  SIGNAL lc_cnt : UNSIGNED(31 DOWNTO 0) := (OTHERS => '0');
  SIGNAL lc_run : STD_LOGIC; -- see p_lc_gen below
  SIGNAL Q      : STD_LOGIC;

  SIGNAL ram_addr  : STD_LOGIC_VECTOR(15 DOWNTO 0);
  SIGNAL ram_wdata : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL ram_rdata : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL ram_nmrd  : STD_LOGIC;
  SIGNAL ram_nmwr  : STD_LOGIC;
  -- cdp1802's own internal, already-settled 16-bit address -- what
  -- actually drives cs1800_prcx18_memory now (see its header and
  -- cs1800.vhd's A_full note). ram_addr above stays purely for
  -- dbg_ram_addr/ILA visibility, same as before.
  SIGNAL a_full_i  : STD_LOGIC_VECTOR(15 DOWNTO 0);

  SIGNAL n_i    : STD_LOGIC_VECTOR(2 DOWNTO 0);
  SIGNAL tpb_i  : STD_LOGIC;
  SIGNAL io_din_i : STD_LOGIC_VECTOR(7 DOWNTO 0);

  SIGNAL sel1_n : STD_LOGIC; -- N=1, active low
  SIGNAL sel4_n : STD_LOGIC; -- N=4 and Q='1', active low
  SIGNAL io_sel_reg : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL uart_a_nsel : STD_LOGIC;
  SIGNAL uart_a_dout : STD_LOGIC_VECTOR(7 DOWNTO 0);

  -- Raw cdp1854 TX pulse, before the FIFO -- see header comment. Fed
  -- straight out on uart_tx_data/valid (unchanged) AND into the FIFO
  -- push logic below.
  SIGNAL uart_a_tx_data_i  : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL uart_a_tx_valid_i : STD_LOGIC;

  -- Interrupt wiring, 2026-09-15 -- see BRINGUP_LOG.md's entry and the
  -- real SIO board schematic (3 NAND gates + 2 diodes, per the user's
  -- own description): gate 1 ORs both CDP1854 ports' INT onto the
  -- shared backplane nINT (port B not needed here -- see
  -- cs1800_console.vhd's identical note); gate 2 inverts that onto the
  -- shared bus; gate 3 pulls EF2 low only while Q is also high, letting
  -- firmware identify "am I the interrupt source" by setting Q=1 and
  -- polling EF2. nEF_i replaces the previous static ctrl_in-derived
  -- EF1/EF2/EF3 for EF2 specifically -- EF1/EF3 stay ctrl_in-controlled
  -- (still useful for manual testing via devmem).
  SIGNAL uart_a_nint_i : STD_LOGIC;
  SIGNAL nEF_i         : STD_LOGIC_VECTOR(2 DOWNTO 0);

  -- Software-drainable TX FIFO: work.byte_fifo (256 bytes, registered
  -- head/avail -- see its own header for why: an earlier hand-rolled
  -- copy of this same FIFO, right here, had a combinational head
  -- output that a real hardware bug traced back to -- see
  -- BRINGUP_LOG.md's "isolating cdp1854+UART" entry). ctrl_in(7)
  -- (otherwise-unused) is edge-detected into a one-cycle pop pulse.
  SIGNAL tx_fifo_pop      : STD_LOGIC := '0';
  SIGNAL tx_fifo_pop_prev : STD_LOGIC := '0';
  -- Edge-detected push pulse -- see p_tx_fifo_push below (milestone 3n).
  SIGNAL tx_fifo_push      : STD_LOGIC := '0';
  SIGNAL tx_fifo_push_prev : STD_LOGIC := '0';

BEGIN

  -- Free-running LC divider: see cs1800_top.vhd, unchanged idiom.
  -- ctrl_in(5) freeze added 2026-09-16 (see BRINGUP_LOG.md's "keystroke
  -- injection, third attempt" -- the user's own suggestion): the
  -- pre-existing LC/50Hz timer interrupt fires every 10-20ms,
  -- swamping any attempt to isolate a UART-receive-driven interrupt on
  -- the ILA. ctrl_in(5) was already unused for its own logic here
  -- (EF2 is computed live now, not from ctrl_in(5) -- see nEF_i(1)
  -- below), so it's repurposed as an LC-freeze bit. Polarity chosen so
  -- the existing "0x68" convention used throughout this project's
  -- tooling (ctrl_in(5)='1') is UNCHANGED -- LC free-runs normally
  -- unless a test deliberately clears bit 5 (e.g. ctrl_in=0x48).
  p_lc_gen : PROCESS(CLOCK)
  BEGIN
    IF rising_edge(CLOCK) THEN
      IF lc_run = '1' THEN
        IF lc_cnt = to_unsigned(g_lc_half_period - 1, lc_cnt'length) THEN
          lc_cnt <= (OTHERS => '0');
          lc     <= NOT lc;
        ELSE
          lc_cnt <= lc_cnt + 1;
        END IF;
      END IF;
    END IF;
  END PROCESS;
  lc_run <= ctrl_in(5); -- '1' = normal (matches existing "0x68"), '0' = freeze LC for debug

  sel1_n <= '0' WHEN n_i = "001" ELSE '1';
  sel4_n <= '0' WHEN (n_i = "100" AND Q = '1') ELSE '1';
  uart_a_nsel <= '0' WHEN (sel4_n = '0' AND io_sel_reg(2) = '0') ELSE '1';
  io_din_i <= uart_a_dout;

  -- ctrl_in(6 DOWNTO 4) is EF3/EF2/EF1 (bit 6=EF3, 5=EF2, 4=EF1) -- see
  -- cs1800.vhd's nEF(2 DOWNTO 0)=EF3/EF2/EF1 convention. EF2 (index 1)
  -- is now live -- see uart_a_nint_i/nEF_i comment above.
  nEF_i(0) <= ctrl_in(4); -- EF1, still manual
  nEF_i(2) <= ctrl_in(6); -- EF3, still manual
  nEF_i(1) <= '0' WHEN (uart_a_nint_i = '0' AND Q = '1') ELSE '1'; -- EF2, live

  u_cs1800 : ENTITY work.cs1800
  PORT MAP (
    CLOCK  => CLOCK,
    LC     => lc,
    Q      => Q,
    nEF    => nEF_i,
    nINT   => uart_a_nint_i,
    reset  => ctrl_in(0),
    halt   => ctrl_in(1),
    single => ctrl_in(2),
    run    => ctrl_in(3),

    dbg_ram_addr => ram_addr,
    dbg_data     => ram_wdata,
    dbg_nmrd     => ram_nmrd,
    dbg_nmwr     => ram_nmwr,
    dbg_sc       => dbg_sc,
    dbg_tpb      => tpb_i,
    dbg_n        => n_i,
    dbg_tmp_page => dbg_tmp_page,
    dbg_R_in     => dbg_R_in,
    dbg_forceS1  => dbg_forceS1,
    dbg_extraS1  => dbg_extraS1,
    dbg_R_A      => dbg_R_A,
    dbg_R_B      => dbg_R_B,
    dbg_R1       => dbg_R1,
    ram_data_out_ext => ram_rdata,
    io_data_in_ext   => io_din_i,
    A_full           => a_full_i
    -- dbg_tpa/mem_wait left unconnected (default '0') -- not used here.
  );

  dbg_Q    <= Q;
  dbg_nEF2 <= nEF_i(1);

  dbg_ram_addr <= ram_addr;
  dbg_data     <= ram_wdata;
  dbg_nmrd     <= ram_nmrd;
  dbg_nmwr     <= ram_nmwr;
  dbg_tpb      <= tpb_i;

  u_ram : ENTITY work.cs1800_prcx18_memory
  GENERIC MAP (
    g_ram_words => g_ram_words
  )
  PORT MAP (
    clk     => CLOCK,
    sel_ext => ctrl_in(0), -- '1' while reset is asserted

    a_address  => a_full_i,
    a_data_in  => ram_wdata,
    a_data_out => ram_rdata,
    a_nWE      => ram_nmwr,
    a_nCS      => '0',
    a_nOE      => ram_nmrd,

    b_addr => ram_b_addr,
    b_din  => ram_b_din,
    b_dout => ram_b_dout,
    b_we   => ram_b_we,
    b_en   => ram_b_en
  );

  -- FPGA/1802 note: OUT asserts nMRD, INP asserts nMWR on this CPU --
  -- see cs1800_console.vhd's header for why (confirmed against
  -- instr.vhd, matches cs1800.vhd's own pre-existing io_out.vhd wiring).
  u_io_select : ENTITY work.cs1800_io_select
  PORT MAP (
    clk     => tpb_i,
    data_in => ram_wdata,
    nCS     => sel1_n,
    nWE     => ram_nmrd,
    sel_out => io_sel_reg
  );

  u_uart_a : ENTITY work.cdp1854
  PORT MAP (
    clk      => tpb_i,
    data_in  => ram_wdata,
    data_out => uart_a_dout,
    nCS  => uart_a_nsel,
    rsel => io_sel_reg(1),
    nWE  => ram_nmrd,
    nOE  => ram_nmwr,
    rx_data           => uart_rx_data,
    rx_data_available => uart_rx_available,
    tx_data       => uart_a_tx_data_i,
    tx_data_valid => uart_a_tx_valid_i,
    nINT          => uart_a_nint_i,
    dbg_control_reg => dbg_uart_control,
    dbg_status_reg  => dbg_uart_status
  );

  -- Raw pass-through, unchanged meaning -- see header comment.
  uart_tx_data  <= uart_a_tx_data_i;
  uart_tx_valid <= uart_a_tx_valid_i;

  -- Edge-detect ctrl_in(7) into a one-cycle pop pulse for byte_fifo.
  p_tx_fifo_pop : PROCESS(CLOCK)
  BEGIN
    IF rising_edge(CLOCK) THEN
      tx_fifo_pop_prev <= ctrl_in(7);
      tx_fifo_pop      <= ctrl_in(7) AND NOT tx_fifo_pop_prev;
    END IF;
  END PROCESS;

  -- Edge-detect uart_a_tx_valid_i into a one-CLOCK-cycle push pulse,
  -- 2026-09-15 (see boards/cora-z7-07s/BRINGUP_LOG.md's "milestone
  -- 3n") -- real hardware-only bug found via the real PRCX-18 boot
  -- banner arriving with every byte duplicated 8 times: cdp1854 is
  -- clocked by tpb_i (one edge per whole CDP1802 machine cycle, ~8
  -- real CLOCK cycles -- see u_uart_a below), so its tx_data_valid
  -- output is a registered signal that naturally stays asserted for
  -- that entire machine cycle, not a single-CLOCK-wide pulse.
  -- byte_fifo (clocked by the fast, free-running CLOCK, not tpb_i)
  -- samples `push` on every one of those ~8 fast edges and pushes
  -- push_data every single time it's still high -- the exact same
  -- "held level sampled by a faster clock" hazard `p_tx_fifo_pop`
  -- above already exists to avoid on the pop side, just never applied
  -- to push. Simulation never caught this because
  -- tb_prcx18_lutram.vhd's own UART capture watches the *raw*
  -- uart_tx_data/valid ports with its own external edge-detection
  -- (see that file's own header), bypassing this FIFO entirely; the
  -- earlier standalone `cdp1854_uart_test_top`/`dummy_cpu_driver` test
  -- that did prove byte_fifo correct on real hardware happened to
  -- pulse push for only one real CLOCK cycle, not a full CDP1802
  -- machine cycle, so it never exercised this exact case either.
  p_tx_fifo_push : PROCESS(CLOCK)
  BEGIN
    IF rising_edge(CLOCK) THEN
      tx_fifo_push_prev <= uart_a_tx_valid_i;
      tx_fifo_push      <= uart_a_tx_valid_i AND NOT tx_fifo_push_prev;
    END IF;
  END PROCESS;

  u_tx_fifo : ENTITY work.byte_fifo
  GENERIC MAP ( g_depth_bits => 8 )
  PORT MAP (
    clk       => CLOCK,
    push      => tx_fifo_push,
    push_data => uart_a_tx_data_i,
    pop       => tx_fifo_pop,
    head      => uart_tx_fifo_data,
    avail     => uart_tx_fifo_avail
  );

  status_out <= "000000" & lc & Q;

END str;
