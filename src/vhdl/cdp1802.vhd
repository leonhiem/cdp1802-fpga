-------------------------------------------------------------------------------
--
-- File Name: cdp1802.vhd
-- Author: Leon Hiemstra
--
-- Title: Top Level of CDP1802 Microprocessor
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


ENTITY cdp1802 IS
  PORT (
    CLOCK    : IN    STD_LOGIC;
    nWAIT    : IN    STD_LOGIC;
    nCLEAR   : IN    STD_LOGIC;
    Q        : OUT   STD_LOGIC;
    SC       : OUT   STD_LOGIC_VECTOR(1 DOWNTO 0);
    nMRD     : OUT   STD_LOGIC;
    -- FPGA note: split from a single INOUT 'DATA' pin into an explicit
    -- in/out/output-enable triplet -- no internal 'Z'. This is purely
    -- internal wiring in cdp18.vhd/cs1800.vhd (never a real chip pin
    -- there), so the parent does the actual bus merge.
    DATA_IN  : IN    STD_LOGIC_VECTOR(7 DOWNTO 0);
    DATA_OUT : OUT   STD_LOGIC_VECTOR(7 DOWNTO 0);
    DATA_OE  : OUT   STD_LOGIC;
    N        : OUT   STD_LOGIC_VECTOR(2 DOWNTO 0);
    nEF      : IN    STD_LOGIC_VECTOR(3 DOWNTO 0);
    ADDR     : OUT   STD_LOGIC_VECTOR(7 DOWNTO 0);
    -- FPGA note, 2026-09-15 (see boards/cora-z7-07s/BRINGUP_LOG.md's
    -- "milestone 3l" and doc/CDP1802_MEMORY_TIMING.md): ADDR's 8-bit,
    -- time-multiplexed shape (high byte, then low byte, latched by an
    -- external TPA-triggered register -- real 4042s on the actual
    -- memory board) exists purely because the real 40-pin chip only
    -- has 8 address pins. A_full is the same address the CPU already
    -- holds internally, whole and already-clocked (register A, `p_reg_A`
    -- below), one machine cycle before ADDR/TPA ever multiplex it onto
    -- a narrow bus at all -- there is no reason a fully-integrated FPGA
    -- memory needs to reconstruct that 16 bits back out of ADDR the way
    -- external hardware must; it can just use this instead. Purely
    -- additive: ADDR/TPA/every existing instantiation are completely
    -- unaffected.
    A_full   : OUT   STD_LOGIC_VECTOR(15 DOWNTO 0);
    TPA      : OUT   STD_LOGIC;
    TPB      : OUT   STD_LOGIC;
    nMWR     : OUT   STD_LOGIC;
    nINT     : IN    STD_LOGIC;
    nDMA_OUT : IN    STD_LOGIC;
    nDMA_IN  : IN    STD_LOGIC;

    -- Exploratory debug taps, 2026-09-15 (see boards/cora-z7-07s/
    -- BRINGUP_LOG.md's "milestone 3i"): none of these have a real chip
    -- pin -- tmp_page/R_in/forceS1/extraS1 are purely FPGA-internal to
    -- this multi-cycle state machine, unlike every other port above.
    -- Added to chase a real-hardware-only LBR bug via an ILA capture.
    dbg_tmp_page : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    dbg_R_in     : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    dbg_forceS1  : OUT STD_LOGIC;
    dbg_extraS1  : OUT STD_LOGIC
  );
END cdp1802;


ARCHITECTURE str OF cdp1802 IS

  SIGNAL rst       : STD_LOGIC;
  SIGNAL addr_lohi : STD_LOGIC;
  SIGNAL A_sel_lohi : STD_LOGIC_VECTOR(1 DOWNTO 0);

  SIGNAL float_DATA : STD_LOGIC;
  SIGNAL float_T    : STD_LOGIC;
  SIGNAL reset_DATA : STD_LOGIC;

  SIGNAL preset_IE : STD_LOGIC;
  SIGNAL IE_out    : STD_LOGIC;

  SIGNAL wr_T0     : STD_LOGIC;
  SIGNAL wr_T1     : STD_LOGIC;
  SIGNAL wr_T      : STD_LOGIC;
  SIGNAL T_in      : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL T_out     : STD_LOGIC_VECTOR(7 DOWNTO 0);


  SIGNAL wr_P      : STD_LOGIC;
  SIGNAL preset_P  : STD_LOGIC;
  SIGNAL P_in      : STD_LOGIC_VECTOR(3 DOWNTO 0);
  SIGNAL P_out     : STD_LOGIC_VECTOR(3 DOWNTO 0);

  SIGNAL XtoR      : STD_LOGIC;
  SIGNAL wr_X      : STD_LOGIC;
  SIGNAL preset_X  : STD_LOGIC;
  SIGNAL X_in      : STD_LOGIC_VECTOR(3 DOWNTO 0);
  SIGNAL X_out     : STD_LOGIC_VECTOR(3 DOWNTO 0);

  SIGNAL StoR      : STD_LOGIC;
  SIGNAL NtoR      : STD_LOGIC;
  SIGNAL DtoR      : STD_LOGIC;
  SIGNAL wr_N      : STD_LOGIC;
  SIGNAL N_in      : STD_LOGIC_VECTOR(3 DOWNTO 0);
  SIGNAL N_out     : STD_LOGIC_VECTOR(3 DOWNTO 0);

  SIGNAL wr_I      : STD_LOGIC;
  SIGNAL I_in      : STD_LOGIC_VECTOR(3 DOWNTO 0);
  SIGNAL I_out     : STD_LOGIC_VECTOR(3 DOWNTO 0);

  SIGNAL wr_D      : STD_LOGIC;
  SIGNAL rd_D      : STD_LOGIC;
  SIGNAL D_in      : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL D_in_amux : STD_LOGIC_VECTOR(7 DOWNTO 0); -- D_in candidate: A-register byte
  SIGNAL D_in_dmux : STD_LOGIC_VECTOR(7 DOWNTO 0); -- D_in candidate: external bus (DATA_IN)
  SIGNAL D_out     : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL alu_in    : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL alu_out   : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL alu_oper  : STD_LOGIC_VECTOR(3 DOWNTO 0);
  SIGNAL carry     : STD_LOGIC;
  SIGNAL wr_DF     : STD_LOGIC;
  SIGNAL DF_out    : STD_LOGIC;

  SIGNAL wr_R      : STD_LOGIC;
  SIGNAL addr_R    : STD_LOGIC_VECTOR(3 DOWNTO 0);
  SIGNAL mask_R    : STD_LOGIC_VECTOR(1 DOWNTO 0);
  SIGNAL R_in      : STD_LOGIC_VECTOR(15 DOWNTO 0);
  SIGNAL R_out     : STD_LOGIC_VECTOR(15 DOWNTO 0);

  SIGNAL wr_A      : STD_LOGIC;
  SIGNAL A_out     : STD_LOGIC_VECTOR(15 DOWNTO 0);

  SIGNAL wr_Q      : STD_LOGIC;
  SIGNAL Q_in      : STD_LOGIC;
  SIGNAL Q_out     : STD_LOGIC;

  SIGNAL wr_IE     : STD_LOGIC;
  SIGNAL IE_in     : STD_LOGIC;

  SIGNAL DMA_IN    : STD_LOGIC;
  SIGNAL DMA_OUT   : STD_LOGIC;
  SIGNAL INT       : STD_LOGIC;
  SIGNAL Go_Idle   : STD_LOGIC;
  SIGNAL Do_MRD    : STD_LOGIC;
  SIGNAL Do_MWR    : STD_LOGIC;

  SIGNAL state     : STD_LOGIC_VECTOR(3 DOWNTO 0);
  SIGNAL clk_cnt   : STD_LOGIC_VECTOR(2 DOWNTO 0);
  SIGNAL forceS1   : STD_LOGIC;
  SIGNAL extraS1   : STD_LOGIC;

BEGIN

  DMA_IN  <= NOT nDMA_IN;
  DMA_OUT <= NOT nDMA_OUT;
  INT     <= NOT nINT;

  u_control : ENTITY work.control
  PORT MAP (
    clk       => CLOCK,
    nwait     => nWAIT,
    nclear    => nCLEAR,
    dma_in    => DMA_IN,
    dma_out   => DMA_OUT,
    interrupt => INT,
    rst       => rst,
    sc        => SC,
    tpa       => TPA,
    tpb       => TPB,
    nMRD      => nMRD,
    nMWR      => nMWR,
    addr_lohi => addr_lohi,
    ie        => IE_out,
    wr_T      => wr_T0,
    preset_P  => preset_P,
    preset_X  => preset_X,
    preset_IE => preset_IE,
    reset_DATA => reset_DATA,
    state      => state,
    clk_cnt_out => clk_cnt,
    Go_Idle    => Go_Idle,
    Do_MRD     => Do_MRD,
    Do_MWR     => Do_MWR,
    forceS1    => forceS1,
    extraS1    => extraS1
  );

  u_instr : ENTITY work.instr
  PORT MAP (
    clk       => CLOCK,
    state     => state,
    clk_cnt   => clk_cnt,
    NtoR      => NtoR,
    XtoR      => XtoR,
    StoR      => StoR,
    DtoR      => DtoR,
    wr_A      => wr_A,
    A_out     => A_out,
    wr_I      => wr_I,
    wr_N      => wr_N,
    mask_R    => mask_R,
    N_out     => N_out,
    P_out     => P_out,
    I_out     => I_out,
    Go_Idle   => Go_Idle,
    Do_MRD    => Do_MRD,
    Do_MWR    => Do_MWR,
    Q_in      => Q_in,
    Q_out     => Q_out,
    IE_out    => IE_out,
    IE_in     => IE_in,
    wr_IE     => wr_IE,
    wr_Q      => wr_Q,
    float_DATA => float_DATA,
    float_T    => float_T,
    A_sel_lohi => A_sel_lohi,
    D_out     => D_out,
    D_in      => D_in,
    DF_out    => DF_out,
    alu_oper  => alu_oper,
    wr_D      => wr_D,
    rd_D      => rd_D,
    wr_DF     => wr_DF,
    X_in      => X_in,
    wr_X      => wr_X,
    P_in      => P_in,
    wr_P      => wr_P,
    wr_R      => wr_R,
    R_in      => R_in,
    nEF       => nEF,
    forceS1   => forceS1,
    extraS1   => extraS1,
    T_out     => T_out,
    wr_T      => wr_T1,
    N_addr_out => N,
    dma_in    => DMA_IN,
    dma_out   => DMA_OUT,
    dbg_tmp_page => dbg_tmp_page
  );

  dbg_R_in    <= R_in;
  dbg_forceS1 <= forceS1;
  dbg_extraS1 <= extraS1;
  A_full      <= A_out;

  u_Q : ENTITY work.ff
  PORT MAP (
    clk => CLOCK,
    rst => rst,
    wr  => wr_Q,
    d   => Q_in,
    q   => Q_out
  );
  Q <= Q_out;

  u_IE : ENTITY work.ff
  GENERIC MAP (
    g_init   => '1',
    g_preset => '0'
  )
  PORT MAP (
    clk    => CLOCK,
    rst    => rst,
    preset => preset_IE,
    wr     => wr_IE,
    d      => IE_in,
    q      => IE_out
  );


  T_in(3 DOWNTO 0) <= P_out;
  T_in(7 DOWNTO 4) <= X_out;
  addr_R <= X_out WHEN XtoR = '1' ELSE N_out WHEN NtoR = '1' ELSE "0010" WHEN StoR = '1' ELSE "0000" WHEN DtoR = '1' ELSE P_out;

  wr_T <= '1' WHEN (wr_T0 = '1' OR wr_T1 = '1') ELSE '0';

  u_reg_T : ENTITY work.reg
  GENERIC MAP (
    g_width => 8
  )
  PORT MAP (
    clk => CLOCK,
    -- no reset

    d_out => T_out,
    d_in  => T_in,

    wr    => wr_T
  );


  u_reg_P : ENTITY work.reg
  GENERIC MAP (
    g_width => 4,
    g_preset => "XXXXXXXXXXXX0001" -- Set at interrupt
  )
  PORT MAP (
    clk => CLOCK,
    rst => rst,
    preset => preset_P,

    d_out => P_out,
    d_in  => P_in,

    wr    => wr_P
  );


  u_reg_X : ENTITY work.reg
  GENERIC MAP (
    g_width => 4,
    g_preset => "XXXXXXXXXXXX0010" -- Set at interrupt
  )
  PORT MAP (
    clk => CLOCK,
    rst => rst,
    preset => preset_X,

    d_out => X_out,
    d_in  => X_in,

    wr    => wr_X
  );


  u_reg_N : ENTITY work.reg
  GENERIC MAP (
    g_width => 4
  )
  PORT MAP (
    clk => CLOCK,
    rst => rst,

    d_out => N_out,
    d_in  => N_in,

    wr    => wr_N
  );
  N_in <= D_in(3 DOWNTO 0);



  u_reg_I : ENTITY work.reg
  GENERIC MAP (
    g_width => 4
  )
  PORT MAP (
    clk => CLOCK,
    rst => rst,

    d_out => I_out,
    d_in  => I_in,

    wr    => wr_I
  );
  I_in <= D_in(7 DOWNTO 4);


  u_reg_D : ENTITY work.reg
  GENERIC MAP (
    g_width => 8
  )
  PORT MAP (
    clk => CLOCK,
    -- no reset

    d_out => alu_in,
    d_in  => alu_out,

    wr    => wr_D,
    rd    => rd_D
  );

  u_DF : ENTITY work.ff
  PORT MAP (
    clk => CLOCK,
    rst => rst,
    wr  => wr_DF,
    d   => carry,
    q   => DF_out
  );

  u_reg_R : ENTITY work.reg_R
  PORT MAP (
    clk => CLOCK,
    rst => rst,

    d_out => R_out,
    d_in  => R_in,

    addr  => addr_R,
    mask  => mask_R,

    wr    => wr_R
  );

  p_reg_A : PROCESS(CLOCK, rst, R_out, wr_A)
  BEGIN
    IF falling_edge(CLOCK) THEN
      IF rst = '1' THEN
        A_out <= (OTHERS => '0');
      END IF;

      IF wr_A = '1' THEN
        A_out <= R_out;
      END IF;
    END IF;
  END PROCESS;


  u_amux_A : ENTITY work.amux
  PORT MAP (
    input   => A_out,
    selA    => addr_lohi,
    outputA => ADDR,
    selD    => A_sel_lohi,
    outputD => D_in_amux
  );

  u_dmux_D : ENTITY work.dmux
  PORT MAP (
    float0   => float_DATA,
    float1   => float_T,
    rst      => reset_DATA,
    d_src0   => D_out,
    d_src1   => T_out,
    d_snk    => D_in_dmux,
    data_in  => DATA_IN,
    data_out => DATA_OUT,
    data_oe  => DATA_OE
  );

  -- D_in used to be driven directly by both amux and dmux (resolved via
  -- tri-state 'Z': whichever one wasn't selected floated). The two are
  -- mutually exclusive by construction -- selD picks the A-register
  -- byte path, otherwise D_in comes from the external bus -- so this is
  -- now one explicit mux instead of a two-driver resolved signal.
  D_in <= D_in_amux WHEN (A_sel_lohi = "01" OR A_sel_lohi = "10") ELSE D_in_dmux;

  u_alu : ENTITY work.alu
  PORT MAP (
    oper    => alu_oper,
    alu_in  => alu_in,
    alu_out => alu_out,
    d_in    => D_in,
    d_out   => D_out,
    carry_in => DF_out,
    carry_out => carry
  );

END str;
