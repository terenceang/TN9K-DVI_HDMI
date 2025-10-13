--------------------------------------------------------------------------------
-- Module: tn9k_clock_generator
-- Project: Tang Nano 9K HDMI Test Pattern Generator
-- Description: Clock generation wrapper for HDMI video system
--
-- Purpose:
--   This module wraps the Gowin PLL and clock divider IP cores to generate
--   the precise clock frequencies required for HDMI video output. It takes
--   the 27 MHz crystal oscillator input and produces two synchronized clocks:
--   - 126 MHz for TMDS serialization (5x the pixel clock)
--   - 25.2 MHz for pixel clock (640x480@60Hz VGA timing)
--
-- Input Clock:
--   27 MHz from the onboard crystal oscillator
--
-- Output Clocks:
--   1. clkout0: 25.2 MHz pixel clock
--      - Used by video timing generator and pixel data pipeline
--      - Generates one pixel per clock cycle
--      - Required for 640x480@60Hz: 25.175 MHz (approximated as 25.2 MHz)
--
--   2. clkout1: 126 MHz TMDS serial clock
--      - Used by DVI/HDMI transmitter for serialization
--      - Must be exactly 5x the pixel clock (5 × 25.2 = 126 MHz)
--      - Each pixel requires 10 bits after TMDS encoding
--      - DDR transmission sends 2 bits per clock: 10 bits / 2 = 5x multiplier
--
-- PLL Configuration:
--   The Gowin_rPLL component is configured to multiply the 27 MHz input
--   to 126 MHz output using the following parameters:
--   - IDIV_SEL = 2 (input divider)
--   - FBDIV_SEL = 13 (feedback divider)
--   - ODIV_SEL = 2 (output divider - applied internally)
--
--   IMPORTANT - Correct Gowin PLL Formula:
--   CLKOUT = CLKIN × (FBDIV_SEL + 1) / (IDIV_SEL + 1)
--
--   Calculation for 126 MHz output:
--   CLKOUT = 27 MHz × (13 + 1) / (2 + 1)
--   CLKOUT = 27 MHz × 14 / 3
--   CLKOUT = 27 MHz × 4.666...
--   CLKOUT = 126 MHz
--
-- Clock Divider Configuration:
--   The Gowin_CLKDIV component divides the 126 MHz PLL output by 5
--   to generate the 25.2 MHz pixel clock:
--   - DIV_MODE = "5" (divide by 5)
--   - Input: 126 MHz (from PLL)
--   - Output: 126 MHz / 5 = 25.2 MHz
--
--   This ensures perfect phase alignment between the pixel clock and
--   serial clock, which is critical for TMDS serialization.
--
-- Lock Signal:
--   The PLL lock output indicates when the PLL has stabilized and is
--   generating a valid clock. This signal should be used to hold the
--   video system in reset until clocks are stable. The lock signal
--   typically goes high 100-200 microseconds after power-on.
--
-- Notes:
--   - Both output clocks are phase-aligned since they derive from the same PLL
--   - The 5:1 ratio is maintained precisely by the hardware clock divider
--   - Reset is active high for this wrapper but converted to active low
--     for the Gowin_CLKDIV component
--   - The PLL does not have a reset input; it self-starts on power-up
--
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

--------------------------------------------------------------------------------
-- Entity: tn9k_clock_generator
-- Description: Top-level clock generation wrapper for HDMI video system
--------------------------------------------------------------------------------
entity tn9k_clock_generator is
    generic (
        G_CLKIN_FREQ_MHZ    : real := 27.0;   -- Input clock frequency in MHz
        G_CLKOUT0_FREQ_MHZ  : real := 25.2;   -- Desired pixel clock frequency in MHz
        G_CLKOUT1_FREQ_MHZ  : real := 126.0;  -- Desired TMDS serial clock frequency in MHz
        G_PLL_IDIV_SEL      : integer := 2;   -- PLL input divider selection (actual divisor is IDIV_SEL+1)
        G_PLL_FBDIV_SEL     : integer := 13;  -- PLL feedback divider selection (actual multiplier is FBDIV_SEL+1)
        G_PLL_ODIV_SEL      : integer := 2;   -- PLL output divider selection
        G_CLKDIV_RATIO      : integer := 5    -- Clock divider ratio
    );
    port (
        -- Input clock from 27 MHz crystal oscillator
        clkin     : in  std_logic;  -- 27 MHz input clock from Tang Nano 9K onboard crystal

        -- Reset control
        reset     : in  std_logic;  -- Active high reset for clock divider
                                    -- Note: PLL has no reset and will start automatically

        -- Output clocks
        clkout0   : out std_logic;  -- 25.2 MHz pixel clock for video timing and data
                                    -- This clock drives the video timing generator and
                                    -- pixel processing pipeline (one pixel per cycle)

        clkout1   : out std_logic;  -- 126 MHz TMDS serialization clock (5x pixel clock)
                                    -- This clock drives the TMDS encoder serializers
                                    -- Must be exactly 5x pixel clock for proper DDR serialization

        -- Status output
        lock      : out std_logic   -- PLL lock indicator (active high when stable)
                                    -- Connect to system reset logic to ensure clocks
                                    -- are stable before releasing video pipeline from reset
    );
end tn9k_clock_generator;

--------------------------------------------------------------------------------
-- Architecture: rtl
-- Description: Structural implementation wrapping Gowin IP cores
--------------------------------------------------------------------------------
architecture rtl of tn9k_clock_generator is

    ----------------------------------------------------------------------------
    -- Component Declarations
    ----------------------------------------------------------------------------

    -- Gowin_rPLL: Ring PLL IP core from Gowin
    -- Configured to generate 126 MHz from 27 MHz input
    --
    -- Configuration (set in gowin_rpll.ipc file):
    --   - FCLKIN = 27 MHz (input frequency)
    --   - IDIV_SEL = 2 (input divider value, actual divisor is IDIV_SEL+1 = 3)
    --   - FBDIV_SEL = 13 (feedback divider value, actual multiplier is FBDIV_SEL+1 = 14)
    --   - ODIV_SEL = 2 (output divider, applied internally in VCO path)
    --
    -- Formula: CLKOUT = CLKIN × (FBDIV_SEL + 1) / (IDIV_SEL + 1)
    --          126 MHz = 27 MHz × (13 + 1) / (2 + 1)
    --          126 MHz = 27 MHz × 14 / 3
    --
    -- The PLL has no reset input and will automatically lock after power-up.
    -- Lock time is typically 100-200 microseconds.
    component Gowin_rPLL
        port (
            clkout : out std_logic;  -- 126 MHz PLL output clock
            lock   : out std_logic;  -- Lock status: '1' when PLL is locked and stable
            clkin  : in  std_logic   -- 27 MHz input clock from crystal
        );
    end component;

    -- Gowin_CLKDIV: Hardware clock divider IP core from Gowin
    -- Configured to divide by 5 to generate pixel clock
    --
    -- Configuration (set in gowin_clkdiv.ipc file):
    --   - DIV_MODE = "5" (division ratio)
    --   - GSREN = "false" (no global set/reset)
    --
    -- This divider provides clean division with 50% duty cycle and
    -- maintains phase alignment with the source clock (126 MHz PLL output).
    --
    -- Division: 126 MHz / 5 = 25.2 MHz
    --
    -- The resetn input is active low and synchronously resets the divider.
    component Gowin_CLKDIV
        port (
            clkout  : out std_logic;  -- 25.2 MHz divided output clock
            hclkin  : in  std_logic;  -- High-speed input clock (126 MHz from PLL)
            resetn  : in  std_logic   -- Active low synchronous reset
        );
    end component;

    ----------------------------------------------------------------------------
    -- Internal Signals
    ----------------------------------------------------------------------------

    signal pll_clkout : std_logic;  -- 126 MHz output from PLL
                                    -- This is the intermediate clock that feeds both:
                                    -- 1. clkout1 output directly (TMDS serial clock)
                                    -- 2. Clock divider input (to generate pixel clock)

    signal rst_n      : std_logic;  -- Active low reset for clock divider
                                    -- Converted from active high 'reset' input

begin

    ----------------------------------------------------------------------------
    -- Signal Assignments
    ----------------------------------------------------------------------------

    -- Convert active high reset to active low for clock divider
    -- The Gowin_CLKDIV component uses active low reset (resetn)
    -- while this wrapper uses active high reset for consistency
    rst_n <= not reset;

    -- Route 126 MHz PLL output directly to TMDS serial clock output
    -- This is the 5x serialization clock for the TMDS encoders
    clkout1 <= pll_clkout;

    ----------------------------------------------------------------------------
    -- Component Instantiations
    ----------------------------------------------------------------------------

    -- PLL Instance: Generates 126 MHz from 27 MHz input
    --
    -- This is the primary clock multiplier that takes the stable 27 MHz
    -- crystal oscillator and generates the 126 MHz high-speed clock needed
    -- for TMDS serialization.
    --
    -- The PLL will automatically start and lock after power-up. No reset
    -- input is required or available. The lock output should be monitored
    -- and used to keep downstream logic in reset until the PLL stabilizes.
    --
    -- Lock time: typically 100-200 microseconds after power-up
    u_pll: Gowin_rPLL
        port map (
            clkout => pll_clkout,   -- Output: 126 MHz (5x pixel clock for TMDS serialization)
            lock   => lock,         -- Output: PLL lock status (high when stable)
            clkin  => clkin         -- Input: 27 MHz from Tang Nano 9K crystal oscillator
        );

    -- Clock Divider Instance: Generates 25.2 MHz pixel clock from 126 MHz
    --
    -- This hardware divider ensures perfect phase alignment between the
    -- pixel clock and the 5x serialization clock. Using a hardware divider
    -- instead of a separate PLL output guarantees the required integer
    -- relationship between the two clocks.
    --
    -- The divider maintains a 50% duty cycle on the output and can be
    -- synchronously reset using the active low resetn input.
    --
    -- Division ratio: 126 MHz / 5 = 25.2 MHz
    u_clkdiv: Gowin_CLKDIV
        port map (
            clkout => clkout0,      -- Output: 25.2 MHz pixel clock for video timing
            hclkin => pll_clkout,   -- Input: 126 MHz high-speed clock from PLL
            resetn => rst_n         -- Input: Active low synchronous reset
        );

end rtl;
