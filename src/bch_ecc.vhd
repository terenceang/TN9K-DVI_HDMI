--------------------------------------------------------------------------------
-- BCH Error Correction Code (ECC) Calculator
--------------------------------------------------------------------------------
-- Description:
--   Calculates 8-bit BCH ECC for HDMI packet headers
--   Per HDMI 1.4a spec section 5.2.3.1
--
--   Protects 3-byte packet header (HB0, HB1, HB2) with 8-bit ECC
--   ECC is transmitted as 4th byte in subpacket 0
--
--   BCH polynomial: x^8 + x^2 + x + 1 (0x107)
--
-- Usage:
--   Input: 24-bit header (HB0 & HB1 & HB2)
--   Output: 8-bit ECC
--
-- Author: Tang Nano 9K HDMI Audio Project
-- Date: October 2025
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity bch_ecc is
    port (
        -- Input: 24-bit packet header (HB0, HB1, HB2)
        header_in   : in  std_logic_vector(23 downto 0);
        
        -- Output: 8-bit BCH ECC
        ecc_out     : out std_logic_vector(7 downto 0)
    );
end bch_ecc;

architecture rtl of bch_ecc is

    --------------------------------------------------------------------------------
    -- BCH Polynomial Calculation
    --------------------------------------------------------------------------------
    -- BCH code for HDMI: systematic code with generator polynomial g(x) = x^8 + x^2 + x + 1
    -- Division by 0x107 in GF(2)
    --------------------------------------------------------------------------------
    
    function calculate_bch_ecc(header : std_logic_vector(23 downto 0)) return std_logic_vector is
        variable temp : std_logic_vector(31 downto 0);
        variable ecc : std_logic_vector(7 downto 0);
        variable feedback : std_logic;
    begin
        -- Initialize with header shifted left by 8 bits (multiply by x^8)
        temp := header & x"00";
        
        -- Perform polynomial division (24 iterations for 24 data bits)
        for i in 23 downto 0 loop
            feedback := temp(31);
            
            -- Shift left
            temp := temp(30 downto 0) & '0';
            
            -- XOR with generator polynomial if feedback bit is 1
            if feedback = '1' then
                -- Generator polynomial: x^8 + x^2 + x + 1
                -- As bit pattern: bit 8, 2, 1, 0 = 0x00000107
                -- After shift, XOR with 0x0000010E (shifted by 1)
                temp(8) := temp(8) xor '1';  -- x^8 term
                temp(2) := temp(2) xor '1';  -- x^2 term
                temp(1) := temp(1) xor '1';  -- x term
                temp(0) := temp(0) xor '1';  -- constant term
            end if;
        end loop;
        
        -- Remainder is the ECC (lower 8 bits)
        ecc := temp(7 downto 0);
        
        return ecc;
    end function calculate_bch_ecc;

begin

    --------------------------------------------------------------------------------
    -- Combinational ECC Calculation
    --------------------------------------------------------------------------------
    ecc_out <= calculate_bch_ecc(header_in);

end rtl;
