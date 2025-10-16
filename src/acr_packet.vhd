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
use work.hdmi_config_pkg.all;

entity acr_packet is
    generic (
        -- Audio sample rate (Hz)
        AUDIO_SAMPLE_RATE : integer := HDMI_AUDIO_DEFAULT.sample_rate;
        -- Pixel/TMDS clock frequency (Hz)
        PIXEL_CLK_FREQ    : integer := HDMI_AUDIO_DEFAULT.pixel_clock_hz;
        -- ACR transmission interval (pixel clocks)
        -- Send every frame = 800x525 = 420,000 pixel clocks
        ACR_INTERVAL      : integer := HDMI_AUDIO_DEFAULT.acr_interval;
        -- HDMI N parameter (Table 7-1)
        N_VALUE           : integer := HDMI_AUDIO_DEFAULT.acr_n_value
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
    -- BCH ECC Component
    --------------------------------------------------------------------------------
    component bch_ecc is
        port (
            header_in   : in  std_logic_vector(23 downto 0);
            ecc_out     : out std_logic_vector(7 downto 0)
        );
    end component;

    --------------------------------------------------------------------------------
    -- ACR Constants (per HDMI spec)
    --------------------------------------------------------------------------------
    
    -- Calculate CTS: (f_TMDS × N) / (128 × f_s)
    -- For 25.2 MHz: (25,200,000 × 6144) / (128 × 48,000) = 25,200
    constant CTS_VALUE : integer := (PIXEL_CLK_FREQ * N_VALUE) / (128 * AUDIO_SAMPLE_RATE);
    
    -- ACR packet header bytes (HB0, HB1, HB2)
    constant ACR_HB0 : std_logic_vector(7 downto 0) := x"01";  -- ACR packet type
    constant ACR_HB1 : std_logic_vector(7 downto 0) := x"00";  -- Reserved
    constant ACR_HB2 : std_logic_vector(7 downto 0) := x"00";  -- Reserved
    
    -- BCH ECC signals
    signal acr_header : std_logic_vector(23 downto 0);
    signal acr_ecc    : std_logic_vector(7 downto 0);
    
    -- Synthesis attributes to prevent optimization of ECC signal
    -- Declare attribute types once and then apply to signals below
    attribute syn_keep : boolean;
    attribute syn_preserve : boolean;
    attribute syn_keep of acr_ecc : signal is true;
    attribute syn_preserve of acr_ecc : signal is true;
    
    --------------------------------------------------------------------------------
    -- ACR Packet Structure (8 words × 32 bits)
    --------------------------------------------------------------------------------
    type acr_packet_t is array (0 to 7) of std_logic_vector(31 downto 0);
    
    -- ACR packet with ECC (computed by bch_ecc component)
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
    attribute syn_preserve of acr_valid_reg : signal is true;
    attribute syn_preserve of acr_request_reg : signal is true;
    attribute syn_preserve of acr_sent_count : signal is true;
    attribute syn_keep of acr_valid_reg : signal is true;

begin

    --------------------------------------------------------------------------------
    -- BCH ECC Calculation for ACR Packet Header
    --------------------------------------------------------------------------------
    -- Header: HB0=0x01, HB1=0x00, HB2=0x00
    acr_header <= ACR_HB2 & ACR_HB1 & ACR_HB0;
    
    bch_ecc_inst: bch_ecc
        port map (
            header_in => acr_header,
            ecc_out   => acr_ecc
        );
    
    --------------------------------------------------------------------------------
    -- ACR Packet Assembly with BCH ECC
    --------------------------------------------------------------------------------
    -- Word 0: [ECC] [HB2] [HB1] [HB0]
    -- Per HDMI spec: Subpacket 0 contains header bytes + ECC
    acr_packet_rom(0) <= acr_ecc & ACR_HB2 & ACR_HB1 & ACR_HB0;
    acr_packet_rom(1) <= std_logic_vector(to_unsigned(CTS_VALUE, 20)) & x"000";
    acr_packet_rom(2) <= std_logic_vector(to_unsigned(N_VALUE, 20)) & x"000";
    acr_packet_rom(3) <= (others => '0');
    acr_packet_rom(4) <= (others => '0');
    acr_packet_rom(5) <= (others => '0');
    acr_packet_rom(6) <= (others => '0');
    acr_packet_rom(7) <= (others => '0');

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
                    if word_index = 0 then
                        acr_start_reg <= '1';
                    else
                        acr_start_reg <= '0';
                    end if;
                    if word_index = 7 then
                        acr_end_reg <= '1';
                    else
                        acr_end_reg <= '0';
                    end if;
                    
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

