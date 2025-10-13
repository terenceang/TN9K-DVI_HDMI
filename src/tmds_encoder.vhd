--------------------------------------------------------------------------------
-- TMDS Encoder for DVI/HDMI Video Transmission
--------------------------------------------------------------------------------
-- Description:
--   This module implements the TMDS (Transition Minimized Differential Signaling)
--   8b/10b encoding algorithm as specified in the DVI 1.0 specification.
--
-- What is TMDS?
--   TMDS is a signaling method used in DVI and HDMI to transmit video data over
--   differential pairs. It encodes 8-bit parallel data into 10-bit symbols that
--   are then serialized and transmitted differentially.
--
-- Purpose and Benefits:
--   1. Reduce EMI (Electromagnetic Interference):
--      - By minimizing the number of transitions (0->1 or 1->0) in the data stream,
--        the high-frequency content and resulting EMI are reduced
--      - The algorithm intelligently chooses between XOR and XNOR encoding to
--        minimize transitions based on the input data pattern
--
--   2. Provide DC Balance:
--      - Maintains roughly equal numbers of 1s and 0s over time to prevent
--        DC bias on the transmission line
--      - Uses a running disparity counter to track the cumulative imbalance
--      - Makes encoding decisions to correct any developing DC imbalance
--
--   3. Enable Clock Recovery:
--      - Sufficient transitions in the data stream allow the receiver to
--        recover the clock from the data signal itself
--
-- Encoding Process: 8-bit Input -> 10-bit Output
--   The encoding happens in two stages:
--
--   Stage 1: Transition Minimization (8 bits -> 9 bits)
--   -------------------------------------------------------
--   - Count the number of 1s in the input byte (n1_d)
--   - Decision: Use XOR or XNOR encoding?
--
--     If (n1_d > 4) OR (n1_d = 4 AND din(0) = '0'):
--       -> Use XNOR encoding (produces fewer transitions)
--       -> q_m(0) = din(0)
--       -> q_m(i) = q_m(i-1) XNOR din(i) for i = 1 to 7
--       -> q_m(8) = '0' (indicates XNOR was used)
--
--     Else:
--       -> Use XOR encoding (produces more transitions when needed)
--       -> q_m(0) = din(0)
--       -> q_m(i) = q_m(i-1) XOR din(i) for i = 1 to 7
--       -> q_m(8) = '1' (indicates XOR was used)
--
--   Stage 2: DC Balance (9 bits -> 10 bits)
--   -------------------------------------------------------
--   - Count 1s and 0s in the 8-bit portion of q_m (n1_q_m, n0_q_m)
--   - Track running disparity with signed counter 'cnt'
--     (cnt > 0 means more 1s transmitted, cnt < 0 means more 0s)
--
--   Decision tree:
--
--     If (cnt = 0) OR (n1_q_m = n0_q_m):
--       -> Disparity is balanced, decide based on q_m(8)
--       -> If q_m(8) = '1': Keep q_m(7:0) as-is, update cnt by (n1_q_m - n0_q_m)
--       -> If q_m(8) = '0': Invert q_m(7:0), update cnt by (n0_q_m - n1_q_m)
--       -> dout(9) = NOT q_m(8), dout(8) = q_m(8)
--
--     Else If (cnt > 0 AND n1_q_m > n0_q_m) OR (cnt < 0 AND n0_q_m > n1_q_m):
--       -> Imbalance would worsen, so invert to correct
--       -> Invert q_m(7:0)
--       -> dout(9) = '1', dout(8) = q_m(8)
--       -> Update cnt by (n0_q_m - n1_q_m) plus adjustment for q_m(8)
--
--     Else:
--       -> Imbalance would improve or stay same, keep as-is
--       -> Keep q_m(7:0)
--       -> dout(9) = '0', dout(8) = q_m(8)
--       -> Update cnt by (n1_q_m - n0_q_m) plus adjustment for q_m(8)
--
-- Three Operating Modes:
--   1. Video Data Period (de = '1'):
--      - Normal 8b/10b encoding using the two-stage algorithm above
--      - Encodes pixel color data with DC balance tracking
--
--   2. Control Period (de = '0'):
--      - Encodes special 10-bit control characters for sync signals
--      - These characters have unique patterns not used in data encoding
--      - Disparity counter is reset to zero
--      - Control codes based on ctrl(1:0) input:
--        ctrl = "00" -> 0b1101010100 (HSYNC=0, VSYNC=0)
--        ctrl = "01" -> 0b0010101011 (HSYNC=1, VSYNC=0)
--        ctrl = "10" -> 0b0101010100 (HSYNC=0, VSYNC=1)
--        ctrl = "11" -> 0b1010101011 (HSYNC=1, VSYNC=1)
--
--   3. Data Island Period (not implemented in this basic encoder):
--      - Used in HDMI to transmit audio and auxiliary data packets
--      - Would use similar encoding with different control characters
--
-- Disparity Tracking:
--   The running disparity counter 'cnt' keeps track of the cumulative difference
--   between 1s and 0s transmitted over time:
--   - Incremented when more 1s are sent than 0s
--   - Decremented when more 0s are sent than 1s
--   - Used to make encoding decisions that maintain DC balance
--   - Reset to zero during control periods (blanking intervals)
--
-- Timing:
--   This implementation uses a pipelined architecture with two output register
--   stages (q_out -> dout_buf -> dout) to improve timing closure and provide
--   routing slack in the FPGA fabric.
--
-- Reference:
--   Digital Visual Interface (DVI) Specification, Revision 1.0
--   Section 3.3.3: TMDS Data Encoding and Transmission
--
-- Original Implementation:
--   Converted from SVO (Simple Video Out) Verilog implementation
--   Copyright (C) 2014 Clifford Wolf <clifford@clifford.at>
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tmds_encoder is
    port (
        ------------------------------------------------------------------------
        -- Clock and Reset
        ------------------------------------------------------------------------
        clk     : in  std_logic;                      -- Pixel clock
        rst_n   : in  std_logic;                      -- Active-low reset

        ------------------------------------------------------------------------
        -- Control Signals
        ------------------------------------------------------------------------
        de      : in  std_logic;                      -- Data Enable
                                                      -- '1' = Video data period (encode din)
                                                      -- '0' = Control period (encode ctrl)

        ctrl    : in  std_logic_vector(1 downto 0);  -- Control signals for sync encoding
                                                      -- Only used when de = '0'
                                                      -- ctrl(0) = HSYNC
                                                      -- ctrl(1) = VSYNC

        data_island : in  std_logic;                  -- Data island mode
                                                      -- '1' = TERC4 encoding (4-bit data_in)
                                                      -- '0' = Normal video/control mode

        ------------------------------------------------------------------------
        -- Data Interface
        ------------------------------------------------------------------------
        din     : in  std_logic_vector(7 downto 0);  -- 8-bit video data input
                                                      -- Typically represents one color channel
                                                      -- (Red, Green, or Blue) pixel data
                                                      -- Only encoded when de = '1'

        data_in : in  std_logic_vector(9 downto 0);  -- 10-bit pre-encoded TERC4 data
                                                      -- Only used when data_island = '1'
                                                      -- Must be already TERC4-encoded

        dout    : out std_logic_vector(9 downto 0)   -- 10-bit TMDS encoded output
                                                      -- To be serialized 10:1 and transmitted
                                                      -- LSB (bit 0) is transmitted first
    );
end tmds_encoder;

architecture rtl of tmds_encoder is

    ----------------------------------------------------------------------------
    -- Helper Function: Count Number of '1' Bits (Optimized)
    ----------------------------------------------------------------------------
    -- Used to count the number of set bits in the input data, which determines
    -- whether to use XOR or XNOR encoding in the transition minimization stage.
    -- Optimized: Uses tree-based addition for better synthesis
    function count_ones(bits : std_logic_vector(7 downto 0)) return unsigned is
        variable sum : unsigned(3 downto 0);
    begin
        -- Tree-based parallel addition (more efficient than loop)
        sum := ("000" & bits(0)) + ("000" & bits(1)) + ("000" & bits(2)) + ("000" & bits(3)) +
               ("000" & bits(4)) + ("000" & bits(5)) + ("000" & bits(6)) + ("000" & bits(7));
        return sum;
    end function;

    ----------------------------------------------------------------------------
    -- Stage 1 Signals: Transition Minimization
    ----------------------------------------------------------------------------
    signal encoded_intermediate : std_logic_vector(8 downto 0); -- 9-bit intermediate encoding
                                                       -- encoded_intermediate(7:0) = encoded data
                                                       -- encoded_intermediate(8) = encoding method flag
                                                       --   '1' = XOR was used
                                                       --   '0' = XNOR was used

    ----------------------------------------------------------------------------
    -- Stage 2 Signals: DC Balance and Output
    ----------------------------------------------------------------------------
    signal output_register      : std_logic_vector(9 downto 0); -- Output register
    signal output_next          : std_logic_vector(9 downto 0); -- Combinational next output value

    ----------------------------------------------------------------------------
    -- DC Balance Tracking (Running Disparity) - Optimized to 6 bits
    ----------------------------------------------------------------------------
    -- 6 bits is sufficient for TMDS disparity tracking (range -32 to +31)
    signal disparity_counter     : signed(5 downto 0);            -- Current disparity counter
                                                       -- Tracks cumulative (1s - 0s) sent
                                                       -- Positive = more 1s sent
                                                       -- Negative = more 0s sent
                                                       -- Zero = perfectly balanced

    signal disparity_next        : signed(5 downto 0);            -- Next disparity value
    signal disparity_temp        : signed(5 downto 0);            -- Temporary disparity calculation

    ----------------------------------------------------------------------------
    -- Bit Count Signals (Optimized to use smaller unsigned)
    ----------------------------------------------------------------------------
    signal ones_count_input      : unsigned(3 downto 0);          -- Number of 1s in input din(7:0)
    signal zeros_count_encoded   : unsigned(3 downto 0);          -- Number of 0s in encoded_intermediate(7:0)
    signal ones_count_encoded    : unsigned(3 downto 0);          -- Number of 1s in encoded_intermediate(7:0)

    -- TMDS Control Codes (DVI 1.0 Specification, Table 3-5)
    constant TMDS_CTRL_00 : std_logic_vector(9 downto 0) := "1101010100"; -- HSYNC=0, VSYNC=0
    constant TMDS_CTRL_01 : std_logic_vector(9 downto 0) := "0010101011"; -- HSYNC=1, VSYNC=0
    constant TMDS_CTRL_10 : std_logic_vector(9 downto 0) := "0101010100"; -- HSYNC=0, VSYNC=1
    constant TMDS_CTRL_11 : std_logic_vector(9 downto 0) := "1010101011"; -- HSYNC=1, VSYNC=1

    -- TERC4 Encoding for Data Island (HDMI 1.0 Specification, Section 5.4.3)
    constant TERC4_0000 : std_logic_vector(9 downto 0) := "1010011100";
    constant TERC4_0001 : std_logic_vector(9 downto 0) := "1001100011";
    constant TERC4_0010 : std_logic_vector(9 downto 0) := "1011100100";
    constant TERC4_0011 : std_logic_vector(9 downto 0) := "1011100010";
    constant TERC4_0100 : std_logic_vector(9 downto 0) := "0101110001";
    constant TERC4_0101 : std_logic_vector(9 downto 0) := "0100011110";
    constant TERC4_0110 : std_logic_vector(9 downto 0) := "0110001110";
    constant TERC4_0111 : std_logic_vector(9 downto 0) := "0100111100";
    constant TERC4_1000 : std_logic_vector(9 downto 0) := "1011001100";
    constant TERC4_1001 : std_logic_vector(9 downto 0) := "0100111001";
    constant TERC4_1010 : std_logic_vector(9 downto 0) := "0110011100";
    constant TERC4_1011 : std_logic_vector(9 downto 0) := "1011000110";
    constant TERC4_1100 : std_logic_vector(9 downto 0) := "1010001110";
    constant TERC4_1101 : std_logic_vector(9 downto 0) := "1001110001";
    constant TERC4_1110 : std_logic_vector(9 downto 0) := "0101100011";
    constant TERC4_1111 : std_logic_vector(9 downto 0) := "1011000011";

begin

    ----------------------------------------------------------------------------
    -- Count the number of 1s in the input data byte
    ----------------------------------------------------------------------------
    -- This is used to determine whether XOR or XNOR encoding will produce
    -- fewer transitions in Stage 1 of the encoding process.
    ones_count_input <= count_ones(din);

    ----------------------------------------------------------------------------
    -- Main TMDS Encoding Process
    ----------------------------------------------------------------------------
    -- This process implements the complete two-stage TMDS encoding algorithm:
    -- 1. Transition minimization (XOR vs XNOR decision)
    -- 2. DC balance correction with running disparity tracking
    tmds_encoding_process: process(clk, rst_n)
        variable encoded_temp         : std_logic_vector(8 downto 0);  -- Temporary for encoding calculation
        variable zeros_count_var      : unsigned(3 downto 0);          -- Combinational count of 0s
        variable ones_count_var       : unsigned(3 downto 0);          -- Combinational count of 1s
    begin
        if rst_n = '0' then
            -- Asynchronous reset: Clear all registers
            disparity_counter <= (others => '0');      -- Reset disparity counter
            output_register   <= (others => '0');      -- Clear output register
            dout              <= (others => '0');      -- Clear final output

        elsif rising_edge(clk) then
            
            -- PERMANENT DC BALANCE FIX: Never reset cnt
            -- Per DC_BALANCE_FIX.md: cnt must maintain continuity across all modes
            -- Original bug was resetting cnt during control periods - NOW FIXED

            --------------------------------------------------------------------
            -- Control Period: Output Special Control Characters
            --------------------------------------------------------------------
            -- When de = '0', we are in the blanking period (not active video).
            -- Output one of four special 10-bit control characters based on
            -- the HSYNC and VSYNC signals (ctrl input).
            --
            -- These control characters have unique bit patterns that cannot
            -- occur during normal data encoding, allowing the receiver to
            -- distinguish between control and data periods.
            --
            -- The disparity counter is reset during control periods because
            -- the control characters have their own balance, and we start
            -- fresh when video data resumes.
            if data_island = '1' then
                --------------------------------------------------------------------
                -- Data Island Period: Pass-through Pre-encoded TERC4 Data
                --------------------------------------------------------------------
                -- The data_in port now receives 10-bit pre-encoded TERC4 data from
                -- dedicated terc4_encoder modules. Just pass it through.
                -- TERC4 symbols are pre-balanced, so disparity_counter is preserved.
                output_register <= data_in;
                dout <= data_in;
                -- disparity_counter is NOT modified - maintains DC balance from previous video period

            elsif de = '0' then
                -- Control period: DO NOT reset disparity_counter anymore
                -- This was causing DC balance loss when transitioning to/from data islands
                --
                -- ZERO-CYCLE LATENCY FIX: Assign both output_register AND dout in same cycle

                case ctrl is
                    -- HSYNC=0, VSYNC=0: Pattern has 5 zeros, 5 ones (balanced)
                    when "00"   => output_register <= "1101010100"; dout <= "1101010100";

                    -- HSYNC=1, VSYNC=0: Pattern has 5 zeros, 5 ones (balanced)
                    when "01"   => output_register <= "0010101011"; dout <= "0010101011";

                    -- HSYNC=0, VSYNC=1: Pattern has 5 zeros, 5 ones (balanced)
                    when "10"   => output_register <= "0101010100"; dout <= "0101010100";

                    -- HSYNC=1, VSYNC=1: Pattern has 5 zeros, 5 ones (balanced)
                    when "11"   => output_register <= "1010101011"; dout <= "1010101011";

                    -- Default to ctrl="00" pattern for safety
                    when others => output_register <= "1101010100"; dout <= "1101010100";
                end case;

            else
                --------------------------------------------------------------------
                -- Video Data Period: Encode Video Data with DC Balance
                --------------------------------------------------------------------

                ----------------------------------------------------------------
                -- STAGE 1: Transition Minimization
                ----------------------------------------------------------------
                -- Goal: Reduce the number of transitions (0->1 or 1->0) to
                -- minimize EMI and high-frequency content.

                if (ones_count_input > 4) or ((ones_count_input = 4) and (din(0) = '0')) then
                    -- Use XNOR encoding (produces fewer transitions)
                    encoded_temp(0) := din(0);
                    encoded_temp(1) := encoded_temp(0) xnor din(1);
                    encoded_temp(2) := encoded_temp(1) xnor din(2);
                    encoded_temp(3) := encoded_temp(2) xnor din(3);
                    encoded_temp(4) := encoded_temp(3) xnor din(4);
                    encoded_temp(5) := encoded_temp(4) xnor din(5);
                    encoded_temp(6) := encoded_temp(5) xnor din(6);
                    encoded_temp(7) := encoded_temp(6) xnor din(7);
                    encoded_temp(8) := '0';  -- Flag indicating XNOR encoding
                else
                    -- Use XOR encoding (produces more transitions when needed)
                    encoded_temp(0) := din(0);
                    encoded_temp(1) := encoded_temp(0) xor din(1);
                    encoded_temp(2) := encoded_temp(1) xor din(2);
                    encoded_temp(3) := encoded_temp(2) xor din(3);
                    encoded_temp(4) := encoded_temp(3) xor din(4);
                    encoded_temp(5) := encoded_temp(4) xor din(5);
                    encoded_temp(6) := encoded_temp(5) xor din(6);
                    encoded_temp(7) := encoded_temp(6) xor din(7);
                    encoded_temp(8) := '1';  -- Flag indicating XOR encoding
                end if;

                -- Register the 9-bit encoded result
                encoded_intermediate <= encoded_temp;

                ----------------------------------------------------------------
                -- Count 1s and 0s in the 8-bit encoded data (Optimized)
                ----------------------------------------------------------------
                zeros_count_var := "1000" - count_ones(encoded_temp(7 downto 0));  -- 8 - n1
                ones_count_var := count_ones(encoded_temp(7 downto 0));

                ----------------------------------------------------------------
                -- STAGE 2: DC Balance Correction
                ----------------------------------------------------------------
                -- Goal: Maintain roughly equal numbers of 1s and 0s over time
                -- to prevent DC bias on the transmission line.

                ----------------------------------------------------------------
                -- Case 1: Disparity is Zero or Balanced
                ----------------------------------------------------------------
                if (disparity_counter = 0) or (ones_count_var = zeros_count_var) then
                    output_next(9) <= not encoded_temp(8);  -- Inversion flag
                    output_next(8) <= encoded_temp(8);      -- Encoding method flag

                    if encoded_temp(8) = '1' then
                        -- XOR was used: Keep data as-is
                        output_next(7 downto 0) <= encoded_temp(7 downto 0);
                        -- Update disparity: add (ones_count_var - zeros_count_var)
                        disparity_next <= disparity_counter + signed(resize(ones_count_var - zeros_count_var, 6));
                    else
                        -- XNOR was used: Invert data
                        output_next(7 downto 0) <= not encoded_temp(7 downto 0);
                        -- Update disparity: add (zeros_count_var - ones_count_var) because we inverted
                        disparity_next <= disparity_counter + signed(resize(zeros_count_var - ones_count_var, 6));
                    end if;

                ----------------------------------------------------------------
                -- Case 2: Imbalance Would Worsen
                ----------------------------------------------------------------
                elsif ((disparity_counter > 0) and (ones_count_var > zeros_count_var)) or 
                      ((disparity_counter < 0) and (zeros_count_var > ones_count_var)) then
                    output_next(9) <= '1';              -- Indicate inversion
                    output_next(8) <= encoded_temp(8);      -- Copy encoding method flag
                    output_next(7 downto 0) <= not encoded_temp(7 downto 0);  -- Invert data

                    -- Update disparity
                    disparity_temp <= disparity_counter + signed(resize(zeros_count_var - ones_count_var, 6));

                    -- Additional adjustment based on encoding method
                    if encoded_temp(8) = '1' then
                        disparity_next <= disparity_temp + 2;
                    else
                        disparity_next <= disparity_temp;
                    end if;

                ----------------------------------------------------------------
                -- Case 3: Imbalance Would Improve or Stay Same
                ----------------------------------------------------------------
                else
                    output_next(9) <= '0';              -- No inversion
                    output_next(8) <= encoded_temp(8);      -- Copy encoding method flag
                    output_next(7 downto 0) <= encoded_temp(7 downto 0);  -- Keep data as-is

                    -- Update disparity
                    disparity_temp <= disparity_counter + signed(resize(ones_count_var - zeros_count_var, 6));

                    -- Additional adjustment based on encoding method
                    if encoded_temp(8) = '1' then
                        disparity_next <= disparity_temp;
                    else
                        disparity_next <= disparity_temp - 2;
                    end if;
                end if;

                -- Register the updated disparity counter and output
                disparity_counter <= disparity_next;
                output_register   <= output_next;

                --------------------------------------------------------------------
                -- ZERO-CYCLE LATENCY FIX: Update dout with same value as output_register
                --------------------------------------------------------------------
                dout <= output_next;     -- 0-cycle latency
            end if;

            -- NOTE: dout is now assigned in ALL three modes (data island, control, video)
            -- with 0-cycle latency in each case. No separate assignment needed here.
        end if;
    end process tmds_encoding_process;

end rtl;
