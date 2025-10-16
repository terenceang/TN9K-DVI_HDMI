--------------------------------------------------------------------------------
-- HDMI Configuration Package
--------------------------------------------------------------------------------
-- Description:
--   Centralizes video timing and audio configuration records so that all
--   modules can share a single source of truth for default parameters.
--
--   The defaults describe the 640x480@60Hz VGA mode used by the Tang Nano 9K
--   reference design, including the audio transport parameters required by
--   the HDMI specification.
--
-- Author: Tang Nano 9K HDMI Audio Project
-- Date: October 2025
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

package hdmi_config_pkg is

    ----------------------------------------------------------------------------
    -- Video Timing Definition
    ----------------------------------------------------------------------------
    type video_timing_t is record
        h_active       : integer;
        h_front        : integer;
        h_sync         : integer;
        h_back         : integer;
        h_total        : integer;
        h_active_start : integer;
        v_active       : integer;
        v_front        : integer;
        v_sync         : integer;
        v_back         : integer;
        v_total        : integer;
        v_active_start : integer;
    end record;

    ----------------------------------------------------------------------------
    -- Audio Transport Definition
    ----------------------------------------------------------------------------
    type audio_config_t is record
        sample_rate    : integer;
        pixel_clock_hz : integer;
        acr_n_value    : integer;
        acr_interval   : integer;
    end record;

    ----------------------------------------------------------------------------
    -- Default HDMI 640x480@60Hz Timing (Tang Nano 9K Reference)
    ----------------------------------------------------------------------------
    constant HDMI_TIMING_640x480 : video_timing_t := (
        h_active       => 640,
        h_front        => 16,
        h_sync         => 96,
        h_back         => 48,
        h_total        => 800,
        h_active_start => 160,
        v_active       => 480,
        v_front        => 10,
        v_sync         => 2,
        v_back         => 23,  -- portion of back porch before active video
        v_total        => 525,
        v_active_start => 35
    );

    ----------------------------------------------------------------------------
    -- Default HDMI Audio Configuration (48 kHz LPCM)
    ----------------------------------------------------------------------------
    constant HDMI_AUDIO_DEFAULT : audio_config_t := (
        sample_rate    => 48_000,
        pixel_clock_hz => 25_200_000,
        acr_n_value    => 6144,
        acr_interval   => 420_000
    );

end package hdmi_config_pkg;

package body hdmi_config_pkg is
end package body hdmi_config_pkg;
