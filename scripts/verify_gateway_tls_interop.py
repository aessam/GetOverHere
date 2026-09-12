#!/usr/bin/env python3
"""Real Apple Network.framework / AndroidKeyStore TLS, both server roles.

Requires prebuilt test APKs already installed on an idle emulator. Uses scoped
ADB tunnels, not USB Ethernet; no physical gateway, audio or radio claim.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import socket
import subprocess
import time
import uuid

from verify_gateway_system import GateError, device_lock, require, sha256, source_identity
from probe_gateway_android import probe
from contextlib import ExitStack


TEST = "com.aessam.comeoverhere.GatewayCrossPlatformTLSFixtureTest#controlledExchange"
RUNNER = "com.aessam.comeoverhere.test/androidx.test.runner.AndroidJUnitRunner"


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def run(args, output):
    command = subprocess.run(args, text=True, capture_output=True, timeout=40)
    output.write_text(command.stdout + command.stderr)
    require(command.returncode == 0, f"command failed: {output}")
    return command.stdout


def await_text(path, predicate, process, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = path.read_text() if path.exists() else ""
        result = predicate(value)
        if result:
            return result
        require(process.poll() is None, f"process exited before readiness: {path}")
        time.sleep(0.05)
    raise GateError(f"readiness deadline: {path}")


def ready_json(value):
    for line in value.splitlines():
        if line.startswith("{"):
            row = json.loads(line)
            if row.get("event") == "ready":
                return row
    return None


def verify(args):
    require(args.serial.startswith("emulator-"), "this isolated fixture requires an emulator, not a user's active phone")
    require(args.binary.is_file(), "build Packages/GatewayTLSFixture first")
    require(args.apk.is_file() and args.test_apk.is_file(), "both selected Android APKs must exist")
    args.output.mkdir(parents=True, exist_ok=False)
    adb = [args.adb, "-s", args.serial]
    results = []
    expected_hash = hashlib.sha256(bytes(index % 251 for index in range(65_536))).hexdigest()
    with ExitStack() as stack:
        device_lock(stack, args.serial)
        require(run(adb + ["get-state"], args.output / "device.log").strip() == "device", "emulator unavailable")
        app = probe(args.adb, args.serial, args.apk)
        instrumentation = probe(args.adb, args.serial, args.test_apk, package="com.aessam.comeoverhere.test")
        metadata = {"apple_fixture_sha256": sha256(args.binary), "android_app": app,
                    "android_instrumentation": instrumentation, "source_observation": source_identity(),
                    "scope": "installed_binary_identity_not_a_build_source_attestation"}
        (args.output / "preflight.json").write_text(json.dumps(metadata, indent=2) + "\n")
        for apple_role in ("server", "client"):
            android_role = "client" if apple_role == "server" else "server"
            case = args.output / f"apple-{apple_role}"
            case.mkdir()
            run_id = uuid.uuid4().hex
            def instrument(mode, extra=()):
                return adb + ["shell", "am", "instrument", "-w", "-r", "-e", "class", TEST,
                              "-e", "gatewayTlsRun", run_id, "-e", "gatewayTlsMode", mode, *extra, RUNNER]
            native = None
            apple = None
            tunnel = None
            try:
                identity = run(instrument("identity"), case / "android-identity.log")
                match = re.search(r"GATEWAY_PIN=([a-f0-9]{64})", identity)
                require(match and "OK (1 test)" in identity, "Android identity fixture did not run exactly one test")
                peer_pin = match[1]
                local_port = free_port()
                android_port = 50114
                if apple_role == "server":
                    run(adb + ["reverse", "--no-rebind", f"tcp:{android_port}", f"tcp:{local_port}"], case / "tunnel.log")
                    tunnel = ("reverse", f"tcp:{android_port}")
                else:
                    local_port = int(run(adb + ["forward", "--no-rebind", "tcp:0", f"tcp:{android_port}"], case / "tunnel.log").strip())
                    tunnel = ("forward", f"tcp:{local_port}")
                with (case / "apple.log").open("w") as apple_log, (case / "android.log").open("w") as android_log:
                    apple = subprocess.Popen([str(args.binary.resolve()), apple_role, str(local_port), peer_pin],
                                             stdin=subprocess.PIPE, stdout=apple_log, stderr=subprocess.STDOUT, text=True)
                    ready = await_text(case / "apple.log", ready_json, apple)
                    require(re.fullmatch("[a-f0-9]{64}", ready["pin"]), "invalid Apple identity pin")
                    native = subprocess.Popen(instrument(android_role, ["-e", "gatewayTlsPin", ready["pin"],
                                               "-e", "gatewayTlsPort", str(android_port)]), stdout=android_log, stderr=subprocess.STDOUT)
                    if apple_role == "client":
                        await_text(case / "android.log", lambda value: "GATEWAY_SERVER_READY" in value, native)
                        apple.stdin.write("GO\n"); apple.stdin.flush()
                    require(apple.wait(timeout=30) == 0, f"Apple TLS failed: {case / 'apple.log'}")
                    require(native.wait(timeout=30) == 0, f"Android TLS command failed: {case / 'android.log'}")
                native_output = (case / "android.log").read_text()
                require("OK (1 test)" in native_output and "FAILURES" not in native_output, "Android test failed/skipped")
                require(f"GATEWAY_PASS bytes=65536 sha256={expected_hash}" in native_output, "Android payload evidence missing")
                rows = [json.loads(line) for line in (case / "apple.log").read_text().splitlines() if line.startswith("{")]
                require(any(row.get("event") == "pass" and row.get("bytes") == 65536 and row.get("sha256") == expected_hash
                            for row in rows), "Apple payload evidence missing")
                results.append({"apple_role": apple_role, "android_role": android_role, "status": "PASS",
                                "bytes_roundtripped": 65536, "sha256": expected_hash})
            finally:
                for process in (apple, native):
                    if process is not None and process.poll() is None:
                        process.terminate()
                        try: process.wait(timeout=3)
                        except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=3)
                if tunnel:
                    run(adb + [tunnel[0], "--remove", tunnel[1]], case / "tunnel-cleanup.log")
                cleanup = run(instrument("cleanup"), case / "identity-cleanup.log")
                require("OK (1 test)" in cleanup and "FAILURES" not in cleanup, "Test-only identity cleanup failed")
    result = {"schema": 1, "scope": "apple_android_tls_over_adb_only", "serial": args.serial,
              "passed": len(results), "failed": 0, "skipped": 0, "cases": results,
              "artifacts": {"apple_fixture_sha256": metadata["apple_fixture_sha256"],
                            "android_app_sha256": app["installed_sha256"],
                            "android_test_sha256": instrumentation["installed_sha256"]}}
    (args.output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"Apple/Android TLS: {len(results)}/2 server-role exchanges passed, 65536 exact bytes each. Not USB/radio qualification.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--binary", type=Path, required=True, help="executable under swift build --show-bin-path")
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--test-apk", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        verify(args)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
