#!/usr/bin/env python3
"""
HDMI Waveform Analyzer
Analyzes CSV waveform data from Gowin logic analyzer.
"""

import csv
import re
from collections import defaultdict
from typing import Dict, List, Tuple, Optional
import sys
import argparse


class WaveformAnalyzer:
    PACKET_TYPES = {
        0x00: "Null Packet",
        0x01: "Audio Clock Regeneration (ACR)",
        0x02: "Audio Sample Packet",
        0x03: "General Control Packet",
        0x04: "AVI InfoFrame",
        0x05: "Source Product Description InfoFrame",
        0x06: "Audio InfoFrame",
        0x07: "MPEG Source InfoFrame",
        0x0A: "Gamut Metadata Packet",
        0x0D: "Vendor-Specific InfoFrame"
    }

    # HDMI TERC4 encoding table (4-bit symbol -> 10-bit TMDS code)
    TERC4_TABLE = {
        0x0: 0b1010011100,
        0x1: 0b1001100011,
        0x2: 0b1011100100,
        0x3: 0b1011100010,
        0x4: 0b0101110001,
        0x5: 0b0100011110,
        0x6: 0b0110001110,
        0x7: 0b0100111100,
        0x8: 0b1011001100,
        0x9: 0b0100111001,
        0xA: 0b0110011100,
        0xB: 0b1011000110,
        0xC: 0b1010001110,
        0xD: 0b1001110001,
        0xE: 0b0101100011,
        0xF: 0b1011000011
    }

    TERC4_DECODE = {value: symbol for symbol, value in TERC4_TABLE.items()}

    PREAMBLE_PATTERN = {
        'red':  0b1101010100,
        'green': 0b1101010100,
        'blue': 0b1101010100
    }

    GUARD_PATTERN = {
        'red':  0b1011001100,
        'green': 0b1011001100,
        'blue': 0b1011001100
    }

    PREAMBLE_LENGTH = 8
    GUARD_LENGTH = 2
    MAX_ISLAND_SAMPLES = 96

    def __init__(self, csv_file: str, time_unit_override: str = None):
        self.csv_file = csv_file
        self.time_unit = time_unit_override
        self.period = 1
        self.headers = []
        self.data = []
        self.signals = {}
        self.bus_signals = {}
        self.data_islands = []  # Store extracted data island info
        self.packet_info = []

    def decode_terc4_symbol(self, value: Optional[int]) -> Optional[int]:
        """Decode a 10-bit TMDS symbol back to its 4-bit TERC4 value"""
        if value is None:
            return None
        return self.TERC4_DECODE.get(value)

    def is_guard_symbol(self, sample: Dict) -> bool:
        """Heuristic check for HDMI guard band (all channels match guard pattern)"""
        for channel in ('red', 'green', 'blue'):
            if sample.get(channel) != self.GUARD_PATTERN[channel]:
                return False
        return True

    def collect_data_island(self,
                             start_idx: int,
                             preamble_col_idx: int,
                             h_counter_bus: Optional[List[Optional[int]]],
                             red_bus: Optional[List[Optional[int]]],
                             green_bus: Optional[List[Optional[int]]],
                             blue_bus: Optional[List[Optional[int]]]) -> Tuple[List[Dict], int]:
        """
        Collect consecutive samples that make up a data island, starting at the
        provided index. The capture continues until the horizontal counter wraps
        (start of a new line) or we hit a safety limit.
        """
        samples: List[Dict] = []
        idx = start_idx
        prev_h = None

        while idx < len(self.data) and len(samples) < self.MAX_ISLAND_SAMPLES:
            row = self.data[idx]
            time_raw = row[0]
            try:
                time_value = int(time_raw)
            except ValueError:
                time_value = idx

            h_count = None
            if h_counter_bus and idx < len(h_counter_bus):
                h_count = h_counter_bus[idx]

            sample = {
                'index': idx,
                'time': time_value,
                'h_count': h_count,
                'preamble_active': row[preamble_col_idx].strip() == '1',
                'red': red_bus[idx] if red_bus and idx < len(red_bus) else None,
                'green': green_bus[idx] if green_bus and idx < len(green_bus) else None,
                'blue': blue_bus[idx] if blue_bus and idx < len(blue_bus) else None
            }

            samples.append(sample)

            # Detect wrap on horizontal counter -> end of island
            if prev_h is not None and h_count is not None and h_count < prev_h:
                # Remove wrap sample; it's part of next line
                samples.pop()
                idx -= 1  # step back so caller resumes from wrap sample
                break

            prev_h = h_count
            idx += 1

        next_index = min(idx + 1, len(self.data))
        return samples, next_index

    def build_segment_entries(self, segment_samples: List[Dict], segment_type: str) -> List[Dict]:
        """
        Build per-sample entries with decoded/expected information for a given segment.
        segment_type: 'preamble', 'guard_leading', 'guard_trailing', 'header', 'ecc', 'payload'
        """
        entries: List[Dict] = []

        if segment_type == 'preamble':
            expected_pattern = self.PREAMBLE_PATTERN
        elif segment_type in ('guard_leading', 'guard_trailing'):
            expected_pattern = self.GUARD_PATTERN
        else:
            expected_pattern = None

        for sample in segment_samples:
            entry = {
                'time': sample.get('time'),
                'h_count': sample.get('h_count'),
                'values': {
                    'red': sample.get('red'),
                    'green': sample.get('green'),
                    'blue': sample.get('blue')
                },
                'decoded': {},
                'expected': {},
                'match': {}
            }

            for channel in ('red', 'green', 'blue'):
                value = sample.get(channel)
                nibble = self.decode_terc4_symbol(value)
                entry['decoded'][channel] = nibble

                if expected_pattern is not None:
                    expected_value = expected_pattern[channel]
                else:
                    expected_value = self.TERC4_TABLE.get(nibble) if nibble is not None else None

                entry['expected'][channel] = expected_value
                if expected_value is None or value is None:
                    entry['match'][channel] = None
                else:
                    entry['match'][channel] = (value == expected_value)

            entries.append(entry)

        return entries

    def locate_leading_guard(self, samples: List[Dict], start_idx: int) -> Tuple[List[Dict], int]:
        """
        Identify the leading guard band after the preamble.
        Returns (guard_samples, next_index_after_guard).
        """
        if start_idx >= len(samples):
            return [], start_idx

        for idx in range(start_idx, max(len(samples) - self.GUARD_LENGTH + 1, start_idx)):
            window = samples[idx:idx + self.GUARD_LENGTH]
            if len(window) < self.GUARD_LENGTH:
                break
            if all(self.is_guard_symbol(sample) for sample in window):
                return window, idx + self.GUARD_LENGTH

        end_idx = min(start_idx + self.GUARD_LENGTH, len(samples))
        return samples[start_idx:end_idx], end_idx

    def locate_trailing_guard(self, samples: List[Dict], min_start_idx: int) -> Tuple[List[Dict], int]:
        """
        Identify the trailing guard band at the end of the island.
        Returns (guard_samples, start_index_of_guard).
        """
        if not samples:
            return [], 0

        for idx in range(len(samples) - self.GUARD_LENGTH, min_start_idx - 1, -1):
            window = samples[idx:idx + self.GUARD_LENGTH]
            if len(window) < self.GUARD_LENGTH:
                continue
            if all(self.is_guard_symbol(sample) for sample in window):
                return window, idx

        start_idx = max(len(samples) - self.GUARD_LENGTH, min_start_idx)
        if start_idx < len(samples):
            return samples[start_idx:], start_idx

        return [], len(samples)

    def parse_csv(self):
        """Parse the CSV file and extract waveform data"""
        with open(self.csv_file, 'r') as f:
            lines = f.readlines()

        # Find the data header line (contains "time unit:")
        data_start = 0
        for i, line in enumerate(lines):
            if 'time unit:' in line:
                data_start = i
                break

        # Parse headers
        header_line = lines[data_start].strip()
        self.headers = [h.strip() for h in header_line.split(',')]

        # Extract time unit if not overridden
        if not self.time_unit:
            time_match = re.search(r'time unit:\s*(\w+)', header_line)
            if time_match:
                self.time_unit = time_match.group(1)

        # Parse data rows
        reader = csv.reader(lines[data_start + 1:])
        for row in reader:
            if len(row) > 1:
                self.data.append(row)

        print(f"[+] Loaded {len(self.data)} samples")
        print(f"[+] Time unit: {self.time_unit}")
        print(f"[+] Total signals: {len(self.headers) - 1}")

    def reconstruct_buses(self):
        """Reconstruct multi-bit bus signals from individual bits"""
        bus_pattern = re.compile(r'(.+)[[](\d+)]')

        bus_info = defaultdict(list)
        for idx, header in enumerate(self.headers):
            match = bus_pattern.search(header)
            if match:
                bus_name = match.group(1)
                bit_num = int(match.group(2))
                bus_info[bus_name].append((bit_num, idx))

        for bus_name, bits in bus_info.items():
            bits.sort(reverse=True)  # MSB first
            self.bus_signals[bus_name] = []

            for row in self.data:
                bus_value = 0
                has_x = False
                for bit_num, col_idx in bits:
                    if col_idx < len(row):
                        bit_val = row[col_idx].strip()
                        if bit_val == 'X':
                            has_x = True
                            break
                        elif bit_val == '1':
                            bus_value |= (1 << bit_num)

                if has_x:
                    self.bus_signals[bus_name].append(None)
                else:
                    self.bus_signals[bus_name].append(bus_value)

        print(f"[+] Reconstructed {len(self.bus_signals)} bus signals")
        for bus in self.bus_signals.keys():
            print(f"  - {bus}")

    def get_signal_column(self, signal_name: str) -> int:
        """Find column index for a signal"""
        for idx, header in enumerate(self.headers):
            if signal_name in header:
                return idx
        return -1

    def find_transitions(self, signal_name: str, from_val: str = None, to_val: str = None) -> List[Tuple[int, str, str]]:
        """Find all transitions of a signal"""
        col_idx = self.get_signal_column(signal_name)
        if col_idx < 0:
            print(f"[-] Signal '{signal_name}' not found")
            return []

        transitions = []
        prev_val = None

        for row in self.data:
            time = int(row[0])
            val = row[col_idx].strip() if col_idx < len(row) else 'X'

            if prev_val is not None and val != prev_val:
                if (from_val is None or prev_val == from_val) and (to_val is None or val == to_val):
                    transitions.append((time, prev_val, val))

            prev_val = val

        return transitions

    def analyze_data_islands(self):
        """Analyze data island occurrences"""
        preamble_col_idx = self.get_signal_column('preamble_active')

        if preamble_col_idx < 0:
            print("[-] preamble_active signal not found")
            return

        h_counter_bus = self.bus_signals.get('horizontal_counter')
        if h_counter_bus is None:
            print("[-] horizontal_counter bus not found")
            return

        red_bus = self.bus_signals.get('tmds_encoded_red')
        green_bus = self.bus_signals.get('tmds_encoded_green')
        blue_bus = self.bus_signals.get('tmds_encoded_blue')

        if red_bus is None or green_bus is None or blue_bus is None:
            print("[-] TMDS encoded channel data not found")
            return

        prev_preamble = False
        idx = 0

        while idx < len(self.data):
            row = self.data[idx]
            preamble_active = row[preamble_col_idx].strip() == '1'

            if preamble_active and not prev_preamble:
                samples, next_idx = self.collect_data_island(
                    idx,
                    preamble_col_idx,
                    h_counter_bus,
                    red_bus,
                    green_bus,
                    blue_bus
                )

                if samples:
                    decoded_island = self.decode_data_island(samples)
                    if decoded_island:
                        self.packet_info.append({
                            'start_time': samples[0]['time'],
                            'end_time': samples[-1]['time'],
                            'start_h_count': samples[0]['h_count'],
                            'end_h_count': samples[-1]['h_count'],
                            'decoded_island': decoded_island
                        })
                idx = next_idx
                prev_preamble = False
                continue

            prev_preamble = preamble_active
            idx += 1

    def decode_data_island(self, samples: List[Dict]) -> Optional[Dict]:
        """Decode a single data island from captured samples"""
        if not samples:
            return None

        preamble_length = 0
        for sample in samples:
            if sample.get('preamble_active'):
                preamble_length += 1
            else:
                break

        if preamble_length == 0:
            preamble_length = min(self.PREAMBLE_LENGTH, len(samples))

        preamble_samples = samples[:preamble_length]

        leading_guard_samples, data_start_idx = self.locate_leading_guard(samples, preamble_length)

        trailing_guard_samples, trailing_start_idx = self.locate_trailing_guard(samples, data_start_idx)

        if trailing_start_idx <= data_start_idx:
            data_samples = samples[data_start_idx:]
            trailing_guard_samples = []
        else:
            data_samples = samples[data_start_idx:trailing_start_idx]

        header_samples = data_samples[:4]
        ecc_samples = data_samples[4:8]
        payload_samples = data_samples[8:]

        segment_data = {
            'preamble': self.build_segment_entries(preamble_samples, 'preamble'),
            'guard_leading': self.build_segment_entries(leading_guard_samples, 'guard_leading'),
            'header': self.build_segment_entries(header_samples, 'header'),
            'ecc': self.build_segment_entries(ecc_samples, 'ecc'),
            'payload': self.build_segment_entries(payload_samples, 'payload'),
            'guard_trailing': self.build_segment_entries(trailing_guard_samples, 'guard_trailing')
        }

        header_info = self.decode_packet_header(header_samples)
        ecc_info = self.decode_ecc(ecc_samples, header_info)

        return {
            'segments': segment_data,
            'header': header_info,
            'ecc': ecc_info,
            'total_samples': len(samples)
        }

    def decode_packet_header(self, header_samples: List[Dict]) -> Dict:
        """Decode HDMI packet header bytes from the first four data samples"""
        hb0 = hb1 = hb2 = 0
        red_nibbles: List[Optional[int]] = []
        green_nibbles: List[Optional[int]] = []
        blue_nibbles: List[Optional[int]] = []

        for i, sample in enumerate(header_samples[:4]):
            red_nibble = self.decode_terc4_symbol(sample.get('red'))
            green_nibble = self.decode_terc4_symbol(sample.get('green'))
            blue_nibble = self.decode_terc4_symbol(sample.get('blue'))

            red_nibbles.append(red_nibble)
            green_nibbles.append(green_nibble)
            blue_nibbles.append(blue_nibble)

            if red_nibble is not None:
                hb0 |= ((red_nibble & 0x3) << (i * 2))
            if green_nibble is not None:
                hb1 |= ((green_nibble & 0x3) << (i * 2))
            if blue_nibble is not None:
                hb2 |= ((blue_nibble & 0x3) << (i * 2))

        has_full_header = len(header_samples) >= 4 and None not in red_nibbles[:4] and None not in green_nibbles[:4] and None not in blue_nibbles[:4]

        packet_type = hb0 if has_full_header else None
        packet_name = self.PACKET_TYPES.get(packet_type, f"Unknown (0x{hb0:02X})") if packet_type is not None else "Incomplete header"

        return {
            'packet_type': packet_type,
            'packet_name': packet_name,
            'hb0': hb0,
            'hb1': hb1,
            'hb2': hb2,
            'nibbles': {
                'red': red_nibbles,
                'green': green_nibbles,
                'blue': blue_nibbles
            },
            'complete': has_full_header
        }

    def decode_ecc(self, ecc_samples: List[Dict], header_info: Dict) -> Dict:
        """Decode ECC bits from the next four samples following the header"""
        ecc_value = 0
        red_nibbles: List[Optional[int]] = []

        for i, sample in enumerate(ecc_samples[:4]):
            red_nibble = self.decode_terc4_symbol(sample.get('red'))
            red_nibbles.append(red_nibble)
            if red_nibble is not None:
                ecc_value |= ((red_nibble & 0x3) << (i * 2))

        expected_ecc = None
        if header_info and header_info.get('complete'):
            expected_ecc = self.calculate_bch_ecc(header_info['hb0'], header_info['hb1'], header_info['hb2'])

        ecc_match = expected_ecc is not None and expected_ecc == ecc_value

        return {
            'received': ecc_value,
            'expected': expected_ecc,
            'match': ecc_match if expected_ecc is not None else None,
            'nibbles': red_nibbles
        }

    def calculate_bch_ecc(self, hb0: int, hb1: int, hb2: int) -> int:
        """
        Calculate BCH(31,24) ECC used by HDMI packets.
        Generator polynomial: x^7 + x^3 + x^2 + 1 (0x8D with implied x^7 term)
        """
        data = ((hb0 & 0xFF) << 16) | ((hb1 & 0xFF) << 8) | (hb2 & 0xFF)
        poly = 0x8D
        degree = 7
        lfsr = 0

        for i in range(23, -1, -1):
            bit = (data >> i) & 1
            feedback = bit ^ ((lfsr >> (degree - 1)) & 1)
            lfsr = (lfsr << 1) & ((1 << degree) - 1)
            if feedback:
                lfsr ^= 0x0D

        return lfsr & 0x7F

    def analyze_timing(self):
        """Analyze horizontal and vertical timing"""
        h_count_signal = 'horizontal_counter'
        v_count_signal = 'vertical_counter'

        print("\n" + "="*60)
        print("TIMING ANALYSIS")
        print("="*60)

        print("\n640x480@60Hz VESA Timing Information:")
        print("  Pixel Clock: 25.175 MHz")
        print("  Horizontal Timing:")
        print("    H-Total: 800")
        print("    H-Active: 640")
        print("    H-Front Porch: 16")
        print("    H-Sync Pulse: 96")
        print("    H-Back Porch: 48")
        print("  Vertical Timing:")
        print("    V-Total: 525")
        print("    V-Active: 480")
        print("    V-Front Porch: 10")
        print("    V-Sync Pulse: 2")
        print("    V-Back Porch: 33")

        if h_count_signal not in self.bus_signals:
            print(f"\n[-] {h_count_signal} not found in waveform")
            return

        h_counts = self.bus_signals[h_count_signal]
        v_counts = self.bus_signals.get(v_count_signal, [])

        # Get capture range
        h_min = min([h for h in h_counts if h is not None])
        h_max = max([h for h in h_counts if h is not None])
        v_min = min([v for v in v_counts if v is not None]) if v_counts else 0
        v_max = max([v for v in v_counts if v is not None]) if v_counts else 0

        print(f"\nCapture Range:")
        print(f"  H_COUNT: {h_min} to {h_max} (of 800 total)")
        if v_counts:
            print(f"  V_COUNT: {v_min} to {v_max} (of 525 total)")

        # Determine frame position
        print(f"\nFrame Position Analysis:")

        # Horizontal position
        if h_min < 640:
            if h_max < 640:
                h_region = "Active Video"
            else:
                h_region = "Active Video + Horizontal Blanking"
        else:
            h_region = "Horizontal Blanking"
        print(f"  Horizontal: {h_region}")

        # Vertical position
        if v_counts:
            if v_min < 480:
                if v_max < 480:
                    v_region = "Active Video"
                else:
                    v_region = "Active Video + Vertical Blanking"
            else:
                v_region = "Vertical Blanking"
            print(f"  Vertical: {v_region}")

    def check_sync_signals(self):
        """Check hsync and vsync behavior"""
        print("\n" + "="*60)
        print("SYNC SIGNAL ANALYSIS")
        print("="*60)

        hsync_transitions = self.find_transitions('video_hsync')
        vsync_transitions = self.find_transitions('video_vsync')

        print(f"\nHSync transitions: {len(hsync_transitions)}")
        print(f"VSync transitions: {len(vsync_transitions)}")

    def export_summary(self, output_file: str = None):
        """Export analysis summary to file"""
        if output_file is None:
            output_file = self.csv_file.replace('.csv', '_analysis.txt')

        # Redirect print to file
        original_stdout = sys.stdout
        with open(output_file, 'w') as f:
            sys.stdout = f

            print("HDMI WAVEFORM ANALYSIS REPORT")
            print("="*60)
            print(f"Source: {self.csv_file}")
            print(f"Samples: {len(self.data)}")
            if self.time_unit in ['ns', 'us', 'ms']:
                print(f"Duration: {int(self.data[-1][0]) * self.period:.2f} {self.time_unit}")
            else:
                print(f"Duration: {self.data[-1][0]} {self.time_unit}")

            self.analyze_timing()
            self.check_sync_signals()

            print("\n" + "="*60)
            print("DATA ISLAND ANALYSIS")
            print("="*60)
            def fmt_hex(value: Optional[int]) -> str:
                return f"0x{value:03X}" if value is not None else "----"

            def fmt_byte(value: Optional[int]) -> str:
                return f"0x{value:02X}" if value is not None else "--"

            def fmt_nibble(value: Optional[int]) -> str:
                return f"0x{value:X}" if value is not None else "--"

            def fmt_match(value: Optional[bool]) -> str:
                if value is True:
                    return "OK"
                if value is False:
                    return "ERR"
                return "   "

            segment_order = [
                ('preamble', "Preamble"),
                ('guard_leading', "Guard Band (Start)"),
                ('header', "Header Symbols"),
                ('ecc', "ECC Symbols"),
                ('payload', "Packet Data"),
                ('guard_trailing', "Guard Band (End)")
            ]

            for idx, packet in enumerate(self.packet_info, start=1):
                decoded_island = packet['decoded_island']
                segments = decoded_island.get('segments', {})
                header = decoded_island.get('header', {})
                ecc = decoded_island.get('ecc', {})

                print(f"\nPacket #{idx}")
                start_h = packet.get('start_h_count')
                end_h = packet.get('end_h_count')
                print(f"  H_COUNT range: {start_h if start_h is not None else 'N/A'} -> {end_h if end_h is not None else 'N/A'}")
                print(f"  Samples captured: {decoded_island.get('total_samples', 0)}")

                packet_type = header.get('packet_type')
                packet_name = header.get('packet_name', "Unknown")
                if packet_type is not None:
                    print(f"  Packet Type: {packet_name} (0x{packet_type:02X})")
                else:
                    print(f"  Packet Type: {packet_name}")

                hb0 = header.get('hb0')
                hb1 = header.get('hb1')
                hb2 = header.get('hb2')
                print(f"  Header Bytes: HB0={fmt_byte(hb0)}, HB1={fmt_byte(hb1)}, HB2={fmt_byte(hb2)}")

                ecc_received = ecc.get('received')
                ecc_expected = ecc.get('expected')
                ecc_status = ecc.get('match')
                status_text = "OK" if ecc_status else ("MISMATCH" if ecc_status is False else "N/A")
                print(f"  ECC Byte: received={fmt_byte(ecc_received)}, expected={fmt_byte(ecc_expected)}, status={status_text}")

                for seg_key, seg_label in segment_order:
                    entries = segments.get(seg_key, [])
                    if not entries:
                        continue
                    print(f"  {seg_label}:")
                    for entry in entries:
                        h_val = entry.get('h_count')
                        time_val = entry.get('time')
                        line = f"    H:{h_val if h_val is not None else '---':>4} Time:{time_val if time_val is not None else '---':>6} |"

                        channel_parts = []
                        for channel in ('red', 'green', 'blue'):
                            value = entry['values'][channel]
                            expected = entry['expected'][channel]
                            match = entry['match'][channel]
                            nibble = entry['decoded'][channel]
                            part = f"{channel[0].upper()}:{fmt_hex(value)}/{fmt_hex(expected)} {fmt_match(match)}"
                            if nibble is not None:
                                part += f" nib:{fmt_nibble(nibble)}"
                            channel_parts.append(part)

                        line += " " + "  ".join(channel_parts)
                        print(line)

        sys.stdout = original_stdout
        print(f"\n[+] Summary exported to: {output_file}")

    def set_time_unit(self, time_unit: str):
        """Set the time unit, converting from frequency if necessary"""
        if time_unit.lower().endswith('hz'):
            freq = float(time_unit.lower().replace('hz', '').replace('m', 'e6').replace('k', 'e3'))
            self.period = 1 / freq
            if self.period < 1e-6:
                self.time_unit = "ns"
                self.period = self.period * 1e9
            elif self.period < 1e-3:
                self.time_unit = "us"
                self.period = self.period * 1e6
            else:
                self.time_unit = "ms"
                self.period = self.period * 1e3
        else:
            self.time_unit = time_unit

    def run_full_analysis(self):
        """Run complete analysis pipeline"""
        print("\n" + "="*60)
        print("HDMI WAVEFORM ANALYZER")
        print("="*60)
        print(f"File: {self.csv_file}\n")

        self.parse_csv()
        self.reconstruct_buses()
        self.analyze_data_islands()
        self.analyze_timing()
        self.check_sync_signals()

        print("\n" + "="*60)
        print("PACKET TYPE SUMMARY")
        print("="*60)
        packet_types = [packet['decoded_island']['header']['packet_name'] for packet in self.packet_info]
        if packet_types:
            for packet_type in set(packet_types):
                print(f"  - {packet_type}: {packet_types.count(packet_type)}")
        else:
            print("  No packets found")

        print("\n" + "="*60)
        print("ANALYSIS COMPLETE")
        print("="*60)


def main():
    parser = argparse.ArgumentParser(
        description='HDMI Waveform Analyzer',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Run full waveform analysis
  python read_waveform.py

  # Specify custom CSV file
  python read_waveform.py --file path/to/waveform.csv

  # Export analysis to text file
  python read_waveform.py --export

  # Override time unit
  python read_waveform.py --time-unit 25.2mhz
        """
        )

    parser.add_argument('--file', '-f',
                        default=r"e:\\OneDrive\\Desktop\\FPGA\\TN9K+DVI_HDMI\\impl\\wave\\TN9K_HDMI_VIDEO_core0.csv",
                        help='Path to CSV waveform file')
    parser.add_argument('--export', '-e',
                        action='store_true',
                        help='Export analysis to text file')
    parser.add_argument('--time-unit', '-t',
                        help='Override time unit (e.g., ns, us, ms, 25.2mhz)')

    args = parser.parse_args()

    csv_file = args.file
    analyzer = WaveformAnalyzer(csv_file)

    if args.time_unit:
        analyzer.set_time_unit(args.time_unit)

    try:
        analyzer.parse_csv()
        analyzer.reconstruct_buses()
        analyzer.analyze_data_islands()

        if args.export:
            analyzer.export_summary()
        else:
            analyzer.run_full_analysis()

    except FileNotFoundError:
        print(f"[-] Error: File not found: {csv_file}")
        print(f"[-] Please check the path and try again")
        sys.exit(1)
    except Exception as e:
        print(f"[-] Error: {str(e)}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
