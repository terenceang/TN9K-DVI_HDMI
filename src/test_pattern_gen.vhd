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
    -- Color Bar Pattern Generation (8-Bar Standard Pattern)
    --------------------------------------------------------------------------------
    -- Generates standard SMPTE color bars: White, Yellow, Cyan, Green, Magenta, Red, Blue, Black
    -- Each bar is exactly 80 pixels wide (640/8 = 80)
    color_pattern_generator: process(clk_pixel, rst_n)
        variable bar_index : integer range 0 to 7;
    begin
        if rst_n = '0' then
            r <= (others => '0');
            g <= (others => '0');
            b <= (others => '0');
        elsif rising_edge(clk_pixel) then
            if de = '1' then
                -- Calculate bar index: 0-7 based on horizontal position
                -- Divide h_count by 80 to get bar number (0-7)
                -- h_count: 0-79 → bar 0, 80-159 → bar 1, ..., 560-639 → bar 7
                bar_index := to_integer(h_count(9 downto 0)) / 80;
                
                -- Clamp to valid range (defensive programming)
                if bar_index > 7 then
                    bar_index := 7;
                end if;

                -- Generate 8-color bar pattern with explicit case statement
                -- Standard SMPTE color bar pattern (left to right):
                case bar_index is
                    when 0 =>  -- Bar 0 (0-79): White (R=1, G=1, B=1)
                        r <= x"FF";
                        g <= x"FF";
                        b <= x"FF";
                    when 1 =>  -- Bar 1 (80-159): Yellow (R=1, G=1, B=0)
                        r <= x"FF";
                        g <= x"FF";
                        b <= x"00";
                    when 2 =>  -- Bar 2 (160-239): Cyan (R=0, G=1, B=1)
                        r <= x"00";
                        g <= x"FF";
                        b <= x"FF";
                    when 3 =>  -- Bar 3 (240-319): Green (R=0, G=1, B=0)
                        r <= x"00";
                        g <= x"FF";
                        b <= x"00";
                    when 4 =>  -- Bar 4 (320-399): Magenta (R=1, G=0, B=1)
                        r <= x"FF";
                        g <= x"00";
                        b <= x"FF";
                    when 5 =>  -- Bar 5 (400-479): Red (R=1, G=0, B=0)
                        r <= x"FF";
                        g <= x"00";
                        b <= x"00";
                    when 6 =>  -- Bar 6 (480-559): Blue (R=0, G=0, B=1)
                        r <= x"00";
                        g <= x"00";
                        b <= x"FF";
                    when 7 =>  -- Bar 7 (560-639): Black (R=0, G=0, B=0)
                        r <= x"00";
                        g <= x"00";
                        b <= x"00";
                    when others =>
                        r <= x"00";
                        g <= x"00";
                        b <= x"00";
                end case;
            else
                -- Blanking period - all channels to zero
                r <= x"00";
                g <= x"00";
                b <= x"00";
            end if;
        end if;
    end process color_pattern_generator;

end rtl;