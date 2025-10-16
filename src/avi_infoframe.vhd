--------------------------------------------------------------------------------
-- AVI InfoFrame Generator
--------------------------------------------------------------------------------
-- Description:
--   Generates Auxiliary Video Information (AVI) InfoFrame packets
--   Per HDMI 1.4a spec CEA-861-D
--
--   Describes video format: VIC=1 (640×480p@60Hz, 4:3)
--
--   InfoFrame structure:
--     Header (3 bytes): Type=0x82, Version=0x02, Length=0x0D
--     Data (13 bytes): Video format, colorimetry, aspect ratio, etc.
--     Checksum (1 byte)
--
--   Must be sent at least once per two video fields
--
-- Features:
--   - Registered outputs (no combinational path)
--   - Automatic checksum calculation
--   - Frame counter for observable transmission
--   - Synthesis attributes to prevent optimization
--
-- Clock Domain: Pixel clock (25.2 MHz)
-- Author: Tang Nano 9K HDMI Audio Project
-- Date: October 2025
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity avi_infoframe is
    port (
        -- Clock and reset
        clk_pixel       : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Frame sync (vsync rising edge triggers transmission)
        vsync_rising    : in  std_logic;
        
        -- Output to scheduler (registered)
        avi_data        : out std_logic_vector(31 downto 0);  -- 32-bit word
        avi_valid       : out std_logic;                      -- AVI ready
        avi_ready       : in  std_logic;                      -- Scheduler accepts
        avi_start       : out std_logic;                      -- First word
        avi_end         : out std_logic;                      -- Last word
        avi_request     : out std_logic;                      -- Request transmission slot
        
        -- Debug counters (observable for synthesis)
        dbg_avi_sent    : out std_logic_vector(15 downto 0)
    );
end avi_infoframe;

architecture rtl of avi_infoframe is

    --------------------------------------------------------------------------------
    -- BCH ECC Component
    --------------------------------------------------------------------------------
    component bch_ecc is
        port (
            header_in   : in  std_logic_vector(23 downto 0);
            ecc_out     : out std_logic_vector(7 downto 0)
        );
    end component;

    --------------------------------------------------------------------------------
    -- AVI Constants (per HDMI spec)
    --------------------------------------------------------------------------------
    constant AVI_TYPE    : std_logic_vector(7 downto 0) := x"82";  -- AVI InfoFrame
    constant AVI_VERSION : std_logic_vector(7 downto 0) := x"02";  -- Version 2
    constant AVI_LENGTH  : std_logic_vector(7 downto 0) := x"0D";  -- 13 bytes
    
    -- BCH ECC signals for packet header
    signal avi_packet_header : std_logic_vector(23 downto 0);
    signal avi_packet_ecc    : std_logic_vector(7 downto 0);
    
    -- Synthesis attributes to prevent optimization of ECC signal
    -- Declare attribute types once and then apply to signals below
    attribute syn_keep : boolean;
    attribute syn_preserve : boolean;
    attribute syn_keep of avi_packet_ecc : signal is true;
    attribute syn_preserve of avi_packet_ecc : signal is true;
    
    -- Video format: VIC=1 (640×480p@60Hz), RGB, 4:3
    constant VIDEO_ID_CODE  : std_logic_vector(6 downto 0) := "0000001";  -- VIC=1
    constant PIXEL_REPEAT   : std_logic_vector(3 downto 0) := "0000";     -- No repeat
    constant COLOR_SPACE    : std_logic_vector(1 downto 0) := "00";        -- RGB
    constant ACTIVE_FORMAT  : std_logic_vector(3 downto 0) := "1000";      -- Same as picture
    constant ASPECT_RATIO   : std_logic_vector(1 downto 0) := "01";        -- 4:3
    
    --------------------------------------------------------------------------------
    -- AVI Packet Structure (8 words × 32 bits)
    --------------------------------------------------------------------------------
    type avi_packet_t is array (0 to 7) of std_logic_vector(31 downto 0);
    
    -- Static part of AVI packet (checksum and ECC computed at runtime)
    -- Note: Word 0 contains packet header (HB0, HB1, HB2) + BCH ECC
    --       Word 1+ contains InfoFrame payload starting with InfoFrame checksum (PB0)
    constant AVI_PACKET_BASE : avi_packet_t := (
        0 => x"00" & AVI_LENGTH & AVI_VERSION & AVI_TYPE,  -- Packet header + ECC (filled at runtime)
        1 => ('0' & VIDEO_ID_CODE) & x"00" & ("00" & ASPECT_RATIO & ACTIVE_FORMAT) & x"00",  -- PB0=checksum (filled) + PB1-PB3
        2 => x"000000" & ("0" & COLOR_SPACE & '1' & "00" & "00"),  -- PB4-PB7 (DB1)
        3 => x"00000000",  -- PB8-PB11
        4 => x"00000000",  -- PB12-PB15
        5 => x"00000000",  -- PB16-PB19
        6 => x"00000000",  -- PB20-PB23
        7 => x"00000000"   -- PB24-PB27
    );
    
    signal avi_packet_with_checksum : avi_packet_t;
    signal infoframe_checksum : unsigned(7 downto 0);
    
    --------------------------------------------------------------------------------
    -- State Machine
    --------------------------------------------------------------------------------
    type state_t is (ST_IDLE, ST_SEND_PACKET);
    signal state : state_t;
    
    --------------------------------------------------------------------------------
    -- Timing & Control
    --------------------------------------------------------------------------------
    signal word_index       : unsigned(2 downto 0);  -- 0-7
    signal request_pending  : std_logic;
    signal frame_counter    : unsigned(7 downto 0);  -- Periodic transmission
    
    --------------------------------------------------------------------------------
    -- Output Registers
    --------------------------------------------------------------------------------
    signal avi_data_reg     : std_logic_vector(31 downto 0);
    signal avi_valid_reg    : std_logic;
    signal avi_start_reg    : std_logic;
    signal avi_end_reg      : std_logic;
    signal avi_request_reg  : std_logic;
    
    --------------------------------------------------------------------------------
    -- Debug Counter
    --------------------------------------------------------------------------------
    signal avi_sent_count   : unsigned(15 downto 0);
    
    --------------------------------------------------------------------------------
    -- Synthesis Attributes
    --------------------------------------------------------------------------------
    attribute syn_preserve of avi_valid_reg : signal is true;
    attribute syn_preserve of avi_request_reg : signal is true;
    attribute syn_preserve of avi_sent_count : signal is true;
    attribute syn_keep of avi_valid_reg : signal is true;

begin

    --------------------------------------------------------------------------------
    -- BCH ECC Calculation for HDMI Packet Header
    --------------------------------------------------------------------------------
    -- Packet header: HB0=Type, HB1=Version, HB2=Length
    avi_packet_header <= AVI_LENGTH & AVI_VERSION & AVI_TYPE;
    
    bch_ecc_inst: bch_ecc
        port map (
            header_in => avi_packet_header,
            ecc_out   => avi_packet_ecc
        );
    
    --------------------------------------------------------------------------------
    -- InfoFrame Checksum Calculation
    --------------------------------------------------------------------------------
    -- Checksum = 256 - (sum of all header and data bytes) mod 256
    --------------------------------------------------------------------------------
    checksum_calc: process(clk_pixel, rst_n)
        variable sum : unsigned(15 downto 0);
    begin
        if rst_n = '0' then
            infoframe_checksum <= (others => '0');
        elsif rising_edge(clk_pixel) then
            -- Sum all bytes: Header + Data
            sum := (others => '0');
            sum := sum + unsigned(AVI_TYPE);
            sum := sum + unsigned(AVI_VERSION);
            sum := sum + unsigned(AVI_LENGTH);
            
            -- Data Byte 1: Scan Info[1:0] | Bar Info[3:2] | Active Format[4] | Color[6:5] | Reserved[7]
            sum := sum + unsigned(std_logic_vector'("0" & COLOR_SPACE & '1' & "00" & "00"));  -- RGB, Active Format valid
            
            -- Data Byte 2: Active Format[3:0] | Aspect Ratio[5:4] | Colorimetry[7:6]
            sum := sum + unsigned(std_logic_vector'("00" & ASPECT_RATIO & ACTIVE_FORMAT));
            
            -- Data Byte 3: Nonuniform scaling, RGB Quantization
            sum := sum + x"00";
            
            -- Data Byte 4: VIC[6:0] | Reserved[7]
            sum := sum + unsigned(std_logic_vector'('0' & VIDEO_ID_CODE));
            
            -- Data Byte 5: Pixel Repeat[3:0] | Reserved[7:4]
            sum := sum + unsigned(std_logic_vector'(x"0" & PIXEL_REPEAT));
            
            -- Data Bytes 6-13: Reserved (0x00)
            for i in 6 to 13 loop
                sum := sum + x"00";
            end loop;
            
            -- Calculate checksum
            infoframe_checksum <= 256 - sum(7 downto 0);
        end if;
    end process checksum_calc;
    
    --------------------------------------------------------------------------------
    -- AVI Packet Assembly with Checksum and ECC
    --------------------------------------------------------------------------------
    -- Combine base packet with computed checksum and BCH ECC
    --------------------------------------------------------------------------------
    avi_packet_assembly: process(infoframe_checksum, avi_packet_ecc)
    begin
        -- Copy base packet
        avi_packet_with_checksum <= AVI_PACKET_BASE;
        -- Insert BCH ECC into word 0 bits [31:24]
        avi_packet_with_checksum(0)(31 downto 24) <= avi_packet_ecc;
        -- Insert InfoFrame checksum into word 1 bits [7:0] (PB0)
        avi_packet_with_checksum(1)(7 downto 0) <= std_logic_vector(infoframe_checksum);
    end process avi_packet_assembly;
    
    --------------------------------------------------------------------------------
    -- Transmission Request Logic
    --------------------------------------------------------------------------------
    -- Request transmission every 4 frames (periodic refresh)
    --------------------------------------------------------------------------------
    avi_request_logic: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            frame_counter <= (others => '0');
            request_pending <= '0';
            avi_request_reg <= '0';
            
        elsif rising_edge(clk_pixel) then
            -- Count frames
            if vsync_rising = '1' then
                frame_counter <= frame_counter + 1;
                
                -- Request every 4 frames
                if frame_counter(1 downto 0) = "11" then
                    request_pending <= '1';
                    avi_request_reg <= '1';
                end if;
            end if;
            
            -- Clear request when transmission starts
            if state = ST_SEND_PACKET and word_index = 0 then
                request_pending <= '0';
                avi_request_reg <= '0';
            end if;
        end if;
    end process avi_request_logic;
    
    --------------------------------------------------------------------------------
    -- AVI Transmission State Machine
    --------------------------------------------------------------------------------
    avi_sender: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            state <= ST_IDLE;
            word_index <= (others => '0');
            avi_data_reg <= (others => '0');
            avi_valid_reg <= '0';
            avi_start_reg <= '0';
            avi_end_reg <= '0';
            
        elsif rising_edge(clk_pixel) then
            
            case state is
                
                --------------------------------------------------------------------
                -- IDLE: Wait for transmission request
                --------------------------------------------------------------------
                when ST_IDLE =>
                    avi_valid_reg <= '0';
                    avi_start_reg <= '0';
                    avi_end_reg <= '0';
                    
                    if request_pending = '1' and avi_ready = '1' then
                        state <= ST_SEND_PACKET;
                        word_index <= (others => '0');
                    end if;
                
                --------------------------------------------------------------------
                -- SEND_PACKET: Stream AVI packet words to scheduler
                --------------------------------------------------------------------
                when ST_SEND_PACKET =>
                    -- Output current word from ROM
                    avi_data_reg <= avi_packet_with_checksum(to_integer(word_index));
                    avi_valid_reg <= '1';
                    if word_index = 0 then
                        avi_start_reg <= '1';
                    else
                        avi_start_reg <= '0';
                    end if;
                    if word_index = 7 then
                        avi_end_reg <= '1';
                    else
                        avi_end_reg <= '0';
                    end if;
                    
                    -- Wait for scheduler ready
                    if avi_ready = '1' then
                        if word_index = 7 then
                            -- Packet complete
                            state <= ST_IDLE;
                            avi_valid_reg <= '0';
                        else
                            -- Next word
                            word_index <= word_index + 1;
                        end if;
                    end if;
                
                when others =>
                    state <= ST_IDLE;
                    
            end case;
        end if;
    end process avi_sender;
    
    --------------------------------------------------------------------------------
    -- Debug Counter
    --------------------------------------------------------------------------------
    debug_counter: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            avi_sent_count <= (others => '0');
        elsif rising_edge(clk_pixel) then
            if state = ST_SEND_PACKET and word_index = 7 and avi_ready = '1' then
                avi_sent_count <= avi_sent_count + 1;
            end if;
        end if;
    end process debug_counter;
    
    --------------------------------------------------------------------------------
    -- Output Assignments (all registered)
    --------------------------------------------------------------------------------
    avi_data <= avi_data_reg;
    avi_valid <= avi_valid_reg;
    avi_start <= avi_start_reg;
    avi_end <= avi_end_reg;
    avi_request <= avi_request_reg;
    dbg_avi_sent <= std_logic_vector(avi_sent_count);

end rtl;
