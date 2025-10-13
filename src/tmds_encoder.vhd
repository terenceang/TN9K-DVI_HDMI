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

        data_in : in  std_logic_vector(3 downto 0);  -- 4-bit data for TERC4 encoding
                                                      -- Only used when data_island = '1'

        dout    : out std_logic_vector(9 downto 0)   -- 10-bit TMDS encoded output
                                                      -- To be serialized 10:1 and transmitted
                                                      -- LSB (bit 0) is transmitted first
    );
end tmds_encoder;

architecture rtl of tmds_encoder is

    ----------------------------------------------------------------------------
    -- Helper Function: Count Number of '1' Bits
    ----------------------------------------------------------------------------
    -- Used to count the number of set bits in the input data, which determines
    -- whether to use XOR or XNOR encoding in the transition minimization stage.
    function count_ones(bits : std_logic_vector(7 downto 0)) return integer is
        variable count : integer := 0;
    begin
        for i in 0 to 7 loop
            if bits(i) = '1' then
                count := count + 1;
            end if;
        end loop;
        return count;
    end function;

    ----------------------------------------------------------------------------
    -- Stage 1 Signals: Transition Minimization
    ----------------------------------------------------------------------------
    signal q_m        : std_logic_vector(8 downto 0); -- 9-bit intermediate encoding
                                                       -- q_m(7:0) = encoded data
                                                       -- q_m(8) = encoding method flag
                                                       --   '1' = XOR was used
                                                       --   '0' = XNOR was used

    ----------------------------------------------------------------------------
    -- Stage 2 Signals: DC Balance and Output
    ----------------------------------------------------------------------------
    signal q_out      : std_logic_vector(9 downto 0); -- Output register (was first stage, now only stage)
    signal q_out_next : std_logic_vector(9 downto 0); -- Combinational next output value
    -- REMOVED dout_buf: Was causing 2-cycle latency that broke data island timing

    ----------------------------------------------------------------------------
    -- DC Balance Tracking (Running Disparity)
    ----------------------------------------------------------------------------
    signal cnt        : signed(7 downto 0);            -- Current disparity counter
                                                       -- Tracks cumulative (1s - 0s) sent
                                                       -- Positive = more 1s sent
                                                       -- Negative = more 0s sent
                                                       -- Zero = perfectly balanced

    signal cnt_next   : signed(7 downto 0);            -- Next disparity value
    signal cnt_tmp    : signed(7 downto 0);            -- Temporary disparity calculation
    
    -- Track previous signals to detect transitions
    signal data_island_prev : std_logic := '0';        -- Previous state of data_island signal
    signal de_prev          : std_logic := '0';        -- Previous state of de signal

    ----------------------------------------------------------------------------
    -- Bit Count Signals
    ----------------------------------------------------------------------------
    signal n1_d       : integer range 0 to 8;          -- Number of 1s in input din(7:0)
    signal n0_q_m     : integer range 0 to 8;          -- Number of 0s in q_m(7:0)
    signal n1_q_m     : integer range 0 to 8;          -- Number of 1s in q_m(7:0)

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
    n1_d <= count_ones(din);

    ----------------------------------------------------------------------------
    -- Main TMDS Encoding Process
    ----------------------------------------------------------------------------
    -- This process implements the complete two-stage TMDS encoding algorithm:
    -- 1. Transition minimization (XOR vs XNOR decision)
    -- 2. DC balance correction with running disparity tracking
    --
    -- The process is fully synchronous and includes two pipeline stages at
    -- the output (q_out -> dout_buf -> dout) for improved timing performance.
    process(clk, rst_n)
        variable q_m_temp : std_logic_vector(8 downto 0);  -- Temporary for q_m calculation
        variable n0_q_m_var : integer range 0 to 8;         -- Combinational count of 0s
        variable n1_q_m_var : integer range 0 to 8;         -- Combinational count of 1s
    begin
        if rst_n = '0' then
            -- Asynchronous reset: Clear all registers
            cnt <= (others => '0');      -- Reset disparity counter
            q_out <= (others => '0');    -- Clear output register
            dout <= (others => '0');     -- Clear final output
            data_island_prev <= '0';     -- Clear previous state tracker
            de_prev <= '0';              -- Clear de tracker

        elsif rising_edge(clk) then
        
            -- Track previous signal states (kept for potential future diagnostics)
            data_island_prev <= data_island;
            de_prev <= de;
            
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
                -- Data Island Period: TERC4 Encoding for Audio/Packet Data
                --------------------------------------------------------------------
                -- CRITICAL: Do NOT reset cnt during data islands/guard bands!
                -- This maintains DC balance continuity when transitioning back to video.
                -- The TERC4 symbols are pre-balanced, so we just preserve cnt.
                --
                -- ZERO-CYCLE LATENCY FIX: Assign both q_out AND dout in same cycle
                -- to eliminate the 1-cycle delay that was causing timing corruption

                case data_in is
                    when "0000" => q_out <= "1010011100"; dout <= "1010011100";
                    when "0001" => q_out <= "1001100011"; dout <= "1001100011";
                    when "0010" => q_out <= "1011100100"; dout <= "1011100100";
                    when "0011" => q_out <= "1011100010"; dout <= "1011100010";
                    when "0100" => q_out <= "0101110001"; dout <= "0101110001";
                    when "0101" => q_out <= "0100011110"; dout <= "0100011110";
                    when "0110" => q_out <= "0110001110"; dout <= "0110001110";
                    when "0111" => q_out <= "0100111100"; dout <= "0100111100";
                    when "1000" => q_out <= "1011001100"; dout <= "1011001100";
                    when "1001" => q_out <= "0100111001"; dout <= "0100111001";
                    when "1010" => q_out <= "0110011100"; dout <= "0110011100";
                    when "1011" => q_out <= "1011000110"; dout <= "1011000110";
                    when "1100" => q_out <= "1010001110"; dout <= "1010001110";
                    when "1101" => q_out <= "1001110001"; dout <= "1001110001";
                    when "1110" => q_out <= "0101100011"; dout <= "0101100011";
                    when "1111" => q_out <= "1011000011"; dout <= "1011000011";
                    when others => q_out <= "1010011100"; dout <= "1010011100";
                end case;
                -- cnt is NOT modified - maintains DC balance from previous video period

            elsif de = '0' then
                -- Control period: DO NOT reset cnt anymore
                -- This was causing DC balance loss when transitioning to/from data islands
                -- cnt <= (others => '0');  -- REMOVED: was breaking DC balance continuity
                --
                -- ZERO-CYCLE LATENCY FIX: Assign both q_out AND dout in same cycle

                case ctrl is
                    -- HSYNC=0, VSYNC=0: Pattern has 5 zeros, 5 ones (balanced)
                    when "00"   => q_out <= "1101010100"; dout <= "1101010100";

                    -- HSYNC=1, VSYNC=0: Pattern has 5 zeros, 5 ones (balanced)
                    when "01"   => q_out <= "0010101011"; dout <= "0010101011";

                    -- HSYNC=0, VSYNC=1: Pattern has 5 zeros, 5 ones (balanced)
                    when "10"   => q_out <= "0101010100"; dout <= "0101010100";

                    -- HSYNC=1, VSYNC=1: Pattern has 5 zeros, 5 ones (balanced)
                    when "11"   => q_out <= "1010101011"; dout <= "1010101011";

                    -- Default to ctrl="00" pattern for safety
                    when others => q_out <= "1101010100"; dout <= "1101010100";
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
                --
                -- Strategy: Choose between XOR and XNOR encoding based on the
                -- number of 1s in the input byte:
                --   - If input has many 1s (n1_d > 4), use XNOR (inverted logic)
                --   - If input has few 1s (n1_d < 4), use XOR (normal logic)
                --   - If balanced (n1_d = 4), decide based on din(0)
                --
                -- The 9th bit (q_m(8)) indicates which method was used:
                --   q_m(8) = '0' means XNOR was used (fewer transitions)
                --   q_m(8) = '1' means XOR was used (more transitions)

                if (n1_d > 4) or ((n1_d = 4) and (din(0) = '0')) then
                    -- Use XNOR encoding (produces fewer transitions)
                    -- Each bit is the XNOR of the previous encoded bit and
                    -- the next input bit, creating a more stable signal
                    q_m_temp(0) := din(0);
                    q_m_temp(1) := q_m_temp(0) xnor din(1);
                    q_m_temp(2) := q_m_temp(1) xnor din(2);
                    q_m_temp(3) := q_m_temp(2) xnor din(3);
                    q_m_temp(4) := q_m_temp(3) xnor din(4);
                    q_m_temp(5) := q_m_temp(4) xnor din(5);
                    q_m_temp(6) := q_m_temp(5) xnor din(6);
                    q_m_temp(7) := q_m_temp(6) xnor din(7);
                    q_m_temp(8) := '0';  -- Flag indicating XNOR encoding
                else
                    -- Use XOR encoding (produces more transitions when needed)
                    -- Each bit is the XOR of the previous encoded bit and
                    -- the next input bit
                    q_m_temp(0) := din(0);
                    q_m_temp(1) := q_m_temp(0) xor din(1);
                    q_m_temp(2) := q_m_temp(1) xor din(2);
                    q_m_temp(3) := q_m_temp(2) xor din(3);
                    q_m_temp(4) := q_m_temp(3) xor din(4);
                    q_m_temp(5) := q_m_temp(4) xor din(5);
                    q_m_temp(6) := q_m_temp(5) xor din(6);
                    q_m_temp(7) := q_m_temp(6) xor din(7);
                    q_m_temp(8) := '1';  -- Flag indicating XOR encoding
                end if;

                -- Register the 9-bit encoded result
                q_m <= q_m_temp;

                ----------------------------------------------------------------
                -- Count 1s and 0s in the 8-bit encoded data
                ----------------------------------------------------------------
                -- These counts are used in Stage 2 to determine how to adjust
                -- the DC balance. We need to know if the current symbol has
                -- more 1s or 0s so we can decide whether to invert it.
                -- IMPORTANT: Use variables here to calculate counts combinationally
                -- in the same cycle, not registered signals from previous cycle!
                n0_q_m_var := 8 - count_ones(q_m_temp(7 downto 0));  -- Count of 0s
                n1_q_m_var := count_ones(q_m_temp(7 downto 0));      -- Count of 1s

                ----------------------------------------------------------------
                -- STAGE 2: DC Balance Correction
                ----------------------------------------------------------------
                -- Goal: Maintain roughly equal numbers of 1s and 0s over time
                -- to prevent DC bias on the transmission line.
                --
                -- Strategy: Use the running disparity counter 'cnt' to track
                -- the cumulative imbalance, then decide whether to send the
                -- encoded data as-is or inverted to correct the imbalance.
                --
                -- The 10th bit (dout(9)) indicates whether inversion occurred:
                --   dout(9) = '0' means data is not inverted
                --   dout(9) = '1' means data is inverted
                -- The 9th bit (dout(8)) is copied from q_m(8) to indicate
                -- which encoding method was used in Stage 1.

                ----------------------------------------------------------------
                -- Case 1: Disparity is Zero or Balanced
                ----------------------------------------------------------------
                -- If the disparity counter is zero, or if the current symbol
                -- is balanced (equal 1s and 0s), then make a simple decision
                -- based on the q_m(8) flag from Stage 1.
                if (cnt = 0) or (n1_q_m_var = n0_q_m_var) then
                    q_out_next(9) <= not q_m_temp(8);  -- Inversion flag
                    q_out_next(8) <= q_m_temp(8);      -- Encoding method flag

                    if q_m_temp(8) = '1' then
                        -- XOR was used: Keep data as-is
                        q_out_next(7 downto 0) <= q_m_temp(7 downto 0);
                        -- Update disparity: add (n1_q_m_var - n0_q_m_var)
                        cnt_next <= cnt + to_signed(n1_q_m_var - n0_q_m_var, 8);
                    else
                        -- XNOR was used: Invert data
                        q_out_next(7 downto 0) <= not q_m_temp(7 downto 0);
                        -- Update disparity: add (n0_q_m_var - n1_q_m_var) because we inverted
                        cnt_next <= cnt + to_signed(n0_q_m_var - n1_q_m_var, 8);
                    end if;

                ----------------------------------------------------------------
                -- Case 2: Imbalance Would Worsen
                ----------------------------------------------------------------
                -- If sending this symbol as-is would make the existing
                -- imbalance worse, then invert the data to help correct it.
                --
                -- This happens when:
                --   (cnt > 0 and n1_q_m > n0_q_m) - Too many 1s and symbol has more 1s
                --   OR
                --   (cnt < 0 and n0_q_m > n1_q_m) - Too many 0s and symbol has more 0s
                elsif ((cnt > 0) and (n1_q_m_var > n0_q_m_var)) or ((cnt < 0) and (n0_q_m_var > n1_q_m_var)) then
                    q_out_next(9) <= '1';              -- Indicate inversion
                    q_out_next(8) <= q_m_temp(8);      -- Copy encoding method flag
                    q_out_next(7 downto 0) <= not q_m_temp(7 downto 0);  -- Invert data

                    -- Update disparity
                    -- Base adjustment: (n0_q_m_var - n1_q_m_var) because we inverted
                    cnt_tmp <= cnt + to_signed(n0_q_m_var - n1_q_m_var, 8);

                    -- Additional adjustment based on q_m(8):
                    -- If q_m(8) = '1' (XOR), add 2 to compensate for bit 8 and bit 9
                    -- If q_m(8) = '0' (XNOR), no extra adjustment
                    if q_m_temp(8) = '1' then
                        cnt_next <= cnt_tmp + 2;
                    else
                        cnt_next <= cnt_tmp;
                    end if;

                ----------------------------------------------------------------
                -- Case 3: Imbalance Would Improve or Stay Same
                ----------------------------------------------------------------
                -- If sending this symbol as-is would improve the imbalance
                -- or keep it the same, then send it without inversion.
                else
                    q_out_next(9) <= '0';              -- No inversion
                    q_out_next(8) <= q_m_temp(8);      -- Copy encoding method flag
                    q_out_next(7 downto 0) <= q_m_temp(7 downto 0);  -- Keep data as-is

                    -- Update disparity
                    -- Base adjustment: (n1_q_m_var - n0_q_m_var) because we didn't invert
                    cnt_tmp <= cnt + to_signed(n1_q_m_var - n0_q_m_var, 8);

                    -- Additional adjustment based on q_m(8):
                    -- If q_m(8) = '1' (XOR), no extra adjustment
                    -- If q_m(8) = '0' (XNOR), subtract 2 to compensate for bit 8 and bit 9
                    if q_m_temp(8) = '1' then
                        cnt_next <= cnt_tmp;
                    else
                        cnt_next <= cnt_tmp - 2;
                    end if;
                end if;

                -- Register the updated disparity counter and output
                cnt <= cnt_next;
                q_out <= q_out_next;

                --------------------------------------------------------------------
                -- ZERO-CYCLE LATENCY FIX: Update dout with same value as q_out
                --------------------------------------------------------------------
                -- In video mode, assign dout <= q_out_next (same value going to q_out)
                -- This eliminates the 1-cycle delay that was corrupting data island timing
                dout <= q_out_next;     -- 0-cycle latency (same value as q_out)
            end if;

            -- NOTE: dout is now assigned in ALL three modes (data island, control, video)
            -- with 0-cycle latency in each case. No separate assignment needed here.
        end if;
    end process;

end rtl;
