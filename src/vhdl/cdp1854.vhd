-------------------------------------------------------------------------------
--
-- File Name: cdp1854.vhd
-- Author: Leon Hiemstra
--
-- Title: CDP1854 UART -- register-level model (Mode 1)
--
-- License: MIT
--
-- Description:
--   A register-compatible model of the real CDP1854 UART chip used on the
--   CS1800's SIO board (see doc/CS1800_HARDWARE.md and doc/CDP1854_UART.md
--   in the repo for the real hardware this is modeling, and
--   doc/PRCX18_ANALYSIS.md for the real firmware behavior this was built
--   to satisfy). This is a register-transfer-level model, not a
--   gate-level reverse engineering like the CDP1802 core -- real firmware
--   only depends on the register map and status/control semantics below,
--   confirmed against both the actual datasheet and the real PRCX-18 ROM's
--   own driver code.
--
--   Register selection (the real chip's RSEL pin, Table 3 of the
--   datasheet): rsel='0' selects the Transmitter/Receiver Holding
--   register pair (data), rsel='1' selects the Control/Status register
--   pair. On the real CS1800 SIO board this is driven by a separate,
--   software-managed selector (see cs1800_io_select.vhd) rather than a
--   dedicated hardware address bit -- this entity doesn't need to know
--   that; it just takes rsel as an ordinary input, exactly like nCS/nWE/
--   nOE.
--
--   Deliberate simplifications (this model targets register-protocol
--   correctness -- reaching a real boot prompt in simulation -- not real
--   serial-bit timing or hardware bring-up):
--     - No real bit-serial shift register or baud-rate timing is modeled.
--       A byte written to the Transmitter Holding register (rsel='0')
--       appears immediately on tx_data/tx_data_valid; THRE and TSRE
--       (Status Register bits 7/6) are tied permanently high as a result
--       -- the model is always "instantly" ready to accept the next
--       character.
--     - The Control Register's individual fields (word length, parity,
--       stop bits, IE, BREAK, TR) are latched but not otherwise acted
--       on -- nothing in this model's behavior depends on them yet.
--     - The receive side latches on a rising edge of rx_data_available
--       (a real byte "just arrived" event -- see p_receive below) into
--       an internal Receiver Holding Register/DA flip-flop, cleared on
--       a genuine CPU read of the Data register (rsel='0'), matching
--       the real datasheet's own "DA cleared by: read of Data, TPB
--       leading edge" rule (Table 1) -- fixed 2026-09-18 after real
--       hardware testing (see BRINGUP_LOG.md) found the previous plain
--       level-follow (status_reg(0) <= rx_data_available, no read-
--       clear at all) meant an external hold longer than the CPU's own
--       read-and-move-on time made every subsequent ~680Hz poll see
--       "another new byte" indefinitely, causing real, reproducible
--       disruption on real hardware (Console Task restarts, output
--       corruption) -- not evidence PRCX-18 ignores DA, just a missing
--       clear-on-read in this model. OE/PE/FE/ES/PSI (Status Register
--       bits 1/2/3/4/5) are still tied low -- no error/modem-status
--       conditions are modeled (in particular, a second
--       rx_data_available edge arriving before the first is read does
--       NOT set OE here, unlike a real chip -- deliberately out of
--       scope for now).
--
-- FPGA note: clocked on tpb (mapped to the "clk" port here), matching
-- this codebase's existing io_out.vhd convention for IO peripherals --
-- TPB is the CDP1802's own "data valid, safe to latch" timing pulse for
-- an OUT instruction, and is held stable for a full CLOCK period each
-- machine cycle (see control.vhd), so a single rising-edge capture on it
-- is a clean, glitch-free register load. (This is a different situation
-- from ram.vhd's async-write-latch hardware bug from earlier in this
-- project's bring-up -- io_out.vhd's rising_edge(clk)-based design was
-- never the async/level-sensitive pattern that caused that.)
--
-------------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.std_logic_1164.ALL;
USE IEEE.numeric_std.ALL;


ENTITY cdp1854 IS
  PORT (
    clk      : IN  STD_LOGIC; -- driven by TPB -- see FPGA note above
    -- Master Reset (active high here), modeling the real chip's pin 21
    -- (nMR). On the real SIO board it is driven by bit 7 of the CD4076
    -- latch at OUT 11 (N=1, Q=1), through an inverter -- per the
    -- user's own schematic reading. PRCX-18 pulses it once, early in
    -- boot: `OUT 1, 0x80` at ROM 0x0023, cleared again by the next
    -- OUT 1. Clears da_reg and control_reg asynchronously (this entity
    -- is otherwise clocked by TPB only, which doesn't run while the CPU
    -- is held in reset). Defaults to '0' (inactive) so instantiations
    -- that don't map it are unaffected.
    --
    -- Note: this was added 2026-09-18 while chasing what looked like DA
    -- stuck at 1 -- a misreading: status_reg's THRE/TSRE are hard-wired
    -- '1' here, so 0xC0 is the idle value (DA=0) and 0xC1 is DA=1. The
    -- reset is kept because it matches the real hardware, not because
    -- it fixed a bug.
    reset    : IN  STD_LOGIC := '0';
    data_in  : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
    -- FPGA note: driven '0' when not selected/reading, so the parent
    -- that shares this bus can OR-merge it with other drivers instead of
    -- relying on tri-state resolution (matching io_inp.vhd's convention).
    data_out : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    nCS      : IN  STD_LOGIC; -- '0' when this chip is addressed
    rsel     : IN  STD_LOGIC; -- '0' = Data register pair, '1' = Status/Control pair
    nWE      : IN  STD_LOGIC; -- '0' during an OUT (CPU write)
    nOE      : IN  STD_LOGIC; -- '0' during an INP (CPU read)

    -- Receive side: see "Deliberate simplifications" above.
    rx_data           : IN STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    rx_data_available : IN STD_LOGIC := '0';

    -- Transmit side: a byte lands here the instant firmware writes the
    -- Transmitter Holding register (rsel='0'); tx_data_valid pulses for
    -- one clk cycle. See "Deliberate simplifications" above.
    tx_data       : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    tx_data_valid : OUT STD_LOGIC;

    -- Interrupt output (real chip's INT pin, open-drain active-low on
    -- the real hardware -- modeled here as an ordinary active-low
    -- output, matching nCS/nWE/nOE's convention). Per the datasheet
    -- (doc/CDP1854_UART.md, Table 4/"Interrupts" section), a real chip
    -- asserts this when IE (Control Register bit 5) is set AND DA or
    -- THRE is true -- but this model only gates on DA (Data Available,
    -- the receive-driven case this was built for -- see cs1800.vhd/
    -- cs1800_prcx18_top.vhd's interrupt-wiring notes). THRE is
    -- deliberately NOT part of this condition: it's tied permanently
    -- '1' (this model has no real "busy" state -- see "Deliberate
    -- simplifications" above), so gating on it would assert nINT
    -- continuously and permanently the instant IE is ever set, with no
    -- way to clear it -- confirmed as a real hardware-only failure
    -- 2026-09-15 (see BRINGUP_LOG.md): the real ROM's own boot-time
    -- device-clear sweep (doc/PRCX18_ANALYSIS.md) writes whatever
    -- uninitialized RAM garbage it finds to every I/O port, including
    -- this UART's Control Register -- if that garbage byte happens to
    -- have IE=1, an always-true THRE term would storm the CPU with
    -- interrupts before it ever reaches real console code. A future
    -- refinement could latch THRE and clear it exactly once per
    -- character written, matching the datasheet's clear-on-write rule,
    -- if the transmit side ever needs real interrupt-driven output.
    nINT : OUT STD_LOGIC;

    -- Debug taps, 2026-09-16 (see BRINGUP_LOG.md's "keystroke
    -- injection" entries): direct, unconditional visibility into
    -- control_reg/status_reg -- specifically to measure IE
    -- (control_reg(5)) and DA (status_reg(0)) on real hardware
    -- directly, rather than continuing to infer IE's real value from
    -- disassembly alone (already flagged inconclusive) or from nINT/
    -- EF2 staying inactive (consistent with IE=0, but doesn't rule out
    -- a wiring bug elsewhere -- this settles it directly). No real
    -- chip pin -- purely additive.
    dbg_control_reg : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    dbg_status_reg  : OUT STD_LOGIC_VECTOR(7 DOWNTO 0)
  );
END cdp1854;

ARCHITECTURE str OF cdp1854 IS

  -- Latched but not otherwise acted on yet -- see file header. Kept as a
  -- real register (not just discarded) so a future extension (e.g.
  -- honoring TR/BREAK) has something to read.
  SIGNAL control_reg : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');

  -- Status Register bit assignment, Table 2 of the CDP1854 datasheet
  -- (doc/CDP1854_UART.md): THRE(7) TSRE(6) PSI(5) ES(4) FE(3) PE(2) OE(1) DA(0).
  SIGNAL status_reg : STD_LOGIC_VECTOR(7 DOWNTO 0);

  SIGNAL tx_data_valid_i : STD_LOGIC := '0';

  -- Receiver Holding Register + DA flip-flop -- see file header and
  -- p_receive below. da_reg (not the raw rx_data_available input) is
  -- what status_reg(0) actually reflects.
  SIGNAL rx_holding_reg      : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL da_reg              : STD_LOGIC := '0';
  SIGNAL rx_data_available_d : STD_LOGIC := '0'; -- one-cycle-delayed, for edge detect

BEGIN

  status_reg(0) <= da_reg; -- DA
  status_reg(1) <= '0';               -- OE
  status_reg(2) <= '0';               -- PE
  status_reg(3) <= '0';               -- FE
  status_reg(4) <= '0';               -- ES
  status_reg(5) <= '0';               -- PSI
  status_reg(6) <= '1';               -- TSRE (always empty -- see file header)
  status_reg(7) <= '1';               -- THRE (always empty -- see file header)

  p_write : PROCESS (clk, reset) IS
  BEGIN
    IF reset = '1' THEN
      control_reg <= (OTHERS => '0');
    ELSIF rising_edge(clk) THEN
      tx_data_valid_i <= '0';
      IF nCS = '0' AND nWE = '0' THEN
        IF rsel = '1' THEN
          control_reg <= data_in;
        ELSE
          tx_data         <= data_in;
          tx_data_valid_i <= '1';
        END IF;
      END IF;
    END IF;
  END PROCESS;

  tx_data_valid <= tx_data_valid_i;

  -- Receiver Holding Register + DA: latch on a rising edge of
  -- rx_data_available (a real byte "just arrived" event), clear only
  -- on a genuine CPU read of the Data register -- see file header.
  -- Both conditions are checked at the same TPB-driven clock this
  -- whole entity already uses, matching the datasheet's "TPB leading
  -- edge" clear timing exactly. If both happen on the same edge (an
  -- edge arriving in the same cycle as a read), the new arrival wins
  -- (DA stays set) -- an edge case that can't actually occur from
  -- this model's own external injection protocol (set-then-clear is
  -- always a separate, later write), listed here for completeness.
  p_receive : PROCESS (clk, reset) IS
  BEGIN
    IF reset = '1' THEN
      da_reg               <= '0';
      rx_data_available_d  <= '0';
    ELSIF rising_edge(clk) THEN
      rx_data_available_d <= rx_data_available;

      IF nCS = '0' AND nOE = '0' AND rsel = '0' THEN
        da_reg <= '0';
      END IF;

      IF rx_data_available = '1' AND rx_data_available_d = '0' THEN
        rx_holding_reg <= rx_data;
        da_reg         <= '1';
      END IF;
    END IF;
  END PROCESS;

  dbg_control_reg <= control_reg;
  dbg_status_reg  <= status_reg;

  -- IE = control_reg(5) -- see Table 4 in doc/CDP1854_UART.md. DA
  -- only -- see nINT's own port comment above for why THRE is excluded.
  nINT <= '0' WHEN (control_reg(5) = '1' AND status_reg(0) = '1') ELSE '1';

  p_read : PROCESS (nCS, nOE, rsel, rx_holding_reg, status_reg) IS
  BEGIN
    data_out <= (OTHERS => '0');
    IF nCS = '0' AND nOE = '0' THEN
      IF rsel = '1' THEN
        data_out <= status_reg;
      ELSE
        data_out <= rx_holding_reg;
      END IF;
    END IF;
  END PROCESS;

END str;
