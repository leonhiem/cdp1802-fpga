-------------------------------------------------------------------------------
--
-- File Name: ram.vhd
-- Author: Leon Hiemstra
--
-- Title: CDP18 RAM including test program
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
USE work.instr_pkg.ALL;


ENTITY ram IS
  PORT (
    address : IN STD_LOGIC_VECTOR(15 DOWNTO 0);
    -- FPGA note: split from a single INOUT 'data' pin into separate
    -- write-data-in / read-data-out signals -- no internal 'Z'. The
    -- parent (cdp18.vhd/cs1800.vhd) merges data_out with whatever else
    -- shares the system bus.
    data_in  : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
    data_out : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    nWE, nCS, nOE: IN STD_LOGIC
  );
END ram;

ARCHITECTURE str OF ram IS

TYPE ram_type IS ARRAY (0 to 275) OF std_logic_vector(7 DOWNTO 0);

SIGNAL ram1 : ram_type:= (

-- Testprogram. This program has no function, 
-- it is only intended for testing instructions

-- instr    addr mnemonic  description
  c_DIS,   -- 0x00: Disable interrupts
  X"00",   -- 0x01
  c_SEX_2, -- 0x02: X=2
  c_SEQ,   -- 0x03: Q=1
  c_GHI_0, -- 0x04: R(N).1->D (N=0) : D will be 0
  c_PHI_3, -- 0x05: D->R(N).1 (N=3) : R(3).1 will be 0
  c_LDI,   -- 0x06: M(R(P))->D; R(P)+1 : D will be 0x1E
  X"1E",   -- 0x07: 
  c_PLO_3, -- 0x08: D->R(N).0 (N=3) :
  c_STR_3, -- 0x09: D->M(R(N))(N=3) :
  c_INC_3, -- 0x0A: R(N)+1          :
  c_SEX_3, -- 0x0B: X=3
  c_STXD,  -- 0x0C: D->M(R(X)); R(X)-1 :
  c_IRX,   -- 0x0D: R(X)+1          :
  c_IRX,   -- 0x0E: R(X)+1          :
  c_GLO_3, -- 0x0F: R(N).0->D (N=3) :
  c_STR_3, -- 0x10: D->M(R(N))(N=3) : 
  c_NOP,   -- 0x11: NOP
  c_LDA_3, -- 0x12: M(R(N))->D; R(N)+1 (N=3) :
  c_STR_3, -- 0x13: D->M(R(N))(N=3) :
  c_LDN_3, -- 0x14: M(R(N))->D(N=3) :
  c_INC_3, -- 0x15: R(N)+1          :
  c_STR_3, -- 0x16: D->M(R(N))(N=3) :
  c_LDXA,  -- 0x17: M(R(X))->D ; R(X)+1 :
  c_STR_3, -- 0x18: D->M(R(N))(N=3) :
  c_LDX,   -- 0x19: M(R(X))->D      :
  c_INC_3, -- 0x1A: R(N)+1          :
  c_STR_3, -- 0x1B: D->M(R(N))(N=3) :
  c_INC_3, -- 0x1C: R(N)+1          :
  c_SEP_3, -- 0x1D: N->P : switch PC to R(3); jumping to address 0x0025
  X"00",   -- 0x1E: 0x00 : will be 0x1E
  X"00",   -- 0x1F: 0x00 : will be 0x1E
  X"00",   -- 0x20: 0x00 : will be 0x20
  X"00",   -- 0x21: 0x00 : will be 0x20
  X"00",   -- 0x22: 0x00 : will be 0x20
  X"00",   -- 0x23: 0x00 : will be 0x20
  X"00",   -- 0x24: 0x00 : will be 0x20
  c_SEX_2, -- 0x25: X=2
  c_GHI_3, -- 0x26: R(N).1->D (N=3) : D will be 0
  c_PHI_2, -- 0x27: D->R(N).1 (N=2) : R(2).1 will be 0

  -- OR
  c_LDI,   -- 0x28: M(R(P))->D; R(P)+1 : D will be:

  X"9A",   -- 0x29: <------------- point to data <--------- !!!

  c_PLO_2, -- 0x2A: D->R(N).0 (N=2)
  c_LDI,   -- 0x2B: M(R(P))->D; R(P)+1 : D will be 0x92
  X"92",   -- 0x2C:
  c_OR,    -- 0x2D: M(R(X)) OR D -> D
  c_STR_2, -- 0x2E: D->M(R(N))(N=2) : addr M(R(2)) will be result of OR = 0xD7

  -- ORI
  c_INC_2, -- 0x2F: R(N)+1
  c_ORI,   -- 0x30: M(R(P)) OR D -> D; R(P)+1 : result is 0xFF
  X"28",   -- 0x31:
  c_STR_2, -- 0x32: D->M(R(N))(N=2) : addr M(R(2)) will be result of ORI = 0xFF

  -- XOR
  c_LDI,   -- 0x33: M(R(P))->D; R(P)+1 : D will be 0x33
  X"33",   -- 0x34:
  c_XOR,   -- 0x35: M(R(X)) XOR D -> D
  c_INC_2, -- 0x36: R(N)+1
  c_STR_2, -- 0x37: D->M(R(N))(N=2) : addr M(R(2)) will be result of XOR = 0xCC

  -- XRI
  c_INC_2, -- 0x38: R(N)+1
  c_XRI,   -- 0x39: M(R(P)) OR D -> D; R(P)+1 : result is 0xE4
  X"28",   -- 0x3A:
  c_STR_2, -- 0x3B: D->M(R(N))(N=2) : addr M(R(2)) will be result of XRI = 0xE4

  -- AND
  c_LDI,   -- 0x3C: M(R(P))->D; R(P)+1 : D will be 0x04
  X"04",   -- 0x3D:
  c_AND,   -- 0x3E: M(R(X)) AND D -> D
  c_INC_2, -- 0x3F: R(N)+1
  c_STR_2, -- 0x40: D->M(R(N))(N=2) : addr M(R(2)) will be result of AND = 0x04

  -- ANI
  c_INC_2, -- 0x41: R(N)+1
  c_ANI,   -- 0x42: M(R(P)) OR D -> D; R(P)+1 : result is 0x04
  X"FF",   -- 0x43:
  c_STR_2, -- 0x44: D->M(R(N))(N=2) : addr M(R(2)) will be result of ANI = 0x04

  -- SHR
  c_INC_2, -- 0x45: R(N)+1
  c_LDI,   -- 0x46: M(R(P))->D; R(P)+1
  X"85",   -- 0x47:
  c_SHR,   -- 0x48: D >>= 1; LSB(D)->DF; 0->MSB(D)
  c_STR_2, -- 0x49: D->M(R(N))(N=2) : addr M(R(2)) will be result of SHR

  -- SHL
  c_INC_2, -- 0x4A: R(N)+1
  c_LDI,   -- 0x4B: M(R(P))->D; R(P)+1
  X"85",   -- 0x4C:
  c_SHL,   -- 0x4D: D <<= 1; MSB(D)->DF; 0->LSB(D)
  c_STR_2, -- 0x4E: D->M(R(N))(N=2) : addr M(R(2)) will be result of SHL

  -- RSHR
  c_INC_2, -- 0x4F: R(N)+1
  c_LDI,   -- 0x50: M(R(P))->D; R(P)+1
  X"85",   -- 0x51:
  c_RSHR,  -- 0x52: D >>= 1; LSB(D)->DF; DF->MSB(D)
  c_STR_2, -- 0x53: D->M(R(N))(N=2) : addr M(R(2)) will be result of RSHR

  -- RSHL
  c_INC_2, -- 0x54: R(N)+1
  c_LDI,   -- 0x55: M(R(P))->D; R(P)+1
  X"1D",   -- 0x56:
  c_RSHL,  -- 0x57: D <<= 1; MSB(D)->DF; DF->LSB(D)
  c_STR_2, -- 0x58: D->M(R(N))(N=2) : addr M(R(2)) will be result of RSHL

  -- ADD
  c_LDI,   -- 0x59: M(R(P))->D; R(P)+1
  X"F0",   -- 0x5A:
  c_ADD,   -- 0x5B: M(R(X))+D -> DF, D : 0x3A + 0xF0 = 0x12A
  c_INC_2, -- 0x5C: R(N)+1
  c_STR_2, -- 0x5D: D->M(R(N))(N=2) : addr M(R(2)) will be result of ADD

  -- ADI
  c_INC_2, -- 0x5E: R(N)+1
  c_ADI,   -- 0x5F: M(R(P)) + D -> DF,D; R(P)+1 : result is 0x11A
  X"F0",   -- 0x60:
  c_STR_2, -- 0x61: D->M(R(N))(N=2) : addr M(R(2)) will be result of ADI

  -- ADC
  c_INC_2, -- 0x62: R(N)+1
  c_LDI,   -- 0x63: M(R(P))->D; R(P)+1
  X"2D",   -- 0x64:
  c_ADC,   -- 0x65: M(R(X))+D+DF -> DF, D : 0x3A + 0x2D + DF=1 = 0x68, DF=0
  c_STR_2, -- 0x66: D->M(R(N))(N=2) : addr M(R(2)) will be result of ADC

  -- ADCI
  c_INC_2, -- 0x67: R(N)+1
  c_ADCI,  -- 0x68: M(R(P))+D+DF -> DF,D; R(P)+1 : result is 0x58, DF=1 
  X"F0",   -- 0x69:
  c_STR_2, -- 0x6A: D->M(R(N))(N=2) : addr M(R(2)) will be result of ADCI

  -- SD
  c_INC_2, -- 0x6B: R(N)+1
  c_LDI,   -- 0x6C: M(R(P))->D; R(P)+1
  X"0E",   -- 0x6D:
  c_SD,    -- 0x6E: M(R(X))-D -> DF, D : 0x42 - 0x0E = 0x34, DF=1 (0x42 + 0xF1 + 1 = 0x134)
  c_STR_2, -- 0x6F: D->M(R(N))(N=2) : addr M(R(2)) will be result of SD

  -- SD
  c_INC_2, -- 0x70: R(N)+1
  c_LDI,   -- 0x71: M(R(P))->D; R(P)+1
  X"92",   -- 0x72:
  c_SD,    -- 0x73: M(R(X))-D -> DF, D : 0x57 - 0x92 = 0xC5, DF=0
  c_STR_2, -- 0x74: D->M(R(N))(N=2) : addr M(R(2)) will be result of SD

  -- SDB
  c_INC_2, -- 0x75: R(N)+1
  c_LDI,   -- 0x76: M(R(P))->D; R(P)+1
  X"20",   -- 0x77:
  c_SDB,   -- 0x78: M(R(X))-D-(NOT DF) -> DF, D : 0x40 - 0x20 (borrow=1) = 0x1F, DF=1 (borrow=0)
  c_STR_2, -- 0x79: D->M(R(N))(N=2) : addr M(R(2)) will be result of SDB

  -- SDI
  c_INC_2, -- 0x7A: R(N)+1
  c_SDI,   -- 0x7B: M(R(P)) - D -> DF,D; R(P)+1
  X"F0",   -- 0x7C:
  c_STR_2, -- 0x7D: D->M(R(N))(N=2) : addr M(R(2)) will be result of SDI. 0xF0 - 0x1F = 0xD1, DF=1

  -- SDBI
  c_INC_2, -- 0x7E: R(N)+1
  c_SDBI,  -- 0x7F: M(R(P)) - D - (NOT DF) -> DF,D; R(P)+1 : 0xF0 - 0xD1 (borrow=0) = 0x1F, DF=1 (borrow=0)
  X"F0",   -- 0x80:
  c_STR_2, -- 0x81: D->M(R(N))(N=2) : addr M(R(2)) will be result of SDI


  -- SM
  c_INC_2, -- 0x82: R(N)+1
  c_LDI,   -- 0x83: M(R(P))->D; R(P)+1
  X"92",   -- 0x84:
  c_SM,    -- 0x85: D-M(R(X)) -> DF, D : 0x92 - 0x57 = 0x3B, DF=1
  c_STR_2, -- 0x86: D->M(R(N))(N=2) : addr M(R(2)) will be result of SD

  -- SMBI
  c_INC_2, -- 0x87: R(N)+1
  c_LDI,   -- 0x88: M(R(P))->D; R(P)+1
  X"71",   -- 0x89:
  c_SMBI,  -- 0x8A: D-M(R(P)) - (NOT DF) -> DF,D; R(P)+1 : 0x71 - 0xF2 - DF=1 (borrow=0) = 0x7F, DF=0 (borrow=1)
  X"F2",   -- 0x8B:
  c_STR_2, -- 0x8C: D->M(R(N))(N=2) : addr M(R(2)) will be result of SMBI

  -- SMB
  c_INC_2, -- 0x8D: R(N)+1
  c_LDI,   -- 0x8E: M(R(P))->D; R(P)+1
  X"4A",   -- 0x8F:
  c_SMB,   -- 0x90: D-M(R(X))-(NOT DF) -> DF, D : 0x4A - 0xC1 - DF=0 (borrow=1) = 0x88, DF=0 (borrow=1)
  c_STR_2, -- 0x91: D->M(R(N))(N=2) : addr M(R(2)) will be result of SMB

  -- SMI
  c_INC_2, -- 0x92: R(N)+1
  c_LDI,   -- 0x93: M(R(P))->D; R(P)+1
  X"1B",   -- 0x94:
  c_SMI,   -- 0x95: D-M(R(P)) -> DF,D; R(P)+1 : 0x1B - 0x1A = 0x01, DF=1 (borrow=0)
  X"1A",   -- 0x96:
  c_STR_2, -- 0x97: D->M(R(N))(N=2) : addr M(R(2)) will be result of SMI


  c_BR,    -- 0x98: M(R(P))->R(P).0 : Unconditional short branch
  X"B1",   -- 0x99:

  -- data
  X"57", -- 0x9A: 1st argument for OR = 0x57. will be 0xD7 after
  X"00", -- 0x9B: 0x00 : will be 0xFF after ORI
  X"00", -- 0x9C: 0x00 : will be 0xCC after XOR
  X"00", -- 0x9D: 0x00 : will be 0xE4 after XRI
  X"00", -- 0x9E: 0x00 : will be 0x04 after AND
  X"00", -- 0x9F: 0x00 : will be 0x04 after ANI
  X"00", -- 0xA0: 0x00 : will be 0x42 after SHR
  X"00", -- 0xA1: 0x00 : will be 0x0A after SHL
  X"00", -- 0xA2: 0x00 : will be 0xC2 after RSHR
  X"00", -- 0xA3: 0x00 : will be 0x3A after RSHL
  X"00", -- 0xA4: 0x00 : will be 0x2A after ADD
  X"00", -- 0xA5: 0x00 : will be 0x1A after ADI
  X"3A", -- 0xA6: 0x00 : will be 0x68 after ADC
  X"00", -- 0xA7: 0x00 : will be 0x58 after ADCI

  X"42", -- 0xA8: 0x00 : will be 0x34 after SD
  X"57", -- 0xA9: 0x00 : will be 0xC5 after SD
  X"40", -- 0xAA: 0x00 : will be 0x1F after SDB
  X"00", -- 0xAB: 0x00 : will be 0xD1 after SDI
  X"00", -- 0xAC: 0x00 : will be 0x1F after SDBI
  X"57", -- 0xAD: 0x00 : will be 0x3B after SM
  X"00", -- 0xAE: 0x00 : will be 0x7F after SMBI
  X"C1", -- 0xAF: 0x00 : will be 0x88 after SMB
  X"00", -- 0xB0: 0x00 : will be 0x01 after SMI

  -- testing conditional branches
  c_BQ,  -- 0xB1: IF Q=1, M(R(P))->R(P).0 ELSE R(P)+1
  X"B5", -- 0xB2:
  c_BNZ, -- 0xB3: IF D NOT 0, M(R(P))->R(P).0 ELSE R(P)+1 : (D was 0x01, must jump)
  X"B8", -- 0xB4:
  c_REQ, -- 0xB5: Q=0
  c_BNQ, -- 0xB6: IF Q=0, M(R(P))->R(P).0 ELSE R(P)+1 : (must jump)
  X"B3", -- 0xB7:

  c_BN1, -- 0xB8: IF EF1=0, M(R(P))->R(P).0 ELSE R(P)+1 : (nEF is input as "1110", no jump)
  X"B3", -- 0xB9:
  c_B1,  -- 0xBA: IF EF1=1, M(R(P))->R(P).0 ELSE R(P)+1 : (nEF is input as "1110", jump)
  X"BE", -- 0xBB:
  c_B2,  -- 0xBC: IF EF2=1, M(R(P))->R(P).0 ELSE R(P)+1 : (should not even be here)
  X"B3", -- 0xBD:

  c_LSKP, -- 0xBE: R(P)+2
  c_NOP, -- 0xBF:
  c_NOP, -- 0xC0:
  c_LBR, -- 0xC1: M(R(P))->R(P).1; M(R(P+1))->R(P).0 : jump to next RAM page
  X"01", -- 0xC2: -- jump to address.hi
  X"00", -- 0xC3: -- jump to address.lo

  -- come back from next page (I):
  c_LSNQ, -- 0xC4: -- long skip if Q=0 (must long skip)
  X"00", -- 0xC5:
  X"00", -- 0xC6:
  c_LBNQ, -- 0xC7: -- long branch if Q=0 (must jump to next page)
  X"01", -- 0xC8:
  X"05", -- 0xC9:

  -- come back from next page (II):
  c_LSDF, -- 0xCA: long skip if DF=1 (DF was still 1 , so must long skip)
  X"00", -- 0xCB:
  X"00", -- 0xCC:
  c_LBDF, -- 0xCD: long branch if DF=1 (DF was still 1, so must long branch to next page)
  X"01", -- 0xCE:
  X"0A", -- 0xCF:

  -- come back from this page after setting stackpointer:
  -- set ISR entry point
  c_PHI_1, -- 0xD0: R(1).1=0x00 (D was still 0)
  c_LDI, -- 0xD1:
  X"E2", -- 0xD2:
  c_PLO_1, -- 0xD3: R(1).0 written, pointing to the ISR

  c_SEX_3, -- 0xD4: enable IE
  c_RET,   -- 0xD5: enable IE
  X"23",   -- 0xD6: stack-R2 program-R3
  c_REQ,   -- 0xD7: Q=0

  X"00", -- 0xD8: -- wait for interrupt here


  -- coming back from ISR
  c_LBR, -- 0xD9: -- jump to next page
  X"01", -- 0xDA:
  X"0E", -- 0xDB:

  X"00", -- 0xDC:
  X"00", -- 0xDD:
  X"00", -- 0xDE:
  X"00", -- 0xDF:
  X"00", -- 0xE0:
  X"00", -- 0xE1:

  -- Start of ISR
  c_SAV, -- 0xE2:
  c_SEX_9, -- 0xE3: mess up X
  c_RET, -- 0xE4: -- return from interrupt with interrupts enabled
  -- End of ISR

  X"00", -- 0xE5:
  X"00", -- 0xE6:
  X"00", -- 0xE7:
  X"00", -- 0xE8:
  X"00", -- 0xE9:
  X"00", -- 0xEA:
  X"00", -- 0xEB:
  X"00", -- 0xEC:
  X"00", -- 0xED:
  X"00", -- 0xEE:
  X"00", -- 0xEF:
  X"00", -- 0xF0:
  X"00", -- 0xF1:

  -- come back from next page -- set stackpointer
  c_PHI_2, -- 0xF2: -- D was still 0; write to R2 and R9
  c_PHI_9, -- 0xF3:
  c_LDI, -- 0xF4:
  X"FF", -- 0xF5:
  c_PLO_2, -- 0xF6: -- write to R2 and R9
  c_PLO_9, -- 0xF7:
  c_LDI, -- 0xF8:
  X"00", -- 0xF9:
  c_BZ, -- 0xFA: -- If D=0 jump to setting of R1 (D=0 so should jump!)
  X"D0", -- 0xFB:

  X"00", -- 0xFC:
  X"00", -- 0xFD:
  X"00", -- 0xFE:
  X"00", -- 0xFF: -- Stack start ^

  -- next page:
  c_LDI, -- 0x100: load D
  X"12", -- 0x101:
  c_LBNZ, -- 0x102: if D!=0 jump
  X"00",  -- 0x103:
  X"C4",  -- 0x104:

  c_LDI, -- 0x105: load D
  X"00", -- 0x106:
  c_LBZ, -- 0x107: long branch if D=0 (must long jump!)
  X"00", -- 0x108: back to page 0
  X"CA", -- 0x109:
  c_SEQ, -- 0x10A: Q=1
  c_LBQ, -- 0x10B: long branch if Q=1 (must long jump!)
  X"00", -- 0x10C
  X"F2", -- 0x10D

  -- test OUT, INP
  c_OUT_5, -- 0x10E : output M(R(2)) to output address 5
  c_NOP,  -- 0x10F
  c_INP_D, -- 0x110 : input from input address 5 to M(R(2))
           --         appeared on 0x0100 in ram, which is correct
           --         because c_OUT_5 did a R(X)+1

  c_MARK,  -- 0x111
  -- end program
  c_SEQ, -- 0x112: Q=1
  c_DEC_3  -- 0x113: R(N)-1          : (repeating forever)

);

BEGIN
  PROCESS (address, nCS, nWE, nOE, data_in) IS
    BEGIN
      data_out <= (OTHERS => '0'); -- chip is not selected
      IF (nCS = '0') THEN
        IF nWE = '0' THEN -- write
          ram1(to_integer(unsigned(address))) <= data_in;
        END IF;

        IF nWE = '1' AND nOE = '0' THEN -- read
          data_out <= ram1(to_integer(unsigned(address)));
        ELSE
          data_out <= (OTHERS => '0');
        END IF;
      END IF;
  END PROCESS;
END str;
