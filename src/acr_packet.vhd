--------------------------------------------------------------------------------
-- Audio Clock Regeneration (ACR) Packet Generator
--------------------------------------------------------------------------------
-- Description:
--   Generates ACR packets for audio/video clock synchronization
--   Per HDMI 1.4a spec section 5.3.3
--
--   For 48 kHz audio:
--     N = 6144 (fixed, per spec table 7-1)
--     CTS = (f_TMDS × N) / (128 × f_audio)
--         = (25.2 MHz × 6144) / (128 × 48 kHz)
--         = 25,200 (for 25.2 MHz pixel clock)
--
--   ACR packets must be sent periodically (every frame or more frequently)
--
-- Features:
--   - Registered outputs (no combinational path)
--   - Periodic transmission timer
--   - Highest priority in scheduler
--   - Synthesis attributes to prevent optimization
--
-- Clock Domain: Pixel clock (25.2 MHz)
-- Author: Tang Nano 9K HDMI Audio Project
-- Date: October 2025
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity acr_packet is
    generic (
        -- Audio sample rate (Hz)
        AUDIO_SAMPLE_RATE : integer := 48_000;
        -- Pixel/TMDS clock frequency (Hz)
        PIXEL_CLK_FREQ    : integer := 25_200_000;
        -- ACR transmission interval (pixel clocks)
        -- Send every frame = 800×525 = 420,000 pixel clocks
        ACR_INTERVAL      : integer := 420_000
    );
    port (
        -- Clock and reset
        clk_pixel       : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Frame sync (vsync rising edge)
        vsync_rising    : in  std_logic;
        
        -- Output to scheduler (registered)
        acr_data        : out std_logic_vector(31 downto 0);  -- 32-bit word
        acr_valid       : out std_logic;                      -- ACR ready
        acr_ready       : in  std_logic;                      -- Scheduler accepts
        acr_start       : out std_logic;                      -- First word
        acr_end         : out std_logic;                      -- Last word
        acr_request     : out std_logic;                      -- Request transmission slot
        
        -- Debug counters (observable for synthesis)
        dbg_acr_sent    : out std_logic_vector(15 downto 0)
    );
end acr_packet;

architecture rtl of acr_packet is

    --------------------------------------------------------------------------------
    -- ACR Constants (per HDMI spec)
    --------------------------------------------------------------------------------
    constant N_VALUE : integer := 6144;  -- Fixed for 48 kHz
    
    -- Calculate CTS: (f_TMDS × N) / (128 × f_s)
    -- For 25.2 MHz: (25,200,000 × 6144) / (128 × 48,000) = 25,200
    constant CTS_VALUE : integer := (PIXEL_CLK_FREQ * N_VALUE) / (128 * AUDIO_SAMPLE_RATE);
    
    -- ACR packet type
    constant ACR_HEADER_TYPE : std_logic_vector(7 downto 0) := x"01";
    
    --------------------------------------------------------------------------------
    -- ACR Packet Structure (8 words × 32 bits)
    --------------------------------------------------------------------------------
    type acr_packet_t is array (0 to 7) of std_logic_vector(31 downto 0);
    signal acr_packet_rom : acr_packet_t;
    
    --------------------------------------------------------------------------------
    -- State Machine
    --------------------------------------------------------------------------------
    type state_t is (ST_IDLE, ST_SEND_PACKET);
    signal state : state_t;
    
    --------------------------------------------------------------------------------
    -- Timing & Control
    --------------------------------------------------------------------------------
    signal word_index       : unsigned(2 downto 0);  -- 0-7
    signal transmission_timer : unsigned(19 downto 0);  -- Up to 1M cycles
    signal request_pending  : std_logic;
    
    --------------------------------------------------------------------------------
    -- Output Registers
    --------------------------------------------------------------------------------
    signal acr_data_reg     : std_logic_vector(31 downto 0);
    signal acr_valid_reg    : std_logic;
    signal acr_start_reg    : std_logic;
    signal acr_end_reg      : std_logic;
    signal acr_request_reg  : std_logic;
    
    --------------------------------------------------------------------------------
    -- Debug Counter
    --------------------------------------------------------------------------------
    signal acr_sent_count   : unsigned(15 downto 0);
    
    --------------------------------------------------------------------------------
    -- Synthesis Attributes
    --------------------------------------------------------------------------------
    attribute syn_preserve : boolean;
    attribute syn_keep : boolean;
    
    attribute syn_preserve of acr_valid_reg : signal is true;
    attribute syn_preserve of acr_request_reg : signal is true;
    attribute syn_preserve of acr_sent_count : signal is true;
    attribute syn_keep of acr_valid_reg : signal is true;

begin

    --------------------------------------------------------------------------------
    -- ACR Packet ROM Initialization
    --------------------------------------------------------------------------------
    -- Format per HDMI spec section 5.3.3:
    --   Word 0: Header (Type, Version, Length)
    --   Words 1-7: CTS and N values
    --------------------------------------------------------------------------------
    acr_packet_init: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            -- Header: Type=0x01 (ACR)
            acr_packet_rom(0) <= x"00" & x"00" & x"00" & ACR_HEADER_TYPE;
            
            -- Subpacket 0: CTS[19:0] (split across bytes)
            -- CTS = 25200 = 0x6270
            acr_packet_rom(1) <= std_logic_vector(to_unsigned(CTS_VALUE, 20)) & x"000";
            
            -- Subpacket 1: N[19:0] (split across bytes)
            -- N = 6144 = 0x1800
            acr_packet_rom(2) <= std_logic_vector(to_unsigned(N_VALUE, 20)) & x"000";
            
            -- Remaining words: padding
            acr_packet_rom(3) <= (others => '0');
            acr_packet_rom(4) <= (others => '0');
            acr_packet_rom(5) <= (others => '0');
            acr_packet_rom(6) <= (others => '0');
            acr_packet_rom(7) <= (others => '0');
        end if;
    end process acr_packet_init;
    
    --------------------------------------------------------------------------------
    -- Transmission Timer
    --------------------------------------------------------------------------------
    -- Request ACR transmission periodically (every frame)
    --------------------------------------------------------------------------------
    acr_timer: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            transmission_timer <= (others => '0');
            request_pending <= '0';
            acr_request_reg <= '0';
            
        elsif rising_edge(clk_pixel) then
            -- Increment timer
            transmission_timer <= transmission_timer + 1;
            
            -- Request on vsync or timer expiry
            if vsync_rising = '1' or transmission_timer >= ACR_INTERVAL then
                request_pending <= '1';
                acr_request_reg <= '1';
                transmission_timer <= (others => '0');
            end if;
            
            -- Clear request when transmission starts
            if state = ST_SEND_PACKET and word_index = 0 then
                request_pending <= '0';
                acr_request_reg <= '0';
            end if;
        end if;
    end process acr_timer;
    
    --------------------------------------------------------------------------------
    -- ACR Transmission State Machine
    --------------------------------------------------------------------------------
    acr_sender: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            state <= ST_IDLE;
            word_index <= (others => '0');
            acr_data_reg <= (others => '0');
            acr_valid_reg <= '0';
            acr_start_reg <= '0';
            acr_end_reg <= '0';
            
        elsif rising_edge(clk_pixel) then
            
            case state is
                
                --------------------------------------------------------------------
                -- IDLE: Wait for transmission request
                --------------------------------------------------------------------
                when ST_IDLE =>
                    acr_valid_reg <= '0';
                    acr_start_reg <= '0';
                    acr_end_reg <= '0';
                    
                    if request_pending = '1' and acr_ready = '1' then
                        state <= ST_SEND_PACKET;
                        word_index <= (others => '0');
                    end if;
                
                --------------------------------------------------------------------
                -- SEND_PACKET: Stream ACR packet words to scheduler
                --------------------------------------------------------------------
                when ST_SEND_PACKET =>
                    -- Output current word from ROM
                    acr_data_reg <= acr_packet_rom(to_integer(word_index));
                    acr_valid_reg <= '1';
                    acr_start_reg <= '1' when word_index = 0 else '0';
                    acr_end_reg <= '1' when word_index = 7 else '0';
                    
                    -- Wait for scheduler ready
                    if acr_ready = '1' then
                        if word_index = 7 then
                            -- Packet complete
                            state <= ST_IDLE;
                            acr_valid_reg <= '0';
                        else
                            -- Next word
                            word_index <= word_index + 1;
                        end if;
                    end if;
                
                when others =>
                    state <= ST_IDLE;
                    
            end case;
        end if;
    end process acr_sender;
    
    --------------------------------------------------------------------------------
    -- Debug Counter
    --------------------------------------------------------------------------------
    debug_counter: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            acr_sent_count <= (others => '0');
        elsif rising_edge(clk_pixel) then
            if state = ST_SEND_PACKET and word_index = 7 and acr_ready = '1' then
                acr_sent_count <= acr_sent_count + 1;
            end if;
        end if;
    end process debug_counter;
    
    --------------------------------------------------------------------------------
    -- Output Assignments (all registered)
    --------------------------------------------------------------------------------
    acr_data <= acr_data_reg;
    acr_valid <= acr_valid_reg;
    acr_start <= acr_start_reg;
    acr_end <= acr_end_reg;
    acr_request <= acr_request_reg;
    dbg_acr_sent <= std_logic_vector(acr_sent_count);

end rtl;
