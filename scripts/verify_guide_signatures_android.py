#!/usr/bin/env python3
"""Cross-check CryptoKit and the emulator's real Android signature provider."""
import subprocess
import sys


def run(*arguments):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        raise RuntimeError(f"{arguments[0]} failed: {result.stderr}")
    return result.stdout.strip()


def main():
    if len(sys.argv) != 4 or not sys.argv[3].startswith("emulator-"):
        raise ValueError("usage: verify_guide_signatures_android.py SWIFT_CLI ADB EMULATOR_SERIAL")
    swift, adb, emulator = sys.argv[1:]
    if run(adb, "-s", emulator, "get-state") != "device":
        raise RuntimeError("emulator unavailable")
    key, packet = run(swift, "sign-guide").splitlines()
    output = run(adb, "-s", emulator, "shell", "am", "instrument", "-w", "-r",
                 "-e", "class", "com.aessam.comeoverhere.GuideSignaturePlatformTest",
                 "-e", "guideKey", key, "-e", "guidePacket", packet,
                 "com.aessam.comeoverhere.test/androidx.test.runner.AndroidJUnitRunner")
    if "OK (1 test)" not in output:
        raise RuntimeError(f"native signature fixture failed: {output}")
    exports = [line.split("guide_signature=", 1)[1] for line in output.splitlines() if "guide_signature=" in line]
    if len(exports) != 1:
        raise RuntimeError("expected exactly one Android public signature fixture")
    android_key, android_packet = exports[0].split("|")
    if run(swift, "verify-guide", android_key, android_packet) != run(swift, "realtime-fixture"):
        raise RuntimeError("Android signature changed encrypted fixture bytes")
    print("CryptoKit↔Android native-provider signatures passed; 100 native key/signature/tamper checks")


if __name__ == "__main__":
    main()
