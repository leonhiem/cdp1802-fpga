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
--     - The receive side is a stub for future extension: rx_data/
--       rx_data_available are plain inputs (tie rx_data_available='0' if
--       unused), so a testbench can inject received characters later
--       without changing this entity. OE/PE/FE/ES/PSI (Status Register
--       bits 1/2/3/4/5) are tied low -- no error/modem-status conditions
--       are modeled.
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
    -- (doc/CDP1854_UART.md, Table 4/"Interrupts" section): asserted
    -- when IE (Control Register bit 5) is set AND DA or THRE is true.
    -- THRE.TSRE is folded into the THRE term (TSRE is tied permanently
    -- '1' -- see "Deliberate simplifications" above, so THRE alone
    -- already covers it); PSI/CTS edges aren't modeled (no modem-status
    -- inputs exist on this model), so they never contribute.
    -- Known model limitation: because THRE is tied permanently '1'
    -- (this model has no real "busy" state -- see file header), an
    -- IE=1, TX-side-enabled UART will assert nINT continuously, not
    -- just "once THRE next goes true" the way a real chip with genuine
    -- shift-register timing would. Harmless for the receive-driven use
    -- case (DA-triggered, e.g. keyboard input) this was built for; a
    -- future refinement could latch THRE and clear it exactly once per
    -- character written, matching the datasheet's clear-on-write rule.
    nINT : OUT STD_LOGIC
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

BEGIN

  status_reg(0) <= rx_data_available; -- DA
  status_reg(1) <= '0';               -- OE
  status_reg(2) <= '0';               -- PE
  status_reg(3) <= '0';               -- FE
  status_reg(4) <= '0';               -- ES
  status_reg(5) <= '0';               -- PSI
  status_reg(6) <= '1';               -- TSRE (always empty -- see file header)
  status_reg(7) <= '1';               -- THRE (always empty -- see file header)

  p_write : PROCESS (clk) IS
  BEGIN
    IF rising_edge(clk) THEN
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

  -- IE = control_reg(5) -- see Table 4 in doc/CDP1854_UART.md.
  nINT <= '0' WHEN (control_reg(5) = '1' AND
                     (status_reg(0) = '1' OR status_reg(7) = '1'))
          ELSE '1';

  p_read : PROCESS (nCS, nOE, rsel, rx_data, status_reg) IS
  BEGIN
    data_out <= (OTHERS => '0');
    IF nCS = '0' AND nOE = '0' THEN
      IF rsel = '1' THEN
        data_out <= status_reg;
      ELSE
        data_out <= rx_data;
      END IF;
    END IF;
  END PROCESS;

END str;
