--------------------------------------------------------------------------------
-- HDMI Encoder with Audio Support
--------------------------------------------------------------------------------
-- Description:
--   HDMI/DVI encoder with full audio support
--   Video: 640×480@60Hz (25.2 MHz pixel clock)
--   Audio: 16-bit LPCM, 2-channel, 48 kHz
--
-- Features:
--   - TMDS video encoding
--   - Audio packet transmission (ACR, ASP, AIF, AVI)
--   - TERC4 encoding for data islands
--   - Back-porch packet scheduling
--   - Registered pipeline (no combinational cones)
--
-- Author: Tang Nano 9K HDMI Audio Project
-- Date: October 2025
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.hdmi_config_pkg.all;

entity hdmi_encoder is
    generic (
        TIMING : video_timing_t := HDMI_TIMING_640x480;
        AUDIO  : audio_config_t := HDMI_AUDIO_DEFAULT
    );
    port (
        -- Clocks and reset
        clk_pixel   : in  std_logic;
        clk_serial  : in  std_logic;
        rst_n       : in  std_logic;
        
        -- Video inputs
        hsync       : in  std_logic;
        vsync       : in  std_logic;
        r           : in  std_logic_vector(7 downto 0);
        g           : in  std_logic_vector(7 downto 0);
        b           : in  std_logic_vector(7 downto 0);
        
        -- Audio inputs
        audio_ce    : in  std_logic;
        audio_l     : in  std_logic_vector(15 downto 0);
        audio_r     : in  std_logic_vector(15 downto 0);
        audio_valid : in  std_logic := '1';
        audio_mute  : in  std_logic := '0';
        
        -- Timing outputs
        h_count_out     : out unsigned(10 downto 0);
        v_count_out     : out unsigned(9 downto 0);
        de_debug        : out std_logic;
        
        -- Debug outputs (observable for synthesis)
        dbg_audio_tx_cnt  : out std_logic_vector(15 downto 0);
        dbg_island_active : out std_logic;
        dbg_packet_type   : out std_logic_vector(2 downto 0);
        
        -- TMDS outputs
        tmds_clk_p  : out std_logic;
        tmds_clk_n  : out std_logic;
        tmds_data_p : out std_logic_vector(2 downto 0);
        tmds_data_n : out std_logic_vector(2 downto 0)
    );
end hdmi_encoder;

architecture rtl of hdmi_encoder is

    --------------------------------------------------------------------------------
    -- Component Declarations
    --------------------------------------------------------------------------------
    
    component tmds_encoder
        port (
            clk         : in  std_logic;
            rst_n       : in  std_logic;
            de          : in  std_logic;
            ctrl        : in  std_logic_vector(1 downto 0);
            data_island : in  std_logic;
            din         : in  std_logic_vector(7 downto 0);
            data_in     : in  std_logic_vector(9 downto 0);  -- 10-bit pre-encoded TERC4
            dout        : out std_logic_vector(9 downto 0)
        );
    end component;
    
    component audio_sample_buffer
        port (
            clk_pixel       : in  std_logic;
            rst_n           : in  std_logic;
            audio_ce        : in  std_logic;
            audio_l         : in  std_logic_vector(15 downto 0);
            audio_r         : in  std_logic_vector(15 downto 0);
            audio_valid     : in  std_logic;
            asp_sample_l    : out std_logic_vector(15 downto 0);
            asp_sample_r    : out std_logic_vector(15 downto 0);
            asp_valid       : out std_logic;
            asp_ready       : in  std_logic;
            buf_empty       : out std_logic;
            buf_almost_full : out std_logic;
            dbg_samples_in  : out std_logic_vector(15 downto 0);
            dbg_samples_out : out std_logic_vector(15 downto 0)
        );
    end component;
    
    component audio_sample_packet
        port (
            clk_pixel       : in  std_logic;
            rst_n           : in  std_logic;
            sample_l        : in  std_logic_vector(15 downto 0);
            sample_r        : in  std_logic_vector(15 downto 0);
            sample_valid    : in  std_logic;
            sample_ready    : out std_logic;
            packet_data     : out std_logic_vector(31 downto 0);
            packet_valid    : out std_logic;
            packet_ready    : in  std_logic;
            packet_start    : out std_logic;
            packet_end      : out std_logic;
            dbg_packets_sent : out std_logic_vector(15 downto 0)
        );
    end component;
    
    component acr_packet
        generic (
            AUDIO_SAMPLE_RATE : integer;
            PIXEL_CLK_FREQ    : integer;
            ACR_INTERVAL      : integer;
            N_VALUE           : integer
        );
        port (
            clk_pixel       : in  std_logic;
            rst_n           : in  std_logic;
            vsync_rising    : in  std_logic;
            acr_data        : out std_logic_vector(31 downto 0);
            acr_valid       : out std_logic;
            acr_ready       : in  std_logic;
            acr_start       : out std_logic;
            acr_end         : out std_logic;
            acr_request     : out std_logic;
            dbg_acr_sent    : out std_logic_vector(15 downto 0)
        );
    end component;
    
    component audio_infoframe
        port (
            clk_pixel       : in  std_logic;
            rst_n           : in  std_logic;
            vsync_rising    : in  std_logic;
            aif_data        : out std_logic_vector(31 downto 0);
            aif_valid       : out std_logic;
            aif_ready       : in  std_logic;
            aif_start       : out std_logic;
            aif_end         : out std_logic;
            aif_request     : out std_logic;
            dbg_aif_sent    : out std_logic_vector(15 downto 0)
        );
    end component;
    
    component avi_infoframe
        port (
            clk_pixel       : in  std_logic;
            rst_n           : in  std_logic;
            vsync_rising    : in  std_logic;
            avi_data        : out std_logic_vector(31 downto 0);
            avi_valid       : out std_logic;
            avi_ready       : in  std_logic;
            avi_start       : out std_logic;
            avi_end         : out std_logic;
            avi_request     : out std_logic;
            dbg_avi_sent    : out std_logic_vector(15 downto 0)
        );
    end component;
    
    component packet_scheduler
        generic (
            TIMING : video_timing_t
        );
        port (
            clk_pixel       : in  std_logic;
            rst_n           : in  std_logic;
            h_count         : in  unsigned(10 downto 0);
            v_count         : in  unsigned(9 downto 0);
            vsync_rising    : in  std_logic;
            acr_data        : in  std_logic_vector(31 downto 0);
            acr_valid       : in  std_logic;
            acr_ready       : out std_logic;
            acr_request     : in  std_logic;
            asp_data        : in  std_logic_vector(31 downto 0);
            asp_valid       : in  std_logic;
            asp_ready       : out std_logic;
            aif_data        : in  std_logic_vector(31 downto 0);
            aif_valid       : in  std_logic;
            aif_ready       : out std_logic;
            aif_request     : in  std_logic;
            avi_data        : in  std_logic_vector(31 downto 0);
            avi_valid       : in  std_logic;
            avi_ready       : out std_logic;
            avi_request     : in  std_logic;
            island_active   : out std_logic;
            preamble_active : out std_logic;
            guard_band      : out std_logic;
            packet_data     : out std_logic_vector(31 downto 0);
            dbg_island_active : out std_logic;
            dbg_packet_type : out std_logic_vector(2 downto 0);
            dbg_scheduler_state : out std_logic_vector(3 downto 0)
        );
    end component;
    
    component terc4_encoder
        port (
            clk_pixel       : in  std_logic;
            rst_n           : in  std_logic;
            data_in         : in  std_logic_vector(3 downto 0);
            encode_enable   : in  std_logic;
            guard_band      : in  std_logic;
            preamble        : in  std_logic;
            data_out        : out std_logic_vector(9 downto 0)
        );
    end component;

    
    component OSER10
        port (
            Q     : out std_logic;
            D0    : in  std_logic;
            D1    : in  std_logic;
            D2    : in  std_logic;
            D3    : in  std_logic;
            D4    : in  std_logic;
            D5    : in  std_logic;
            D6    : in  std_logic;
            D7    : in  std_logic;
            D8    : in  std_logic;
            D9    : in  std_logic;
            PCLK  : in  std_logic;
            FCLK  : in  std_logic;
            RESET : in  std_logic
        );
    end component;

    component ELVDS_OBUF
        port (
            I  : in  std_logic;
            O  : out std_logic;
            OB : out std_logic
        );
    end component;

    --------------------------------------------------------------------------------
    -- Timing Signals
    --------------------------------------------------------------------------------
    signal horizontal_position  : unsigned(10 downto 0) := (others => '0');
    signal vertical_position    : unsigned(9 downto 0)  := (others => '0');
    signal data_enable          : std_logic;
   signal sync_control_signals : std_logic_vector(1 downto 0);
   signal dvi_mode             : std_logic;
    
    -- Vsync edge detection
    signal vsync_prev    : std_logic;
    signal vsync_rising  : std_logic;

    --------------------------------------------------------------------------------
    -- Derived Timing/Audio Constants (Single Source of Truth)
    --------------------------------------------------------------------------------
    constant H_ACTIVE        : integer := TIMING.h_active;
    constant H_TOTAL         : integer := TIMING.h_total;
    constant H_ACTIVE_START  : integer := TIMING.h_active_start;
    constant H_ACTIVE_END    : integer := H_ACTIVE_START + H_ACTIVE;

    constant V_ACTIVE        : integer := TIMING.v_active;
    constant V_TOTAL         : integer := TIMING.v_total;
    constant V_ACTIVE_START  : integer := TIMING.v_active_start;
    constant V_ACTIVE_END    : integer := V_ACTIVE_START + V_ACTIVE;

    constant PIXEL_CLK_FREQ     : integer := AUDIO.pixel_clock_hz;
    constant AUDIO_SAMPLE_RATE  : integer := AUDIO.sample_rate;
    constant ACR_N_VALUE        : integer := AUDIO.acr_n_value;
    constant ACR_INTERVAL       : integer := AUDIO.acr_interval;

    constant H_ACTIVE_START_U : unsigned(horizontal_position'range) := to_unsigned(H_ACTIVE_START, horizontal_position'length);
    constant H_ACTIVE_END_U   : unsigned(horizontal_position'range) := to_unsigned(H_ACTIVE_END, horizontal_position'length);
    constant V_ACTIVE_START_U : unsigned(vertical_position'range)   := to_unsigned(V_ACTIVE_START, vertical_position'length);
    constant V_ACTIVE_END_U   : unsigned(vertical_position'range)   := to_unsigned(V_ACTIVE_END, vertical_position'length);
    
    --------------------------------------------------------------------------------
    -- Audio Buffer Signals
    --------------------------------------------------------------------------------
    signal audio_l_mux       : std_logic_vector(15 downto 0);
    signal audio_r_mux       : std_logic_vector(15 downto 0);
    signal buf_sample_l      : std_logic_vector(15 downto 0);
    signal buf_sample_r      : std_logic_vector(15 downto 0);
    signal buf_sample_valid  : std_logic;
    signal buf_sample_ready  : std_logic;
    
    --------------------------------------------------------------------------------
    -- Audio Packet Signals
    --------------------------------------------------------------------------------
    signal asp_data      : std_logic_vector(31 downto 0);
    signal asp_valid     : std_logic;
    signal asp_ready     : std_logic;
    
    signal acr_data      : std_logic_vector(31 downto 0);
    signal acr_valid     : std_logic;
    signal acr_ready     : std_logic;
    signal acr_request   : std_logic;
    
    signal aif_data      : std_logic_vector(31 downto 0);
    signal aif_valid     : std_logic;
    signal aif_ready     : std_logic;
    signal aif_request   : std_logic;
    
    signal avi_data      : std_logic_vector(31 downto 0);
    signal avi_valid     : std_logic;
    signal avi_ready     : std_logic;
    signal avi_request   : std_logic;
    
    --------------------------------------------------------------------------------
    -- Scheduler Signals
    --------------------------------------------------------------------------------
    signal island_active   : std_logic;
    signal preamble_active : std_logic;
    signal guard_band      : std_logic;
    signal packet_data     : std_logic_vector(31 downto 0);
    
    --------------------------------------------------------------------------------
    -- TERC4 Signals
    --------------------------------------------------------------------------------
    signal terc4_data_red   : std_logic_vector(3 downto 0);
    signal terc4_data_green : std_logic_vector(3 downto 0);
    signal terc4_data_blue  : std_logic_vector(3 downto 0);
    signal terc4_out_red    : std_logic_vector(9 downto 0);
    signal terc4_out_green  : std_logic_vector(9 downto 0);
    signal terc4_out_blue   : std_logic_vector(9 downto 0);
    
    --------------------------------------------------------------------------------
    -- TMDS Mux Signals (registered 1 cycle before TMDS encoder)
    --------------------------------------------------------------------------------
    signal tmds_input_de    : std_logic;
    signal tmds_input_ctrl  : std_logic_vector(1 downto 0);
    signal tmds_input_island : std_logic;
    signal tmds_input_red   : std_logic_vector(7 downto 0);
    signal tmds_input_green : std_logic_vector(7 downto 0);
    signal tmds_input_blue  : std_logic_vector(7 downto 0);
    signal tmds_terc4_red   : std_logic_vector(9 downto 0);
    signal tmds_terc4_green : std_logic_vector(9 downto 0);
    signal tmds_terc4_blue  : std_logic_vector(9 downto 0);
    
    --------------------------------------------------------------------------------
    -- TMDS Encoder Signals
    --------------------------------------------------------------------------------
    signal tmds_encoded_red     : std_logic_vector(9 downto 0);
    signal tmds_encoded_green   : std_logic_vector(9 downto 0);
    signal tmds_encoded_blue    : std_logic_vector(9 downto 0);
    
    signal tmds_serial_red      : std_logic;
    signal tmds_serial_green    : std_logic;
    signal tmds_serial_blue     : std_logic;
    signal serializer_reset     : std_logic;
    
    --------------------------------------------------------------------------------
    -- Debug Signals
    --------------------------------------------------------------------------------
    signal dbg_asp_packets  : std_logic_vector(15 downto 0);
    signal dbg_acr_packets  : std_logic_vector(15 downto 0);
    signal dbg_samples_in   : std_logic_vector(15 downto 0);

    begin

    -- Apply mute control by zeroing incoming samples when requested
    audio_l_mux <= (others => '0') when audio_mute = '1' else audio_l;
    audio_r_mux <= (others => '0') when audio_mute = '1' else audio_r;

    serializer_reset <= not rst_n;

    -- DVI mode is enabled when audio is not valid
    dvi_mode <= not audio_valid;

    --------------------------------------------------------------------------------
    -- Video Timing Counter (driven by shared configuration)
    --------------------------------------------------------------------------------
    -- Counter sequencing: front porch -> sync -> back porch -> active video
    --   Horizontal positions derived from TIMING record
    --   Default values correspond to 640x480@60Hz
    --------------------------------------------------------------------------------
    timing_counter: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            horizontal_position <= (others => '0');
            vertical_position <= (others => '0');
        elsif rising_edge(clk_pixel) then
            if horizontal_position = H_TOTAL - 1 then
                horizontal_position <= (others => '0');
                if vertical_position = V_TOTAL - 1 then
                    vertical_position <= (others => '0');
                else
                    vertical_position <= vertical_position + 1;
                end if;
            else
                horizontal_position <= horizontal_position + 1;
            end if;
        end if;
    end process timing_counter;

    -- Data enable signal generation driven by shared timing configuration
    data_enable <= '1' when (horizontal_position >= H_ACTIVE_START_U and horizontal_position < H_ACTIVE_END_U and
                             vertical_position >= V_ACTIVE_START_U and vertical_position < V_ACTIVE_END_U) else '0';

    -- Output timing signals
    h_count_out <= horizontal_position;
    v_count_out <= vertical_position;
    de_debug    <= data_enable;

    -- Sync control signals for blue channel
    sync_control_signals <= vsync & hsync;
    
    --------------------------------------------------------------------------------
    -- Vsync Edge Detection (for frame-sync triggers)
    --------------------------------------------------------------------------------
    vsync_edge_detect: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            vsync_prev <= '0';
            vsync_rising <= '0';
        elsif rising_edge(clk_pixel) then
            vsync_prev <= vsync;
            if vsync = '1' and vsync_prev = '0' then
                vsync_rising <= '1';
            else
                vsync_rising <= '0';
            end if;
        end if;
    end process vsync_edge_detect;
    
    --------------------------------------------------------------------------------
    -- Audio Sample Buffer
    --------------------------------------------------------------------------------
    audio_buf: audio_sample_buffer
        port map (
            clk_pixel       => clk_pixel,
            rst_n           => rst_n,
            audio_ce        => audio_ce,
            audio_l         => audio_l_mux,
            audio_r         => audio_r_mux,
            audio_valid     => audio_valid,
            asp_sample_l    => buf_sample_l,
            asp_sample_r    => buf_sample_r,
            asp_valid       => buf_sample_valid,
            asp_ready       => buf_sample_ready,
            buf_empty       => open,
            buf_almost_full => open,
            dbg_samples_in  => dbg_samples_in,
            dbg_samples_out => open
        );
    
    --------------------------------------------------------------------------------
    -- Audio Sample Packet (ASP) Builder
    --------------------------------------------------------------------------------
    asp_builder: audio_sample_packet
        port map (
            clk_pixel       => clk_pixel,
            rst_n           => rst_n,
            sample_l        => buf_sample_l,
            sample_r        => buf_sample_r,
            sample_valid    => buf_sample_valid,
            sample_ready    => buf_sample_ready,
            packet_data     => asp_data,
            packet_valid    => asp_valid,
            packet_ready    => asp_ready,
            packet_start    => open,
            packet_end      => open,
            dbg_packets_sent => dbg_asp_packets
        );
    
    --------------------------------------------------------------------------------
    -- ACR Packet Generator
    --------------------------------------------------------------------------------
    acr_gen: acr_packet
        generic map (
            AUDIO_SAMPLE_RATE => AUDIO_SAMPLE_RATE,
            PIXEL_CLK_FREQ    => PIXEL_CLK_FREQ,
            ACR_INTERVAL      => ACR_INTERVAL,
            N_VALUE           => ACR_N_VALUE
        )
        port map (
            clk_pixel       => clk_pixel,
            rst_n           => rst_n,
            vsync_rising    => vsync_rising,
            acr_data        => acr_data,
            acr_valid       => acr_valid,
            acr_ready       => acr_ready,
            acr_start       => open,
            acr_end         => open,
            acr_request     => acr_request,
            dbg_acr_sent    => dbg_acr_packets
        );
    
    --------------------------------------------------------------------------------
    -- Audio InfoFrame (AIF) Generator
    --------------------------------------------------------------------------------
    aif_gen: audio_infoframe
        port map (
            clk_pixel       => clk_pixel,
            rst_n           => rst_n,
            vsync_rising    => vsync_rising,
            aif_data        => aif_data,
            aif_valid       => aif_valid,
            aif_ready       => aif_ready,
            aif_start       => open,
            aif_end         => open,
            aif_request     => aif_request,
            dbg_aif_sent    => open
        );
    
    --------------------------------------------------------------------------------
    -- AVI InfoFrame Generator
    --------------------------------------------------------------------------------
    avi_gen: avi_infoframe
        port map (
            clk_pixel       => clk_pixel,
            rst_n           => rst_n,
            vsync_rising    => vsync_rising,
            avi_data        => avi_data,
            avi_valid       => avi_valid,
            avi_ready       => avi_ready,
            avi_start       => open,
            avi_end         => open,
            avi_request     => avi_request,
            dbg_avi_sent    => open
        );
    
    --------------------------------------------------------------------------------
    -- Packet Scheduler (back-porch only)
    --------------------------------------------------------------------------------
    scheduler: packet_scheduler
        generic map (
            TIMING => TIMING
        )
        port map (
            clk_pixel       => clk_pixel,
            rst_n           => rst_n,
            h_count         => horizontal_position,
            v_count         => vertical_position,
            vsync_rising    => vsync_rising,
            acr_data        => acr_data,
            acr_valid       => acr_valid,
            acr_ready       => acr_ready,
            acr_request     => acr_request,
            asp_data        => asp_data,
            asp_valid       => asp_valid,
            asp_ready       => asp_ready,
            aif_data        => aif_data,
            aif_valid       => aif_valid,
            aif_ready       => aif_ready,
            aif_request     => aif_request,
            avi_data        => avi_data,
            avi_valid       => avi_valid,
            avi_ready       => avi_ready,
            avi_request     => avi_request,
            island_active   => island_active,
            preamble_active => preamble_active,
            guard_band      => guard_band,
            packet_data     => packet_data,
            dbg_island_active => dbg_island_active,
            dbg_packet_type => dbg_packet_type,
            dbg_scheduler_state => open
        );
    
    --------------------------------------------------------------------------------
    -- TERC4 Encoders (one per channel)
    --------------------------------------------------------------------------------
    -- Extract 4-bit chunks from 32-bit packet data
    -- Split packet data into 3 channels (simplified: use byte 0,1,2)
    terc4_data_blue  <= packet_data(3 downto 0);
    terc4_data_green <= packet_data(11 downto 8);
    terc4_data_red   <= packet_data(19 downto 16);
    
    terc4_enc_red: terc4_encoder
        port map (
            clk_pixel       => clk_pixel,
            rst_n           => rst_n,
            data_in         => terc4_data_red,
            encode_enable   => island_active,
            guard_band      => guard_band,
            preamble        => preamble_active,
            data_out        => terc4_out_red
        );
    
    terc4_enc_green: terc4_encoder
        port map (
            clk_pixel       => clk_pixel,
            rst_n           => rst_n,
            data_in         => terc4_data_green,
            encode_enable   => island_active,
            guard_band      => guard_band,
            preamble        => preamble_active,
            data_out        => terc4_out_green
        );
    
    terc4_enc_blue: terc4_encoder
        port map (
            clk_pixel       => clk_pixel,
            rst_n           => rst_n,
            data_in         => terc4_data_blue,
            encode_enable   => island_active,
            guard_band      => guard_band,
            preamble        => preamble_active,
            data_out        => terc4_out_blue
        );
    
    --------------------------------------------------------------------------------
    -- Video / Data Island Mux (registered 1 cycle before TMDS)
    --------------------------------------------------------------------------------
    video_island_mux: process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            tmds_input_de <= '0';
            tmds_input_ctrl <= "00";
            tmds_input_island <= '0';
            tmds_input_red <= (others => '0');
            tmds_input_green <= (others => '0');
            tmds_input_blue <= (others => '0');
            tmds_terc4_red <= (others => '0');
            tmds_terc4_green <= (others => '0');
            tmds_terc4_blue <= (others => '0');
        elsif rising_edge(clk_pixel) then
            -- Audio/Data island path active during packet transmission (HDMI only)
            if (island_active = '1' or preamble_active = '1' or guard_band = '1') and dvi_mode = '0' then
                -- Data island mode: Use TERC4 encoded data
                tmds_input_de <= '0';
                tmds_input_ctrl <= "00";
                tmds_input_island <= '1';
                tmds_input_red <= (others => '0');
                tmds_input_green <= (others => '0');
                tmds_input_blue <= (others => '0');
                tmds_terc4_red <= terc4_out_red;
                tmds_terc4_green <= terc4_out_green;
                tmds_terc4_blue <= terc4_out_blue;
            else
                -- Video mode: Pass through RGB data
                tmds_input_de <= data_enable;
                tmds_input_ctrl <= sync_control_signals;
                tmds_input_island <= '0';
                tmds_input_red <= r;
                tmds_input_green <= g;
                tmds_input_blue <= b;
                tmds_terc4_red <= (others => '0');
                tmds_terc4_green <= (others => '0');
                tmds_terc4_blue <= (others => '0');
            end if;
        end if;
    end process video_island_mux;
    
    --------------------------------------------------------------------------------
    -- TMDS Encoders
    --------------------------------------------------------------------------------
    tmds_encoder_red: tmds_encoder
        port map (
            clk         => clk_pixel,
            rst_n       => rst_n,
            de          => tmds_input_de,
            ctrl        => "00",
            data_island => tmds_input_island,
            din         => tmds_input_red,
            data_in     => tmds_terc4_red,    -- 10-bit pre-encoded TERC4
            dout        => tmds_encoded_red
        );

    tmds_encoder_green: tmds_encoder
        port map (
            clk         => clk_pixel,
            rst_n       => rst_n,
            de          => tmds_input_de,
            ctrl        => "00",
            data_island => tmds_input_island,
            din         => tmds_input_green,
            data_in     => tmds_terc4_green,  -- 10-bit pre-encoded TERC4
            dout        => tmds_encoded_green
        );

    tmds_encoder_blue: tmds_encoder
        port map (
            clk         => clk_pixel,
            rst_n       => rst_n,
            de          => tmds_input_de,
            ctrl        => tmds_input_ctrl,
            data_island => tmds_input_island,
            din         => tmds_input_blue,
            data_in     => tmds_terc4_blue,   -- 10-bit pre-encoded TERC4
            dout        => tmds_encoded_blue
        );

    --------------------------------------------------------------------------------
    -- 10:1 Serializers
    --------------------------------------------------------------------------------
    serializer_red: OSER10
        port map (
            Q     => tmds_serial_red,
            D0    => tmds_encoded_red(0),
            D1    => tmds_encoded_red(1),
            D2    => tmds_encoded_red(2),
            D3    => tmds_encoded_red(3),
            D4    => tmds_encoded_red(4),
            D5    => tmds_encoded_red(5),
            D6    => tmds_encoded_red(6),
            D7    => tmds_encoded_red(7),
            D8    => tmds_encoded_red(8),
            D9    => tmds_encoded_red(9),
            PCLK  => clk_pixel,
            FCLK  => clk_serial,
            RESET => serializer_reset
        );

    serializer_green: OSER10
        port map (
            Q     => tmds_serial_green,
            D0    => tmds_encoded_green(0),
            D1    => tmds_encoded_green(1),
            D2    => tmds_encoded_green(2),
            D3    => tmds_encoded_green(3),
            D4    => tmds_encoded_green(4),
            D5    => tmds_encoded_green(5),
            D6    => tmds_encoded_green(6),
            D7    => tmds_encoded_green(7),
            D8    => tmds_encoded_green(8),
            D9    => tmds_encoded_green(9),
            PCLK  => clk_pixel,
            FCLK  => clk_serial,
            RESET => serializer_reset
        );

    serializer_blue: OSER10
        port map (
            Q     => tmds_serial_blue,
            D0    => tmds_encoded_blue(0),
            D1    => tmds_encoded_blue(1),
            D2    => tmds_encoded_blue(2),
            D3    => tmds_encoded_blue(3),
            D4    => tmds_encoded_blue(4),
            D5    => tmds_encoded_blue(5),
            D6    => tmds_encoded_blue(6),
            D7    => tmds_encoded_blue(7),
            D8    => tmds_encoded_blue(8),
            D9    => tmds_encoded_blue(9),
            PCLK  => clk_pixel,
            FCLK  => clk_serial,
            RESET => serializer_reset
        );

    --------------------------------------------------------------------------------
    -- Differential Output Buffers
    --------------------------------------------------------------------------------
    diff_buffer_clock: ELVDS_OBUF
        port map (
            I  => clk_pixel,
            O  => tmds_clk_p,
            OB => tmds_clk_n
        );

    diff_buffer_red: ELVDS_OBUF
        port map (
            I  => tmds_serial_red,
            O  => tmds_data_p(2),
            OB => tmds_data_n(2)
        );

    diff_buffer_green: ELVDS_OBUF
        port map (
            I  => tmds_serial_green,
            O  => tmds_data_p(1),
            OB => tmds_data_n(1)
        );

    diff_buffer_blue: ELVDS_OBUF
        port map (
            I  => tmds_serial_blue,
            O  => tmds_data_p(0),
            OB => tmds_data_n(0)
        );
    
    --------------------------------------------------------------------------------
    -- Debug Output Assignments
    --------------------------------------------------------------------------------
    dbg_audio_tx_cnt <= dbg_asp_packets;  -- Or combine with ACR count

end rtl;
