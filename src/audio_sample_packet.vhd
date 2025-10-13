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
    
    --------------------------------------------------------------------------------
    -- Packet State Machine
    --------------------------------------------------------------------------------
    type state_t is (
        ST_IDLE,            -- Waiting for samples
        ST_BUILD_HEADER,    -- Building packet header
        ST_BUILD_SUBPKT0,   -- Subpacket 0 (samples 0-1)
        ST_BUILD_SUBPKT1,   -- Subpacket 1 (samples 2-3)
        ST_BUILD_SUBPKT2,   -- Subpacket 2 (samples 4-5)
        ST_BUILD_SUBPKT3,   -- Subpacket 3 (samples 6-7)
        ST_SEND_PACKET      -- Packet ready for transmission
    );
    signal state : state_t;
    
    --------------------------------------------------------------------------------
    -- Sample Storage (2 samples minimum for ASP)
    --------------------------------------------------------------------------------
    type sample_buf_t is array (0 to 1) of std_logic_vector(31 downto 0);
    signal sample_buffer : sample_buf_t;
    signal sample_count : unsigned(1 downto 0);  -- 0-2 samples stored
    
    --------------------------------------------------------------------------------
    -- Packet Storage (8 words × 32 bits)
    --------------------------------------------------------------------------------
    type packet_buf_t is array (0 to 7) of std_logic_vector(31 downto 0);
    signal packet_buffer : packet_buf_t;
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
    -- ASP Builder State Machine
    --------------------------------------------------------------------------------
    asp_builder: process(clk_pixel, rst_n)
        variable subpkt_byte_count : integer range 0 to 6;
    begin
        if rst_n = '0' then
            state <= ST_IDLE;
            sample_buffer <= (others => (others => '0'));
            packet_buffer <= (others => (others => '0'));
            sample_count <= (others => '0');
            word_index <= (others => '0');
            sample_ready_reg <= '1';
            packet_valid_reg <= '0';
            packet_start_reg <= '0';
            packet_end_reg <= '0';
            packet_data_reg <= (others => '0');
            
        elsif rising_edge(clk_pixel) then
            
            -- Default: accept samples when in IDLE
            sample_ready_reg <= '1' when state = ST_IDLE else '0';
            
            case state is
                
                --------------------------------------------------------------------
                -- IDLE: Collect samples from buffer
                --------------------------------------------------------------------
                when ST_IDLE =>
                    packet_valid_reg <= '0';
                    packet_start_reg <= '0';
                    packet_end_reg <= '0';
                    
                    -- Capture incoming samples
                    if sample_valid = '1' and sample_count < 2 then
                        sample_buffer(to_integer(sample_count)) <= sample_r & sample_l;
                        sample_count <= sample_count + 1;
                    end if;
                    
                    -- When we have at least 2 samples (1 stereo pair), build packet
                    if sample_count >= 1 then
                        state <= ST_BUILD_HEADER;
                        sample_ready_reg <= '0';
                    end if;
                
                --------------------------------------------------------------------
                -- BUILD_HEADER: Create ASP header
                --------------------------------------------------------------------
                when ST_BUILD_HEADER =>
                    -- ASP Header (3 bytes): Type | Subpacket Count | Reserved
                    -- Word 0: Type[7:0] | Count[15:8] | Reserved[23:16] | Reserved[31:24]
                    packet_buffer(0) <= x"00" & x"00" & x"04" & ASP_HEADER_TYPE;
                    word_index <= (others => '0');
                    state <= ST_BUILD_SUBPKT0;
                
                --------------------------------------------------------------------
                -- BUILD_SUBPKT0: Pack first sample pair
                --------------------------------------------------------------------
                when ST_BUILD_SUBPKT0 =>
                    -- Subpacket 0: Sample 0 L/R (16-bit each)
                    -- Word 1: L0[15:0] | R0[31:16]
                    if sample_count > 0 then
                        packet_buffer(1) <= sample_buffer(0);  -- L0, R0
                    else
                        packet_buffer(1) <= (others => '0');
                    end if;
                    state <= ST_BUILD_SUBPKT1;
                
                --------------------------------------------------------------------
                -- BUILD_SUBPKT1: Pack second sample pair (if available)
                --------------------------------------------------------------------
                when ST_BUILD_SUBPKT1 =>
                    -- Word 2: L1[15:0] | R1[31:16]
                    if sample_count > 1 then
                        packet_buffer(2) <= sample_buffer(1);  -- L1, R1
                    else
                        packet_buffer(2) <= (others => '0');
                    end if;
                    state <= ST_BUILD_SUBPKT2;
                
                --------------------------------------------------------------------
                -- BUILD_SUBPKT2: Pack third sample pair (zero for now)
                --------------------------------------------------------------------
                when ST_BUILD_SUBPKT2 =>
                    packet_buffer(3) <= (others => '0');  -- L2, R2 (no samples)
                    state <= ST_BUILD_SUBPKT3;
                
                --------------------------------------------------------------------
                -- BUILD_SUBPKT3: Pack fourth sample pair (zero for now)
                --------------------------------------------------------------------
                when ST_BUILD_SUBPKT3 =>
                    packet_buffer(4) <= (others => '0');  -- L3, R3 (no samples)
                    
                    -- Padding words
                    packet_buffer(5) <= (others => '0');
                    packet_buffer(6) <= (others => '0');
                    packet_buffer(7) <= (others => '0');
                    
                    state <= ST_SEND_PACKET;
                    word_index <= (others => '0');
                
                --------------------------------------------------------------------
                -- SEND_PACKET: Stream packet words to scheduler
                --------------------------------------------------------------------
                when ST_SEND_PACKET =>
                    -- Output current word
                    packet_data_reg <= packet_buffer(to_integer(word_index));
                    packet_valid_reg <= '1';
                    packet_start_reg <= '1' when word_index = 0 else '0';
                    packet_end_reg <= '1' when word_index = 7 else '0';
                    
                    -- Wait for scheduler ready
                    if packet_ready = '1' then
                        if word_index = 7 then
                            -- Packet complete
                            state <= ST_IDLE;
                            packet_valid_reg <= '0';
                            sample_count <= (others => '0');
                            sample_ready_reg <= '1';
                        else
                            -- Next word
                            word_index <= word_index + 1;
                        end if;
                    end if;
                
                when others =>
                    state <= ST_IDLE;
                    
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
            if state = ST_SEND_PACKET and word_index = 7 and packet_ready = '1' then
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
