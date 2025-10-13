# Signal Naming - Quick Reference

**Last Updated**: October 13, 2025

## Common Signal Mappings (Quick Lookup)

### Clocks
| Old | New | Notes |
|-----|-----|-------|
| `clk` | `system_clock` | 27 MHz input |
| `clk_pixel` | `pixel_clock` | 25.2 MHz |
| `clk_serial` | `serial_clock_5x` | 126 MHz (5× pixel) |

### Resets
| Old | New |
|-----|-----|
| `reset_n` | `external_reset_n` (top) / `reset_n` (modules) |
| `rst_sync_n` | `reset_synchronized` |
| `rst_n` | `reset_n` |

### Video Signals
| Old | New |
|-----|-----|
| `hsync` | `video_hsync` |
| `vsync` | `video_vsync` |
| `de` | `video_data_enable` |
| `r` | `video_red` |
| `g` | `video_green` |
| `b` | `video_blue` |

### Counters
| Old | New |
|-----|-----|
| `h_count` | `horizontal_counter` / `horizontal_position` |
| `v_count` | `vertical_counter` / `vertical_position` |

### TMDS Encoder Signals
| Old | New | Type |
|-----|-----|------|
| `q_m` | `encoded_intermediate` | 9-bit signal |
| `q_out` | `output_register` | 10-bit signal |
| `cnt` | `disparity_counter` | 6-bit signed |
| `n1_d` | `ones_count_input` | 4-bit unsigned |
| `dout` | `encoded_output` | 10-bit output |

### TMDS Encoder Variables
| Old | New |
|-----|-----|
| `q_m_temp` | `encoded_temp` |
| `n0_q_m_var` | `zeros_count_var` |
| `n1_q_m_var` | `ones_count_var` |
| `cnt_next` | `disparity_next` |
| `cnt_tmp` | `disparity_temp` |
| `q_out_next` | `output_next` |

### Instance Names
| Old | New |
|-----|-----|
| `u_clk_gen` | `clock_generator_inst` |
| `u_pattern_gen` | `pattern_generator_inst` |
| `u_hdmi_enc` | `hdmi_encoder_inst` |
| `encoder_r/g/b` | `red/green/blue_channel_encoder_inst` |
| `serializer_r/g/b` | `red/green/blue_channel_serializer_inst` |

## Naming Patterns

- **Clocks**: `{function}_clock` or `clock_{detail}`
- **Resets**: `reset_{scope}` or `{scope}_reset`
- **Video**: `video_{signal}`
- **Counters**: `{dimension}_counter`
- **TMDS**: `tmds_encoded_{channel}` or `{stage}_{detail}`
- **Instances**: `{function}_inst`

## Files Modified

✅ `tn9k_hdmi_video_top.vhd`  
✅ `hdmi_encoder.vhd`  
✅ `test_pattern_gen.vhd`  
✅ `tmds_encoder.vhd`

## Status

Build: ✅ SUCCESS  
Resources: 122 Logic, 103 Registers (unchanged)  
Documentation: Complete

See `SIGNAL_NAMING_GUIDE.md` for detailed information.
