#!/usr/bin/env python3
"""Check an already-built Release app for debug control entry points."""
import argparse
from pathlib import Path
import plistlib
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    with (args.app / "Info.plist").open("rb") as file:
        info = plistlib.load(file)
    schemes = [scheme for item in info.get("CFBundleURLTypes", []) for scheme in item.get("CFBundleURLSchemes", [])]
    if "goh-debug" in schemes or (args.app / "Info.Debug.plist").exists():
        raise RuntimeError("Debug URL/resource leaked into Release")
    executable = args.app / info["CFBundleExecutable"]
    # Debug builds can place implementation in a dylib, so check both locations.
    binaries = [executable, *args.app.glob("*.dylib")]
    for binary in binaries:
        symbols = subprocess.run(["/usr/bin/nm", str(binary)], capture_output=True, text=True, check=True).stdout
        strings = subprocess.run(["/usr/bin/strings", str(binary)], capture_output=True, text=True, check=True).stdout
        if any(value in symbols for value in ("DebugControlServer", "DebugAppControl", "DebugControlPanel")):
            raise RuntimeError("Debug control symbols leaked into Release")
        if any(value in strings for value in ("GOH_DEBUG_CONTROL", "goh-debug://", "Debug control state:")):
            raise RuntimeError("Debug control strings leaked into Release")
    print("PASS: Release plist, resources, symbols and strings exclude debug control")


if __name__ == "__main__":
    main()
