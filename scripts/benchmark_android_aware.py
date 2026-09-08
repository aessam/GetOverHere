#!/usr/bin/env python3
"""Explicit two-phone Aware goodput measurement. No Internet endpoint or LAN fallback."""
import argparse
import concurrent.futures
import hashlib
import json
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--guide", required=True)
    parser.add_argument("--guest", required=True)
    parser.add_argument("--emulator", default="emulator-5554")
    parser.add_argument("--millis", type=int, default=10_000)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--reuse-installed", action="store_true")
    parser.add_argument("--preflight-only", action="store_true")
    parser.add_argument("--smoke-only", action="store_true")
    args = parser.parse_args()
    if not (100 <= args.millis <= 30_000 and 1 <= args.rounds <= 5):
        parser.error("millis must be 100..30000 and rounds 1..5")
    if args.guide == args.guest or any(not re.fullmatch(r"[A-Za-z0-9]+", x) for x in (args.guide, args.guest)):
        parser.error("choose two distinct physical USB serials")
    if not re.fullmatch(r"emulator-[0-9]+", args.emulator):
        parser.error("smoke test must use an explicit emulator")
    adb = Path(os.environ.get("ANDROID_HOME", str(Path.home() / "Library/Android/sdk"))) / "platform-tools/adb"
    if not adb.is_file():
        parser.error("adb missing")

    def device(serial, *command, timeout=30):
        return run([str(adb), "-s", serial, *command], timeout)

    for serial in (args.guide, args.guest, args.emulator):
        if device(serial, "get-state").strip() != "device":
            raise RuntimeError(f"Device unavailable: {serial}")
    for serial in (args.guide, args.guest):
        if int(device(serial, "shell", "getprop", "ro.build.version.sdk")) < 34:
            raise RuntimeError(f"Android 14+ required: {serial}")
        if device(serial, "shell", "settings", "get", "global", "wifi_on").strip() != "1":
            raise RuntimeError(f"Enable Wi-Fi on {serial}; Aware cannot run with its radio disabled")
    if args.preflight_only:
        print("Preflight passed: explicit Android pair, Wi-Fi enabled, emulator present", flush=True)
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
        "apk_sha256": hashes,
        "scope": "PIN-secured production Android Aware socket and bridge goodput; synthetic verified data, no tour AEAD/codec",
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
    print("Socket loopback, full-duplex protocol, corruption rejection and percentile smoke passed", flush=True)
    if args.smoke_only:
        return
    for serial in (args.guide, args.guest):
        install(serial, args.reuse_installed)

    rows = []
    for orientation, guide, guest in (("forward", args.guide, args.guest), ("reverse", args.guest, args.guide)):
        # Fresh radio ownership and PIN per guide role. No automatic retry hiding setup failures.
        extra = {"benchmarkRoom": uuid.uuid4(), "benchmarkToken": uuid.uuid4(),
                 "benchmarkPIN": f"{secrets.randbelow(1_000_000):06d}",
                 "benchmarkMillis": args.millis, "benchmarkRounds": args.rounds}
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
        measured = [row for row in rows if row["orientation"] == orientation and row["phase"] in
                    ("guide_to_guest", "guest_to_guide", "duplex")]
        if len(measured) != args.rounds * 3:
            raise RuntimeError("Missing benchmark trials")
        for mode in ("guide_to_guest", "guest_to_guide", "duplex"):
            samples = [row for row in measured if row["phase"] == mode]
            print(f"{orientation} {mode}: " + "; ".join(
                f"{field} min/median/max={min(row[field] for row in samples):.2f}/"
                f"{statistics.median(row[field] for row in samples):.2f}/{max(row[field] for row in samples):.2f}"
                for field in ("guide_to_guest_mbps", "guest_to_guide_mbps", "rtt_p95_ms")), flush=True)
    print(f"Aware benchmark passed; verified receiver goodput, not a radio PHY maximum. Results: {artifacts / 'results.json'}", flush=True)


if __name__ == "__main__":
    main()
