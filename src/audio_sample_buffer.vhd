--------------------------------------------------------------------------------
-- Audio Sample Buffer (FIFO)
--------------------------------------------------------------------------------
-- Description:
--   4-entry ping-pong buffer for 16-bit stereo (L/R) audio samples
--   Entirely in pixel clock domain - no CDC required
--
--   Captures samples on audio_ce when audio_valid is asserted
--   Provides registered outputs to ASP builder with ready/valid handshake
--
-- Features:
--   - 4-sample deep FIFO (2 stereo pairs)
--   - Registered outputs (no combinational paths)
--   - Almost-full/empty flags for flow control
--   - Synthesis attributes to prevent optimization
--
-- Clock Domain: Pixel clock (25.2 MHz)
-- Author: Tang Nano 9K HDMI Audio Project
-- Date: October 2025
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity audio_sample_buffer is
    port (
        -- Clock and reset
        clk_pixel       : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Audio input (from external source or test generator)
        audio_ce        : in  std_logic;                        -- 48 kHz pulse
        audio_l         : in  std_logic_vector(15 downto 0);    -- Left channel
        audio_r         : in  std_logic_vector(15 downto 0);    -- Right channel
        audio_valid     : in  std_logic;                        -- Data valid with audio_ce
        
        -- Output to ASP builder (registered)
        asp_sample_l    : out std_logic_vector(15 downto 0);
        asp_sample_r    : out std_logic_vector(15 downto 0);
        asp_valid       : out std_logic;                        -- Sample pair available
        asp_ready       : in  std_logic;                        -- ASP ready to consume
        
        -- Status flags
        buf_empty       : out std_logic;
        buf_almost_full : out std_logic;                        -- ≥3 samples (warn source)
        
        -- Debug counters (observable for synthesis)
        dbg_samples_in  : out std_logic_vector(15 downto 0);
        dbg_samples_out : out std_logic_vector(15 downto 0)
    );
end audio_sample_buffer;

architecture rtl of audio_sample_buffer is

    --------------------------------------------------------------------------------
    -- FIFO Storage (4 entries × 32 bits each = 128 bits total)
    --------------------------------------------------------------------------------
    type sample_array_t is array (0 to 3) of std_logic_vector(31 downto 0);
    signal fifo_mem : sample_array_t;
    
    --------------------------------------------------------------------------------
    -- FIFO Pointers
    --------------------------------------------------------------------------------
    signal wr_ptr : unsigned(1 downto 0);  -- Write pointer (0-3)
    signal rd_ptr : unsigned(1 downto 0);  -- Read pointer (0-3)
    signal count  : unsigned(2 downto 0);  -- Fill level (0-4)
    
    --------------------------------------------------------------------------------
    -- Internal Signals (registered)
    --------------------------------------------------------------------------------
    signal sample_l_reg   : std_logic_vector(15 downto 0);
    signal sample_r_reg   : std_logic_vector(15 downto 0);
    signal valid_reg      : std_logic;
    signal empty_flag     : std_logic;
    signal almost_full_flag : std_logic;
    
    --------------------------------------------------------------------------------
    -- Debug Counters
    --------------------------------------------------------------------------------
    signal samples_in_count  : unsigned(15 downto 0);
    signal samples_out_count : unsigned(15 downto 0);
    
    --------------------------------------------------------------------------------
    -- Synthesis Attributes
    --------------------------------------------------------------------------------
    attribute syn_preserve : boolean;
    attribute syn_keep : boolean;
    
    attribute syn_preserve of valid_reg : signal is true;
    attribute syn_preserve of samples_in_count : signal is true;
    attribute syn_preserve of samples_out_count : signal is true;
    attribute syn_keep of valid_reg : signal is true;

begin

    --------------------------------------------------------------------------------
    -- FIFO Control Process (read/write/count/flags/debug consolidated)
    --------------------------------------------------------------------------------
    fifo_core: process(clk_pixel, rst_n)
        variable current_sample : std_logic_vector(31 downto 0);
        variable write_fire     : boolean;
        variable read_fire      : boolean;
        variable next_count     : unsigned(2 downto 0);
    begin
        if rst_n = '0' then
            wr_ptr <= (others => '0');
            rd_ptr <= (others => '0');
            count  <= (others => '0');
            empty_flag <= '1';
            almost_full_flag <= '0';
            sample_l_reg <= (others => '0');
            sample_r_reg <= (others => '0');
            valid_reg <= '0';
            samples_in_count <= (others => '0');
            samples_out_count <= (others => '0');
            for i in 0 to 3 loop
                fifo_mem(i) <= (others => '0');
            end loop;
        elsif rising_edge(clk_pixel) then
            -- Determine read/write events for this cycle
            write_fire := (audio_ce = '1' and audio_valid = '1');
            read_fire  := (count /= 0 and (asp_ready = '1' or valid_reg = '0'));

            -- Prevent overflow: block write when full without simultaneous read
            if write_fire and count = 4 and not read_fire then
                write_fire := false;
            end if;

            -- Read path
            if read_fire then
                current_sample := fifo_mem(to_integer(rd_ptr));
                sample_l_reg <= current_sample(15 downto 0);
                sample_r_reg <= current_sample(31 downto 16);
                valid_reg <= '1';
                rd_ptr <= rd_ptr + 1;
            elsif asp_ready = '1' then
                -- Consumed current sample without new data ready
                valid_reg <= '0';
            end if;

            -- Write path
            if write_fire then
                fifo_mem(to_integer(wr_ptr)) <= audio_r & audio_l;
                wr_ptr <= wr_ptr + 1;
            end if;

            -- Update count and status flags
            next_count := count;
            if write_fire then
                next_count := next_count + 1;
            end if;
            if read_fire then
                next_count := next_count - 1;
            end if;
            count <= next_count;

            if next_count = 0 then
                empty_flag <= '1';
            else
                empty_flag <= '0';
            end if;

            if next_count >= 3 then
                almost_full_flag <= '1';
            else
                almost_full_flag <= '0';
            end if;

            -- Debug counters
            if write_fire then
                samples_in_count <= samples_in_count + 1;
            end if;
            if read_fire then
                samples_out_count <= samples_out_count + 1;
            end if;
        end if;
    end process fifo_core;
    
    --------------------------------------------------------------------------------
    -- Output Assignments (all registered)
    --------------------------------------------------------------------------------
    asp_sample_l <= sample_l_reg;
    asp_sample_r <= sample_r_reg;
    asp_valid <= valid_reg;
    buf_empty <= empty_flag;
    buf_almost_full <= almost_full_flag;
    dbg_samples_in <= std_logic_vector(samples_in_count);
    dbg_samples_out <= std_logic_vector(samples_out_count);

end rtl;
