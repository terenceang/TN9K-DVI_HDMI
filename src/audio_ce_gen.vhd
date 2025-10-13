--------------------------------------------------------------------------------
-- Audio Clock Enable Generator
--------------------------------------------------------------------------------
-- Description:
--   Generates a 48 kHz single-cycle enable pulse from 25.2 MHz pixel clock
--   Ratio: 25,200,000 / 48,000 = 525 pixel clocks per audio sample
--
--   Includes optional CDC for external audio sources via toggle synchronizer
--
-- Features:
--   - Clean integer divider (no jitter accumulation)
--   - Registered output (no combinational path to consumers)
--   - Optional toggle-based CDC from external clock domain
--   - Synthesis attributes to prevent optimization
--
-- Clock Domain: Pixel clock (25.2 MHz)
-- Author: Tang Nano 9K HDMI Audio Project
-- Date: October 2025
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity audio_ce_gen is
    generic (
        -- Pixel clock frequency (Hz)
        PIXEL_CLK_FREQ  : integer := 25_200_000;
        -- Audio sample rate (Hz)
        AUDIO_SAMPLE_RATE : integer := 48_000
    );
    port (
        -- Pixel clock domain
        clk_pixel       : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Optional external audio clock domain toggle (for CDC)
        -- Leave unconnected if audio source is already in pixel domain
        ext_audio_toggle : in  std_logic := '0';
        
        -- Audio clock enable output (48 kHz pulse in pixel domain)
        audio_ce        : out std_logic;
        
        -- Debug: cycle counter for verification
        dbg_ce_counter  : out std_logic_vector(15 downto 0)
    );
end audio_ce_gen;

architecture rtl of audio_ce_gen is

    --------------------------------------------------------------------------------
    -- Constants
    --------------------------------------------------------------------------------
    -- Division ratio: 25,200,000 / 48,000 = 525
    constant DIVIDE_RATIO : integer := PIXEL_CLK_FREQ / AUDIO_SAMPLE_RATE;
    
    --------------------------------------------------------------------------------
    -- Clock Enable Generator Signals
    --------------------------------------------------------------------------------
    signal ce_counter       : integer range 0 to DIVIDE_RATIO-1;
    signal audio_ce_internal : std_logic;
    signal ce_event_count   : unsigned(15 downto 0);
    
    --------------------------------------------------------------------------------
    -- CDC Synchronizer Signals (for external audio sources)
    --------------------------------------------------------------------------------
    signal ext_toggle_sync1 : std_logic;
    signal ext_toggle_sync2 : std_logic;
    signal ext_toggle_prev  : std_logic;
    signal ext_audio_event  : std_logic;
    
    --------------------------------------------------------------------------------
    -- Synthesis Attributes (prevent optimization)
    --------------------------------------------------------------------------------
    attribute syn_preserve : boolean;
    attribute syn_keep : boolean;
    
    attribute syn_preserve of audio_ce_internal : signal is true;
    attribute syn_preserve of ce_event_count : signal is true;
    attribute syn_keep of audio_ce_internal : signal is true;
    
begin

    --------------------------------------------------------------------------------
    -- Audio Clock Enable Generator (Internal)
    --------------------------------------------------------------------------------
    -- Generates a single-cycle pulse every 525 pixel clocks (48 kHz from 25.2 MHz)
    --------------------------------------------------------------------------------
    ce_generator: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            ce_counter <= 0;
            audio_ce_internal <= '0';
        elsif rising_edge(clk_pixel) then
            -- Default: no pulse
            audio_ce_internal <= '0';
            
            if ce_counter = DIVIDE_RATIO - 1 then
                -- Generate pulse and reset counter
                audio_ce_internal <= '1';
                ce_counter <= 0;
            else
                -- Increment counter
                ce_counter <= ce_counter + 1;
            end if;
        end if;
    end process ce_generator;
    
    --------------------------------------------------------------------------------
    -- CDC Synchronizer (Optional External Audio Source)
    --------------------------------------------------------------------------------
    -- Two-stage synchronizer for toggle signal from external clock domain
    -- Edge detection generates a single-cycle pulse in pixel domain
    --------------------------------------------------------------------------------
    cdc_synchronizer: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            ext_toggle_sync1 <= '0';
            ext_toggle_sync2 <= '0';
            ext_toggle_prev <= '0';
            ext_audio_event <= '0';
        elsif rising_edge(clk_pixel) then
            -- Two-FF synchronizer chain
            ext_toggle_sync1 <= ext_audio_toggle;
            ext_toggle_sync2 <= ext_toggle_sync1;
            
            -- Edge detection (toggle changed)
            ext_toggle_prev <= ext_toggle_sync2;
            if ext_toggle_sync2 /= ext_toggle_prev then
                ext_audio_event <= '1';
            else
                ext_audio_event <= '0';
            end if;
        end if;
    end process cdc_synchronizer;
    
    --------------------------------------------------------------------------------
    -- Output Mux: Internal generator OR external CDC event
    --------------------------------------------------------------------------------
    -- If ext_audio_toggle is connected and toggling, use that
    -- Otherwise use internal 48 kHz generator
    --------------------------------------------------------------------------------
    output_mux: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            audio_ce <= '0';
        elsif rising_edge(clk_pixel) then
            -- Use external event if available, otherwise internal generator
            audio_ce <= ext_audio_event or audio_ce_internal;
        end if;
    end process output_mux;
    
    --------------------------------------------------------------------------------
    -- Debug Counter (observable for synthesis)
    --------------------------------------------------------------------------------
    -- Counts audio_ce pulses to keep logic observable
    --------------------------------------------------------------------------------
    debug_counter: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            ce_event_count <= (others => '0');
        elsif rising_edge(clk_pixel) then
            if audio_ce_internal = '1' or ext_audio_event = '1' then
                ce_event_count <= ce_event_count + 1;
            end if;
        end if;
    end process debug_counter;
    
    -- Output debug counter (registered)
    dbg_ce_counter <= std_logic_vector(ce_event_count);
    
end rtl;
