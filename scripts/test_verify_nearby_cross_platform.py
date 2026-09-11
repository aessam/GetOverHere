#!/usr/bin/env python3
"""Host-only orchestration tests. All device/build commands are explicit stubs.

These tests never install an app or access a radio and prove no physical path.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


STUB = r'''
import json, os, pathlib, signal, sys, time
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
case = os.environ.get("MOCK_CASE", "success")
def record(event):
    with open(os.environ["MOCK_CALLS"], "a") as log:
        log.write(json.dumps({"name": name, "args": args, "event": event, "pid": os.getpid()}) + "\n")
record("start")
def stop(signum, frame):
    record("terminated")
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
if name == "xcode-select":
    print(os.environ["MOCK_XCODE"])
elif name == "git":
    if "rev-parse" in args: print("explicit-host-stub-not-a-build-identity")
elif name == "xcodebuild":
    if "-version" in args: print("Mock Xcode - host orchestration only")
    else:
        if case == "ios_failure":
            time.sleep(0.2)  # Let the owned peer stub install its TERM observer.
            sys.exit(2)
        if case == "interrupt": time.sleep(60)
        pathlib.Path(args[args.index("-resultBundlePath") + 1]).mkdir()
elif name == "xcrun":
    if "--find" in args: print("/mock/devicectl")
    elif "lockState" in args:
        pathlib.Path(args[args.index("--json-output") + 1]).write_text(json.dumps({"passcodeRequired": case == "locked"}))
    elif "export" in args:
        destination = pathlib.Path(args[args.index("--output-path") + 1])
        destination.mkdir()
        (destination / "mock-saved-diagnostic.txt").write_text("Explicit host stub of saved xcresult diagnostic; no device access")
    elif "xcresulttool" in args:
        print(json.dumps({"totalTestCount": 1, "passedTests": 0 if case in ("ios_skip", "ios_test_failure") else 1,
                          "skippedTests": 1 if case == "ios_skip" else 0,
                          "failedTests": 1 if case == "ios_test_failure" else 0, "expectedFailures": 0}))
    else: print("Mock physical device detail, no device access")
elif name == "adb":
    if "get-state" in args: print("device")
    elif "install" in args: print("Success")
    elif "packages" in args: print("package:com.aessam.comeoverhere uid:10042")
    elif "logcat" in args:
        if case == "log_failure": sys.exit(1)
        while True: time.sleep(0.1)
    elif "instrument" in args:
        if case in ("ios_failure", "interrupt"): time.sleep(60)
        if case == "android_skip": print("INSTRUMENTATION_STATUS_CODE: -4")
        print("OK (1 test)")
else:
    raise RuntimeError("Unexpected mock command: " + name)
'''


class MixedHarnessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="GetOverHereMixedHarnessHost.")
        self.root = Path(self.temp.name)
        self.bin = self.root / "mock-bin"
        self.bin.mkdir()
        for name in ("xcode-select", "git", "xcodebuild", "xcrun", "adb"):
            path = self.bin / name
            path.write_text(f"#!{sys.executable}\n" + STUB)
            path.chmod(0o755)
        self.script = self.root / "scripts/verify_nearby_cross_platform.sh"
        self.script.parent.mkdir()
        shutil.copyfile(Path(__file__).with_name(self.script.name), self.script)
        self.derived = self.root / "derived"
        products = self.derived / "Build/Products"
        products.mkdir(parents=True)
        manifest = {"TestConfigurations": [{"TestTargets": [{
            "BlueprintName": "GetOverHereTests", "EnvironmentVariables": {}}]}]}
        with (products / "GetOverHere_GetOverHere_iphoneos-mock.xctestrun").open("wb") as output:
            plistlib.dump(manifest, output)
        for relative in ("Android/app/build/outputs/apk/debug/app-debug.apk",
                         "Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk",
                         "derived/Build/Products/Debug-iphoneos/GetOverHere.app/GetOverHere"):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"explicit mock artifact: no physical qualification")
        sdk = self.root / "sdk/platform-tools"
        sdk.mkdir(parents=True)
        (sdk / "adb").symlink_to(self.bin / "adb")
        self.xcode = self.root / "Mock Xcode/Contents/Developer"
        self.xcode.mkdir(parents=True)
        self.calls = self.root / "calls.jsonl"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        GOH_IOS_DEVICE="mock-iphone", GOH_NEARBY_ANDROID="mock-android",
                        GOH_NEARBY_USE_BUILT="1", GOH_IOS_NEARBY_DERIVED=str(self.derived),
                        ANDROID_HOME=str(self.root / "sdk"), MOCK_XCODE=str(self.xcode),
                        MOCK_CALLS=str(self.calls))
        self.env.pop("GOH_XCODE_DEVELOPER_DIR", None)
        self.env.pop("GOH_NEARBY_PROFILE", None)
        self.env.pop("GOH_NEARBY_IOS_ROLES", None)
        self.env.pop("GOH_BLE_PROBE_STYLE", None)
        self.artifacts = []

    def tearDown(self):
        for path in self.artifacts:
            # Exact mktemp path emitted by this isolated test, never a broad root.
            if path.parent == Path("/tmp") and path.name.startswith("GetOverHereNearbyCross."):
                shutil.rmtree(path)
        self.temp.cleanup()

    def capture_artifacts(self, output):
        for line in output.splitlines():
            if line.startswith("Artifacts: "):
                path = Path(line.removeprefix("Artifacts: "))
                self.artifacts.append(path)
                return path
        self.fail("Harness did not report its artifact directory")

    def run_harness(self, case="success", profile="protocol", roles="both", probe_style="queued"):
        result = subprocess.run(["bash", str(self.script)], env=dict(self.env, MOCK_CASE=case,
                                GOH_NEARBY_PROFILE=profile, GOH_NEARBY_IOS_ROLES=roles,
                                GOH_BLE_PROBE_STYLE=probe_style), text=True, capture_output=True, timeout=15)
        return result, self.capture_artifacts(result.stdout)

    def events(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def test_protocol_runs_both_orientations_with_hashes_and_scoped_logs(self):
        result, artifacts = self.run_harness()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        events = self.events()
        instruments = [e for e in events if "instrument" in e["args"]]
        self.assertEqual(["guest", "guide"], [e["args"][e["args"].index("nearbyRole") + 1] for e in instruments])
        self.assertTrue(all("nearbyRoom" in e["args"] for e in instruments))
        self.assertTrue(any("--uid=10042" in e["args"] for e in events))
        self.assertTrue(any(e["event"] == "terminated" and "logcat" in e["args"] for e in events))
        self.assertIn("no correspondence to workspace HEAD claimed", (artifacts / "run.txt").read_text())
        self.assertEqual(4, len((artifacts / "artifacts.sha256").read_text().splitlines()))
        runs = [e for e in events if "test-without-building" in e["args"]]
        self.assertEqual(2, len(runs))
        self.assertTrue(all("never" in e["args"] for e in runs))
        self.assertFalse(any("build-for-testing" in e["args"] for e in events))

    def test_live_profile_selects_production_tests_and_matching_room_names(self):
        result, artifacts = self.run_harness(profile="live")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        instruments = [e for e in self.events() if "instrument" in e["args"]]
        for ios_role, event in zip(("guide", "guest"), instruments):
            self.assertIn("com.aessam.comeoverhere.NearbyLiveSessionTest", event["args"])
            with (artifacts / f"ios-{ios_role}.xctestrun").open("rb") as source:
                variables = plistlib.load(source)["TestConfigurations"][0]["TestTargets"][0]["EnvironmentVariables"]
            self.assertEqual(variables["GOH_NEARBY_LIVE_ROOM_NAME"], event["args"][event["args"].index("nearbyRoomName") + 1])
            self.assertNotIn("GOH_NEARBY_ROOM", variables)

    def test_single_direction_runs_only_requested_role_and_labels_it(self):
        for role in ("guide", "guest"):
            with self.subTest(role=role):
                start = len(self.events()) if self.calls.exists() else 0
                result, _ = self.run_harness(roles=role)
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                instruments = [e for e in self.events()[start:] if "instrument" in e["args"]]
                self.assertEqual(1, len(instruments))
                opposite = "guest" if role == "guide" else "guide"
                args = instruments[0]["args"]
                self.assertEqual(opposite, args[args.index("nearbyRole") + 1])
                self.assertIn(f"passed for iOS roles: {role};", result.stdout)
                self.assertNotIn("passed for iOS roles: guide guest", result.stdout)

    def test_channel_probe_passes_matching_style_and_room_without_audio_claim(self):
        for style in ("queued", "sequential", "after_close", "distinct_psms"):
            with self.subTest(style=style):
                start = len(self.events()) if self.calls.exists() else 0
                result, artifacts = self.run_harness(profile="channel-probe", roles="guest", probe_style=style)
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                instruments = [e for e in self.events()[start:] if "instrument" in e["args"]]
                self.assertEqual(1, len(instruments))
                args = instruments[0]["args"]
                self.assertIn("com.aessam.comeoverhere.BluetoothChannelProbeTest", args)
                self.assertEqual("guide", args[args.index("nearbyRole") + 1])
                self.assertEqual(style, args[args.index("nearbyProbeStyle") + 1])
                with (artifacts / "ios-guest.xctestrun").open("rb") as source:
                    variables = plistlib.load(source)["TestConfigurations"][0]["TestTargets"][0]["EnvironmentVariables"]
                self.assertEqual(style, variables["GOH_BLE_PROBE_STYLE"])
                self.assertEqual(args[args.index("nearbyRoom") + 1], variables["GOH_NEARBY_ROOM"])
                self.assertIn("no application audio qualification", result.stdout)
                self.assertNotIn("Mixed-platform direct BLE", result.stdout)

    def test_invalid_probe_configuration_stops_before_device_commands(self):
        for overrides in ({"GOH_NEARBY_IOS_ROLES": "both", "GOH_BLE_PROBE_STYLE": "queued"},
                          {"GOH_NEARBY_IOS_ROLES": "guide", "GOH_BLE_PROBE_STYLE": "queued"},
                          {"GOH_NEARBY_IOS_ROLES": "guest", "GOH_BLE_PROBE_STYLE": "invalid"},
                          {"GOH_NEARBY_IOS_ROLES": "invalid", "GOH_BLE_PROBE_STYLE": "queued"}):
            with self.subTest(overrides=overrides):
                result = subprocess.run(["bash", str(self.script)], env=dict(self.env,
                                        GOH_NEARBY_PROFILE="channel-probe", **overrides),
                                        text=True, capture_output=True, timeout=5)
                self.assertNotEqual(0, result.returncode)
                self.assertFalse(self.calls.exists())

    def test_failed_result_exports_only_saved_xcresult_diagnostics(self):
        result, artifacts = self.run_harness(case="ios_test_failure", roles="guest")
        self.assertNotEqual(0, result.returncode)
        exports = [e for e in self.events() if "export" in e["args"]]
        self.assertEqual(1, len(exports))
        self.assertIn("diagnostics", exports[0]["args"])
        self.assertTrue((artifacts / "ios-guest-diagnostics/mock-saved-diagnostic.txt").exists())
        self.assertTrue(all("sysdiagnose" not in e["args"] for e in self.events()))

    def test_locked_preflight_never_installs_or_starts_tests(self):
        result, _ = self.run_harness(case="locked")
        self.assertNotEqual(0, result.returncode)
        self.assertFalse(any("install" in e["args"] or "instrument" in e["args"] for e in self.events()))

    def test_ios_failure_terminates_only_started_peer_and_logger_jobs(self):
        result, _ = self.run_harness(case="ios_failure")
        self.assertNotEqual(0, result.returncode)
        stopped = [e for e in self.events() if e["event"] == "terminated"]
        self.assertTrue(any("instrument" in e["args"] for e in stopped))
        self.assertTrue(any("logcat" in e["args"] for e in stopped))

    def test_skipped_ios_case_is_not_a_pass(self):
        result, _ = self.run_harness(case="ios_skip")
        self.assertNotEqual(0, result.returncode)
        self.assertNotIn("PASS mixed BLE", result.stdout)

    def test_missing_log_capture_is_not_a_pass(self):
        result, _ = self.run_harness(case="log_failure")
        self.assertNotEqual(0, result.returncode)

    def test_android_assumption_skip_is_not_a_pass(self):
        result, _ = self.run_harness(case="android_skip")
        self.assertNotEqual(0, result.returncode)
        self.assertNotIn("PASS mixed BLE", result.stdout)

    def test_interrupt_terminates_owned_jobs_and_preserves_manifest(self):
        process = subprocess.Popen(["bash", str(self.script)], env=dict(self.env, MOCK_CASE="interrupt"),
                                   text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                if self.calls.exists():
                    events = self.events()
                    if all(any(marker in e["args"] for e in events)
                           for marker in ("instrument", "test-without-building", "logcat")):
                        break
                time.sleep(0.05)
            else:
                self.fail("Host stub instrumentation did not start")
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=10)
            artifacts = self.capture_artifacts(stdout)
            self.assertEqual(143, process.returncode, stdout + stderr)
            self.assertTrue((artifacts / "interrupted.xctestrun").exists())
            self.assertEqual(3, len([e for e in self.events() if e["event"] == "terminated"]))
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == "__main__":
    unittest.main()
