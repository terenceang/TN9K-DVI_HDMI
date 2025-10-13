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
    -- AIF Constants (per HDMI spec)
    --------------------------------------------------------------------------------
    constant AIF_TYPE    : std_logic_vector(7 downto 0) := x"84";  -- Audio InfoFrame
    constant AIF_VERSION : std_logic_vector(7 downto 0) := x"01";  -- Version 1
    constant AIF_LENGTH  : std_logic_vector(7 downto 0) := x"0A";  -- 10 bytes
    
    -- Audio format: LPCM=0x01, 2-channel, 48 kHz, 16-bit
    constant AUDIO_CODING_TYPE  : std_logic_vector(3 downto 0) := x"1";  -- LPCM
    constant CHANNEL_COUNT      : std_logic_vector(2 downto 0) := "001";  -- 2 channels
    constant SAMPLE_FREQUENCY   : std_logic_vector(2 downto 0) := "011";  -- 48 kHz
    constant SAMPLE_SIZE        : std_logic_vector(1 downto 0) := "10";   -- 16-bit
    
    --------------------------------------------------------------------------------
    -- AIF Packet Structure (8 words × 32 bits)
    --------------------------------------------------------------------------------
    type aif_packet_t is array (0 to 7) of std_logic_vector(31 downto 0);
    signal aif_packet_rom : aif_packet_t;
    signal checksum : unsigned(7 downto 0);
    
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
    attribute syn_preserve : boolean;
    attribute syn_keep : boolean;
    
    attribute syn_preserve of aif_valid_reg : signal is true;
    attribute syn_preserve of aif_request_reg : signal is true;
    attribute syn_preserve of aif_sent_count : signal is true;
    attribute syn_keep of aif_valid_reg : signal is true;

begin

    --------------------------------------------------------------------------------
    -- Checksum Calculation
    --------------------------------------------------------------------------------
    -- Checksum = 256 - (sum of all header and data bytes) mod 256
    --------------------------------------------------------------------------------
    checksum_calc: process(clk_pixel, rst_n)
        variable sum : unsigned(15 downto 0);
    begin
        if rst_n = '0' then
            checksum <= (others => '0');
        elsif rising_edge(clk_pixel) then
            -- Sum all bytes: Header + Data
            sum := (others => '0');
            sum := sum + unsigned(AIF_TYPE);
            sum := sum + unsigned(AIF_VERSION);
            sum := sum + unsigned(AIF_LENGTH);
            
            -- Data Byte 1: CT[3:0] | CC[2:0] | Reserved[0]
            sum := sum + (x"0" & AUDIO_CODING_TYPE) + ("00000" & CHANNEL_COUNT);
            
            -- Data Byte 2: SF[2:0] | SS[1:0] | Reserved[2:0]
            sum := sum + ("00000" & SAMPLE_FREQUENCY) + ("000000" & SAMPLE_SIZE);
            
            -- Data Byte 3: Reserved (0x00)
            sum := sum + x"00";
            
            -- Data Byte 4: Speaker allocation (stereo = 0x00)
            sum := sum + x"00";
            
            -- Data Bytes 5-10: Reserved (0x00)
            sum := sum + x"00" + x"00" + x"00" + x"00" + x"00" + x"00";
            
            -- Calculate checksum
            checksum <= 256 - sum(7 downto 0);
        end if;
    end process checksum_calc;
    
    --------------------------------------------------------------------------------
    -- AIF Packet ROM Initialization
    --------------------------------------------------------------------------------
    -- Format per HDMI spec CEA-861-D:
    --   Word 0: Header (Type, Version, Length, Checksum)
    --   Words 1-2: Data bytes (audio format info)
    --   Words 3-7: Reserved/padding
    --------------------------------------------------------------------------------
    aif_packet_init: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            -- Word 0: Type | Version | Length | Checksum
            aif_packet_rom(0) <= std_logic_vector(checksum) & AIF_LENGTH & AIF_VERSION & AIF_TYPE;
            
            -- Word 1: Data Byte 1 | Data Byte 2 | Data Byte 3 | Data Byte 4
            -- DB1: CT[7:4]=0001 (LPCM), CC[3:1]=001 (2ch), Reserved[0]=0
            -- DB2: SF[7:5]=011 (48kHz), SS[4:3]=10 (16-bit), Reserved[2:0]=000
            -- DB3: Reserved = 0x00
            -- DB4: Speaker allocation = 0x00 (stereo)
            aif_packet_rom(1) <= x"00" & x"00" & ("00000" & SAMPLE_FREQUENCY & SAMPLE_SIZE & "000") & (x"0" & AUDIO_CODING_TYPE & CHANNEL_COUNT & '0');
            
            -- Word 2: Data Bytes 5-8 (reserved)
            aif_packet_rom(2) <= x"00000000";
            
            -- Words 3-7: Data Bytes 9-10 + padding
            aif_packet_rom(3) <= x"00000000";
            aif_packet_rom(4) <= x"00000000";
            aif_packet_rom(5) <= x"00000000";
            aif_packet_rom(6) <= x"00000000";
            aif_packet_rom(7) <= x"00000000";
        else
            -- Update checksum in Word 0 dynamically
            aif_packet_rom(0)(31 downto 24) <= std_logic_vector(checksum);
        end if;
    end process aif_packet_init;
    
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
                    aif_data_reg <= aif_packet_rom(to_integer(word_index));
                    aif_valid_reg <= '1';
                    aif_start_reg <= '1' when word_index = 0 else '0';
                    aif_end_reg <= '1' when word_index = 7 else '0';
                    
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
