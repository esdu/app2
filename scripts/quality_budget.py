#!/usr/bin/env python3
"""Issue #12 scenario arithmetic; assumptions are NOT measured encoder limits.

Run normally for Markdown rows, or with --self-test for arithmetic/boundary checks.
No app, capture, encoder, or quality setting is changed by this offline tool.
"""

import argparse
from dataclasses import dataclass
from fractions import Fraction
import unittest


MIB = 1_048_576
COMPLETED_CAP = 160 * MIB
CAPTURE_GUARD = 192 * MIB
AUDIO_BPS = 64_000
VBR_FACTOR = Fraction(5, 4)
CONTAINER_FACTOR = Fraction(102, 100)
FILE_ALLOWANCE = 64 * 1024


def ceil_fraction(value):
    return -(-value.numerator // value.denominator)


def within_caps(completed, capture):
    # SegmentIndex prunes above 160 MiB; capture's guard requires strictly <192.
    return completed <= COMPLETED_CAP and capture < CAPTURE_GUARD


@dataclass(frozen=True)
class Budget:
    completed: int
    steady_capture: int
    leased_completed: int
    leased_capture: int
    export_reserve: int

    @property
    def total_with_export(self):
        return self.leased_capture + self.export_reserve


def budget(seconds, video_mbps, audio=True):
    if seconds <= 0 or video_mbps <= 0:
        raise ValueError("Positive duration and bitrate required")
    # Nominal two-second segments plus one boundary segment; up to three
    # finishing writers and one active writer are conservatively reserved.
    rate = Fraction(video_mbps * 1_000_000 + (AUDIO_BPS if audio else 0), 8)
    rate *= VBR_FACTOR * CONTAINER_FACTOR
    segment_count = (seconds + 1) // 2 + 1
    completed = ceil_fraction(rate * (seconds + 2)) + segment_count * FILE_ALLOWANCE
    writers = ceil_fraction(rate * 8) + 4 * FILE_ALLOWANCE
    leased_completed = 2 * completed  # One disjoint, full-window old save lease.
    # HighestQuality export has no established bitrate bound. 2x is only a
    # planning reserve for sensitivity analysis, not an asserted upper bound.
    export_reserve = ceil_fraction(2 * rate * seconds) + MIB
    return Budget(completed, completed + writers, leased_completed,
                  leased_completed + writers, export_reserve)


class BoundaryChecks(unittest.TestCase):
    def test_caps_distinguish_pruning_from_strict_guard(self):
        self.assertTrue(within_caps(COMPLETED_CAP, CAPTURE_GUARD - 1))
        self.assertFalse(within_caps(COMPLETED_CAP + 1, CAPTURE_GUARD - 1))
        self.assertFalse(within_caps(COMPLETED_CAP, CAPTURE_GUARD))

    def test_long_window_candidate_boundary(self):
        four = budget(120, 4)
        five = budget(120, 5)
        six = budget(120, 6)
        self.assertTrue(within_caps(four.leased_completed, four.leased_capture))
        self.assertGreater(four.leased_completed, COMPLETED_CAP * Fraction(9, 10))
        self.assertGreater(five.leased_completed, COMPLETED_CAP)
        self.assertGreater(six.leased_capture, CAPTURE_GUARD)

    def test_units_audio_and_disjoint_lease(self):
        on, off = budget(30, 4), budget(30, 4, audio=False)
        # AAC contributes 64,000 bits/s with the same explicit margin factors.
        self.assertGreater(on.completed, off.completed)
        self.assertEqual(on.leased_completed, 2 * on.completed)
        self.assertEqual(on.total_with_export, on.leased_capture + on.export_reserve)
        self.assertEqual(ceil_fraction(Fraction(1, 2)), 1)

    def test_4k_reference_fails_even_without_a_save(self):
        self.assertGreater(budget(120, 50).completed, COMPLETED_CAP)
        self.assertGreater(budget(120, 50).steady_capture, CAPTURE_GUARD)

    def test_invalid_inputs(self):
        for seconds, bitrate in [(0, 4), (-1, 4), (30, 0)]:
            with self.assertRaises(ValueError):
                budget(seconds, bitrate)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        unittest.main(argv=["quality_budget"], exit=True)
    print("| Mb/s | Window s | Completed | Steady capture | With old lease: completed | With old lease: capture | Capture + export reserve |")
    print("| --- | --- | --- | --- | --- | --- | --- |")
    for bitrate in (4, 5, 6):
        for seconds in (15, 30, 60, 120):
            item = budget(seconds, bitrate)
            values = (item.completed, item.steady_capture, item.leased_completed,
                      item.leased_capture, item.total_with_export)
            print(f"| {bitrate} | {seconds} | " + " | ".join(f"{x / MIB:.1f}" for x in values) + " |")


if __name__ == "__main__":
    main()
