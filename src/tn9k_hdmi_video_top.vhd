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
        tmds_data_n  : out std_logic_vector(2 downto 0);

        -- Temporary debug outputs (for logic analyzer / oscilloscope)
        debug_h_count_out : out std_logic_vector(3 downto 0);
        debug_v_count_out : out std_logic_vector(3 downto 0);
        debug_de_out      : out std_logic;
        debug_hsync_out   : out std_logic;
        debug_vsync_out   : out std_logic
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
    signal clk_pixel  : std_logic;
    signal clk_serial : std_logic;
    signal pll_lock   : std_logic;

    -- Reset synchronization (2-stage synchronizer for metastability protection)
    signal rst_sync_stage1_n : std_logic;
    signal rst_sync_n        : std_logic;

    -- Video signals
    signal hsync : std_logic;
    signal vsync : std_logic;
    signal de    : std_logic;
    signal r, g, b : std_logic_vector(7 downto 0);

    -- Debug signals
    signal debug_h_count_int : unsigned(10 downto 0);
    signal debug_v_count_int : unsigned(9 downto 0);

    -- Gowin-specific synthesis attribute to prevent optimization
    attribute syn_keep : string;
    attribute syn_keep of debug_h_count_int : signal is "true";
    attribute syn_keep of debug_v_count_int : signal is "true";
    attribute syn_keep of hsync : signal is "true";
    attribute syn_keep of vsync : signal is "true";
    attribute syn_keep of de : signal is "true";
    attribute syn_keep of r : signal is "true";
    attribute syn_keep of g : signal is "true";
    attribute syn_keep of b : signal is "true";

begin

    --------------------------------------------------------------------------------
    -- Clock Generation
    --------------------------------------------------------------------------------
    -- 27 MHz -> 126 MHz (serial) and 25.2 MHz (pixel)
    --------------------------------------------------------------------------------
    u_clk_gen: tn9k_clock_generator
        port map (
            clkin   => clk_27m,
            reset   => not rst_n,
            clkout0 => clk_pixel,
            clkout1 => clk_serial,
            lock    => pll_lock
        );

    --------------------------------------------------------------------------------
    -- Reset Synchronization (2-Stage for Metastability Protection)
    --------------------------------------------------------------------------------
    -- Combines external reset with PLL lock and synchronizes to pixel clock domain
    -- Two flip-flop stages reduce probability of metastability propagation
    --------------------------------------------------------------------------------
    process(clk_pixel)
    begin
        if rising_edge(clk_pixel) then
            -- Stage 1: First flip-flop (may go metastable)
            rst_sync_stage1_n <= rst_n and pll_lock;
            -- Stage 2: Second flip-flop (resolves metastability)
            rst_sync_n <= rst_sync_stage1_n;
        end if;
    end process;

    --------------------------------------------------------------------------------
    -- Test Pattern Generator
    --------------------------------------------------------------------------------
    -- Uses h_count/v_count from HDMI encoder as master timing source
    -- This ensures perfect synchronization between video generation and encoding
    --------------------------------------------------------------------------------
    u_pattern: test_pattern_gen
        generic map (
            H_ACTIVE => H_ACTIVE,
            H_TOTAL  => H_TOTAL,
            V_ACTIVE => V_ACTIVE,
            V_TOTAL  => V_TOTAL
        )
        port map (
            clk_pixel      => clk_pixel,
            rst_n          => rst_sync_n,
            h_count        => debug_h_count_int,  -- Master timing from HDMI encoder
            v_count        => debug_v_count_int,  -- Master timing from HDMI encoder
            hsync          => hsync,
            vsync          => vsync,
            de             => de,
            r              => r,
            g              => g,
            b              => b
        );

    --------------------------------------------------------------------------------
    -- HDMI Encoder
    --------------------------------------------------------------------------------
    u_hdmi: hdmi_encoder
        generic map (
            H_ACTIVE => H_ACTIVE,
            H_TOTAL  => H_TOTAL,
            V_ACTIVE => V_ACTIVE,
            V_TOTAL  => V_TOTAL
        )
        port map (
            clk_pixel      => clk_pixel,
            clk_serial     => clk_serial,
            rst_n          => rst_sync_n,
            hsync          => hsync,
            vsync          => vsync,
            r              => r,
            g              => g,
            b              => b,
            tmds_clk_p     => tmds_clk_p,
            tmds_clk_n     => tmds_clk_n,
            tmds_data_p    => tmds_data_p,
            tmds_data_n    => tmds_data_n,
            h_count_out    => debug_h_count_int,
            v_count_out    => debug_v_count_int,
            de_debug       => de
        );

    --------------------------------------------------------------------------------
    -- Debug Output Assignments (Temporary - for logic analyzer)
    --------------------------------------------------------------------------------
    debug_h_count_out <= std_logic_vector(debug_h_count_int(3 downto 0));
    debug_v_count_out <= std_logic_vector(debug_v_count_int(3 downto 0));
    debug_de_out      <= de;
    debug_hsync_out   <= hsync;
    debug_vsync_out   <= vsync;

end rtl;
