--------------------------------------------------------------------------------
-- Audio InfoFrame (AIF) Generator
--------------------------------------------------------------------------------
-- Description:
--   Generates Audio InfoFrame packets per HDMI 1.4a spec
--   Describes audio stream properties: LPCM, 2-channel, 48 kHz, 16-bit
--
--   InfoFrame structure:
--     Header (3 bytes): Type=0x84, Version=0x01, Length=0x0A
--     Data (10 bytes): Audio format, channel count, sample rate, etc.
--     Checksum (1 byte)
--
--   Must be sent at least once per video field and repeated periodically
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

entity audio_infoframe is
    port (
        -- Clock and reset
        clk_pixel       : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Frame sync (vsync rising edge triggers transmission)
        vsync_rising    : in  std_logic;
        
        -- Output to scheduler (registered)
        aif_data        : out std_logic_vector(31 downto 0);  -- 32-bit word
        aif_valid       : out std_logic;                      -- AIF ready
        aif_ready       : in  std_logic;                      -- Scheduler accepts
        aif_start       : out std_logic;                      -- First word
        aif_end         : out std_logic;                      -- Last word
        aif_request     : out std_logic;                      -- Request transmission slot
        
        -- Debug counters (observable for synthesis)
        dbg_aif_sent    : out std_logic_vector(15 downto 0)
    );
end audio_infoframe;

architecture rtl of audio_infoframe is

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
    -- AIF Constants (per HDMI spec)
    --------------------------------------------------------------------------------
    constant AIF_TYPE    : std_logic_vector(7 downto 0) := x"84";  -- Audio InfoFrame
    constant AIF_VERSION : std_logic_vector(7 downto 0) := x"01";  -- Version 1
    constant AIF_LENGTH  : std_logic_vector(7 downto 0) := x"0A";  -- 10 bytes
    
    -- BCH ECC signals for packet header
    signal aif_packet_header : std_logic_vector(23 downto 0);
    signal aif_packet_ecc    : std_logic_vector(7 downto 0);
    
    -- Synthesis attributes to prevent optimization of ECC signal
    -- Declare attribute types once and then apply to signals below
    attribute syn_keep : boolean;
    attribute syn_preserve : boolean;
    attribute syn_keep of aif_packet_ecc : signal is true;
    attribute syn_preserve of aif_packet_ecc : signal is true;
    
    -- Audio format: LPCM=0x01, 2-channel, 48 kHz, 16-bit
    constant AUDIO_CODING_TYPE  : std_logic_vector(3 downto 0) := x"1";  -- LPCM
    constant CHANNEL_COUNT      : std_logic_vector(2 downto 0) := "001";  -- 2 channels
    constant SAMPLE_FREQUENCY   : std_logic_vector(2 downto 0) := "011";  -- 48 kHz
    constant SAMPLE_SIZE        : std_logic_vector(1 downto 0) := "10";   -- 16-bit
    
    --------------------------------------------------------------------------------
    -- AIF Packet Structure (8 words × 32 bits)
    --------------------------------------------------------------------------------
    type aif_packet_t is array (0 to 7) of std_logic_vector(31 downto 0);
    
    -- Static part of AIF packet (checksum and ECC computed at runtime)
    constant AIF_PACKET_BASE : aif_packet_t := (
        0 => x"00" & AIF_LENGTH & AIF_VERSION & AIF_TYPE,  -- Packet header + ECC (filled at runtime)
        1 => x"00" & x"00" & (SAMPLE_SIZE & SAMPLE_FREQUENCY & "000") & x"00",  -- PB0=checksum (filled) + PB1-PB3
        2 => x"00000000",  -- PB4-PB7
        3 => x"00000000",  -- PB8-PB11
        4 => x"00000000",  -- PB12-PB15
        5 => x"00000000",  -- PB16-PB19
        6 => x"00000000",  -- PB20-PB23
        7 => x"00000000"   -- PB24-PB27
    );
    
    signal aif_packet_with_checksum : aif_packet_t;
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
    signal aif_data_reg     : std_logic_vector(31 downto 0);
    signal aif_valid_reg    : std_logic;
    signal aif_start_reg    : std_logic;
    signal aif_end_reg      : std_logic;
    signal aif_request_reg  : std_logic;
    
    --------------------------------------------------------------------------------
    -- Debug Counter
    --------------------------------------------------------------------------------
    signal aif_sent_count   : unsigned(15 downto 0);
    
    --------------------------------------------------------------------------------
    -- Synthesis Attributes
    --------------------------------------------------------------------------------
    attribute syn_preserve of aif_valid_reg : signal is true;
    attribute syn_preserve of aif_request_reg : signal is true;
    attribute syn_preserve of aif_sent_count : signal is true;
    attribute syn_keep of aif_valid_reg : signal is true;

begin

    --------------------------------------------------------------------------------
    -- BCH ECC Calculation for HDMI Packet Header
    --------------------------------------------------------------------------------
    -- Packet header: HB0=Type, HB1=Version, HB2=Length
    aif_packet_header <= AIF_LENGTH & AIF_VERSION & AIF_TYPE;
    
    bch_ecc_inst: bch_ecc
        port map (
            header_in => aif_packet_header,
            ecc_out   => aif_packet_ecc
        );
    
    --------------------------------------------------------------------------------
    -- InfoFrame Checksum Calculation
    --------------------------------------------------------------------------------
    -- Checksum Calculation
    --------------------------------------------------------------------------------
    checksum_proc: process(clk_pixel, rst_n)
        variable sum : unsigned(15 downto 0);
    begin
        if rst_n = '0' then
            infoframe_checksum <= (others => '0');
        elsif rising_edge(clk_pixel) then
            -- Sum all bytes: Header + Data
            sum := (others => '0');
            sum := sum + unsigned(AIF_TYPE);
            sum := sum + unsigned(AIF_VERSION);
            sum := sum + unsigned(AIF_LENGTH);
            
            -- Data Byte 1: CT[3:0] | CC[2:0] | Reserved[0]
            sum := sum + unsigned(std_logic_vector'(x"0" & AUDIO_CODING_TYPE));
            sum := sum + unsigned(std_logic_vector'("00000" & CHANNEL_COUNT));
            
            -- Data Byte 2: SF[2:0] | SS[1:0] | Reserved[2:0]
            sum := sum + unsigned(std_logic_vector'("00000" & SAMPLE_FREQUENCY));
            sum := sum + unsigned(std_logic_vector'("000000" & SAMPLE_SIZE));
            
            -- Data Byte 3: Reserved (0x00)
            sum := sum + x"00";
            
            -- Data Byte 4: Speaker allocation (stereo = 0x00)
            sum := sum + x"00";
            
            -- Data Bytes 5-10: Reserved (0x00)
            sum := sum + x"00" + x"00" + x"00" + x"00" + x"00" + x"00";
            
            -- Calculate checksum
            infoframe_checksum <= 256 - sum(7 downto 0);
        end if;
    end process checksum_proc;
    
    --------------------------------------------------------------------------------
    -- AIF Packet Assembly with Checksum and ECC
    --------------------------------------------------------------------------------
    -- Combine base packet with computed checksum and BCH ECC
    --------------------------------------------------------------------------------
    aif_packet_assembly: process(infoframe_checksum, aif_packet_ecc)
    begin
        -- Copy base packet
        aif_packet_with_checksum <= AIF_PACKET_BASE;
        -- Insert BCH ECC into word 0 bits [31:24]
        aif_packet_with_checksum(0)(31 downto 24) <= aif_packet_ecc;
        -- Insert InfoFrame checksum into word 1 bits [7:0] (PB0)
        aif_packet_with_checksum(1)(7 downto 0) <= std_logic_vector(infoframe_checksum);
        -- Insert audio format into word 1 bits [15:8] (PB1)
        aif_packet_with_checksum(1)(15 downto 8) <= AUDIO_CODING_TYPE & CHANNEL_COUNT & '0';
    end process aif_packet_assembly;
    
    --------------------------------------------------------------------------------
    -- Transmission Request Logic
    --------------------------------------------------------------------------------
    -- Request transmission every 8 frames (periodic refresh)
    --------------------------------------------------------------------------------
    aif_request_logic: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            frame_counter <= (others => '0');
            request_pending <= '0';
            aif_request_reg <= '0';
            
        elsif rising_edge(clk_pixel) then
            -- Count frames
            if vsync_rising = '1' then
                frame_counter <= frame_counter + 1;
                
                -- Request every 8 frames
                if frame_counter(2 downto 0) = "111" then
                    request_pending <= '1';
                    aif_request_reg <= '1';
                end if;
            end if;
            
            -- Clear request when transmission starts
            if state = ST_SEND_PACKET and word_index = 0 then
                request_pending <= '0';
                aif_request_reg <= '0';
            end if;
        end if;
    end process aif_request_logic;
    
    --------------------------------------------------------------------------------
    -- AIF Transmission State Machine
    --------------------------------------------------------------------------------
    aif_sender: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            state <= ST_IDLE;
            word_index <= (others => '0');
            aif_data_reg <= (others => '0');
            aif_valid_reg <= '0';
            aif_start_reg <= '0';
            aif_end_reg <= '0';
            
        elsif rising_edge(clk_pixel) then
            
            case state is
                
                --------------------------------------------------------------------
                -- IDLE: Wait for transmission request
                --------------------------------------------------------------------
                when ST_IDLE =>
                    aif_valid_reg <= '0';
                    aif_start_reg <= '0';
                    aif_end_reg <= '0';
                    
                    if request_pending = '1' and aif_ready = '1' then
                        state <= ST_SEND_PACKET;
                        word_index <= (others => '0');
                    end if;
                
                --------------------------------------------------------------------
                -- SEND_PACKET: Stream AIF packet words to scheduler
                --------------------------------------------------------------------
                when ST_SEND_PACKET =>
                    -- Output current word from ROM
                    aif_data_reg <= aif_packet_with_checksum(to_integer(word_index));
                    aif_valid_reg <= '1';
                    if word_index = 0 then
                        aif_start_reg <= '1';
                    else
                        aif_start_reg <= '0';
                    end if;
                    if word_index = 7 then
                        aif_end_reg <= '1';
                    else
                        aif_end_reg <= '0';
                    end if;
                    
                    -- Wait for scheduler ready
                    if aif_ready = '1' then
                        if word_index = 7 then
                            -- Packet complete
                            state <= ST_IDLE;
                            aif_valid_reg <= '0';
                        else
                            -- Next word
                            word_index <= word_index + 1;
                        end if;
                    end if;
                
                when others =>
                    state <= ST_IDLE;
                    
            end case;
        end if;
    end process aif_sender;
    
    --------------------------------------------------------------------------------
    -- Debug Counter
    --------------------------------------------------------------------------------
    debug_counter: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            aif_sent_count <= (others => '0');
        elsif rising_edge(clk_pixel) then
            if state = ST_SEND_PACKET and word_index = 7 and aif_ready = '1' then
                aif_sent_count <= aif_sent_count + 1;
            end if;
        end if;
    end process debug_counter;
    
    --------------------------------------------------------------------------------
    -- Output Assignments (all registered)
    --------------------------------------------------------------------------------
    aif_data <= aif_data_reg;
    aif_valid <= aif_valid_reg;
    aif_start <= aif_start_reg;
    aif_end <= aif_end_reg;
    aif_request <= aif_request_reg;
    dbg_aif_sent <= std_logic_vector(aif_sent_count);

end rtl;
