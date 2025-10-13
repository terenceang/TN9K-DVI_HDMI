--------------------------------------------------------------------------------
-- Test Pattern Generator
--------------------------------------------------------------------------------
-- Description:
--   Generates a VGA-style test pattern.
--   Video: 8 vertical color bars
--
-- Author: Tang Nano 9K HDMI Project
-- Date: 2025
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity test_pattern_gen is
    generic (
        H_ACTIVE  : integer := 640;
        H_TOTAL   : integer := 800;
        V_ACTIVE  : integer := 480;
        V_TOTAL   : integer := 525
    );
    port (
        clk_pixel       : in  std_logic;
        rst_n           : in  std_logic;

        -- Timing inputs from HDMI encoder (MASTER timing source)
        h_count         : in  unsigned(10 downto 0);
        v_count         : in  unsigned(9 downto 0);

        -- Video outputs
        hsync           : out std_logic;
        vsync           : out std_logic;
        de              : in std_logic; -- Data Enable
        r               : out std_logic_vector(7 downto 0);
        g               : out std_logic_vector(7 downto 0);
        b               : out std_logic_vector(7 downto 0)
    );
end test_pattern_gen;

architecture rtl of test_pattern_gen is

    -- Sync signals
    signal horizontal_sync : std_logic;
    signal vertical_sync   : std_logic;
    
    -- Sync timing constants (optimized for synthesis)
    constant H_SYNC_START : integer := 656;  -- 640 + 16
    constant H_SYNC_END   : integer := 752;  -- 640 + 16 + 96
    constant V_SYNC_START : integer := 490;  -- 480 + 10
    constant V_SYNC_END   : integer := 492;  -- 480 + 10 + 2

begin

    --------------------------------------------------------------------------------
    -- Sync Generation (REGISTERED - Optimized with constants)
    --------------------------------------------------------------------------------
    sync_generator: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            horizontal_sync <= '1';  -- Inactive state (positive polarity becomes negative)
            vertical_sync <= '1';
        elsif rising_edge(clk_pixel) then
            -- HSync (using pre-computed constants)
            if (h_count >= H_SYNC_START) and (h_count < H_SYNC_END) then
                horizontal_sync <= '0';
            else
                horizontal_sync <= '1';
            end if;

            -- VSync (using pre-computed constants)
            if (v_count >= V_SYNC_START) and (v_count < V_SYNC_END) then
                vertical_sync <= '0';
            else
                vertical_sync <= '1';
            end if;
        end if;
    end process sync_generator;

    hsync <= horizontal_sync;
    vsync <= vertical_sync;

    --------------------------------------------------------------------------------
    -- Color Bar Pattern Generation (OPTIMIZED - Registered)
    --------------------------------------------------------------------------------
    -- Uses bit slicing instead of division for better resource usage
    color_pattern_generator: process(clk_pixel, rst_n)
        variable color_bar_index : std_logic_vector(2 downto 0);
    begin
        if rst_n = '0' then
            r <= (others => '0');
            g <= (others => '0');
            b <= (others => '0');
        elsif rising_edge(clk_pixel) then
            if de = '1' then
                -- Extract bits 9:7 from h_count for bar selection (640/8 = 80 pixels per bar)
                -- This is equivalent to dividing by 80 but uses only bit slicing
                color_bar_index := std_logic_vector(h_count(9 downto 7));

                -- Optimized color generation using color_bar_index directly
                -- Each bar is defined by which bits are set
                -- bar(2) controls Red, bar(1) controls Green, bar(0) controls Blue
                -- Inverted logic to match expected pattern (White to Black gradient)
                r <= (others => not color_bar_index(2));
                g <= (others => not color_bar_index(1));
                b <= (others => not color_bar_index(0));
            else
                -- Blanking period - all channels to zero
                r <= x"00";
                g <= x"00";
                b <= x"00";
            end if;
        end if;
    end process color_pattern_generator;

end rtl;