#!/usr/bin/env python3
"""Real CryptoKit/JVM GOHR-v2 exchanges plus admitted-key GOS1 verification/GOH2 decryption.

Uses fresh ECDH/signing keys and fresh UUIDs. No private-key injection or crypto bypass.
The only printed credential belongs to the fixed synthetic CLI test session.
"""
import os
import selectors
import subprocess
import sys
import uuid


def line(process):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(timeout=15):
            raise RuntimeError("Room admission-v2 CLI timed out")
    value = process.stdout.readline()
    if not value:
        raise RuntimeError("Room admission-v2 CLI closed unexpectedly")
    return value


def exchange(guide_path, guest_path, code, mutation=None):
    session, guide_id = str(uuid.uuid4()), str(uuid.uuid4())
    processes = []
    try:
        for path, role in [(guide_path, "room-v2-guide"), (guest_path, "room-v2-guest")]:
            selected_guide = str(uuid.uuid4()) if mutation == "wrong-guide" and role.endswith("guest") else guide_id
            processes.append(subprocess.Popen([path, role, session, selected_guide, code], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1))
        guide, guest = processes
        for step, (source, destination) in enumerate([(guide, guest), (guest, guide), (guide, guest), (guide, guest)]):
            value = line(source)
            if step == 0:
                assert len(bytes.fromhex(value)) == 103, "Challenge size changed"
                if mutation == "v1-version":
                    changed = bytearray.fromhex(value)
                    changed[4] = 1
                    value = changed.hex() + "\n"
            elif step == 1:
                assert len(bytes.fromhex(value)) == 97, "Request size changed"
            elif step == 2:
                assert len(bytes.fromhex(value)) == 183, "Reply size changed"
                if mutation == "reply-tamper":
                    changed = bytearray.fromhex(value)
                    changed[-1] ^= 1
                    value = changed.hex() + "\n"
            elif step == 3 and mutation == "frame-tamper":
                changed = bytearray.fromhex(value)
                changed[-1] ^= 1
                value = changed.hex() + "\n"
            destination.stdin.write(value)
            destination.stdin.flush()
            if (mutation == "v1-version" and step == 0) or (mutation in ("reply-tamper", "wrong-guide") and step == 2):
                break
        if mutation:
            assert guest.wait(timeout=15) in (1, 2), f"Guest accepted {mutation} or crashed"
            assert "error:" in guest.stderr.read().lower(), "Rejection was not explicit"
        else:
            expected_key = line(guide).strip()
            assert line(guest).strip() == "23456789AB", "Media secret changed"
            assert line(guest).strip() == expected_key, "Admitted guide key changed"
            assert line(guest).strip() == "signed-guide-ok", "Admitted key did not verify/decrypt guide frame"
            for process in processes:
                assert process.wait(timeout=15) == 0, process.stderr.read()
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait()
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()


def main():
    if len(sys.argv) != 3 or not all(os.path.isfile(path) and os.access(path, os.X_OK) for path in sys.argv[1:]):
        raise SystemExit("usage: verify_room_admission_v2.py SWIFT_CLI KOTLIN_CLI (already built)")
    swift, kotlin = sys.argv[1:]
    for label, guide, guest in [("Swift→Kotlin", swift, kotlin), ("Kotlin→Swift", kotlin, swift)]:
        for code in ["-", "1234", "My-Tour!42", "a" * 64]:
            exchange(guide, guest, code)
            print(f"ok {label} {'open' if code == '-' else 'locked'} admission + pinned guide signature + AEAD")
        for mutation in ["v1-version", "wrong-guide", "reply-tamper", "frame-tamper"]:
            exchange(guide, guest, "-", mutation)
            print(f"ok {label} rejected {mutation}")
    print("Room admission-v2 parity passed: 8 real key exchanges + 8 explicit rejections")


if __name__ == "__main__":
    main()
