#!/usr/bin/env python3
"""Host checks for benchmark accounting and emulator-only device scope; no adb invocation."""
import copy
import math
import unittest
from unittest.mock import patch

import benchmark_android_aware as benchmark


class AwareBenchmarkRunnerTests(unittest.TestCase):
    def row(self):
        return {
            "phase": "tiny_idle", "offered_packets": 5, "sent_packets": 4, "received_packets": 4,
            "missing_echo_packets": 0, "local_schedule_drops": 1, "late_echo_packets": 2,
            "duration_ms": 100, "offered_pps": 50, "late_threshold_ms": 150,
            "signed_frame_bytes": 244, "probe_prefix_bytes": 12,
            "scope": "aware_tcp_guide_adapter_synthetic_audio_framing", "codec_or_acoustic_measurement": False,
            "rtt_samples_ms": [1., 2., 150., 200.], "send_lag_samples_ms": [0., 1., 2., 3.],
            "rtt_p50_ms": 2., "rtt_p95_ms": 200., "rtt_p99_ms": 200., "rtt_max_ms": 200.,
            "send_lag_p95_ms": 3., "asset_target_bytes_per_second": 0,
            "asset_received_bytes": 0, "asset_receive_ns": 0,
        }

    def test_bulk_remains_default(self):
        args = benchmark.parse_args(["--guide", "phone1", "--guest", "phone2"])
        self.assertEqual("bulk", args.profile)
        self.assertEqual(("phone1", "phone2", "emulator-5554"), benchmark.preflight_serials(args))

    def test_emulator_smoke_needs_no_physical_serials(self):
        args = benchmark.parse_args(["--smoke-only", "--profile", "tiny"])
        self.assertEqual(("emulator-5554",), benchmark.preflight_serials(args))

    def test_emulator_smoke_never_contacts_supplied_phones(self):
        commands = []
        with patch.object(benchmark.Path, "is_file", return_value=True), patch.object(
                benchmark, "run", side_effect=lambda command, timeout: commands.append(command) or "device\n"):
            benchmark.main(["--smoke-only", "--preflight-only", "--guide", "phone1", "--guest", "phone2"])
        self.assertEqual(1, len(commands))
        self.assertEqual(["-s", "emulator-5554", "get-state"], commands[0][-3:])

    def test_physical_profile_requires_two_distinct_serials(self):
        for args in ([], ["--guide", "same", "--guest", "same"],
                     ["--guide", "emulator-5554", "--guest", "phone2"]):
            with self.subTest(args=args), self.assertRaises(SystemExit):
                benchmark.parse_args(args)

    def test_rejects_invalid_duration_and_profile(self):
        for extra in (["--millis", "0"], ["--millis", "30001"], ["--rounds", "6"], ["--profile", "udp"]):
            with self.subTest(extra=extra), self.assertRaises(SystemExit):
                benchmark.parse_args(["--smoke-only", *extra])

    def test_nearest_rank_percentiles_match_kotlin(self):
        self.assertEqual(2., benchmark.percentile([3., 1., 2.], .5))
        self.assertEqual(3., benchmark.percentile([3., 1., 2.], .99))
        for values in ([], [math.inf], [math.nan], [-1.]):
            with self.subTest(values=values), self.assertRaises(ValueError):
                benchmark.percentile(values, .95)

    def test_local_schedule_misses_stay_in_denominator(self):
        self.assertEqual(.6, benchmark.validate_tiny_row(self.row(), 100))

    def test_rejects_missing_echo_and_missing_raw_samples(self):
        for updates in ({"missing_echo_packets": 1}, {"rtt_samples_ms": [1.]}, {"local_schedule_drops": 0},
                        {"offered_packets": True}, {"sent_packets": 0}, {"rtt_p95_ms": 2.}):
            with self.subTest(updates=updates), self.assertRaises(ValueError):
                benchmark.validate_tiny_row(dict(self.row(), **updates), 100)

    def test_late_boundary_is_explicit_rtt_not_one_way(self):
        row = self.row()
        self.assertEqual(2, sum(value >= row["late_threshold_ms"] for value in row["rtt_samples_ms"]))
        row["late_echo_packets"] = 1
        with self.assertRaises(ValueError):
            benchmark.validate_tiny_row(row, 100)

    def test_rejects_scope_inflation(self):
        for update in ({"scope": "native_aware_udp"}, {"codec_or_acoustic_measurement": True}, {"probe_prefix_bytes": 0}):
            with self.subTest(update=update), self.assertRaises(ValueError):
                benchmark.validate_tiny_row(dict(self.row(), **update), 100)

    def test_paced_phase_requires_verified_asset_bytes(self):
        row = dict(self.row(), phase="tiny_paced_asset", asset_target_bytes_per_second=524_288)
        with self.assertRaises(ValueError):
            benchmark.validate_tiny_row(row, 100)
        row.update(asset_received_bytes=16_384, asset_receive_ns=100_000_000)
        self.assertEqual(.6, benchmark.validate_tiny_row(row, 100))

    def test_raw_nonfinite_values_cannot_look_like_success(self):
        row = copy.deepcopy(self.row())
        row["rtt_samples_ms"][0] = math.nan
        with self.assertRaises(ValueError):
            benchmark.validate_tiny_row(row, 100)


if __name__ == "__main__":
    unittest.main()
