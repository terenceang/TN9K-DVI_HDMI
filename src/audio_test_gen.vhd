--------------------------------------------------------------------------------
-- Audio Test Tone Generator
--------------------------------------------------------------------------------
-- Description:
--   Generates simple test tones for HDMI audio verification
--   1 kHz sine wave at 48 kHz sample rate
--
-- Features:
--   - 48-sample sine lookup table
--   - Left/Right channel output
--   - Synchronous to audio_ce (48 kHz pulse)
--   - 16-bit signed output
--
-- Author: Tang Nano 9K HDMI Audio Project
-- Date: October 2025
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity audio_test_gen is
    port (
        clk         : in  std_logic;
        rst_n       : in  std_logic;
        audio_ce    : in  std_logic;  -- 48 kHz pulse
        enable      : in  std_logic := '1';
        volume      : in  std_logic_vector(3 downto 0) := (others => '0');  -- Right-shift attenuation (0 = full scale)
        audio_l     : out std_logic_vector(15 downto 0);
        audio_r     : out std_logic_vector(15 downto 0)
    );
end audio_test_gen;

architecture rtl of audio_test_gen is

    --------------------------------------------------------------------------------
    -- Sine Wave Lookup Table (48 samples @ 1 kHz, 48 kHz sample rate)
    --------------------------------------------------------------------------------
    type sine_lut_t is array (0 to 47) of signed(15 downto 0);
    
    -- 1 kHz sine wave: sin(2 * pi * n / 48) scaled to 16-bit
    -- Amplitude: 0x4000 (50% of full scale to avoid clipping)
    constant SINE_TABLE : sine_lut_t := (
        x"0000", x"0868", x"10B5", x"18F8", x"2120", x"2923", x"30FB", x"3896",
        x"3FFF", x"471C", x"4DEB", x"5464", x"5A82", x"603B", x"658B", x"6A6C",
        x"6ED8", x"72CC", x"763F", x"7935", x"7BAE", x"7DA3", x"7F0F", x"7FED",
        x"7FFF", x"7F42", x"7DB8", x"7B5C", x"7831", x"7438", x"6F74", x"69E8",
        x"6397", x"5C8A", x"54C2", x"4C42", x"4309", x"391F", x"2E8A", x"234F",
        x"176E", x"0AF0", x"FDDC", x"F048", x"E23A", x"D3C8", x"C4F6", x"B5D0"
    );
    
    --------------------------------------------------------------------------------
    -- Signals
    --------------------------------------------------------------------------------
    signal sample_index : integer range 0 to 47;
    signal audio_l_reg  : signed(15 downto 0);
    signal audio_r_reg  : signed(15 downto 0);

begin

    --------------------------------------------------------------------------------
    -- Tone Generator Process
    --------------------------------------------------------------------------------
    tone_gen: process(clk, rst_n)
        variable attenuation : natural;
        variable scaled_sample : signed(15 downto 0);
    begin
        if rst_n = '0' then
            sample_index <= 0;
            audio_l_reg <= (others => '0');
            audio_r_reg <= (others => '0');
            
        elsif rising_edge(clk) then
            if audio_ce = '1' and enable = '1' then
                -- Output current sample
                attenuation := to_integer(unsigned(volume));
                scaled_sample := shift_right(SINE_TABLE(sample_index), attenuation);
                audio_l_reg <= scaled_sample;
                audio_r_reg <= scaled_sample;
                
                -- Advance to next sample
                if sample_index = 47 then
                    sample_index <= 0;
                else
                    sample_index <= sample_index + 1;
                end if;
            elsif enable = '0' then
                -- Muted
                audio_l_reg <= (others => '0');
                audio_r_reg <= (others => '0');
            end if;
        end if;
    end process tone_gen;
    
    -- Output assignments
    audio_l <= std_logic_vector(audio_l_reg);
    audio_r <= std_logic_vector(audio_r_reg);

end rtl;
