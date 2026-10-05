#!/usr/bin/env python3
"""Host unit/loopback tests. Every artificial measurement is explicitly a unit fixture."""
from contextlib import ExitStack, redirect_stderr, redirect_stdout
import copy
import io
import json
import math
import plistlib
from pathlib import Path
import random
import socket
import struct
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import wave
import zipfile

import analyze_gateway_acoustics as acoustics
import gateway_fault_proxy as faults
import gateway_android_control as android_control
import gateway_recorder_result as recorder_result
import probe_gateway_android as android_probe
import probe_gateway_ios as ios_probe
import verify_debug_control_release as release_gate
import verify_gateway_system as gateway


FAKE_DRIVER = Path(__file__).parent / "tests/fake_gateway_driver.py"


class GatewayManifestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="GetOverHereGatewayUnit-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.artifact = self.root / "FakeUnitArtifact.bin"
        self.artifact.write_bytes(b"UNIT TEST ARTIFACT ONLY")
        self.digest = gateway.sha256(self.artifact)
        devices = []
        for name, platform, role in (("fake-ios", "ios", "guide"), ("fake-android", "android", "companion"),
                                      ("fake-listener", "android", "listener")):
            probe_path = self.root / f"{name}-probe.json"
            probe = {"id": name, "platform": platform, "model": "UnitTestModel", "os": "UnitTestOS", "installed_sha256": self.digest,
                     "physical": True, "wifi_enabled": True, "session_state": "idle", "debugger_attached": False,
                     "artifact_verification": {"method": "adb_sha256" if platform == "android" else "controlled_install_and_external_metadata", "verified": True}}
            gateway.write_json(probe_path, probe)
            devices.append({"id": name, "platform": platform, "role": role, "model": "UnitTestModel", "os": "UnitTestOS",
                            "artifact": {"path": str(self.artifact), "sha256": self.digest},
                            "probe": {"argv": [sys.executable, str(FAKE_DRIVER), "probe", str(probe_path)], "timeout_s": 5}})
        self.manifest = {"schema": 1, "name": "UNIT-TEST-ONLY", "seed": 17, "revision": "f" * 40, "devices": devices,
                         "scenarios": [{"id": "fake-software", "required": True, "classification": "software", "requires_locked_listeners": False,
                                        "required_assertions": ["unit_fixture_observed"], "required_routes": [],
                                        "tasks": [{"id": "fixture", "device_id": "fake-android", "argv": [sys.executable, str(FAKE_DRIVER), "result", "fake-android", self.digest, "pass"],
                                                   "timeout_s": 5, "expected_tests": 1, "result": "result.json"}], "cleanup": []}]}
        self.manifest_path = self.root / "manifest.json"
        self.source = {"revision": "f" * 40, "dirty": True, "working_tree_sha256": "e" * 64}

    def invoke(self, *arguments):
        gateway.write_json(self.manifest_path, self.manifest)
        with patch.object(gateway, "source_identity", return_value=self.source), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return gateway.main([str(self.manifest_path), *arguments])

    def test_manifest_accepts_explicit_software_unit_fixture(self):
        self.assertEqual(self.manifest, gateway.validate_manifest(self.manifest, self.root))

    def test_duplicate_device_wrong_roles_and_wrong_build_fail(self):
        edits = [lambda value: value["devices"].append(value["devices"][0]),
                 lambda value: value["devices"][1].update(role="guide"),
                 lambda value: value["devices"][1].update(platform="ios"),
                 lambda value: value["devices"][0]["artifact"].update(sha256="0" * 64)]
        for edit in edits:
            value = copy.deepcopy(self.manifest)
            edit(value)
            with self.subTest(edit=edit), self.assertRaises(gateway.GateError):
                gateway.validate_manifest(value, self.root)

    def test_unbounded_command_and_zero_expected_tests_rejected(self):
        for field, value in (("timeout_s", 0), ("timeout_s", 10801), ("timeout_s", True), ("expected_tests", 0),
                             ("argv", []), ("argv", "echo success"), ("result", "../../escape.json")):
            manifest = copy.deepcopy(self.manifest)
            manifest["scenarios"][0]["tasks"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(gateway.GateError):
                gateway.validate_manifest(manifest, self.root)

    def test_two_parallel_drivers_cannot_control_one_device(self):
        scenario = self.manifest["scenarios"][0]
        duplicate = copy.deepcopy(scenario["tasks"][0])
        duplicate.update(id="competing-controller", result="second.json")
        scenario["tasks"].append(duplicate)
        with self.assertRaises(gateway.GateError):
            gateway.validate_manifest(self.manifest, self.root)

    def test_physical_requires_routes_and_cleanup(self):
        scenario = self.manifest["scenarios"][0]
        scenario["classification"] = "physical"
        with self.assertRaises(gateway.GateError):
            gateway.validate_manifest(self.manifest, self.root)
        scenario["required_routes"] = [{"from": "fake-ios", "to": "fake-android", "transport": "usb"}]
        with self.assertRaises(gateway.GateError):
            gateway.validate_manifest(self.manifest, self.root)
        scenario["cleanup"] = [{"argv": [sys.executable, str(FAKE_DRIVER), "cleanup", str(self.root / "cleanup.txt")], "timeout_s": 5}]
        gateway.validate_manifest(self.manifest, self.root)

    def test_dry_run_never_contacts_devices(self):
        with patch.object(gateway, "execute", side_effect=AssertionError("must not execute")):
            self.assertEqual(0, self.invoke("--mode", "dry-run"))

    def test_positive_results_and_offline_revalidation(self):
        output = self.root / "run"
        self.assertEqual(0, self.invoke("--mode", "run", "--output", str(output)))
        gateway.validate_bundle(output)
        state = gateway.read_json(output / "state.json")
        self.assertEqual("PASS", gateway.report(state)["verdict"])
        self.assertEqual("software", gateway.report(state)["rows"][0]["classification"])

    def test_zero_skipped_and_missing_results_never_pass(self):
        for mode in ("zero", "skip", "missing"):
            self.manifest["scenarios"][0]["tasks"][0]["argv"][-1] = mode
            output = self.root / mode
            self.assertEqual(1, self.invoke("--mode", "run", "--output", str(output)))
            state = gateway.read_json(output / "state.json")
            self.assertEqual("FAIL", state["attempts"][0]["status"])
            self.assertEqual("NOT QUALIFIED", gateway.report(state)["verdict"])
            gateway.validate_bundle(output)

    def test_resume_retains_failure_and_only_identical_config(self):
        task = self.manifest["scenarios"][0]["tasks"][0]
        task["argv"][-1:] = ["fail-once", str(self.root / "attempt.marker")]
        output = self.root / "resume"
        self.assertEqual(1, self.invoke("--mode", "run", "--output", str(output)))
        self.assertEqual(0, self.invoke("--mode", "run", "--output", str(output), "--resume"))
        state = gateway.read_json(output / "state.json")
        self.assertEqual(["FAIL", "PASS"], [attempt["status"] for attempt in state["attempts"]])
        self.assertEqual(1, gateway.report(state)["rows"][0]["earlier_failures"])
        self.manifest["seed"] += 1
        self.assertEqual(1, self.invoke("--mode", "run", "--output", str(output), "--resume"))

    def test_tampered_evidence_fails_offline_validation(self):
        output = self.root / "tamper"
        self.assertEqual(0, self.invoke("--mode", "run", "--output", str(output)))
        state = gateway.read_json(output / "state.json")
        (output / state["attempts"][0]["directory"] / "fake-android-unit-evidence.txt").write_text("tampered")
        with self.assertRaises(gateway.GateError):
            gateway.validate_bundle(output)

    def test_unknown_route_and_debugger_lock_do_not_pass(self):
        scenario = self.manifest["scenarios"][0]
        expected = {"from": "fake-android", "to": "fake-listener", "transport": "android_aware"}
        scenario["required_routes"] = [expected]
        result = {"assertions": {"unit_fixture_observed": True}, "routes": [{**expected, "connected": True, "interface": "aware_data0", "fallback_used": False}]}
        with self.assertRaises(gateway.GateError):
            gateway.validate_scenario([result], scenario, self.manifest)
        result["routes"][0]["network_id"] = "UNIT-NETWORK"
        gateway.validate_scenario([result], scenario, self.manifest)
        scenario["requires_locked_listeners"] = True
        result["lifecycle"] = [{"device_id": "fake-listener", "locked": True, "debugger_attached": False, "debug_keep_awake": True}]
        with self.assertRaises(gateway.GateError):
            gateway.validate_scenario([result], scenario, self.manifest)
        result["lifecycle"][0]["debug_keep_awake"] = False
        gateway.validate_scenario([result], scenario, self.manifest)

    def test_probe_does_not_take_over_user_tour_or_accept_self_reported_hash(self):
        device = self.manifest["devices"][0]
        value = gateway.read_json(self.root / "fake-ios-probe.json")
        for change in ({"session_state": "active"}, {"physical": False}, {"wifi_enabled": False},
                       {"artifact_verification": {"method": "app_claim", "verified": True}}):
            with self.subTest(change=change), self.assertRaises(gateway.GateError):
                gateway.validate_probe(device, {**value, **change})

    def test_device_lock_prevents_competing_runner(self):
        with ExitStack() as first:
            gateway.device_lock(first, "unit-test-" + self.root.name)
            with ExitStack() as second, self.assertRaises(gateway.GateError):
                gateway.device_lock(second, "unit-test-" + self.root.name)

    def test_command_timeout_is_bounded_and_retained(self):
        with self.assertRaises(gateway.GateError):
            gateway.execute({"argv": [sys.executable, str(FAKE_DRIVER), "sleep"], "timeout_s": 1}, self.root / "timeout.log")
        self.assertTrue((self.root / "timeout.log").exists())

    def test_preflight_alone_leaves_scenarios_not_run(self):
        output = self.root / "preflight"
        self.assertEqual(0, self.invoke("--mode", "preflight", "--output", str(output)))
        state = gateway.read_json(output / "state.json")
        self.assertEqual("NOT RUN", gateway.report(state)["rows"][0]["status"])


class AcousticAnalyzerTests(unittest.TestCase):
    def test_fft_roundtrip_and_normalized_peak(self):
        generator = random.Random(137)
        values = [generator.uniform(-1, 1) for _ in range(64)]
        restored = acoustics.fft(acoustics.fft(values), inverse=True)
        self.assertLess(max(abs(complex(a) - b) for a, b in zip(values, restored)), 1e-10)
        received = [0.] * 37 + [value * .4 + 3 for value in values] + [0.] * 100
        peak = acoustics.match_delay(values, received, 8000)
        self.assertAlmostEqual(37 / 8, peak["delay_ms"], places=8)

    def test_silent_nonfinite_ambiguous_and_weak_samples_rejected(self):
        generator = random.Random(99)
        reference = [generator.uniform(-1, 1) for _ in range(80)]
        cases = [([0.] * 80, [0.] * 240), ([math.nan] * 80, [0.] * 240),
                 (reference, [*reference, *([0.] * 80), *reference]),
                 (reference, [generator.uniform(-1, 1) for _ in range(240)])]
        for left, right in cases:
            with self.subTest(left=left[:2]), self.assertRaises(ValueError):
                acoustics.match_delay(left, right, 8000)

    def test_known_wav_delays_and_inter_listener_skew(self):
        generator = random.Random(216)
        rate = 8000
        original = [generator.randrange(-12000, 12000) for _ in range(rate)]
        total = rate + 2000
        channels = [original + [0] * 2000]
        for delay, scale in ((960, .5), (1280, -.7)):
            channels.append([0] * delay + [round(value * scale) for value in original] + [0] * (total - rate - delay))
        with tempfile.TemporaryDirectory(prefix="GetOverHereAcousticUnit-") as directory:
            path = Path(directory) / "FakeKnownDelay.wav"
            with wave.open(str(path), "wb") as destination:
                destination.setparams((3, 2, rate, total, "NONE", "not compressed"))
                destination.writeframes(b"".join(struct.pack("<hhh", *frame) for frame in zip(*channels)))
            result = acoustics.analyze(path, 0, [1, 2], [.1, .4, .65], window_ms=100, maximum_delay_ms=200)
            self.assertEqual("VALID_MEASUREMENT", result["status"])
            self.assertAlmostEqual(120, result["listeners"][0]["p95_ms"])
            self.assertAlmostEqual(160, result["listeners"][1]["p99_ms"])
            self.assertAlmostEqual(40, result["skew_p95_ms"])

    def test_percentiles_and_channel_validation(self):
        self.assertEqual(4, acoustics.percentile([4, 1, 3, 2], .95))
        for values in ([], [math.nan], [math.inf]):
            with self.assertRaises(ValueError):
                acoustics.percentile(values, .95)
        with self.assertRaises(ValueError):
            acoustics.analyze(Path("unused"), 0, [0], [1])


class FaultProxyTests(unittest.TestCase):
    def test_seeded_corruption_and_record_identity(self):
        frame = b"UNIT TEST SIGNED FRAME PLACEHOLDER"
        first = faults.transform(frame, {"operation": "corrupt"}, random.Random(43))
        second = faults.transform(frame, {"operation": "corrupt"}, random.Random(43))
        self.assertEqual(first, second)
        self.assertNotEqual(frame, first[0][4:])
        self.assertEqual([struct.pack(">I", len(frame)) + frame], faults.transform(frame, None, random.Random(0)))
        self.assertEqual([b"\0\0\0\0"], faults.transform(b"", None, random.Random(0)))
        self.assertEqual(2, len(faults.transform(frame, {"operation": "duplicate"}, random.Random(0))))
        self.assertEqual([], faults.transform(frame, {"operation": "eof"}, random.Random(0)))

    def test_reject_unbounded_invalid_and_duplicate_faults(self):
        for fault in ({"operation": "block", "milliseconds": 30_001}, {"operation": "unknown"}, {"operation": "delay", "milliseconds": True}):
            with self.assertRaises(ValueError):
                faults.validate_plan({"schema": 1, "seed": 1, "faults": [{"direction": "upstream", "record": 1, **fault}]})
        entry = {"direction": "upstream", "record": 1, "operation": "eof"}
        with self.assertRaises(ValueError):
            faults.validate_plan({"schema": 1, "seed": 1, "faults": [entry, entry]})

    def test_actual_loopback_roundtrip_with_duplicate_injection(self):
        plan = faults.validate_plan({"schema": 1, "seed": 17, "faults": [{"direction": "upstream", "record": 1, "operation": "duplicate"}]})
        results, failures = [], []
        with socket.socket() as echo, socket.socket() as listener:
            echo.bind(("127.0.0.1", 0))
            echo.listen(1)
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)

            def server():
                try:
                    connection, _ = echo.accept()
                    with connection:
                        for _ in range(2):
                            size = faults.read_exact(connection, 4)
                            payload = faults.read_exact(connection, struct.unpack(">I", size)[0])
                            connection.sendall(size + payload)
                except Exception as error:
                    failures.append(error)

            def proxy():
                try:
                    results.append(faults.serve_once(listener, echo.getsockname()[1], plan, 3))
                except Exception as error:
                    failures.append(error)

            workers = [threading.Thread(target=server), threading.Thread(target=proxy)]
            for worker in workers:
                worker.start()
            with socket.create_connection(listener.getsockname(), timeout=2) as client:
                client.sendall(struct.pack(">I", 7) + b"fixture")
                self.assertEqual((struct.pack(">I", 7) + b"fixture") * 2, faults.read_exact(client, 22))
            for worker in workers:
                worker.join(timeout=5)
            self.assertFalse(any(worker.is_alive() for worker in workers))
            self.assertFalse(failures)
        injected = [event for event in results[0]["events"] if event.get("operation") == "duplicate"]
        self.assertEqual(1, len(injected))


class AndroidProbeTests(unittest.TestCase):
    def test_inventory_is_read_only_and_not_a_full_preflight(self):
        answers = iter(["device", "0", "FakeUnitModel", "17", "37", "1", "UNIT INTERFACES"])
        commands = []
        with patch.object(android_probe, "query", side_effect=lambda command, timeout=15: commands.append(command) or next(answers)):
            result = android_probe.probe("adb", "fake-unit-device")
        self.assertEqual("read_only_inventory", result["scope"])
        self.assertNotIn("session_state", result)
        self.assertTrue(all("install" not in command and "force-stop" not in command for command in commands))

    def test_modern_tilde_apk_path_hash_is_verified(self):
        with tempfile.TemporaryDirectory(prefix="GetOverHereAPKPathUnit-") as directory:
            path = Path(directory) / "FakeUnit.apk"
            path.write_bytes(b"UNIT TEST APK")
            digest = gateway.sha256(path)
            answers = iter(["device", "0", "FakeUnitModel", "17", "37", "1", "UNIT INTERFACES",
                            "package:/data/app/~~unit+safe==/com.aessam.comeoverhere-unit==/base.apk", digest + "  /unit/base.apk"])
            with patch.object(android_probe, "query", side_effect=lambda command, timeout=15: next(answers)):
                value = android_probe.probe("adb", "fake-unit-device", path)
            self.assertEqual(digest, value["installed_sha256"])


class AndroidControlClientTests(unittest.TestCase):
    def test_hmac_envelope_matches_swift_protocol_and_id(self):
        import base64
        import hmac
        key = bytes(range(32))
        identity, packet = android_control.envelope("status", {}, key, "00112233-4455-6677-8899-aabbccddeeff")
        self.assertEqual(len(packet) - 4, struct.unpack(">I", packet[:4])[0])
        outer = json.loads(packet[4:])
        payload = base64.b64decode(outer["payload"])
        self.assertEqual(hmac.digest(key, payload, "sha256"), base64.b64decode(outer["mac"]))
        self.assertEqual(identity, json.loads(payload)["id"])

    def test_rejects_expired_or_bad_credentials(self):
        import base64
        import time
        credentials = {"schema": 1, "port": 50999, "key": base64.b64encode(bytes(32)).decode(),
                       "certificate_sha256": "11" * 32, "expires_at_ms": int(time.time() * 1000) + 60000}
        android_control.validate_credentials(credentials)
        for update in ({"expires_at_ms": 1}, {"port": 0}, {"certificate_sha256": "00"}, {"key": "invalid"}):
            with self.subTest(update=update), self.assertRaises(ValueError):
                android_control.validate_credentials({**credentials, **update})

    def test_android_release_excludes_all_debug_classes(self):
        with tempfile.TemporaryDirectory(prefix="GetOverHereReleaseUnit-") as directory:
            path = Path(directory) / "FakeRelease.apk"
            for payload, should_fail in ((b"UNIT TEST NONDEBUG DEX", False), (b"GatewayDebugControl", True)):
                with zipfile.ZipFile(path, "w") as output:
                    output.writestr("AndroidManifest.xml", b"UNIT TEST MANIFEST")
                    output.writestr("classes.dex", payload)
                if should_fail:
                    with self.assertRaises(RuntimeError):
                        release_gate.verify_android_apk(path)
                else:
                    release_gate.verify_android_apk(path)


class IOSReceiptProbeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="GetOverHereIOSReceiptUnit-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / "FakeUnit.app"
        self.app.mkdir()
        (self.app / "FakeBinary").write_bytes(b"UNIT TEST IOS EXECUTABLE")
        with (self.app / "Info.plist").open("wb") as output:
            plistlib.dump({"CFBundleIdentifier": "com.aens.GetOverHere", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"}, output)
        self.snapshot = {"deviceID": "UNIT-APP-INSTANCE", "sessionState": "idle", "bundleBuild": "1", "debuggerAttached": False}
        self.identity = {"id": "UNIT-UDID", "platform": "ios", "model": "UNIT-iPhone", "os": "UNIT-OS", "raw": {}}
        self.commands = []

    def make_receipt(self):
        output = self.root / "receipt"
        with patch.object(ios_probe, "app_snapshot", return_value=self.snapshot), patch.object(ios_probe, "external_identity", return_value=self.identity), \
                patch.object(ios_probe, "bind_snapshot_to_device", return_value={"deviceID": "UNIT-APP-INSTANCE"}), \
                patch.object(ios_probe, "installed_metadata", return_value={"info": {"outcome": "success"}, "result": {"apps": []}}), \
                patch.object(ios_probe, "devicectl", side_effect=lambda args, timeout=30: self.commands.append(args) or {"info": {"outcome": "success"}}):
            ios_probe.install_receipt("UNIT-UDID", self.app, Path("FakeStatusCommand"), output)
        return output / "receipt.json"

    def test_controlled_install_receipt_and_bundle_digest(self):
        path = self.make_receipt()
        receipt = ios_probe.validate_receipt(path, "UNIT-UDID", self.app)
        self.assertEqual(gateway.artifact_sha256(self.app), receipt["artifact_sha256"])
        self.assertEqual("install", self.commands[0][1])
        (self.app / "FakeBinary").write_bytes(b"CHANGED UNIT BUILD")
        with self.assertRaises(gateway.GateError):
            ios_probe.validate_receipt(path, "UNIT-UDID", self.app)

    def test_wrong_device_and_tampered_install_evidence_fail(self):
        path = self.make_receipt()
        with self.assertRaises(gateway.GateError):
            ios_probe.validate_receipt(path, "OTHER-UNIT-DEVICE", self.app)
        (path.parent / "install.json").write_text("{}")
        with self.assertRaises(gateway.GateError):
            ios_probe.validate_receipt(path, "UNIT-UDID", self.app)

    def test_active_tour_is_not_installed_over(self):
        with patch.object(ios_probe, "app_snapshot", return_value={**self.snapshot, "sessionState": "active"}), \
                patch.object(ios_probe, "devicectl", side_effect=AssertionError("must not install")), self.assertRaises(gateway.GateError):
            ios_probe.install_receipt("UNIT-UDID", self.app, Path("FakeStatusCommand"), self.root / "unused")

    def test_read_only_probe_requires_fresh_explicit_radio_observation(self):
        from datetime import datetime, timezone
        receipt = self.make_receipt()
        radio = self.root / "radio.json"
        gateway.write_json(radio, {"device_id": "UNIT-UDID", "wifi_enabled": True, "source": "operator_settings_observation", "observed_at": datetime.now(timezone.utc).isoformat()})
        with patch.object(ios_probe, "app_snapshot", return_value=self.snapshot), patch.object(ios_probe, "external_identity", return_value=self.identity), \
                patch.object(ios_probe, "bind_snapshot_to_device", return_value={"deviceID": "UNIT-APP-INSTANCE"}), \
                patch.object(ios_probe, "installed_metadata", return_value={}), \
                patch.object(ios_probe, "devicectl", side_effect=AssertionError("probe must not install")):
            result = ios_probe.probe("UNIT-UDID", self.app, receipt, Path("FakeStatusCommand"), radio)
            self.assertTrue(result["wifi_enabled"])
            self.assertEqual("controlled_install_and_external_metadata", result["artifact_verification"]["method"])
            value = gateway.read_json(radio)
            value["observed_at"] = "2020-01-01T00:00:00+00:00"
            gateway.write_json(radio, value)
            with self.assertRaises(gateway.GateError):
                ios_probe.probe("UNIT-UDID", self.app, receipt, Path("FakeStatusCommand"), radio)


class NativeRecorderCollectorTests(unittest.TestCase):
    NONCE = "00112233-4455-6677-8899-aabbccddeeff"

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="GetOverHereRecorderUnit-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.trace = self.root / "FakeNativeIOS.jsonl"
        self.header = {"kind": "header", "runID": self.NONCE, "durationSeconds": 2, "deviceID": "UNIT-APP", "bundleBuild": "1"}
        self.samples = [{"kind": "sample", "monotonicNanoseconds": index * 1_000_000_000,
                         "sameRoom": True, "active": True, "snapshot": {"deviceID": "UNIT-APP", "locked": True,
                         "debuggerAttached": False, "debugKeepAwake": False}} for index in range(2)]
        self.summary = {"kind": "result", "runID": self.NONCE, "status": "continuity-checks-passed",
                        "tests": {"executed": 4, "passed": 4, "failed": 0, "skipped": 0}}
        self.probe = {"id": "UNIT-DEVICE", "platform": "ios", "physical": True, "installed_sha256": "e" * 64,
                      "artifact_verification": {"method": "controlled_install_and_external_metadata", "verified": True},
                      "app_snapshot": {"deviceID": "UNIT-APP", "bundleBuild": "1"}}

    def collect(self, locked=False):
        self.trace.write_text("\n".join(json.dumps(value) for value in [self.header, *self.samples, self.summary]) + "\n")
        return recorder_result.make_result("ios", self.trace, None, self.probe, self.NONCE, 2, "UNIT-SCENARIO", locked)

    def test_valid_native_counts_are_observed_not_assumed(self):
        result = self.collect()
        self.assertEqual({"executed": 4, "passed": 4, "failed": 0, "skipped": 0}, result["tests"])
        self.assertEqual(1000, result["maximum_sample_gap_ms"])
        self.assertEqual([], result["routes"])

    def test_sampling_pause_and_build_change_fail(self):
        self.samples[1]["monotonicNanoseconds"] = 10_000_000_000
        result = self.collect()
        self.assertFalse(result["assertions"]["UNIT-DEVICE.sampling_coverage"])
        self.probe["app_snapshot"]["bundleBuild"] = "2"
        self.assertFalse(self.collect()["assertions"]["UNIT-DEVICE.build_identity"])

    def test_room_lock_is_not_screen_lock(self):
        result = self.collect(locked=True)
        self.assertFalse(result["assertions"]["UNIT-DEVICE.locked_without_debugger"])
        self.assertEqual([], result["lifecycle"])
        for sample in self.samples:
            sample["snapshot"]["screenLocked"] = True
        self.assertTrue(self.collect(locked=True)["assertions"]["UNIT-DEVICE.locked_without_debugger"])

    def test_wrong_run_zero_counts_and_missing_result_rejected(self):
        self.summary["tests"]["executed"] = 0
        with self.assertRaises(gateway.GateError):
            self.collect()
        self.summary["tests"]["executed"] = 4
        self.header["runID"] = "00000000-0000-0000-0000-000000000001"
        with self.assertRaises(gateway.GateError):
            self.collect()

    def test_android_recording_maps_same_actual_checks(self):
        trace = self.root / "FakeAndroid.jsonl"
        summary_path = self.root / "FakeAndroidSummary.json"
        header = {"kind": "header", "id": "UNIT-RECORDING", "requested_run_id": self.NONCE,
                  "duration_seconds": 2, "device_id": "UNIT-APP", "bundle_build": 1}
        samples = [{"kind": "sample", "uptime_ms": index * 1000, "same_room": True, "active": True,
                    "locked": True, "debugger_attached": False, "debug_keep_awake": False} for index in range(3)]
        trace.write_text("\n".join(json.dumps(value) for value in [header, *samples]) + "\n")
        gateway.write_json(summary_path, {"id": "UNIT-RECORDING", "requested_run_id": self.NONCE, "observed_samples": 3,
                                         "status": "RECORDED_NOT_QUALIFIED", "tests": {"executed": 6, "passed": 6, "failed": 0, "skipped": 0}})
        probe = {**self.probe, "platform": "android", "artifact_verification": {"method": "adb_sha256", "verified": True}}
        result = recorder_result.make_result("android", trace, summary_path, probe, self.NONCE, 2, "UNIT-SCENARIO", locked=True)
        self.assertEqual(5, result["tests"]["passed"])


if __name__ == "__main__":
    unittest.main()
