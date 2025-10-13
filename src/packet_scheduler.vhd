--------------------------------------------------------------------------------
-- Packet Scheduler with Back-Porch Timing
--------------------------------------------------------------------------------
-- Description:
--   Schedules HDMI packet transmission during horizontal back porch only
--   Implements priority arbitration: ACR > ASP > AIF/AVI (round-robin)
--
--   Timing per HDMI spec:
--     - Preamble (8 pixels before data island)
--     - Leading guard band (2 pixels)
--     - Data island (packet content)
--     - Trailing guard band (2 pixels)
--
--   All control signals are registered 2 cycles early to align with
--   downstream pipeline and ensure they land in back porch on the wire
--
-- Features:
--   - Back-porch-only scheduling (no interference with active video)
--   - Priority-based arbitration
--   - Registered outputs (no combinational paths)
--   - Debug outputs to prevent optimization
--   - Synthesis attributes
--
-- Clock Domain: Pixel clock (25.2 MHz)
-- Author: Tang Nano 9K HDMI Audio Project
-- Date: October 2025
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity packet_scheduler is
    generic (
        -- Timing parameters for 640×480@60Hz
        H_ACTIVE    : integer := 640;   -- Active pixels
        H_SYNC      : integer := 96;    -- Sync pulse width
        H_BACK      : integer := 48;    -- Back porch pixels
        H_FRONT     : integer := 16;    -- Front porch pixels
        H_TOTAL     : integer := 800    -- Total pixels per line
    );
    port (
        -- Clock and reset
        clk_pixel       : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Timing inputs
        h_count         : in  unsigned(10 downto 0);
        v_count         : in  unsigned(9 downto 0);
        vsync_rising    : in  std_logic;
        
        -- ACR packet input (highest priority)
        acr_data        : in  std_logic_vector(31 downto 0);
        acr_valid       : in  std_logic;
        acr_ready       : out std_logic;
        acr_request     : in  std_logic;
        
        -- ASP packet input (medium priority)
        asp_data        : in  std_logic_vector(31 downto 0);
        asp_valid       : in  std_logic;
        asp_ready       : out std_logic;
        
        -- AIF packet input (low priority)
        aif_data        : in  std_logic_vector(31 downto 0);
        aif_valid       : in  std_logic;
        aif_ready       : out std_logic;
        aif_request     : in  std_logic;
        
        -- AVI packet input (low priority)
        avi_data        : in  std_logic_vector(31 downto 0);
        avi_valid       : in  std_logic;
        avi_ready       : out std_logic;
        avi_request     : in  std_logic;
        
        -- Output to TERC4/TMDS mux (registered)
        island_active   : out std_logic;                      -- Data island period
        preamble_active : out std_logic;                      -- Preamble period
        guard_band      : out std_logic;                      -- Guard band period
        packet_data     : out std_logic_vector(31 downto 0);  -- Selected packet data
        
        -- Debug outputs (observable for synthesis)
        dbg_island_active : out std_logic;
        dbg_packet_type   : out std_logic_vector(2 downto 0);  -- 0=None, 1=ACR, 2=ASP, 3=AIF, 4=AVI
        dbg_scheduler_state : out std_logic_vector(3 downto 0)
    );
end packet_scheduler;

architecture rtl of packet_scheduler is

    --------------------------------------------------------------------------------
    -- Timing Constants
    --------------------------------------------------------------------------------
    -- Back porch window: from end of hsync to start of active video
    -- H_SYNC = 96, so back porch starts at pixel 96 and ends at pixel 96+48=144
    constant H_BACK_START : integer := H_SYNC;
    constant H_BACK_END   : integer := H_SYNC + H_BACK;
    
    -- Packet island timing (all in back porch)
    constant PREAMBLE_LENGTH : integer := 8;   -- 8 pixels
    constant GUARD_LENGTH    : integer := 2;   -- 2 pixels each side
    constant ISLAND_LENGTH   : integer := 32;  -- 32 pixels for packet data
    
    -- Total island window: 8 preamble + 2 guard + 32 data + 2 guard = 44 pixels
    constant ISLAND_WINDOW : integer := PREAMBLE_LENGTH + GUARD_LENGTH + ISLAND_LENGTH + GUARD_LENGTH;
    
    --------------------------------------------------------------------------------
    -- State Machine
    --------------------------------------------------------------------------------
    type state_t is (
        ST_IDLE,            -- Waiting for back porch
        ST_PREAMBLE,        -- Transmitting preamble
        ST_GUARD_LEADING,   -- Leading guard band
        ST_ISLAND,          -- Data island (packet transmission)
        ST_GUARD_TRAILING   -- Trailing guard band
    );
    signal state : state_t;
    
    --------------------------------------------------------------------------------
    -- Packet Selection & Arbitration
    --------------------------------------------------------------------------------
    type packet_t is (PKT_NONE, PKT_ACR, PKT_ASP, PKT_AIF, PKT_AVI);
    signal selected_packet : packet_t;
    signal infoframe_toggle : std_logic;  -- Alternates between AIF and AVI
    
    --------------------------------------------------------------------------------
    -- Timing Counters
    --------------------------------------------------------------------------------
    signal pixel_counter : unsigned(5 downto 0);  -- Counts pixels within island window
    signal in_back_porch : std_logic;
    
    --------------------------------------------------------------------------------
    -- Pipeline Registers (2-cycle early outputs)
    --------------------------------------------------------------------------------
    signal island_active_pipe1   : std_logic;
    signal island_active_pipe2   : std_logic;
    signal preamble_active_pipe1 : std_logic;
    signal preamble_active_pipe2 : std_logic;
    signal guard_band_pipe1      : std_logic;
    signal guard_band_pipe2      : std_logic;
    
    --------------------------------------------------------------------------------
    -- Output Registers
    --------------------------------------------------------------------------------
    signal island_active_reg   : std_logic;
    signal preamble_active_reg : std_logic;
    signal guard_band_reg      : std_logic;
    signal packet_data_reg     : std_logic_vector(31 downto 0);
    
    signal acr_ready_reg : std_logic;
    signal asp_ready_reg : std_logic;
    signal aif_ready_reg : std_logic;
    signal avi_ready_reg : std_logic;
    
    --------------------------------------------------------------------------------
    -- Debug Signals
    --------------------------------------------------------------------------------
    signal dbg_island_reg : std_logic;
    signal dbg_packet_type_reg : std_logic_vector(2 downto 0);
    signal dbg_state_reg : std_logic_vector(3 downto 0);
    
    --------------------------------------------------------------------------------
    -- Synthesis Attributes
    --------------------------------------------------------------------------------
    attribute syn_preserve : boolean;
    attribute syn_keep : boolean;
    
    attribute syn_preserve of island_active_reg : signal is true;
    attribute syn_preserve of selected_packet : signal is true;
    attribute syn_preserve of dbg_island_reg : signal is true;
    attribute syn_keep of island_active_reg : signal is true;
    
begin

    --------------------------------------------------------------------------------
    -- Back Porch Detection
    --------------------------------------------------------------------------------
    back_porch_detect: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            in_back_porch <= '0';
        elsif rising_edge(clk_pixel) then
            -- Back porch window: pixel 96 to 143 (48 pixels)
            if h_count >= H_BACK_START and h_count < H_BACK_END then
                in_back_porch <= '1';
            else
                in_back_porch <= '0';
            end if;
        end if;
    end process back_porch_detect;
    
    --------------------------------------------------------------------------------
    -- Packet Arbitration (Priority: ACR > ASP > AIF/AVI round-robin)
    --------------------------------------------------------------------------------
    packet_arbiter: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            selected_packet <= PKT_NONE;
            infoframe_toggle <= '0';
            
        elsif rising_edge(clk_pixel) then
            
            -- Arbitrate only when idle and in back porch
            if state = ST_IDLE and in_back_porch = '1' then
                
                -- Priority 1: ACR (highest priority, clock regeneration critical)
                if acr_request = '1' and acr_valid = '1' then
                    selected_packet <= PKT_ACR;
                    
                -- Priority 2: ASP (audio samples, time-sensitive)
                elsif asp_valid = '1' then
                    selected_packet <= PKT_ASP;
                    
                -- Priority 3: InfoFrames (AIF/AVI alternate)
                elsif aif_request = '1' and aif_valid = '1' and infoframe_toggle = '0' then
                    selected_packet <= PKT_AIF;
                    infoframe_toggle <= '1';  -- Next time try AVI
                    
                elsif avi_request = '1' and avi_valid = '1' and infoframe_toggle = '1' then
                    selected_packet <= PKT_AVI;
                    infoframe_toggle <= '0';  -- Next time try AIF
                    
                else
                    selected_packet <= PKT_NONE;
                end if;
                
            elsif state = ST_GUARD_TRAILING then
                -- Clear selection after packet transmission
                selected_packet <= PKT_NONE;
            end if;
            
        end if;
    end process packet_arbiter;
    
    --------------------------------------------------------------------------------
    -- Scheduler State Machine
    --------------------------------------------------------------------------------
    scheduler_fsm: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            state <= ST_IDLE;
            pixel_counter <= (others => '0');
            acr_ready_reg <= '0';
            asp_ready_reg <= '0';
            aif_ready_reg <= '0';
            avi_ready_reg <= '0';
            
            island_active_pipe1 <= '0';
            island_active_pipe2 <= '0';
            preamble_active_pipe1 <= '0';
            preamble_active_pipe2 <= '0';
            guard_band_pipe1 <= '0';
            guard_band_pipe2 <= '0';
            
        elsif rising_edge(clk_pixel) then
            
            -- Default: no ready signals
            acr_ready_reg <= '0';
            asp_ready_reg <= '0';
            aif_ready_reg <= '0';
            avi_ready_reg <= '0';
            
            case state is
                
                --------------------------------------------------------------------
                -- IDLE: Wait for packet and back porch window
                --------------------------------------------------------------------
                when ST_IDLE =>
                    island_active_pipe1 <= '0';
                    preamble_active_pipe1 <= '0';
                    guard_band_pipe1 <= '0';
                    
                    if in_back_porch = '1' and selected_packet /= PKT_NONE then
                        -- Start packet transmission
                        state <= ST_PREAMBLE;
                        pixel_counter <= (others => '0');
                    end if;
                
                --------------------------------------------------------------------
                -- PREAMBLE: 8 pixels preamble
                --------------------------------------------------------------------
                when ST_PREAMBLE =>
                    preamble_active_pipe1 <= '1';
                    island_active_pipe1 <= '0';
                    guard_band_pipe1 <= '0';
                    
                    pixel_counter <= pixel_counter + 1;
                    
                    if pixel_counter = PREAMBLE_LENGTH - 1 then
                        state <= ST_GUARD_LEADING;
                        pixel_counter <= (others => '0');
                    end if;
                
                --------------------------------------------------------------------
                -- GUARD_LEADING: 2 pixels leading guard band
                --------------------------------------------------------------------
                when ST_GUARD_LEADING =>
                    preamble_active_pipe1 <= '0';
                    guard_band_pipe1 <= '1';
                    island_active_pipe1 <= '0';
                    
                    pixel_counter <= pixel_counter + 1;
                    
                    if pixel_counter = GUARD_LENGTH - 1 then
                        state <= ST_ISLAND;
                        pixel_counter <= (others => '0');
                    end if;
                
                --------------------------------------------------------------------
                -- ISLAND: 32 pixels packet data transmission
                --------------------------------------------------------------------
                when ST_ISLAND =>
                    preamble_active_pipe1 <= '0';
                    guard_band_pipe1 <= '0';
                    island_active_pipe1 <= '1';
                    
                    -- Assert ready to consume packet data
                    case selected_packet is
                        when PKT_ACR => acr_ready_reg <= '1';
                        when PKT_ASP => asp_ready_reg <= '1';
                        when PKT_AIF => aif_ready_reg <= '1';
                        when PKT_AVI => avi_ready_reg <= '1';
                        when others => null;
                    end case;
                    
                    pixel_counter <= pixel_counter + 1;
                    
                    if pixel_counter = ISLAND_LENGTH - 1 then
                        state <= ST_GUARD_TRAILING;
                        pixel_counter <= (others => '0');
                    end if;
                
                --------------------------------------------------------------------
                -- GUARD_TRAILING: 2 pixels trailing guard band
                --------------------------------------------------------------------
                when ST_GUARD_TRAILING =>
                    preamble_active_pipe1 <= '0';
                    guard_band_pipe1 <= '1';
                    island_active_pipe1 <= '0';
                    
                    pixel_counter <= pixel_counter + 1;
                    
                    if pixel_counter = GUARD_LENGTH - 1 then
                        state <= ST_IDLE;
                        pixel_counter <= (others => '0');
                    end if;
                
                when others =>
                    state <= ST_IDLE;
                    
            end case;
            
            -- Pipeline registers (2-cycle delay for alignment)
            island_active_pipe2 <= island_active_pipe1;
            island_active_reg <= island_active_pipe2;
            
            preamble_active_pipe2 <= preamble_active_pipe1;
            preamble_active_reg <= preamble_active_pipe2;
            
            guard_band_pipe2 <= guard_band_pipe1;
            guard_band_reg <= guard_band_pipe2;
            
        end if;
    end process scheduler_fsm;
    
    --------------------------------------------------------------------------------
    -- Packet Data Mux (registered)
    --------------------------------------------------------------------------------
    packet_mux: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            packet_data_reg <= (others => '0');
        elsif rising_edge(clk_pixel) then
            case selected_packet is
                when PKT_ACR => packet_data_reg <= acr_data;
                when PKT_ASP => packet_data_reg <= asp_data;
                when PKT_AIF => packet_data_reg <= aif_data;
                when PKT_AVI => packet_data_reg <= avi_data;
                when others  => packet_data_reg <= (others => '0');
            end case;
        end if;
    end process packet_mux;
    
    --------------------------------------------------------------------------------
    -- Debug Outputs (registered, observable for synthesis)
    --------------------------------------------------------------------------------
    debug_outputs: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            dbg_island_reg <= '0';
            dbg_packet_type_reg <= (others => '0');
            dbg_state_reg <= (others => '0');
        elsif rising_edge(clk_pixel) then
            dbg_island_reg <= island_active_reg;
            
            case selected_packet is
                when PKT_NONE => dbg_packet_type_reg <= "000";
                when PKT_ACR  => dbg_packet_type_reg <= "001";
                when PKT_ASP  => dbg_packet_type_reg <= "010";
                when PKT_AIF  => dbg_packet_type_reg <= "011";
                when PKT_AVI  => dbg_packet_type_reg <= "100";
            end case;
            
            case state is
                when ST_IDLE           => dbg_state_reg <= "0000";
                when ST_PREAMBLE       => dbg_state_reg <= "0001";
                when ST_GUARD_LEADING  => dbg_state_reg <= "0010";
                when ST_ISLAND         => dbg_state_reg <= "0011";
                when ST_GUARD_TRAILING => dbg_state_reg <= "0100";
                when others            => dbg_state_reg <= "1111";
            end case;
        end if;
    end process debug_outputs;
    
    --------------------------------------------------------------------------------
    -- Output Assignments (all registered)
    --------------------------------------------------------------------------------
    island_active <= island_active_reg;
    preamble_active <= preamble_active_reg;
    guard_band <= guard_band_reg;
    packet_data <= packet_data_reg;
    
    acr_ready <= acr_ready_reg;
    asp_ready <= asp_ready_reg;
    aif_ready <= aif_ready_reg;
    avi_ready <= avi_ready_reg;
    
    dbg_island_active <= dbg_island_reg;
    dbg_packet_type <= dbg_packet_type_reg;
    dbg_scheduler_state <= dbg_state_reg;

end rtl;
