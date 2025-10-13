# HDMI Audio Implementation Guide
**Tang Nano 9K - 16-bit LPCM, 2-channel, 48 kHz Audio**

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Top Level (tn9k_hdmi_video_top.vhd)                           │
│                                                                  │
│  ┌────────────────┐     ┌──────────────────────────────────┐  │
│  │ audio_ce_gen   │────→│  HDMI Encoder (with audio)        │  │
│  │ (48 kHz pulse) │     │                                    │  │
│  └────────────────┘     │  ┌──────────────────────────────┐ │  │
│                         │  │ Audio Sample Buffer (FIFO)   │ │  │
│  ┌────────────────┐     │  └──────────┬───────────────────┘ │  │
│  │ Audio Test Gen │────→│             ↓                      │  │
│  │ (Sine/Tone)    │     │  ┌──────────────────────────────┐ │  │
│  └────────────────┘     │  │ Audio Sample Packet (ASP)    │ │  │
│                         │  └──────────┬───────────────────┘ │  │
│                         │             ↓                      │  │
│                         │  ┌──────────────────────────────┐ │  │
│                         │  │ ACR Packet Generator         │ │  │
│                         │  └──────────┬───────────────────┘ │  │
│                         │             ↓                      │  │
│                         │  ┌──────────────────────────────┐ │  │
│                         │  │ Audio InfoFrame (AIF)        │ │  │
│                         │  └──────────┬───────────────────┘ │  │
│                         │             ↓                      │  │
│                         │  ┌──────────────────────────────┐ │  │
│                         │  │ AVI InfoFrame                │ │  │
│                         │  └──────────┬───────────────────┘ │  │
│                         │             ↓                      │  │
│                         │  ┌──────────────────────────────┐ │  │
│                         │  │ Packet Scheduler             │ │  │
│                         │  │ (Priority: ACR>ASP>AIF/AVI)  │ │  │
│                         │  └──────────┬───────────────────┘ │  │
│                         │             ↓                      │  │
│                         │  ┌──────────────────────────────┐ │  │
│                         │  │ TERC4 Encoder + Video Mux    │ │  │
│                         │  └──────────┬───────────────────┘ │  │
│                         │             ↓                      │  │
│                         │  ┌──────────────────────────────┐ │  │
│                         │  │ TMDS Encoder + Serializer    │ │  │
│                         │  └──────────────────────────────┘ │  │
│                         └────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Module Summary

### Created Modules (✅ Complete)

1. **audio_ce_gen.vhd** - 48 kHz clock enable generator
   - Divides 25.2 MHz by 525 to get 48 kHz pulse
   - Includes CDC synchronizer for external audio sources
   - Debug counter to keep logic observable

2. **audio_sample_buffer.vhd** - 4-entry FIFO
   - Stores L/R 16-bit samples in pixel domain
   - Ready/valid handshake interface
   - Almost-full flag for flow control

3. **audio_sample_packet.vhd** - ASP builder
   - Packs 2-channel 16-bit PCM into HDMI Audio Sample Packets
   - State machine builds packet header + subpackets
   - Registered outputs (no combinational paths)

4. **acr_packet.vhd** - Audio Clock Regeneration
   - N = 6144 (fixed for 48 kHz per HDMI spec)
   - CTS = 25,200 (calculated from 25.2 MHz TMDS clock)
   - Periodic transmission (every frame)
   - Highest priority in scheduler

5. **audio_infoframe.vhd** - Audio InfoFrame (AIF)
   - Type=0x84, describes LPCM, 2ch, 48 kHz, 16-bit
   - Automatic checksum calculation
   - Periodic refresh (every 8 frames)

6. **avi_infoframe.vhd** - Video InfoFrame (AVI)
   - VIC=1 (640×480p@60Hz, 4:3)
   - Type=0x82, describes video format
   - Periodic refresh (every 4 frames)

7. **terc4_encoder.vhd** - Data island encoder
   - 4-bit to 10-bit TERC4 encoding
   - Supports preambles and guard bands
   - Registered output

8. **packet_scheduler.vhd** - Back-porch scheduler
   - Priority arbitration: ACR > ASP > AIF/AVI
   - Schedules only during H-back-porch (pixels 96-143)
   - 2-cycle early pipeline for alignment
   - Preamble (8px) + Guard (2px) + Island (32px) + Guard (2px)

## Integration Requirements

### TODO: Update hdmi_encoder.vhd

**Add to entity ports:**
```vhdl
-- Audio inputs
audio_ce          : in  std_logic;
audio_l           : in  std_logic_vector(15 downto 0);
audio_r           : in  std_logic_vector(15 downto 0);
audio_valid       : in  std_logic := '1';

-- Debug outputs
dbg_audio_tx_cnt  : out std_logic_vector(15 downto 0);
dbg_island_active : out std_logic;
dbg_packet_type   : out std_logic_vector(2 downto 0);
```

**Instantiate modules:**
- audio_sample_buffer
- audio_sample_packet
- acr_packet
- audio_infoframe
- avi_infoframe
- packet_scheduler
- terc4_encoder (3 instances, one per channel)

**Add vsync edge detection:**
```vhdl
signal vsync_prev : std_logic;
signal vsync_rising : std_logic;

vsync_edge: process(clk_pixel, rst_n)
begin
    if rst_n = '0' then
        vsync_prev <= '0';
    elsif rising_edge(clk_pixel) then
        vsync_prev <= vsync;
        vsync_rising <= '1' when vsync = '1' and vsync_prev = '0' else '0';
    end if;
end process;
```

**Add video/data-island mux before TMDS encoders:**
```vhdl
-- Final mux (registered 1 cycle before TMDS)
video_island_mux: process(clk_pixel, rst_n)
begin
    if rst_n = '0' then
        tmds_input_red <= (others => '0');
        tmds_input_green <= (others => '0');
        tmds_input_blue <= (others => '0');
        tmds_de <= '0';
        tmds_ctrl <= "00";
    elsif rising_edge(clk_pixel) then
        if island_active = '1' then
            -- Data island: Use TERC4 encoded packet data
            tmds_input_red <= terc4_red_out;
            tmds_input_green <= terc4_green_out;
            tmds_input_blue <= terc4_blue_out;
            tmds_de <= '0';
            tmds_ctrl <= "01";  -- CTL for data island
        elsif preamble_active = '1' or guard_band = '1' then
            -- Preamble/guard: Use TERC4 special symbols
            tmds_input_red <= terc4_red_out;
            tmds_input_green <= terc4_green_out;
            tmds_input_blue <= terc4_blue_out;
            tmds_de <= '0';
            tmds_ctrl <= "01";
        else
            -- Video data: Pass through RGB
            tmds_input_red <= "00" & r;
            tmds_input_green <= "00" & g;
            tmds_input_blue <= "00" & b;
            tmds_de <= data_enable;
            tmds_ctrl <= vsync & hsync;
        end if;
    end if;
end process;
```

### TODO: Update tn9k_hdmi_video_top.vhd

**Add to entity ports:**
```vhdl
-- Audio test inputs (optional - can be internal test generator)
audio_test_enable : in  std_logic := '1';  -- Enable test tone
```

**Instantiate audio_ce_gen:**
```vhdl
audio_ce_generator: audio_ce_gen
    generic map (
        PIXEL_CLK_FREQ => 25_200_000,
        AUDIO_SAMPLE_RATE => 48_000
    )
    port map (
        clk_pixel => pixel_clock,
        rst_n => reset_synchronized,
        ext_audio_toggle => '0',  -- Not used for internal test
        audio_ce => audio_clock_enable,
        dbg_ce_counter => dbg_audio_ce_counter
    );
```

**Add audio test tone generator:**
```vhdl
-- Simple 1 kHz sine wave test generator
audio_test_gen: process(pixel_clock, reset_synchronized)
    constant SINE_TABLE : sine_lut_t := (...);  -- 48 samples of 1 kHz @ 48 kHz
    variable sample_index : integer range 0 to 47 := 0;
begin
    if reset_synchronized = '0' then
        audio_l_test <= (others => '0');
        audio_r_test <= (others => '0');
        sample_index := 0;
    elsif rising_edge(pixel_clock) then
        if audio_clock_enable = '1' then
            -- Output sine wave sample
            audio_l_test <= SINE_TABLE(sample_index);
            audio_r_test <= SINE_TABLE(sample_index);
            
            if sample_index = 47 then
                sample_index := 0;
            else
                sample_index := sample_index + 1;
            end if;
        end if;
    end if;
end process;
```

**Wire to hdmi_encoder:**
```vhdl
hdmi_enc_inst: hdmi_encoder
    port map (
        -- Existing ports...
        audio_ce => audio_clock_enable,
        audio_l => audio_l_test,
        audio_r => audio_r_test,
        audio_valid => '1',
        dbg_audio_tx_cnt => open,  -- Or wire to output for GAO
        dbg_island_active => open,
        dbg_packet_type => open
    );
```

## Timing Constraints (TN9K_HDMI_VIDEO.sdc)

Add false paths for CDC:
```tcl
# Audio CE domain is async to pixel clock (by design)
set_false_path -from [get_pins {audio_ce_gen_inst/ext_toggle_sync1/Q}]
set_false_path -from [get_pins {audio_ce_gen_inst/ext_toggle_sync2/Q}]

# Debug counters don't need tight timing
set_false_path -to [get_ports {dbg_audio_tx_cnt[*]}]
set_false_path -to [get_ports {dbg_island_active}]
set_false_path -to [get_ports {dbg_packet_type[*]}]
```

## Synthesis Attributes

Already included in modules via `syn_preserve` and `syn_keep` attributes on:
- All packet `*_valid` signals
- All debug counters
- Scheduler state and selected_packet signals
- island_active signal

This prevents optimization sweep of audio path.

## Verification Checklist

### Simulation
- [ ] Audio CE generates 48 kHz pulse (525 pixel clocks apart)
- [ ] ACR packets contain N=6144, CTS=25200
- [ ] ASP packets contain non-zero PCM samples
- [ ] AIF/AVI packets have correct checksums
- [ ] Scheduler grants slots: ACR every frame, ASP when buffer has data, AIF/AVI periodic
- [ ] Islands occur only in back-porch (h_count 96-143)
- [ ] Preamble → Guard → Island → Guard sequence correct
- [ ] No islands during active video or sync periods

### Logic Analyzer
- [ ] CTL=0101 (binary) during data islands
- [ ] Guard bands show distinct TERC4 patterns
- [ ] Islands sit squarely in back porch (after hsync, before active video)
- [ ] ACR appears every frame
- [ ] ASP appears when audio playing
- [ ] No glitches on TMDS outputs

### Build
- [ ] No "optimized away" warnings for audio modules
- [ ] Timing met (slack > 0 for all paths)
- [ ] Resource usage acceptable (<20% increase expected)

## Expected Resource Usage

Estimated additional resources for audio path:
- **Logic**: +200-300 LUTs (~2-3% of GW1NR-9C)
- **Registers**: +150-200 FFs (~2-3%)
- **RAM**: Minimal (FIFOs use distributed RAM)

Current baseline: 122 logic, 103 registers
With audio: ~350-450 logic, ~280-320 registers (still <5% utilization)

## HDMI Compliance Notes

### Data Island Timing
Per HDMI 1.4a spec section 5.2.3:
- Preamble: 8 pixels (CTL pattern announcing island)
- Leading guard band: 2 pixels minimum
- Data island: Variable length (we use 32 pixels for packets)
- Trailing guard band: 2 pixels minimum

Total: 8 + 2 + 32 + 2 = 44 pixels
Back porch available: 48 pixels (96-143)
✅ Fits with 4 pixels margin

### Packet Priority
1. **ACR** (highest): Clock regeneration critical for A/V sync
2. **ASP** (medium): Audio samples are time-sensitive
3. **InfoFrames** (low): Descriptive metadata, lower priority

### Audio Sample Rate
- 48 kHz is mandatory for all HDMI sinks
- N=6144 is fixed per CEA-861 table 7-1
- CTS calculated from TMDS clock rate

## Debug Strategy

### GAO (Gowin Analyzer Oscilloscope)
Probe these signals:
```
- h_count (to verify back-porch timing)
- island_active
- preamble_active
- guard_band
- dbg_packet_type (shows which packet transmitting)
- tmds_encoded_blue[9:0] (to see TERC4 patterns)
- acr_valid, asp_valid, aif_valid, avi_valid
```

### Test Sequence
1. Flash to SRAM, verify video still works
2. Check debug counters increment (proves audio path active)
3. Use logic analyzer on HDMI output to verify CTL patterns
4. Test with HDMI monitor that reports audio capability
5. Verify no artifacts in video during audio transmission

## Known Issues from Past Implementations

✅ **Addressed in this design:**
- ❌ InfoFrames optimized away → ✅ Added debug counters + syn_preserve
- ❌ ASP path swept by synthesis → ✅ Observable outputs, registered all paths
- ❌ Islands bleeding into active video → ✅ Strict back-porch scheduling
- ❌ CDC metastability → ✅ 2-FF synchronizers on all clock crossings
- ❌ Long combinational cones → ✅ All muxing registered 1 cycle early
- ❌ Scheduler not granting slots → ✅ Priority arbiter with request signals

## References

- HDMI 1.4a Specification (sections 5.2-5.4)
- CEA-861-D (InfoFrame formats)
- DVI 1.0 Specification (TMDS encoding baseline)
- Gowin rPLL User Guide (clock generation)

---

**Status**: Core modules complete ✅  
**Next**: Integrate into hdmi_encoder.vhd and test  
**Author**: Tang Nano 9K HDMI Audio Project  
**Date**: October 2025  
