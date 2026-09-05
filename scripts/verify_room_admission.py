#!/usr/bin/env python3
"""Cross-language real ephemeral-key exchanges, both directions; no deterministic crypto bypass."""
import os
import selectors
import subprocess
import sys
import uuid


def line(process):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(timeout=10):
            raise RuntimeError("Room admission CLI timed out")
    value = process.stdout.readline()
    if not value:
        raise RuntimeError("Room admission CLI closed unexpectedly")
    return value


def exchange(guide_path, guest_path, code):
    session = str(uuid.uuid4())
    processes = []
    try:
        for path, role in [(guide_path, "room-guide"), (guest_path, "room-guest")]:
            processes.append(subprocess.Popen([path, role, session, code], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1))
        guide, guest = processes
        for source, destination in [(guide, guest), (guest, guide), (guide, guest)]:
            destination.stdin.write(line(source))
            destination.stdin.flush()
        assert line(guest).strip() == "23456789AB", "Session credential roundtrip mismatch"
        for process in processes:
            assert process.wait(timeout=10) == 0, process.stderr.read()
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait()
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()


def main():
    if len(sys.argv) != 3 or not all(os.path.isfile(path) and os.access(path, os.X_OK) for path in sys.argv[1:]):
        raise SystemExit("usage: verify_room_admission.py SWIFT_CLI KOTLIN_CLI (already built)")
    swift, kotlin = sys.argv[1:]
    for label, guide, guest in [("Swift→Kotlin", swift, kotlin), ("Kotlin→Swift", kotlin, swift)]:
        for code in ["-", "1234", "My-Tour!42", "a" * 64]:
            exchange(guide, guest, code)
            print(f"ok {label} {'open' if code == '-' else 'locked'} length={0 if code == '-' else len(code)}")
    print("Room admission parity passed: 8/8 real key exchanges")


if __name__ == "__main__":
    main()
