-------------------------------------------------------------------------------
--
-- File Name: instr.vhd
-- Author: Leon Hiemstra
-- Date: Mar-Oct 2021
--
-- Title: CDP1802 instruction decoder
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

ENTITY instr IS
  PORT (
    clk        : IN  STD_LOGIC;
    state      : IN  STD_LOGIC_VECTOR(3 DOWNTO 0);
    clk_cnt    : IN  STD_LOGIC_VECTOR(2 DOWNTO 0);
    NtoR       : OUT STD_LOGIC;
    XtoR       : OUT STD_LOGIC;
    StoR       : OUT STD_LOGIC;
    DtoR       : OUT STD_LOGIC;
    wr_A       : OUT STD_LOGIC;
    A_out      : IN  STD_LOGIC_VECTOR(15 DOWNTO 0);
    wr_I       : OUT STD_LOGIC;
    wr_N       : OUT STD_LOGIC;
    mask_R     : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    N_out      : IN  STD_LOGIC_VECTOR(3 DOWNTO 0);
    P_out      : IN  STD_LOGIC_VECTOR(3 DOWNTO 0);
    I_out      : IN  STD_LOGIC_VECTOR(3 DOWNTO 0);
    Go_Idle    : OUT STD_LOGIC;
    -- Direction of the S2 cycle in progress, from control.vhd (decided when
    -- the cycle was entered, not re-sampled from the request lines here).
    s2_dir_out : IN  STD_LOGIC := '0';
    Do_MRD     : OUT STD_LOGIC;
    Do_MWR     : OUT STD_LOGIC;
    Q_in       : OUT STD_LOGIC;
    Q_out      : IN  STD_LOGIC;
    IE_out     : IN  STD_LOGIC;
    IE_in      : OUT STD_LOGIC;
    wr_IE      : OUT STD_LOGIC;
    wr_Q       : OUT STD_LOGIC;
    float_DATA : OUT STD_LOGIC;
    float_T    : OUT STD_LOGIC;
    A_sel_lohi : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    D_out      : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
    D_in       : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
    DF_out     : IN  STD_LOGIC;
    alu_oper   : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
    wr_D       : OUT STD_LOGIC;
    rd_D       : OUT STD_LOGIC;
    wr_DF      : OUT STD_LOGIC;
    X_in       : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
    wr_X       : OUT STD_LOGIC;
    P_in       : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
    wr_P       : OUT STD_LOGIC;
    wr_R       : OUT STD_LOGIC;
    R_in       : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    nEF        : IN  STD_LOGIC_VECTOR(3 DOWNTO 0);
    forceS1    : OUT STD_LOGIC;
    extraS1    : IN  STD_LOGIC;
    T_out      : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
    wr_T       : OUT STD_LOGIC;
    N_addr_out : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
    dma_in     : IN  STD_LOGIC;
    dma_out    : IN  STD_LOGIC;

    -- Exploratory debug tap, 2026-09-15 (see boards/cora-z7-07s/
    -- BRINGUP_LOG.md's "milestone 3i"): tmp_page has no real chip pin
    -- (it's a purely FPGA-internal temporary within this multi-cycle
    -- state machine), so it was never exposed before. Added to chase a
    -- real-hardware-only LBR bug via an ILA capture, same as this
    -- project's other dbg_* ports.
    dbg_tmp_page : OUT STD_LOGIC_VECTOR(7 DOWNTO 0)
  );
END instr;


ARCHITECTURE str OF instr IS

  TYPE t_reg IS RECORD
    NtoR     : STD_LOGIC;
    XtoR     : STD_LOGIC;
    StoR     : STD_LOGIC;
    DtoR     : STD_LOGIC;
    wr_A     : STD_LOGIC;
    wr_I     : STD_LOGIC;
    wr_N     : STD_LOGIC;
    mask_R   : STD_LOGIC_VECTOR(1 DOWNTO 0);
    Go_Idle  : STD_LOGIC;
    idl      : STD_LOGIC; -- idling after an IDL instruction (not LOAD mode)
    Do_MRD   : STD_LOGIC;
    Do_MWR   : STD_LOGIC;
    Q_in     : STD_LOGIC;
    wr_Q     : STD_LOGIC;
    float_DATA : STD_LOGIC;
    float_T    : STD_LOGIC;
    A_sel_lohi : STD_LOGIC_VECTOR(1 DOWNTO 0);
    alu_oper   : STD_LOGIC_VECTOR(3 DOWNTO 0);
    wr_D     : STD_LOGIC;
    rd_D     : STD_LOGIC;
    wr_DF    : STD_LOGIC;
    X_in     : STD_LOGIC_VECTOR(3 DOWNTO 0);
    wr_X     : STD_LOGIC;
    P_in     : STD_LOGIC_VECTOR(3 DOWNTO 0);
    wr_P     : STD_LOGIC;
    wr_R     : STD_LOGIC;
    forceS1  : STD_LOGIC;
    tmp_page : STD_LOGIC_VECTOR(7 DOWNTO 0);
    R_in     : STD_LOGIC_VECTOR(15 DOWNTO 0);
    wr_T     : STD_LOGIC;
    wr_IE    : STD_LOGIC;
    IE_in    : STD_LOGIC;
    N_addr_out : STD_LOGIC_VECTOR(2 DOWNTO 0);
  END RECORD;

  SIGNAL r, nxt_r : t_reg;

BEGIN

  p_instr_comb : PROCESS(state, r, N_out, P_out, I_out, A_out, clk_cnt, D_out, D_in, Q_out, DF_out, IE_out, nEF, extraS1, T_out, dma_in, dma_out)
    VARIABLE v : t_reg;
  BEGIN
      v := r;
      v.XtoR := '0';
      v.NtoR := '0';
      v.StoR := '0';
      v.DtoR := '0';
      v.wr_A := '0';
      v.wr_I := '0';
      v.wr_N := '0';
      v.mask_R := "11";
      v.Go_Idle := '0';
      v.Do_MRD  := '0';
      v.Do_MWR  := '0';
      v.wr_Q := '0';
      v.float_DATA := '1';
      v.float_T := '1';
      v.A_sel_lohi := "00";
      v.alu_oper   := c_ALU_NOP;
      v.wr_D := '0';
      v.rd_D := '0';
      v.wr_DF := '0';
      v.wr_X := '0';
      v.wr_P := '0';
      v.wr_R := '0';
      v.wr_T := '0';
      v.wr_IE := '0';
      v.N_addr_out := "000";

      CASE state IS
        WHEN c_S0_FETCH =>
          v.idl := '0';
          IF clk_cnt = "000" THEN
              v.wr_A := '1'; -- R(P) -> A
          ELSIF clk_cnt = "100" THEN
              v.wr_I := '1'; -- M(R(P)) -> I
              v.wr_N := '1'; -- M(R(P)) -> N
          ELSIF clk_cnt = "101" THEN
              v.R_in := std_logic_vector(unsigned(A_out) + 1);
          ELSIF clk_cnt = "110" THEN -- 1 clk later is safer
              v.wr_R := '1';
          END IF;
        WHEN c_S1_RESET =>
          v.forceS1 := '0';
          v.idl := '0';
        WHEN c_S1_INIT =>
          -- R(P)
        WHEN c_S1_EXEC =>
            -- Instruction decoding
            CASE I_out IS
              WHEN "0000" => -- 0x0N
                  IF N_out = "0000" THEN -- IDL
                      v.Go_Idle := '1';
                      -- reads M(R(0)) in this and every idle cycle
                      -- (datasheet Table 2); not in LOAD mode, which also
                      -- uses S1_IDLE (hence the idl flag)
                      v.idl := '1';
                      v.DtoR := '1'; -- select R(0)
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(0) -> A
                      END IF;
                  ELSE -- LDN : M(R(N)) -> D; N!=0
                      v.NtoR := '1'; -- Select R(N)
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(N) -> A
                      ELSIF clk_cnt = "010" THEN
                          v.wr_D := '1'; -- M(R(N)) -> D
                      END IF;
                  END IF;
              WHEN "0001" => -- 0x1N : INC : R(N)+1
                  v.NtoR := '1'; -- Select R(N)
                  IF clk_cnt = "000" THEN
                      v.wr_A := '1'; -- R(N) -> A
                  ELSIF clk_cnt = "011" THEN
                      v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                  ELSIF clk_cnt = "100" THEN
                      v.wr_R := '1';
                  END IF;
              WHEN "0010" => -- 0x2N : DEC : R(N)-1
                  v.NtoR := '1'; -- Select R(N)
                  IF clk_cnt = "000" THEN
                      v.wr_A := '1'; -- R(N) -> A
                  ELSIF clk_cnt = "011" THEN
                      v.R_in := std_logic_vector(unsigned(A_out) - 1); -- A--
                  ELSIF clk_cnt = "100" THEN
                      v.wr_R := '1';
                  END IF;
              WHEN "0011" => -- 0x3N
                  IF N_out = "0000" THEN -- 0x30 : BR : M(R(P)) -> R(P).0
                      -- select R(P)
                      v.mask_R := "01"; -- select R(P).0
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          v.R_in(7 DOWNTO 0) := D_in; -- connect M(R(P))
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "0001" THEN    -- 0x31 : BQ : IF Q=1, M(R(P))->R(P).0 ELSE R(P)+1
                      -- select R(P)
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF Q_out = '1' THEN
                              v.mask_R := "01"; -- select R(P).0
                              v.R_in(7 DOWNTO 0) := D_in; -- connect M(R(P))
                          ELSE
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "0010" THEN    -- 0x32 : BZ : IF D=0, M(R(P))->R(P).0 ELSE R(P)+1
                      -- select R(P)
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF D_out = "00000000" THEN
                              v.mask_R := "01"; -- select R(P).0
                              v.R_in(7 DOWNTO 0) := D_in; -- connect M(R(P))
                          ELSE
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "0011" THEN    -- 0x33 : BDF : IF DF=1, M(R(P))->R(P).0 ELSE R(P)+1
                      -- select R(P)
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF DF_out = '1' THEN
                              v.mask_R := "01"; -- select R(P).0
                              v.R_in(7 DOWNTO 0) := D_in; -- connect M(R(P))
                          ELSE
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "0100" THEN    -- 0x34 : B1 : IF EF1=1, M(R(P))->R(P).0 ELSE R(P)+1
                      -- select R(P)              note: EF1=1 means nEF(0)=0
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF nEF(0) = '0' THEN
                              v.mask_R := "01"; -- select R(P).0
                              v.R_in(7 DOWNTO 0) := D_in; -- connect M(R(P))
                          ELSE
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "0101" THEN    -- 0x35 : B2 : IF EF2=1, M(R(P))->R(P).0 ELSE R(P)+1
                      -- select R(P)              note: EF2=1 means nEF(1)=0
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF nEF(1) = '0' THEN
                              v.mask_R := "01"; -- select R(P).0
                              v.R_in(7 DOWNTO 0) := D_in; -- connect M(R(P))
                          ELSE
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "0110" THEN    -- 0x36 : B3 : IF EF3=1, M(R(P))->R(P).0 ELSE R(P)+1
                      -- select R(P)              note: EF3=1 means nEF(2)=0
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF nEF(2) = '0' THEN
                              v.mask_R := "01"; -- select R(P).0
                              v.R_in(7 DOWNTO 0) := D_in; -- connect M(R(P))
                          ELSE
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "0111" THEN    -- 0x37 : B4 : IF EF4=1, M(R(P))->R(P).0 ELSE R(P)+1
                      -- select R(P)              note: EF4=1 means nEF(3)=0
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF nEF(3) = '0' THEN
                              v.mask_R := "01"; -- select R(P).0
                              v.R_in(7 DOWNTO 0) := D_in; -- connect M(R(P))
                          ELSE
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1000" THEN    -- 0x38 : SKP : R(P)+1
                      -- select R(P); reads M(R(P)) like every short branch
                      -- (datasheet Table 2)
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1001" THEN    -- 0x39 : BNQ : IF Q=0, M(R(P))->R(P).0 ELSE R(P)+1
                      -- select R(P)
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF Q_out = '0' THEN
                              v.mask_R := "01"; -- select R(P).0
                              v.R_in(7 DOWNTO 0) := D_in; -- connect M(R(P))
                          ELSE
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1010" THEN    -- 0x3A : BNZ : IF D NOT 0, M(R(P))->R(P).0 ELSE R(P)+1
                      -- select R(P)
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF D_out /= "00000000" THEN
                              v.mask_R := "01"; -- select R(P).0
                              v.R_in(7 DOWNTO 0) := D_in; -- connect M(R(P))
                          ELSE
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1011" THEN    -- 0x3B : BNF : IF DF=0, M(R(P))->R(P).0 ELSE R(P)+1
                      -- select R(P)
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF DF_out = '0' THEN
                              v.mask_R := "01"; -- select R(P).0
                              v.R_in(7 DOWNTO 0) := D_in; -- connect M(R(P))
                          ELSE
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1100" THEN    -- 0x3C : BN1 : IF EF1=0, M(R(P))->R(P).0 ELSE R(P)+1
                      -- select R(P)              note : EF1=0 means nEF(0)=1
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF nEF(0) = '1' THEN
                              v.mask_R := "01"; -- select R(P).0
                              v.R_in(7 DOWNTO 0) := D_in; -- connect M(R(P))
                          ELSE
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1101" THEN    -- 0x3D : BN2 : IF EF2=0, M(R(P))->R(P).0 ELSE R(P)+1
                      -- select R(P)              note : EF2=0 means nEF(1)=1
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF nEF(1) = '1' THEN
                              v.mask_R := "01"; -- select R(P).0
                              v.R_in(7 DOWNTO 0) := D_in; -- connect M(R(P))
                          ELSE
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1110" THEN    -- 0x3E : BN3 : IF EF3=0, M(R(P))->R(P).0 ELSE R(P)+1
                      -- select R(P)              note : EF3=0 means nEF(2)=1
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF nEF(2) = '1' THEN
                              v.mask_R := "01"; -- select R(P).0
                              v.R_in(7 DOWNTO 0) := D_in; -- connect M(R(P))
                          ELSE
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1111" THEN    -- 0x3F : BN4 : IF EF4=0, M(R(P))->R(P).0 ELSE R(P)+1
                      -- select R(P)              note : EF4=0 means nEF(3)=1
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF nEF(3) = '1' THEN
                              v.mask_R := "01"; -- select R(P).0
                              v.R_in(7 DOWNTO 0) := D_in; -- connect M(R(P))
                          ELSE
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  END IF;
              WHEN "0100" => -- 0x4N : LDA : M(R(N)) -> D ; R(N)+1
                  v.NtoR := '1'; -- Select R(N)
                  v.Do_MRD := '1';
                  IF clk_cnt = "000" THEN
                      v.wr_A := '1'; -- R(N) -> A
                  ELSIF clk_cnt = "011" THEN
                      v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                  ELSIF clk_cnt = "100" THEN
                      v.wr_D := '1'; -- M(R(N)) -> D
                      v.wr_R := '1';
                  END IF;
              WHEN "0101" => -- 0x5N : STR : D -> M(R(N))
                  v.NtoR := '1'; -- Select R(N)
                  v.float_DATA := '0';
                  v.rd_D := '1'; -- D -> M(R(N))
                  IF clk_cnt = "000" THEN
                      v.wr_A := '1'; -- R(N) -> A
                  ELSIF clk_cnt = "011" THEN
                      v.Do_MWR := '1';
                  END IF;
              WHEN "0110" =>
                  IF N_out = "0000" THEN -- 0x60 : IRX : R(X)+1
                      v.XtoR := '1'; -- Select R(X)
                      v.Do_MRD := '1'; -- reads M(R(X)) (datasheet Table 2)
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A
                      ELSIF clk_cnt = "011" THEN
                          v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out(3) = '0' THEN -- 0x6N (N=1-7) : OUT
                      v.XtoR := '1'; -- Select R(X)
                      v.Do_MRD := '1';
                      v.N_addr_out := N_out(2 DOWNTO 0);
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A
                      ELSIF clk_cnt = "011" THEN
                          v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out(3) = '1' THEN -- 0x6N (N=9-F) : INP
                      v.XtoR := '1'; -- Select R(X)
                      v.N_addr_out := N_out(2 DOWNTO 0);
                      -- Real hardware bug found 2026-09-18 (see
                      -- boards/cora-z7-07s/BRINGUP_LOG.md): Do_MWR used
                      -- to be scoped to clk_cnt="011" only, one cycle
                      -- before wr_D's clk_cnt="100" -- but every other
                      -- multi-cycle memory instruction in this file
                      -- (LDN, LDXA, ADC, OUT, ...) asserts its Do_MRD/
                      -- Do_MWR *unconditionally* for the whole
                      -- instruction, precisely so the addressed device
                      -- is still driving the bus whenever a later
                      -- clk_cnt latches from it. INP was the one
                      -- outlier: its device (an external I/O chip, not
                      -- this core's own memory) only drives the shared
                      -- bus while Do_MWR/nMWR is actually asserted (see
                      -- cdp1854.vhd/io_inp.vhd's nCS/nOE gating), so by
                      -- the time wr_D fired one cycle after Do_MWR had
                      -- already dropped, D_in was already floating/
                      -- stale (observed as D silently staying 0x00
                      -- after a real CDP1854 INP, real hardware, despite
                      -- the correct byte visibly reaching M(R(X))).
                      -- Holding Do_MWR unconditionally (matching every
                      -- read-side sibling) keeps the device's output
                      -- alive through wr_D's own clk_cnt, so D and
                      -- M(R(X)) are loaded from the exact same bus
                      -- sample -- real INP: "BUS -> D; BUS -> M(R(X))"
                      -- simultaneously, not one cycle apart.
                      -- ... but it must end before the machine-cycle boundary:
                      -- a real memory latches the data on the trailing edge of
                      -- MWR, and the strobe is registered half a clock late, so
                      -- holding it through clk 7 wrote the NEXT cycle's data.
                      IF clk_cnt /= "111" THEN
                          v.Do_MWR := '1';
                      END IF;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D := '1'; -- BUS -> D
                      END IF;
                  END IF;
              WHEN "0111" => -- 0x7N
                  IF N_out = "0000" THEN    -- 0x70 : RET : M(R(X))->(X,P);R(X)+1;1->IE
                      v.XtoR := '1'; -- Select R(X)
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A
                      ELSIF clk_cnt = "011" THEN
                          v.X_in := D_in(7 DOWNTO 4);
                          v.P_in := D_in(3 DOWNTO 0);
                          v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          v.IE_in := '1';
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                          v.wr_X := '1';
                          v.wr_P := '1';
                          v.wr_IE := '1';
                      END IF;
                  ELSIF N_out = "0001" THEN    -- 0x71 : DIS : M(R(X))->(X,P);R(X)+1;0->IE
                      v.XtoR := '1'; -- Select R(X)
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A
                      ELSIF clk_cnt = "011" THEN
                          v.X_in := D_in(7 DOWNTO 4);
                          v.P_in := D_in(3 DOWNTO 0);
                          v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          v.IE_in := '0';
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                          v.wr_X := '1';
                          v.wr_P := '1';
                          v.wr_IE := '1';
                      END IF;
                  ELSIF N_out = "0010" THEN -- 0x72 : LDXA : M(R(X)) -> D ; R(X)+1
                      v.XtoR := '1'; -- Select R(X)
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A
                      ELSIF clk_cnt = "011" THEN
                          v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D := '1'; -- M(R(X)) -> D
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "0011" THEN    -- 0x73 : STXD : D -> M(R(X)) ; R(X)-1
                      v.XtoR := '1'; -- Select R(X)
                      v.float_DATA := '0';
                      v.rd_D := '1'; -- D -> M(R(X))
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A
                      ELSIF clk_cnt = "011" THEN
                          v.R_in := std_logic_vector(unsigned(A_out) - 1); -- A--
                      ELSIF clk_cnt = "100" THEN
                          v.Do_MWR := '1';
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "0100" THEN -- 0x74 : ADC : M(R(X)) + D + DF -> DF, D
                      v.XtoR := '1'; -- Select R(X)
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_U_ADC;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D := '1'; -- M(R(X)) -> D
                          v.wr_DF := '1'; -- carry -> DF
                      END IF;
                  ELSIF N_out = "0101" THEN -- 0x75 : SDB : M(R(X)) - D - (NOT DF) -> DF, D
                      v.XtoR := '1'; -- Select R(X)
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_S_SUBB;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D := '1'; -- M(R(X)) -> D
                          v.wr_DF := '1'; -- carry -> DF
                      END IF;
                  ELSIF N_out = "0110" THEN -- 0x76 : RSHR : D >>= 1; LSB(D)->DF; DF->MSB(D)
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_RSHR;
                      v.XtoR := '1'; -- Select R(X): bus address per datasheet Table 2 (no access)
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A: bus address per datasheet Table 2 (no access)
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D  := '1'; -- alu_out -> D
                          v.wr_DF := '1'; -- carry -> DF
                      END IF;
                  ELSIF N_out = "0111" THEN -- 0x77 : SMB : D - M(R(X)) - (NOT DF) -> DF, D
                      v.XtoR := '1'; -- Select R(X)
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_S_SUBB_REV;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D := '1'; -- M(R(X)) -> D
                          v.wr_DF := '1'; -- carry -> DF
                      END IF;
                  ELSIF N_out = "1000" THEN    -- 0x78 : SAV : T -> M(R(X))
                      v.XtoR := '1'; -- Select R(X)
                      v.float_T := '0';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A
                      ELSIF clk_cnt = "100" THEN
                          v.Do_MWR := '1';
                      END IF;
                  ELSIF N_out = "1001" THEN    -- 0x79 : MARK : (X,P)->T:M(R(2)) THEN P->X:R(2)-1
                      v.StoR := '1'; -- Select R(2) (Stackpointer)
                      v.float_T := '0';
                      v.X_in  := P_out;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A
                          v.wr_T := '1';
                      ELSIF clk_cnt = "011" THEN
                          v.R_in := std_logic_vector(unsigned(A_out) - 1); -- A--
                      ELSIF clk_cnt = "100" THEN
                          v.Do_MWR := '1';
                          v.wr_R := '1';
                          v.wr_X := '1';
                      END IF;
                  ELSIF N_out = "1011" THEN    -- 0x7B : SEQ
                      v.Q_in  := '1';       -- Q=1
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A: bus address per datasheet Table 2 (no access)
                      ELSIF clk_cnt = "100" THEN
                          v.wr_Q  := '1';
                      END IF;
                  ELSIF N_out = "1010" THEN -- 0x7A : REQ
                      v.Q_in  := '0';       -- Q=0
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A: bus address per datasheet Table 2 (no access)
                      ELSIF clk_cnt = "100" THEN
                          v.wr_Q  := '1';
                      END IF;
                  ELSIF N_out = "1100" THEN -- 0x7C : ADI : M(R(P)) + D +DF -> DF,D; R(P)+1
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_U_ADC;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D := '1'; -- M(R(P)) -> D
                          v.wr_DF := '1'; -- carry -> DF
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1101" THEN -- 0x7D : SDBI : M(R(P)) - D - (NOT DF) -> DF,D; R(P)+1
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_S_SUBB;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D := '1'; -- M(R(P)) -> D
                          v.wr_DF := '1'; -- carry -> DF
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1110" THEN -- 0x7E : RSHL : D <<= 1; MSB(D)->DF; DF->LSB(D)
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_RSHL;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A: bus address per datasheet Table 2 (no access)
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D  := '1'; -- alu_out -> D
                          v.wr_DF := '1'; -- carry -> DF
                      END IF;
                  ELSIF N_out = "1111" THEN -- 0x7F : SMBI : D - M(R(P)) - (NOT DF) -> DF,D; R(P)+1
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_S_SUBB_REV;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D := '1'; -- M(R(P)) -> D
                          v.wr_DF := '1'; -- carry -> DF
                          v.wr_R := '1';
                      END IF;
                  END IF;
              WHEN "1000" => -- 0x8N : GLO : R(N).0 -> D
                  v.NtoR := '1'; -- Select R(N)
                  v.A_sel_lohi := "01"; -- select A.0
                  IF clk_cnt = "000" THEN
                      v.wr_A := '1'; -- R(N) -> A
                  ELSIF clk_cnt = "100" THEN
                      v.wr_D := '1'; -- A.0 -> D
                  END IF;
              WHEN "1001" => -- 0x9N : GHI : R(N).1 -> D
                  v.NtoR := '1'; -- Select R(N)
                  v.A_sel_lohi := "10"; -- select A.1
                  IF clk_cnt = "000" THEN
                      v.wr_A := '1'; -- R(N) -> A
                  ELSIF clk_cnt = "100" THEN
                      v.wr_D := '1'; -- A.1 -> D
                  END IF;
              WHEN "1010" => -- 0xAN : PLO : D -> R(N).0
                  v.NtoR := '1'; -- Select R(N)
                  v.mask_R := "01"; -- select R(N).0
                  v.rd_D := '1';
                  IF clk_cnt = "000" THEN
                      v.wr_A := '1'; -- R(N) -> A: bus address per datasheet Table 2 (no access)
                  ELSIF clk_cnt = "011" THEN
                      v.R_in(7 DOWNTO 0) := D_out; -- connect D
                  ELSIF clk_cnt = "100" THEN
                      v.wr_R := '1';
                  END IF;
              WHEN "1011" => -- 0xBN : PHI : D -> R(N).1
                  v.NtoR := '1'; -- Select R(N)
                  v.mask_R := "10"; -- select R(N).1
                  v.rd_D := '1';
                  IF clk_cnt = "000" THEN
                      v.wr_A := '1'; -- R(N) -> A: bus address per datasheet Table 2 (no access)
                  ELSIF clk_cnt = "011" THEN
                      v.R_in(15 DOWNTO 8) := D_out; -- connect D
                  ELSIF clk_cnt = "100" THEN
                      v.wr_R := '1';
                  END IF;
              WHEN "1100" => -- 0xCN

                  -- All 0xCN instructions require 2x S1 cycles
                  IF clk_cnt = "011" THEN
                      IF extraS1 = '0' THEN
                          v.forceS1 := '1'; -- stay in S1_EXEC
                      ELSE
                          v.forceS1 := '0'; -- leave S1_EXEC
                      END IF;
                  END IF;

                  IF N_out = "0000" THEN -- 0xC0 : LBR : M(R(P))->R(P).1 ; M(R(P+1))->R(P).0
                      -- select R(P)
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF extraS1 = '0' THEN
                              v.tmp_page := D_in; -- connect M(R(P))
                              v.R_in := std_logic_vector(unsigned(A_out) + 1);
                          ELSE
                              v.R_in := r.tmp_page & D_in; -- connect M(R(P))
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "0001" THEN -- 0xC1 : LBQ : IF Q=1, M(R(P))->R(P).1 ; M(R(P+1))->R(P).0
                                            --              ELSE R(P)+2
                      -- select R(P)
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF Q_out = '1' THEN
                              IF extraS1 = '0' THEN
                                  v.tmp_page := D_in; -- connect M(R(P))
                                  v.R_in := std_logic_vector(unsigned(A_out) + 1);
                              ELSE
                                  v.R_in := r.tmp_page & D_in; -- connect M(R(P))
                              END IF;
                          ELSE
                              -- not taken: still reads R(P), then R(P)+1
                              -- (datasheet Table 2), +1 per cycle = +2
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "0010" THEN -- 0xC2 : LBZ : IF D=0, M(R(P))->R(P).1 ; M(R(P+1))->R(P).0
                                            --              ELSE R(P)+2
                      -- select R(P)
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF D_out = "00000000" THEN
                              IF extraS1 = '0' THEN
                                  v.tmp_page := D_in; -- connect M(R(P))
                                  v.R_in := std_logic_vector(unsigned(A_out) + 1);
                              ELSE
                                  v.R_in := r.tmp_page & D_in; -- connect M(R(P))
                              END IF;
                          ELSE
                              -- not taken: still reads R(P), then R(P)+1
                              -- (datasheet Table 2), +1 per cycle = +2
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "0011" THEN -- 0xC3 : LBDF : IF DF=1, M(R(P))->R(P).1 ; M(R(P+1))->R(P).0
                                            --               ELSE R(P)+2
                      -- select R(P)
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF DF_out = '1' THEN
                              IF extraS1 = '0' THEN
                                  v.tmp_page := D_in; -- connect M(R(P))
                                  v.R_in := std_logic_vector(unsigned(A_out) + 1);
                              ELSE
                                  v.R_in := r.tmp_page & D_in; -- connect M(R(P))
                              END IF;
                          ELSE
                              -- not taken: still reads R(P), then R(P)+1
                              -- (datasheet Table 2), +1 per cycle = +2
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "0100" THEN -- 0xC4 : NOP
                      -- no operation, but reads M(R(P)) in both cycles
                      -- (datasheet Table 2)
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      END IF;
                  ELSIF N_out = "0101" THEN    -- 0xC5 : LSNQ : IF Q=0, R(P)+2 ELSE CONTINUE
                      -- select R(P)
                      v.Do_MRD := '1'; -- both cycles read memory (datasheet Table 2)
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          -- taken: reads R(P), R(P)+1 (+1 per cycle); not
                          -- taken: reads R(P) twice (datasheet Table 2)
                          IF Q_out = '0' THEN
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          ELSE
                              v.R_in := A_out;
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "0110" THEN    -- 0xC6 : LSNZ : IF D!=0, R(P)+2 ELSE CONTINUE
                      -- select R(P)
                      v.Do_MRD := '1'; -- both cycles read memory (datasheet Table 2)
                      v.rd_D := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          -- taken: reads R(P), R(P)+1 (+1 per cycle); not
                          -- taken: reads R(P) twice (datasheet Table 2)
                          IF D_out /= "00000000" THEN
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          ELSE
                              v.R_in := A_out;
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "0111" THEN    -- 0xC7 : LSNF : IF DF=0, R(P)+2 ELSE CONTINUE
                      -- select R(P)
                      v.Do_MRD := '1'; -- both cycles read memory (datasheet Table 2)
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          -- taken: reads R(P), R(P)+1 (+1 per cycle); not
                          -- taken: reads R(P) twice (datasheet Table 2)
                          IF DF_out = '0' THEN
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          ELSE
                              v.R_in := A_out;
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1000" THEN    -- 0xC8 : LSKP : R(P)+2
                      -- select R(P); reads R(P), then R(P)+1 (datasheet
                      -- Table 2 lists it with the long branches), +1 per cycle
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1001" THEN -- 0xC9 : LBNQ : IF Q=0, M(R(P))->R(P).1 ; M(R(P+1))->R(P).0
                                            --               ELSE R(P)+2
                      -- select R(P)
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF Q_out = '0' THEN
                              IF extraS1 = '0' THEN
                                  v.tmp_page := D_in; -- connect M(R(P))
                                  v.R_in := std_logic_vector(unsigned(A_out) + 1);
                              ELSE
                                  v.R_in := r.tmp_page & D_in; -- connect M(R(P))
                              END IF;
                          ELSE
                              -- not taken: still reads R(P), then R(P)+1
                              -- (datasheet Table 2), +1 per cycle = +2
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1010" THEN -- 0xCA : LBNZ : IF D!=0, M(R(P))->R(P).1 ; M(R(P+1))->R(P).0
                                            --               ELSE R(P)+2
                      -- select R(P)
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF D_out /= "00000000" THEN
                              IF extraS1 = '0' THEN
                                  v.tmp_page := D_in; -- connect M(R(P))
                                  v.R_in := std_logic_vector(unsigned(A_out) + 1);
                              ELSE
                                  v.R_in := r.tmp_page & D_in; -- connect M(R(P))
                              END IF;
                          ELSE
                              -- not taken: still reads R(P), then R(P)+1
                              -- (datasheet Table 2), +1 per cycle = +2
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1011" THEN -- 0xCB : LBNF : IF DF=0, M(R(P))->R(P).1 ; M(R(P+1))->R(P).0
                                            --               ELSE R(P)+2
                      -- select R(P)
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          IF DF_out = '0' THEN
                              IF extraS1 = '0' THEN
                                  v.tmp_page := D_in; -- connect M(R(P))
                                  v.R_in := std_logic_vector(unsigned(A_out) + 1);
                              ELSE
                                  v.R_in := r.tmp_page & D_in; -- connect M(R(P))
                              END IF;
                          ELSE
                              -- not taken: still reads R(P), then R(P)+1
                              -- (datasheet Table 2), +1 per cycle = +2
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1100" THEN    -- 0xCC : LSIE : IF IE=1, R(P)+2 ELSE CONTINUE
                      -- select R(P)
                      v.Do_MRD := '1'; -- both cycles read memory (datasheet Table 2)
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          -- taken: reads R(P), R(P)+1 (+1 per cycle); not
                          -- taken: reads R(P) twice (datasheet Table 2)
                          IF IE_out = '1' THEN
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          ELSE
                              v.R_in := A_out;
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1101" THEN    -- 0xCD : LSQ : IF Q=1, R(P)+2 ELSE CONTINUE
                      -- select R(P)
                      v.Do_MRD := '1'; -- both cycles read memory (datasheet Table 2)
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          -- taken: reads R(P), R(P)+1 (+1 per cycle); not
                          -- taken: reads R(P) twice (datasheet Table 2)
                          IF Q_out = '1' THEN
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          ELSE
                              v.R_in := A_out;
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1110" THEN    -- 0xCE : LSZ : IF D=0, R(P)+2 ELSE CONTINUE
                      -- select R(P)
                      v.Do_MRD := '1'; -- both cycles read memory (datasheet Table 2)
                      v.rd_D := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          -- taken: reads R(P), R(P)+1 (+1 per cycle); not
                          -- taken: reads R(P) twice (datasheet Table 2)
                          IF D_out = "00000000" THEN
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          ELSE
                              v.R_in := A_out;
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1111" THEN    -- 0xCF : LSDF : IF DF=1, R(P)+2 ELSE CONTINUE
                      -- select R(P)
                      v.Do_MRD := '1'; -- both cycles read memory (datasheet Table 2)
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          -- taken: reads R(P), R(P)+1 (+1 per cycle); not
                          -- taken: reads R(P) twice (datasheet Table 2)
                          IF DF_out = '1' THEN
                              v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                          ELSE
                              v.R_in := A_out;
                          END IF;
                      ELSIF clk_cnt = "100" THEN
                          v.wr_R := '1';
                      END IF;
                  END IF;
              WHEN "1101" => -- 0xDN : SEP
                  v.P_in := N_out;
                  v.NtoR := '1'; -- Select R(N): bus address per datasheet Table 2 (no access)
                  IF clk_cnt = "000" THEN
                      v.wr_A := '1'; -- R(N) -> A
                  ELSIF clk_cnt = "100" THEN
                      v.wr_P  := '1'; -- P=N
                  END IF;
              WHEN "1110" => -- 0xEN : SEX
                  v.X_in  := N_out;
                  v.NtoR := '1'; -- Select R(N): bus address per datasheet Table 2 (no access)
                  IF clk_cnt = "000" THEN
                      v.wr_A := '1'; -- R(N) -> A
                  ELSIF clk_cnt = "100" THEN
                      v.wr_X  := '1'; -- X=N
                  END IF;
              WHEN "1111" =>
                  IF N_out = "0000" THEN -- 0xF0 : LDX : M(R(X)) -> D
                      v.XtoR := '1'; -- Select R(X)
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A
                      ELSIF clk_cnt = "010" THEN
                          v.wr_D := '1'; -- M(R(X)) -> D
                      END IF;
                  ELSIF N_out = "0001" THEN -- 0xF1 : OR : M(R(X)) OR D -> D
                      v.XtoR := '1'; -- Select R(X)
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_OR;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A
                      ELSIF clk_cnt = "010" THEN
                          v.wr_D := '1'; -- M(R(X)) -> D
                      END IF;
                  ELSIF N_out = "0010" THEN -- 0xF2 : AND : M(R(X)) AND D -> D
                      v.XtoR := '1'; -- Select R(X)
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_AND;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A
                      ELSIF clk_cnt = "010" THEN
                          v.wr_D := '1'; -- M(R(X)) -> D
                      END IF;
                  ELSIF N_out = "0011" THEN -- 0xF3 : XOR : M(R(X)) XOR D -> D
                      v.XtoR := '1'; -- Select R(X)
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_XOR;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A
                      ELSIF clk_cnt = "010" THEN
                          v.wr_D := '1'; -- M(R(X)) -> D
                      END IF;
                  ELSIF N_out = "0100" THEN -- 0xF4 : ADD : M(R(X)) + D -> DF, D
                      v.XtoR := '1'; -- Select R(X)
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_U_ADD;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D := '1'; -- M(R(X)) -> D
                          v.wr_DF := '1'; -- carry -> DF
                      END IF;
                  ELSIF N_out = "0101" THEN -- 0xF5 : SD : M(R(X)) - D -> DF, D
                      v.XtoR := '1'; -- Select R(X)
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_S_SUB;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D := '1'; -- M(R(X)) -> D
                          v.wr_DF := '1'; -- carry -> DF
                      END IF;
                  ELSIF N_out = "0110" THEN -- 0xF6 : SHR : D >>= 1; LSB(D)->DF; 0->MSB(D)
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_SHR;
                      v.XtoR := '1'; -- Select R(X): bus address per datasheet Table 2 (no access)
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A: bus address per datasheet Table 2 (no access)
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D  := '1'; -- alu_out -> D
                          v.wr_DF := '1'; -- carry -> DF
                      END IF;
                  ELSIF N_out = "0111" THEN -- 0xF7 : SM : D - M(R(X)) -> DF, D
                      v.XtoR := '1'; -- Select R(X)
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_S_SUB_REV;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(X) -> A
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D := '1'; -- M(R(X)) -> D
                          v.wr_DF := '1'; -- carry -> DF
                      END IF;
                  ELSIF N_out = "1000" THEN -- 0xF8 : LDI : M(R(P)) -> D; R(P)+1
                      v.Do_MRD := '1';
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D := '1'; -- M(R(P)) -> D
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1001" THEN -- 0xF9 : ORI : M(R(P)) OR D -> D; R(P)+1
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_OR;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D := '1'; -- M(R(P)) -> D
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1010" THEN -- 0xFA : ANI : M(R(P)) AND D -> D; R(P)+1
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_AND;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D := '1'; -- M(R(P)) -> D
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1011" THEN -- 0xFB : XRI : M(R(P)) XOR D -> D; R(P)+1
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_XOR;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D := '1'; -- M(R(P)) -> D
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1100" THEN -- 0xFC : ADI : M(R(P)) + D -> DF,D; R(P)+1
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_U_ADD;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D := '1'; -- M(R(P)) -> D
                          v.wr_DF := '1'; -- carry -> DF
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1101" THEN -- 0xFD : SDI : M(R(P)) - D -> DF,D; R(P)+1
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_S_SUB;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D := '1'; -- M(R(P)) -> D
                          v.wr_DF := '1'; -- carry -> DF
                          v.wr_R := '1';
                      END IF;
                  ELSIF N_out = "1110" THEN -- 0xFE : SHL : D <<= 1; MSB(D)->DF; 0->LSB(D)
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_SHL;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A: bus address per datasheet Table 2 (no access)
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D  := '1'; -- alu_out -> D
                          v.wr_DF := '1'; -- carry -> DF
                      END IF;
                  ELSIF N_out = "1111" THEN -- 0xFF : SMI : D - M(R(P)) -> DF,D; R(P)+1
                      v.Do_MRD := '1';
                      v.rd_D := '1';
                      v.alu_oper := c_ALU_S_SUB_REV;
                      IF clk_cnt = "000" THEN
                          v.wr_A := '1'; -- R(P) -> A
                      ELSIF clk_cnt = "011" THEN
                          v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                      ELSIF clk_cnt = "100" THEN
                          v.wr_D := '1'; -- M(R(P)) -> D
                          v.wr_DF := '1'; -- carry -> DF
                          v.wr_R := '1';
                      END IF;
                  END IF;
              WHEN OTHERS =>
            END CASE;
        WHEN c_S1_IDLE =>
            IF r.idl = '1' THEN -- idling after IDL (not LOAD mode)
                v.DtoR := '1'; -- select R(0)
                v.Do_MRD := '1';
                IF clk_cnt = "000" THEN
                    v.wr_A := '1'; -- R(0) -> A
                END IF;
            END IF;
        WHEN c_S2_DMA =>
            v.DtoR := '1'; -- Select R(0)
            -- The direction comes from control.vhd, which decided it when
            -- it entered this cycle (DMA IN has priority over DMA OUT,
            -- datasheet Figure 25). The request lines are not re-sampled:
            -- a controller usually drops them as soon as the cycle is
            -- granted, and the cycle must still be carried out.
            IF s2_dir_out = '0' THEN
                IF clk_cnt = "000" THEN
                    v.wr_A := '1'; -- R(0) -> A
                ELSIF clk_cnt = "011" THEN
                    v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                    v.Do_MWR := '1';
                ELSIF clk_cnt = "100" THEN
                    v.wr_R := '1';
                END IF;
            ELSE
                v.Do_MRD := '1';
                IF clk_cnt = "000" THEN
                    v.wr_A := '1'; -- R(0) -> A
                ELSIF clk_cnt = "011" THEN
                    v.R_in := std_logic_vector(unsigned(A_out) + 1); -- A++
                ELSIF clk_cnt = "100" THEN
                    v.wr_R := '1';
                END IF;
            END IF;
        WHEN c_S3_INTERRUPT =>
          v.idl := '0';
        WHEN OTHERS =>
      END CASE;

      nxt_r <= v; -- update

  END PROCESS;

  p_instr : PROCESS(clk)
  BEGIN
      IF rising_edge(clk) THEN
          r <= nxt_r;
      END IF;
  END PROCESS;

  -- connect
  XtoR <= r.XtoR;
  NtoR <= r.NtoR;
  StoR <= r.StoR;
  DtoR <= r.DtoR;
  wr_A <= r.wr_A;
  wr_I <= r.wr_I;
  wr_N <= r.wr_N;
  mask_R <= r.mask_R;
  Go_Idle <= r.Go_Idle;
  Do_MRD  <= r.Do_MRD;
  Do_MWR  <= r.Do_MWR;
  wr_Q    <= r.wr_Q;
  Q_in    <= r.Q_in;
  float_DATA <= r.float_DATA;
  float_T <= r.float_T;
  A_sel_lohi <= r.A_sel_lohi;
  dbg_tmp_page <= r.tmp_page;
  alu_oper   <= r.alu_oper;
  wr_D   <= r.wr_D;
  rd_D   <= r.rd_D;
  wr_DF  <= r.wr_DF;
  X_in   <= r.X_in;
  wr_X   <= r.wr_X;
  P_in   <= r.P_in;
  wr_P   <= r.wr_P;
  wr_R   <= r.wr_R;
  wr_T   <= r.wr_T;
  R_in   <= r.R_in;
  forceS1 <= r.forceS1;
  IE_in   <= r.IE_in;
  wr_IE   <= r.wr_IE;
  N_addr_out <= r.N_addr_out;

END str;
