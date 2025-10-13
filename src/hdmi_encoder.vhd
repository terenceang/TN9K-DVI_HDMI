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

    attribute syn_preserve : boolean;
    attribute syn_preserve of rtl : architecture is true;

    attribute syn_keep : string;

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

    signal tmds_r : std_logic_vector(9 downto 0);
    signal tmds_g : std_logic_vector(9 downto 0);
    signal tmds_b : std_logic_vector(9 downto 0);

    signal tmds_data_serial : std_logic_vector(2 downto 0);

    signal ctrl_r : std_logic_vector(1 downto 0);
    signal ctrl_g : std_logic_vector(1 downto 0);
    signal ctrl_b : std_logic_vector(1 downto 0);

    signal reset_oser : std_logic;

    signal de : std_logic;

    signal h_count : unsigned(10 downto 0) := (others => '0');
    signal v_count : unsigned(9 downto 0)  := (others => '0');

    attribute syn_keep of h_count : signal is "true";
    attribute syn_keep of v_count : signal is "true";
    attribute syn_keep of de : signal is "true";

begin

    reset_oser <= not rst_n;

    process(clk_pixel, rst_n)
    begin
        if rst_n = '0' then
            h_count <= (others => '0');
            v_count <= (others => '0');
        elsif rising_edge(clk_pixel) then
            if h_count = H_TOTAL - 1 then
                h_count <= (others => '0');
                if v_count = V_TOTAL - 1 then
                    v_count <= (others => '0');
                else
                    v_count <= v_count + 1;
                end if;
            else
                h_count <= h_count + 1;
            end if;
        end if;
    end process;

    de <= '1' when (h_count < H_ACTIVE and v_count < V_ACTIVE) else '0';

    h_count_out <= h_count;
    v_count_out <= v_count;

    de_debug <= de;

    ctrl_b <= vsync & hsync;
    ctrl_g <= "00";
    ctrl_r <= "00";

    enc_red: tmds_encoder
        port map (
            clk         => clk_pixel,
            rst_n       => rst_n,
            de          => de,
            ctrl        => ctrl_r,
            data_island => '0',
            din         => r,
            data_in     => (others => '0'),
            dout        => tmds_r
        );

    enc_green: tmds_encoder
        port map (
            clk         => clk_pixel,
            rst_n       => rst_n,
            de          => de,
            ctrl        => ctrl_g,
            data_island => '0',
            din         => g,
            data_in     => (others => '0'),
            dout        => tmds_g
        );

    enc_blue: tmds_encoder
        port map (
            clk         => clk_pixel,
            rst_n       => rst_n,
            de          => de,
            ctrl        => ctrl_b,
            data_island => '0',
            din         => b,
            data_in     => (others => '0'),
            dout        => tmds_b
        );

    ser_red: OSER10
        port map (
            Q     => tmds_data_serial(2),
            D0    => tmds_r(0),
            D1    => tmds_r(1),
            D2    => tmds_r(2),
            D3    => tmds_r(3),
            D4    => tmds_r(4),
            D5    => tmds_r(5),
            D6    => tmds_r(6),
            D7    => tmds_r(7),
            D8    => tmds_r(8),
            D9    => tmds_r(9),
            PCLK  => clk_pixel,
            FCLK  => clk_serial,
            RESET => reset_oser
        );

    ser_green: OSER10
        port map (
            Q     => tmds_data_serial(1),
            D0    => tmds_g(0),
            D1    => tmds_g(1),
            D2    => tmds_g(2),
            D3    => tmds_g(3),
            D4    => tmds_g(4),
            D5    => tmds_g(5),
            D6    => tmds_g(6),
            D7    => tmds_g(7),
            D8    => tmds_g(8),
            D9    => tmds_g(9),
            PCLK  => clk_pixel,
            FCLK  => clk_serial,
            RESET => reset_oser
        );

    ser_blue: OSER10
        port map (
            Q     => tmds_data_serial(0),
            D0    => tmds_b(0),
            D1    => tmds_b(1),
            D2    => tmds_b(2),
            D3    => tmds_b(3),
            D4    => tmds_b(4),
            D5    => tmds_b(5),
            D6    => tmds_b(6),
            D7    => tmds_b(7),
            D8    => tmds_b(8),
            D9    => tmds_b(9),
            PCLK  => clk_pixel,
            FCLK  => clk_serial,
            RESET => reset_oser
        );

    buf_clk: ELVDS_OBUF
        port map (
            I  => clk_pixel,
            O  => tmds_clk_p,
            OB => tmds_clk_n
        );

    buf_red: ELVDS_OBUF
        port map (
            I  => tmds_data_serial(2),
            O  => tmds_data_p(2),
            OB => tmds_data_n(2)
        );

    buf_green: ELVDS_OBUF
        port map (
            I  => tmds_data_serial(1),
            O  => tmds_data_p(1),
            OB => tmds_data_n(1)
        );

    buf_blue: ELVDS_OBUF
        port map (
            I  => tmds_data_serial(0),
            O  => tmds_data_p(0),
            OB => tmds_data_n(0)
        );

end rtl;