--------------------------------------------------------------------------------
-- Audio Sample Packet (ASP) Builder
--------------------------------------------------------------------------------
-- Description:
--   Packs 16-bit stereo LPCM audio samples into HDMI Audio Sample Packets
--   Per HDMI 1.4a spec section 5.3.3
--
--   Packet structure (32 bytes total):
--     Header (3 bytes): 0x02 (type), subpacket count, reserved
--     Subpackets (4 × 7 bytes): Sample data
--
--   For 16-bit stereo, packs 2 samples (L0, R0, L1, R1) per subpacket
--
-- Features:
--   - Registered outputs (no combinational path to TERC4)
--   - Back-pressure handling via ready/valid
--   - Synthesis attributes to prevent optimization
--
-- Clock Domain: Pixel clock (25.2 MHz)
-- Author: Tang Nano 9K HDMI Audio Project
-- Date: October 2025
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity audio_sample_packet is
    port (
        -- Clock and reset
        clk_pixel       : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Input from audio buffer (registered)
        sample_l        : in  std_logic_vector(15 downto 0);
        sample_r        : in  std_logic_vector(15 downto 0);
        sample_valid    : in  std_logic;
        sample_ready    : out std_logic;
        
        -- Output to scheduler (registered)
        packet_data     : out std_logic_vector(31 downto 0);  -- 32-bit word
        packet_valid    : out std_logic;                      -- Packet ready
        packet_ready    : in  std_logic;                      -- Scheduler accepts
        packet_start    : out std_logic;                      -- First word of packet
        packet_end      : out std_logic;                      -- Last word of packet
        
        -- Debug counters (observable for synthesis)
        dbg_packets_sent : out std_logic_vector(15 downto 0)
    );
end audio_sample_packet;

architecture rtl of audio_sample_packet is

    --------------------------------------------------------------------------------
    -- ASP Packet Constants
    --------------------------------------------------------------------------------
    constant ASP_HEADER_TYPE : std_logic_vector(7 downto 0) := x"02";  -- Audio Sample Packet
    constant HEADER_WORD     : std_logic_vector(31 downto 0) := x"00000402";
    
    --------------------------------------------------------------------------------
    -- Packet State Machine
    --------------------------------------------------------------------------------
    type state_t is (
        ST_WAIT_SAMPLES,    -- Collect incoming samples
        ST_STREAM_PACKET    -- Stream packet words to scheduler
    );
    signal state : state_t;
    
    --------------------------------------------------------------------------------
    -- Sample Storage (2 samples minimum for ASP)
    --------------------------------------------------------------------------------
    type sample_buf_t is array (0 to 1) of std_logic_vector(31 downto 0);
    signal sample_buffer : sample_buf_t;
    signal sample_count : unsigned(1 downto 0);  -- 0-2 samples stored
    
    function packet_word_for(
        idx      : natural;
        samples  : sample_buf_t;
        stored   : unsigned(1 downto 0)
    ) return std_logic_vector is
        constant ZERO32 : std_logic_vector(31 downto 0) := (others => '0');
        variable stored_int : integer;
    begin
        stored_int := to_integer(stored);
        case idx is
            when 0 =>
                return HEADER_WORD;
            when 1 =>
                if stored_int >= 1 then
                    return samples(0);
                else
                    return ZERO32;
                end if;
            when 2 =>
                if stored_int >= 2 then
                    return samples(1);
                else
                    return ZERO32;
                end if;
            when others =>
                return ZERO32;
        end case;
    end function packet_word_for;

    --------------------------------------------------------------------------------
    -- Packet Storage (8 words × 32 bits)
    --------------------------------------------------------------------------------
    signal word_index : unsigned(2 downto 0);  -- 0-7
    
    --------------------------------------------------------------------------------
    -- Output Registers
    --------------------------------------------------------------------------------
    signal packet_data_reg  : std_logic_vector(31 downto 0);
    signal packet_valid_reg : std_logic;
    signal packet_start_reg : std_logic;
    signal packet_end_reg   : std_logic;
    signal sample_ready_reg : std_logic;
    
    --------------------------------------------------------------------------------
    -- Debug Counter
    --------------------------------------------------------------------------------
    signal packets_sent_count : unsigned(15 downto 0);
    
    --------------------------------------------------------------------------------
    -- Synthesis Attributes
    --------------------------------------------------------------------------------
    attribute syn_preserve : boolean;
    attribute syn_keep : boolean;
    
    attribute syn_preserve of packet_valid_reg : signal is true;
    attribute syn_preserve of packets_sent_count : signal is true;
    attribute syn_keep of packet_valid_reg : signal is true;

begin

    --------------------------------------------------------------------------------
    -- ASP Builder State Machine (two-stage: collect samples, then stream packet)
    --------------------------------------------------------------------------------
    asp_builder: process(clk_pixel, rst_n)
        variable can_accept_sample : boolean;
        variable capture_sample    : boolean;
    begin
        if rst_n = '0' then
            state <= ST_WAIT_SAMPLES;
            sample_buffer <= (others => (others => '0'));
            sample_count <= (others => '0');
            word_index <= (others => '0');
            packet_data_reg <= (others => '0');
            packet_valid_reg <= '0';
            packet_start_reg <= '0';
            packet_end_reg <= '0';
            sample_ready_reg <= '1';

        elsif rising_edge(clk_pixel) then

            -- Determine if we can accept a new sample pair this cycle
            can_accept_sample := (state = ST_WAIT_SAMPLES) and (sample_count < 2);
            capture_sample := (sample_valid = '1') and can_accept_sample;

            if can_accept_sample then
                sample_ready_reg <= '1';
            else
                sample_ready_reg <= '0';
            end if;

            if capture_sample then
                sample_buffer(to_integer(sample_count)) <= sample_r & sample_l;
                sample_count <= sample_count + 1;
            end if;

            case state is

                ----------------------------------------------------------------
                -- WAIT_SAMPLES: collect up to two stereo pairs
                ----------------------------------------------------------------
                when ST_WAIT_SAMPLES =>
                    packet_valid_reg <= '0';
                    packet_start_reg <= '0';
                    packet_end_reg <= '0';
                    packet_data_reg <= (others => '0');

                    if to_integer(sample_count) >= 1 then
                        state <= ST_STREAM_PACKET;
                        word_index <= (others => '0');
                    end if;

                ----------------------------------------------------------------
                -- STREAM_PACKET: provide eight 32-bit words to scheduler
                ----------------------------------------------------------------
                when ST_STREAM_PACKET =>
                    packet_data_reg <= packet_word_for(to_integer(word_index), sample_buffer, sample_count);
                    packet_valid_reg <= '1';

                    if word_index = 0 then
                        packet_start_reg <= '1';
                    else
                        packet_start_reg <= '0';
                    end if;

                    if word_index = 7 then
                        packet_end_reg <= '1';
                    else
                        packet_end_reg <= '0';
                    end if;

                    if packet_ready = '1' then
                        if word_index = 7 then
                            state <= ST_WAIT_SAMPLES;
                            packet_valid_reg <= '0';
                            packet_start_reg <= '0';
                            packet_end_reg <= '0';
                            packet_data_reg <= (others => '0');
                            sample_count <= (others => '0');
                        else
                            word_index <= word_index + 1;
                        end if;
                    end if;

                when others =>
                    state <= ST_WAIT_SAMPLES;

            end case;
        end if;
    end process asp_builder;
    
    --------------------------------------------------------------------------------
    -- Debug Counter
    --------------------------------------------------------------------------------
    debug_counter: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            packets_sent_count <= (others => '0');
        elsif rising_edge(clk_pixel) then
            if state = ST_STREAM_PACKET and word_index = 7 and packet_ready = '1' then
                packets_sent_count <= packets_sent_count + 1;
            end if;
        end if;
    end process debug_counter;
    
    --------------------------------------------------------------------------------
    -- Output Assignments (all registered)
    --------------------------------------------------------------------------------
    packet_data <= packet_data_reg;
    packet_valid <= packet_valid_reg;
    packet_start <= packet_start_reg;
    packet_end <= packet_end_reg;
    sample_ready <= sample_ready_reg;
    dbg_packets_sent <= std_logic_vector(packets_sent_count);

end rtl;
