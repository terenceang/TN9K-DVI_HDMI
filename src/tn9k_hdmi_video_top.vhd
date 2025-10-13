--------------------------------------------------------------------------------
-- Tang Nano 9K HDMI Video Test - Top Level
--------------------------------------------------------------------------------
-- Description:
--   HDMI encoder demonstration for video only.
--   Generates a color bar test pattern.
--
-- Features:
--   - 640x480@60Hz video (8 vertical color bars)
--   - DVI-compliant output (can be used with HDMI monitors)
--
-- Hardware: Tang Nano 9K (Gowin GW1NR-9C FPGA)
-- Author: Tang Nano 9K HDMI Project
-- Date: 2025
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tn9k_hdmi_video_top is
    port (
        clk_27m      : in  std_logic;   -- 27 MHz system clock
        rst_n        : in  std_logic;   -- Reset button (S2)

        -- HDMI outputs
        tmds_clk_p   : out std_logic;
        tmds_clk_n   : out std_logic;
        tmds_data_p  : out std_logic_vector(2 downto 0);
        tmds_data_n  : out std_logic_vector(2 downto 0)
    );
end tn9k_hdmi_video_top;

architecture rtl of tn9k_hdmi_video_top is

    --------------------------------------------------------------------------------
    -- Component Declarations
    --------------------------------------------------------------------------------

    component tn9k_clock_generator
        port (
            clkin      : in  std_logic;
            reset      : in  std_logic;
            clkout0    : out std_logic;
            clkout1    : out std_logic;
            lock       : out std_logic
        );
    end component;

    component test_pattern_gen
        generic (
            H_ACTIVE  : integer;
            H_TOTAL   : integer;
            V_ACTIVE  : integer;
            V_TOTAL   : integer
        );
        port (
            clk_pixel       : in  std_logic;
            rst_n           : in  std_logic;
            h_count         : in  unsigned(10 downto 0);
            v_count         : in  unsigned(9 downto 0);
            hsync           : out std_logic;
            vsync           : out std_logic;
            de              : in  std_logic;
            r               : out std_logic_vector(7 downto 0);
            g               : out std_logic_vector(7 downto 0);
            b               : out std_logic_vector(7 downto 0)
        );
    end component;

    component hdmi_encoder
        generic (
            H_ACTIVE  : integer;
            H_TOTAL   : integer;
            V_ACTIVE  : integer;
            V_TOTAL   : integer
        );
        port (
            clk_pixel      : in  std_logic;
            clk_serial     : in  std_logic;
            rst_n          : in  std_logic;
            hsync          : in  std_logic;
            vsync          : in  std_logic;
            r              : in  std_logic_vector(7 downto 0);
            g              : in  std_logic_vector(7 downto 0);
            b              : in  std_logic_vector(7 downto 0);
            tmds_clk_p     : out std_logic;
            tmds_clk_n     : out std_logic;
            tmds_data_p    : out std_logic_vector(2 downto 0);
            tmds_data_n    : out std_logic_vector(2 downto 0);
            h_count_out    : out unsigned(10 downto 0);
            v_count_out    : out unsigned(9 downto 0);
            de_debug       : out std_logic
        );
    end component;

    --------------------------------------------------------------------------------
    -- Constants
    --------------------------------------------------------------------------------

    constant H_ACTIVE : integer := 640;
    constant H_TOTAL  : integer := 800;
    constant V_ACTIVE : integer := 480;
    constant V_TOTAL  : integer := 525;

    --------------------------------------------------------------------------------
    -- Internal Signals
    --------------------------------------------------------------------------------

    -- Clock signals
    signal pixel_clock          : std_logic;
    signal serial_clock_5x      : std_logic;
    signal clock_pll_locked     : std_logic;

    -- Reset synchronization (2-stage synchronizer for metastability protection)
    signal reset_sync_stage1    : std_logic;
    signal reset_synchronized   : std_logic;

    -- Video timing and control signals
    signal video_hsync          : std_logic;
    signal video_vsync          : std_logic;
    signal video_data_enable    : std_logic;
    signal video_red            : std_logic_vector(7 downto 0);
    signal video_green          : std_logic_vector(7 downto 0);
    signal video_blue           : std_logic_vector(7 downto 0);

    -- Timing counters
    signal horizontal_counter   : unsigned(10 downto 0);
    signal vertical_counter     : unsigned(9 downto 0);

begin

    --------------------------------------------------------------------------------
    -- Clock Generation
    --------------------------------------------------------------------------------
    -- 27 MHz -> 126 MHz (serial) and 25.2 MHz (pixel)
    --------------------------------------------------------------------------------
    clock_generator_inst: tn9k_clock_generator
        port map (
            clkin   => clk_27m,
            reset   => not rst_n,
            clkout0 => pixel_clock,
            clkout1 => serial_clock_5x,
            lock    => clock_pll_locked
        );

    --------------------------------------------------------------------------------
    -- Reset Synchronization (2-Stage for Metastability Protection)
    --------------------------------------------------------------------------------
    -- Combines external reset with PLL lock and synchronizes to pixel clock domain
    -- Two flip-flop stages reduce probability of metastability propagation
    --------------------------------------------------------------------------------
    reset_synchronizer: process(pixel_clock)
    begin
        if rising_edge(pixel_clock) then
            -- Stage 1: First flip-flop (may go metastable)
            reset_sync_stage1 <= rst_n and clock_pll_locked;
            -- Stage 2: Second flip-flop (resolves metastability)
            reset_synchronized <= reset_sync_stage1;
        end if;
    end process reset_synchronizer;

    --------------------------------------------------------------------------------
    -- Test Pattern Generator
    --------------------------------------------------------------------------------
    -- Uses h_count/v_count from HDMI encoder as master timing source
    -- This ensures perfect synchronization between video generation and encoding
    --------------------------------------------------------------------------------
    pattern_generator_inst: test_pattern_gen
        generic map (
            H_ACTIVE => H_ACTIVE,
            H_TOTAL  => H_TOTAL,
            V_ACTIVE => V_ACTIVE,
            V_TOTAL  => V_TOTAL
        )
        port map (
            clk_pixel      => pixel_clock,
            rst_n          => reset_synchronized,
            h_count        => horizontal_counter,
            v_count        => vertical_counter,
            hsync          => video_hsync,
            vsync          => video_vsync,
            de             => video_data_enable,
            r              => video_red,
            g              => video_green,
            b              => video_blue
        );

    --------------------------------------------------------------------------------
    -- HDMI Encoder
    --------------------------------------------------------------------------------
    hdmi_encoder_inst: hdmi_encoder
        generic map (
            H_ACTIVE => H_ACTIVE,
            H_TOTAL  => H_TOTAL,
            V_ACTIVE => V_ACTIVE,
            V_TOTAL  => V_TOTAL
        )
        port map (
            clk_pixel      => pixel_clock,
            clk_serial     => serial_clock_5x,
            rst_n          => reset_synchronized,
            hsync          => video_hsync,
            vsync          => video_vsync,
            r              => video_red,
            g              => video_green,
            b              => video_blue,
            tmds_clk_p     => tmds_clk_p,
            tmds_clk_n     => tmds_clk_n,
            tmds_data_p    => tmds_data_p,
            tmds_data_n    => tmds_data_n,
            h_count_out    => horizontal_counter,
            v_count_out    => vertical_counter,
            de_debug       => video_data_enable
        );

end rtl;
