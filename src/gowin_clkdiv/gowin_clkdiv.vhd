--Copyright (C)2014-2025 Gowin Semiconductor Corporation.
--All rights reserved.
--File Title: IP file
--Tool Version: V1.9.12 (64-bit)
--Part Number: GW1NR-LV9QN88C6/I5
--Device: GW1NR-9
--Device Version: C
--Created Time: Tue Oct  7 22:30:42 2025

library IEEE;
use IEEE.std_logic_1164.all;

entity Gowin_CLKDIV is
    port (
        clkout: out std_logic;
        hclkin: in std_logic;
        resetn: in std_logic
    );
end Gowin_CLKDIV;

architecture Behavioral of Gowin_CLKDIV is

    signal gw_gnd: std_logic;

    --component declaration
    component CLKDIV
        generic (
            GSREN: STRING := "false";
            DIV_MODE : STRING := "2"
        );
        port (
            CLKOUT: out std_logic;
            HCLKIN: in std_logic;
            RESETN: in std_logic;
            CALIB: in std_logic
        );
    end component;

begin
    gw_gnd <= '0';

    clkdiv_inst: CLKDIV
        generic map (
            GSREN => "false",
            DIV_MODE => "5"
        )
        port map (
            CLKOUT => clkout,
            HCLKIN => hclkin,
            RESETN => resetn,
            CALIB => gw_gnd
        );

end Behavioral; --Gowin_CLKDIV
