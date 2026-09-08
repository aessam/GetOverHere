#!/usr/bin/env python3
"""Two-phone Aware TCP/guide-adapter benchmark, or emulator-only protocol smoke."""
import argparse
import concurrent.futures
import hashlib
import json
import math
import os
from pathlib import Path
import re
import secrets
import statistics
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
APP = "com.aessam.comeoverhere"
RUNNER = f"{APP}.test/androidx.test.runner.AndroidJUnitRunner"
TEST = f"{APP}.AwarePhysicalBenchmarkTest"


def run(command, timeout=30):
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {command[0]}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--guide")
    parser.add_argument("--guest")
    parser.add_argument("--emulator", default="emulator-5554")
    parser.add_argument("--profile", choices=("bulk", "tiny"), default="bulk")
    parser.add_argument("--millis", type=int, default=10_000)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--reuse-installed", action="store_true")
    parser.add_argument("--preflight-only", action="store_true")
    parser.add_argument("--smoke-only", action="store_true")
    args = parser.parse_args(argv)
    if not (100 <= args.millis <= 30_000 and 1 <= args.rounds <= 5):
        parser.error("millis must be 100..30000 and rounds 1..5")
    if not args.smoke_only and (not args.guide or not args.guest or args.guide == args.guest or
            any(not re.fullmatch(r"[A-Za-z0-9]+", x) for x in (args.guide, args.guest))):
        parser.error("choose two distinct physical USB serials")
    if not re.fullmatch(r"emulator-[0-9]+", args.emulator):
        parser.error("smoke test must use an explicit emulator")
    return args


def preflight_serials(args):
    """Smoke never contacts physical devices, even when serial arguments are supplied."""
    return (args.emulator,) if args.smoke_only else (args.guide, args.guest, args.emulator)


def percentile(values, quantile):
    if not values or not 0 < quantile <= 1 or any(not math.isfinite(v) or v < 0 for v in values):
        raise ValueError("invalid latency samples/quantile")
    return sorted(values)[math.ceil(len(values) * quantile) - 1]


def validate_tiny_row(row, millis):
    """Reject incomplete/contradictory reports; do not turn TCP timeouts into a loss estimate."""
    for field in ("offered_packets", "sent_packets", "received_packets", "missing_echo_packets",
                  "local_schedule_drops", "late_echo_packets", "signed_frame_bytes"):
        if type(row.get(field)) is not int or row[field] < 0:
            raise ValueError(f"invalid {field}")
    offered, sent, received = (row[key] for key in ("offered_packets", "sent_packets", "received_packets"))
    if not (offered == millis // 20 and sent > 0 and offered == sent + row["local_schedule_drops"] and
            sent == received + row["missing_echo_packets"] and row["missing_echo_packets"] == 0):
        raise ValueError("incomplete tiny-packet accounting")
    if row.get("duration_ms") != millis or row.get("offered_pps") != 50 or row.get("late_threshold_ms") != 150:
        raise ValueError("unexpected tiny-packet timing policy")
    if not (158 <= row["signed_frame_bytes"] <= 4096 and row.get("probe_prefix_bytes") == 12):
        raise ValueError("invalid measured frame size")
    if (row.get("scope") != "aware_tcp_guide_adapter_synthetic_audio_framing" or
            row.get("codec_or_acoustic_measurement") is not False):
        raise ValueError("unsupported benchmark scope")
    samples, lags = row.get("rtt_samples_ms", []), row.get("send_lag_samples_ms", [])
    if len(samples) != received or len(lags) != sent:
        raise ValueError("missing raw latency samples")
    for field, quantile in (("rtt_p50_ms", .5), ("rtt_p95_ms", .95), ("rtt_p99_ms", .99), ("rtt_max_ms", 1)):
        if not math.isclose(row.get(field, -1), percentile(samples, quantile), rel_tol=1e-9, abs_tol=1e-6):
            raise ValueError(f"inconsistent {field}")
    if not math.isclose(row.get("send_lag_p95_ms", -1), percentile(lags, .95), rel_tol=1e-9, abs_tol=1e-6):
        raise ValueError("inconsistent send lag")
    if row["late_echo_packets"] != sum(value >= 150 for value in samples):
        raise ValueError("inconsistent late-echo count")
    expected_asset_rate = 524_288 if row.get("phase") == "tiny_paced_asset" else 0
    if row.get("phase") not in ("tiny_idle", "tiny_paced_asset") or row.get("asset_target_bytes_per_second") != expected_asset_rate:
        raise ValueError("unexpected tiny-packet phase/load")
    if expected_asset_rate and (row.get("asset_received_bytes", 0) <= 0 or row.get("asset_receive_ns", 0) <= 0):
        raise ValueError("paced-asset phase had no verified load")
    return (row["local_schedule_drops"] + row["missing_echo_packets"] + row["late_echo_packets"]) / offered


def main(argv=None):
    args = parse_args(argv)
    adb = Path(os.environ.get("ANDROID_HOME", str(Path.home() / "Library/Android/sdk"))) / "platform-tools/adb"
    if not adb.is_file():
        raise RuntimeError("adb missing")

    def device(serial, *command, timeout=30):
        return run([str(adb), "-s", serial, *command], timeout)

    for serial in preflight_serials(args):
        if device(serial, "get-state").strip() != "device":
            raise RuntimeError(f"Device unavailable: {serial}")
    for serial in (() if args.smoke_only else (args.guide, args.guest)):
        if int(device(serial, "shell", "getprop", "ro.build.version.sdk")) < 34:
            raise RuntimeError(f"Android 14+ required: {serial}")
        if device(serial, "shell", "settings", "get", "global", "wifi_on").strip() != "1":
            raise RuntimeError(f"Enable Wi-Fi on {serial}; Aware cannot run with its radio disabled")
    if args.preflight_only:
        print("Preflight passed: emulator only" if args.smoke_only else
              "Preflight passed: explicit Android pair, Wi-Fi enabled, emulator present", flush=True)
        return

    artifacts = Path(tempfile.mkdtemp(prefix="GetOverHereAwareBenchmark.", dir="/tmp"))
    print(f"Artifacts: {artifacts}", flush=True)
    apks = {
        APP: ROOT / "Android/app/build/outputs/apk/debug/app-debug.apk",
        APP + ".test": ROOT / "Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk",
    }
    hashes = {package: hashlib.sha256(path.read_bytes()).hexdigest() for package, path in apks.items()}
    (artifacts / "manifest.json").write_text(json.dumps({
        "commit": run(["git", "-C", str(ROOT), "rev-parse", "HEAD"]).strip(),
        "dirty": bool(run(["git", "-C", str(ROOT), "status", "--porcelain"]).strip()),
        "guide": args.guide, "guest": args.guest, "millis": args.millis, "rounds": args.rounds,
        "profile": args.profile, "smoke_only": args.smoke_only,
        "apk_sha256": hashes,
        "scope": ("emulator TCP loopback component tests; no native Aware radio evidence" if args.smoke_only else
                  "PIN-secured Android Aware TCP with guide-side asset adapter; no direct UDP or acoustic measurement"),
        "payload": ("synthetic codec-sized bytes with real GOH2v4 AEAD/GOS1 serialization, not codec output"
                    if args.profile == "tiny" else "synthetic verified bulk data; no tour AEAD/codec"),
    }, indent=2) + "\n")

    def install(serial, reuse=False):
        for package, apk in apks.items():
            if reuse:
                path = device(serial, "shell", "pm", "path", package).strip()
                if not re.fullmatch(r"package:/data/app/[A-Za-z0-9/._=+~-]+/base\.apk", path):
                    raise RuntimeError(f"Cannot verify single installed APK: {serial} {package}")
                remote = device(serial, "shell", "sha256sum", path.removeprefix("package:")).split()[0]
                if remote != hashes[package]:
                    raise RuntimeError(f"Installed APK differs: {serial} {package}; omit --reuse-installed")
                print(f"Verified installed APK: {serial} {package} {remote}", flush=True)
            else:
                output = device(serial, "install", "-r", str(apk), timeout=180)
                if "Success" not in output:
                    raise RuntimeError(output)

    def instrumentation(serial, method, extra, destination, timeout, test_class=TEST):
        command = ["shell", "am", "instrument", "-w", "-r", "-e", "class", f"{test_class}#{method}"]
        for key, value in extra.items():
            command += ["-e", key, str(value)]
        try:
            output = device(serial, *command, RUNNER, timeout=timeout)
            destination.write_text(output)
            if not re.search(r"OK \(1 test\)", output) or "FAILURES!!!" in output:
                raise RuntimeError(f"Instrumentation failed on {serial}; see {destination}")
            return [json.loads(line.split("aware_benchmark=", 1)[1]) for line in output.splitlines()
                    if line.startswith("INSTRUMENTATION_STATUS: aware_benchmark=")]
        except subprocess.TimeoutExpired as error:
            destination.write_text(str(error))
            device(serial, "shell", "am", "force-stop", APP)
            raise RuntimeError(f"Bounded instrumentation timeout on {serial}; app stopped") from error

    install(args.emulator)
    instrumentation(args.emulator, "existingConnectionOnOldPortCannotBlockAwareListener", {},
                    artifacts / "port-regression.txt", 30, test_class=f"{APP}.AwareListenerPortTest")
    instrumentation(args.emulator, "completionWaitsForPeerBeforeReleasingOwner", {},
                    artifacts / "completion-regression.txt", 30)
    instrumentation(args.emulator, "protocolLoopbackAndCorruptionSmoke", {}, artifacts / "smoke.txt", 60)
    instrumentation(args.emulator, "tinyPacketLoopbackAndCorruptionSmoke", {}, artifacts / "tiny-smoke.txt", 60)
    print("Bulk/tiny socket loopback, signature/corruption, pacing-accounting and percentile smoke passed", flush=True)
    if args.smoke_only:
        return
    for serial in (args.guide, args.guest):
        install(serial, args.reuse_installed)

    rows = []
    for orientation, guide, guest in (("forward", args.guide, args.guest), ("reverse", args.guest, args.guide)):
        # Fresh radio ownership and PIN per guide role. No automatic retry hiding setup failures.
        extra = {"benchmarkRoom": uuid.uuid4(), "benchmarkToken": uuid.uuid4(),
                 "benchmarkPIN": f"{secrets.randbelow(1_000_000):06d}",
                 "benchmarkMillis": args.millis, "benchmarkRounds": args.rounds, "benchmarkProfile": args.profile}
        timeout = 120 + args.rounds * 3 * (args.millis / 1000 + 15)
        for serial in (guide, guest):
            device(serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP")
        print(f"Running {orientation}: guide={guide}, guest={guest}", flush=True)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            jobs = {role: pool.submit(instrumentation, serial, "measurePhysicalAwareGoodput",
                                      dict(extra, benchmarkRole=role), artifacts / f"{orientation}-{role}.txt", timeout)
                    for role, serial in (("guide", guide), ("guest", guest))}
            failures = []
            for role, job in jobs.items():
                try:
                    results = job.result()
                    if not any(x["phase"] == "complete" for x in results):
                        raise RuntimeError(f"Missing completion metrics: {orientation} {role}")
                    rows.extend(dict(row, orientation=orientation, guide_serial=guide, guest_serial=guest) for row in results)
                except Exception as error:
                    failures.append(str(error))
        for serial in (guide, guest):
            package = device(serial, "shell", "pm", "list", "packages", "-U", APP)
            uid = re.search(r"^package:com\.aessam\.comeoverhere uid:(\d+)$", package, re.MULTILINE)
            if not uid:
                raise RuntimeError("Cannot safely scope app log collection")
            (artifacts / f"{orientation}-{serial}-logcat.txt").write_text(
                device(serial, "logcat", "-d", f"--uid={uid[1]}", "-v", "threadtime"))
        (artifacts / "results.json").write_text(json.dumps(rows, indent=2) + "\n")
        if failures:
            raise RuntimeError("; ".join(failures))
        modes = ("tiny_idle", "tiny_paced_asset") if args.profile == "tiny" else ("guide_to_guest", "guest_to_guide", "duplex")
        measured = [row for row in rows if row["orientation"] == orientation and row["phase"] in modes]
        if len(measured) != args.rounds * len(modes) or len({(row["phase"], row["round"]) for row in measured}) != len(measured):
            raise RuntimeError("Missing benchmark trials")
        if args.profile == "tiny":
            for row in measured:
                row["offered_rtt_deadline_miss_fraction"] = validate_tiny_row(row, args.millis)
            (artifacts / "results.json").write_text(json.dumps(rows, indent=2) + "\n")
        for mode in modes:
            samples = [row for row in measured if row["phase"] == mode]
            fields = (("rtt_p95_ms", "rtt_p99_ms", "local_schedule_drops", "late_echo_packets") if args.profile == "tiny"
                      else ("guide_to_guest_mbps", "guest_to_guide_mbps", "rtt_p95_ms"))
            print(f"{orientation} {mode}: " + "; ".join(
                f"{field} min/median/max={min(row[field] for row in samples):.2f}/"
                f"{statistics.median(row[field] for row in samples):.2f}/{max(row[field] for row in samples):.2f}"
                for field in fields), flush=True)
    print(f"Aware {args.profile} adapter benchmark completed; no native UDP/acoustic/capacity claim. Results: {artifacts / 'results.json'}", flush=True)


if __name__ == "__main__":
    main()
