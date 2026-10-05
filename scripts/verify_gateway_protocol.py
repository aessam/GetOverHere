#!/usr/bin/env python3
"""Byte-exact Swift/Kotlin gateway records plus explicit malformed-input rejection.

Runs already-built production core CLIs. Software evidence only: this does not
exercise certificates, TLS sockets, physical USB, radios, or audio playback.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def call(binary, *arguments, reject=False):
    result = subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=10)
    if reject:
        if result.returncode not in (1, 2) or "error" not in result.stderr.lower():
            raise ValueError(f"{binary.name} did not explicitly reject {arguments[0:2]}: exit={result.returncode}, stderr={result.stderr[:300]}")
    elif result.returncode != 0 or not result.stdout.strip():
        raise ValueError(f"{binary.name} failed {arguments[0:2]}: exit={result.returncode}, stderr={result.stderr[:300]}")
    return result.stdout.strip()


def parse_fixture(text):
    lines = text.splitlines()
    if len(lines) != 10:
        raise ValueError(f"gateway-fixture expected 10 nonempty lines, received {len(lines)}")
    records = [("pairing", lines[0]), ("pairing", lines[1]), ("qr", lines[2]), ("qr", lines[3])]
    records += [("lane", line) for line in lines[4:9]]
    records += [("descriptor", lines[9])]
    for kind, value in records:
        if kind == "qr":
            if not value.startswith("goh-hub:1:"):
                raise ValueError("fixture QR prefix changed")
        elif not bytes.fromhex(value).startswith({"pairing": b"GHP1", "lane": b"GHL1", "descriptor": b"GHD1"}[kind]):
            raise ValueError("fixture magic changed")
    return records


def malformed(kind, encoded):
    if kind == "qr":
        return sorted({"", "goh-hub:1:", encoded + "=", " " + encoded, encoded.replace("goh-hub:1:", "goh-hub:2:"), encoded + "+"})
    value = bytes.fromhex(encoded)
    invalid = {value[:count] for count in (0, 1, 3, 4, 5, 16, len(value) // 2, len(value) - 1)}
    invalid.add(b"BAD!" + value[4:])
    invalid.add(value + b"\0")

    def change(start, end, replacement):
        invalid.add(value[:start] + replacement + value[end:])

    if kind == "pairing":
        change(4, 5, b"\xff")
        change(5, 21, bytes(16))
        change(53, 61, bytes(8))
        change(53, 61, b"\xff" * 8)
        if value[4] == 1:
            change(len(value) - 2, len(value), b"\0\0")
            change(125, 157, b"\xaa" * 32)
    elif kind == "lane":
        change(4, 20, bytes(16))
        change(44, 45, b"\xff")
        change(36, 44, (1 if value[44] == 0 else 0).to_bytes(8, "big"))
    else:
        change(4, 12, bytes(8))
        change(12, 20, bytes(8))
        change(20, 22, b"\xff\xff")
        change(len(value) - 65, len(value) - 64, b"\x03")
    return sorted(item.hex() for item in invalid)


def verify(swift, kotlin):
    swift_fixture = call(swift, "gateway-fixture")
    kotlin_fixture = call(kotlin, "gateway-fixture")
    if swift_fixture != kotlin_fixture:
        raise ValueError("Swift/Kotlin gateway fixture bytes differ")
    records = parse_fixture(swift_fixture)
    rows = []
    for number, (kind, value) in enumerate(records):
        for binary in (swift, kotlin):
            decoded = call(binary, "gateway-decode", kind, value)
            if decoded != value:
                raise ValueError(f"{binary.name} changed {kind} bytes during roundtrip")
            rows.append({"binary": binary.name, "record": number, "kind": kind, "case": "cross_roundtrip", "status": "PASS"})
            for index, bad in enumerate(malformed(kind, value)):
                call(binary, "gateway-decode", kind, bad, reject=True)
                rows.append({"binary": binary.name, "record": number, "kind": kind, "case": f"reject_{index}", "status": "PASS"})
    return {"schema": 1, "scope": "cross_language_gateway_core_only", "fixture_lines": len(records),
            "executed": len(rows), "passed": len(rows), "failed": 0, "skipped": 0, "cases": rows}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("swift", type=Path)
    parser.add_argument("kotlin", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        for binary in (args.swift, args.kotlin):
            if not binary.is_file() or not os.access(binary, os.X_OK):
                raise ValueError(f"CLI not executable: {binary}")
        result = verify(args.swift.resolve(), args.kotlin.resolve())
        if args.output:
            args.output.write_text(json.dumps(result, indent=2) + "\n")
        print(f"Gateway protocol parity passed: {result['fixture_lines']} exact fixture lines; {result['passed']}/{result['executed']} roundtrip/rejection cases; 0 skipped. No physical qualification claim.")
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
