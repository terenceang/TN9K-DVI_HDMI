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
    signal hsync_int, vsync_int : std_logic;

    -- Color bar width (640 / 8 = 80 pixels per bar)
    constant BAR_WIDTH : integer := H_ACTIVE / 8;

begin

    --------------------------------------------------------------------------------
    -- Sync Generation (REGISTERED)
    --------------------------------------------------------------------------------
    process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            hsync_int <= '1';  -- Inactive state (positive polarity becomes negative)
            vsync_int <= '1';
        elsif rising_edge(clk_pixel) then
            -- HSync
            if (h_count >= 640 + 16) and (h_count < 640 + 16 + 96) then
                hsync_int <= '0';
            else
                hsync_int <= '1';
            end if;

            -- VSync
            if (v_count >= 480 + 10) and (v_count < 480 + 10 + 2) then
                vsync_int <= '0';
            else
                vsync_int <= '1';
            end if;
        end if;
    end process;

    hsync <= hsync_int;
    vsync <= vsync_int;

    --------------------------------------------------------------------------------
    -- Color Bar Pattern Generation (REGISTERED to match sync timing)
    --------------------------------------------------------------------------------
    process(clk_pixel, rst_n)
        variable bar_select : integer range 0 to 7;
    begin
        if rst_n = '0' then
            r <= (others => '0');
            g <= (others => '0');
            b <= (others => '0');
        elsif rising_edge(clk_pixel) then
            if de = '1' then
                bar_select := to_integer(h_count) / BAR_WIDTH;

                case bar_select is
                    when 0 =>  -- White
                        r <= x"FF"; g <= x"FF"; b <= x"FF";
                    when 1 =>  -- Yellow
                        r <= x"FF"; g <= x"FF"; b <= x"00";
                    when 2 =>  -- Cyan
                        r <= x"00"; g <= x"FF"; b <= x"FF";
                    when 3 =>  -- Green
                        r <= x"00"; g <= x"FF"; b <= x"00";
                    when 4 =>  -- Magenta
                        r <= x"FF"; g <= x"00"; b <= x"FF";
                    when 5 =>  -- Red
                        r <= x"FF"; g <= x"00"; b <= x"00";
                    when 6 =>  -- Blue
                        r <= x"00"; g <= x"00"; b <= x"FF";
                    when 7 =>  -- Black
                        r <= x"00"; g <= x"00"; b <= x"00";
                    when others =>
                        r <= x"00"; g <= x"00"; b <= x"00";
                end case;
            else
                -- Blanking period
                r <= x"00";
                g <= x"00";
                b <= x"00";
            end if;
        end if;
    end process;

end rtl;