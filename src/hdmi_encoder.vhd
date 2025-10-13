library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity hdmi_encoder is
    generic (
        H_ACTIVE  : integer := 640;
        H_TOTAL   : integer := 800;
        V_ACTIVE  : integer := 480;
        V_TOTAL   : integer := 525
    );
    port (
        clk_pixel   : in  std_logic;
        clk_serial  : in  std_logic;
        rst_n       : in  std_logic;
        hsync       : in  std_logic;
        vsync       : in  std_logic;
        r           : in  std_logic_vector(7 downto 0);
        g           : in  std_logic_vector(7 downto 0);
        b           : in  std_logic_vector(7 downto 0);
        h_count_out     : out unsigned(10 downto 0);
        v_count_out     : out unsigned(9 downto 0);
        de_debug        : out std_logic;
        tmds_clk_p  : out std_logic;
        tmds_clk_n  : out std_logic;
        tmds_data_p : out std_logic_vector(2 downto 0);
        tmds_data_n : out std_logic_vector(2 downto 0)
    );
end hdmi_encoder;

architecture rtl of hdmi_encoder is

    component tmds_encoder
        port (
            clk         : in  std_logic;
            rst_n       : in  std_logic;
            de          : in  std_logic;
            ctrl        : in  std_logic_vector(1 downto 0);
            data_island : in  std_logic;
            din         : in  std_logic_vector(7 downto 0);
            data_in     : in  std_logic_vector(3 downto 0);
            dout        : out std_logic_vector(9 downto 0)
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

    signal tmds_encoded_red     : std_logic_vector(9 downto 0);
    signal tmds_encoded_green   : std_logic_vector(9 downto 0);
    signal tmds_encoded_blue    : std_logic_vector(9 downto 0);

    signal tmds_serial_red      : std_logic;
    signal tmds_serial_green    : std_logic;
    signal tmds_serial_blue     : std_logic;

    signal sync_control_signals : std_logic_vector(1 downto 0);

    signal serializer_reset     : std_logic;

    signal data_enable          : std_logic;

    signal horizontal_position  : unsigned(10 downto 0) := (others => '0');
    signal vertical_position    : unsigned(9 downto 0)  := (others => '0');

begin

    serializer_reset <= not rst_n;

    -- Video timing counter - generates horizontal and vertical position counters
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

    -- Data enable signal generation
    data_enable <= '1' when (horizontal_position < H_ACTIVE and vertical_position < V_ACTIVE) else '0';

    -- Output timing signals
    h_count_out <= horizontal_position;
    v_count_out <= vertical_position;
    de_debug    <= data_enable;

    -- Sync control signals for blue channel (carries HSYNC and VSYNC during blanking)
    sync_control_signals <= vsync & hsync;

    -- TMDS Encoder for Red Channel
    tmds_encoder_red: tmds_encoder
        port map (
            clk         => clk_pixel,
            rst_n       => rst_n,
            de          => data_enable,
            ctrl        => "00",  -- No control data on red channel
            data_island => '0',
            din         => r,
            data_in     => (others => '0'),
            dout        => tmds_encoded_red
        );

    -- TMDS Encoder for Green Channel
    tmds_encoder_green: tmds_encoder
        port map (
            clk_pixel,
            rst_n       => rst_n,
            de          => data_enable,
            ctrl        => "00",  -- No control data on green channel
            data_island => '0',
            din         => g,
            data_in     => (others => '0'),
            dout        => tmds_encoded_green
        );

    -- TMDS Encoder for Blue Channel (carries sync signals during blanking)
    tmds_encoder_blue: tmds_encoder
        port map (
            clk         => clk_pixel,
            rst_n       => rst_n,
            de          => data_enable,
            ctrl        => sync_control_signals,  -- HSYNC and VSYNC on blue channel
            data_island => '0',
            din         => b,
            data_in     => (others => '0'),
            dout        => tmds_encoded_blue
        );

    -- 10:1 Serializer for Red Channel
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

    -- 10:1 Serializer for Green Channel
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

    -- 10:1 Serializer for Blue Channel
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

    -- Differential Output Buffer for TMDS Clock
    diff_buffer_clock: ELVDS_OBUF
        port map (
            I  => clk_pixel,
            O  => tmds_clk_p,
            OB => tmds_clk_n
        );

    -- Differential Output Buffer for Red Channel
    diff_buffer_red: ELVDS_OBUF
        port map (
            I  => tmds_serial_red,
            O  => tmds_data_p(2),
            OB => tmds_data_n(2)
        );

    -- Differential Output Buffer for Green Channel
    diff_buffer_green: ELVDS_OBUF
        port map (
            I  => tmds_serial_green,
            O  => tmds_data_p(1),
            OB => tmds_data_n(1)
        );

    -- Differential Output Buffer for Blue Channel
    diff_buffer_blue: ELVDS_OBUF
        port map (
            I  => tmds_serial_blue,
            O  => tmds_data_p(0),
            OB => tmds_data_n(0)
        );

end rtl;