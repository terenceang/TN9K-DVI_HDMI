--------------------------------------------------------------------------------
-- TERC4 Encoder (4-bit to 10-bit)
--------------------------------------------------------------------------------
-- Description:
--   Encodes 4-bit data into 10-bit TERC4 symbols for HDMI data islands
--   Per HDMI 1.4a spec section 5.4.3
--
--   TERC4 encoding provides DC-balanced transmission of packet data
--   Used during data island periods (between guard bands)
--
--   Encoding Table (from HDMI spec):
--     0x0 → 0b1010011100
--     0x1 → 0b1001100011
--     ...
--     0xF → 0b0101100011
--
-- Features:
--   - Registered output (no combinational path to serializer)
--   - Full TERC4 lookup table
--   - Support for guard bands and preambles
--
-- Clock Domain: Pixel clock (25.2 MHz)
-- Author: Tang Nano 9K HDMI Audio Project
-- Date: October 2025
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity terc4_encoder is
    port (
        -- Clock and reset
        clk_pixel       : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Input data (4-bit)
        data_in         : in  std_logic_vector(3 downto 0);
        
        -- Control signals
        encode_enable   : in  std_logic;  -- Enable TERC4 encoding
        guard_band      : in  std_logic;  -- Generate guard band
        preamble        : in  std_logic;  -- Generate preamble
        
        -- Output (10-bit TERC4 symbol)
        data_out        : out std_logic_vector(9 downto 0)
    );
end terc4_encoder;

architecture rtl of terc4_encoder is

    --------------------------------------------------------------------------------
    -- TERC4 Encoding Constants (per HDMI spec Table 5-6)
    --------------------------------------------------------------------------------
    type terc4_lut_t is array (0 to 15) of std_logic_vector(9 downto 0);
    constant TERC4_LUT : terc4_lut_t := (
        0  => "1010011100",  -- 0x0
        1  => "1001100011",  -- 0x1
        2  => "1011100100",  -- 0x2
        3  => "1011100010",  -- 0x3
        4  => "0101110001",  -- 0x4
        5  => "0100011110",  -- 0x5
        6  => "0110001110",  -- 0x6
        7  => "0100111100",  -- 0x7
        8  => "1011001100",  -- 0x8
        9  => "0100111001",  -- 0x9
        10 => "0110011100",  -- 0xA
        11 => "1011000110",  -- 0xB
        12 => "1010001110",  -- 0xC
        13 => "1001110001",  -- 0xD
        14 => "0101100011",  -- 0xE
        15 => "1011000011"   -- 0xF
    );
    
    --------------------------------------------------------------------------------
    -- Guard Band Symbols (per HDMI spec section 5.2.3.4)
    --------------------------------------------------------------------------------
    -- Guard bands separate video data from data islands
    -- Different patterns for channels 0, 1, 2
    constant GB_CHANNEL_0 : std_logic_vector(9 downto 0) := "1011001100";  -- GB0
    constant GB_CHANNEL_1 : std_logic_vector(9 downto 0) := "0100110011";  -- GB1
    constant GB_CHANNEL_2 : std_logic_vector(9 downto 0) := "1011001100";  -- GB2
    
    --------------------------------------------------------------------------------
    -- Preamble Symbols (per HDMI spec section 5.2.3.3)
    --------------------------------------------------------------------------------
    -- Preambles signal the start of data islands
    -- CTL0=1, CTL1=0, CTL2=0, CTL3=1 for data island preamble
    constant PREAMBLE_CHANNEL_0 : std_logic_vector(9 downto 0) := "1101010100";
    constant PREAMBLE_CHANNEL_1 : std_logic_vector(9 downto 0) := "0010101011";
    constant PREAMBLE_CHANNEL_2 : std_logic_vector(9 downto 0) := "0010101011";
    
    --------------------------------------------------------------------------------
    -- Output Register
    --------------------------------------------------------------------------------
    signal data_out_reg : std_logic_vector(9 downto 0);
    
begin

    --------------------------------------------------------------------------------
    -- TERC4 Encoding Process
    --------------------------------------------------------------------------------
    terc4_encode: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            data_out_reg <= (others => '0');
            
        elsif rising_edge(clk_pixel) then
            
            if preamble = '1' then
                ----------------------------------------------------------------
                -- Preamble: Signals start of data island
                ----------------------------------------------------------------
                -- Use channel 0 preamble (can be parameterized for multi-channel)
                data_out_reg <= PREAMBLE_CHANNEL_0;
                
            elsif guard_band = '1' then
                ----------------------------------------------------------------
                -- Guard Band: Separates video data from data islands
                ----------------------------------------------------------------
                -- Use channel 0 guard band (can be parameterized for multi-channel)
                data_out_reg <= GB_CHANNEL_0;
                
            elsif encode_enable = '1' then
                ----------------------------------------------------------------
                -- TERC4 Encoding: Lookup 4-bit input in table
                ----------------------------------------------------------------
                data_out_reg <= TERC4_LUT(to_integer(unsigned(data_in)));
                
            else
                ----------------------------------------------------------------
                -- Default: Output zeros (or could pass through video data)
                ----------------------------------------------------------------
                data_out_reg <= (others => '0');
            end if;
            
        end if;
    end process terc4_encode;
    
    --------------------------------------------------------------------------------
    -- Output Assignment (registered)
    --------------------------------------------------------------------------------
    data_out <= data_out_reg;

end rtl;
