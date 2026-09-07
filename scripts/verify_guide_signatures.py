#!/usr/bin/env python3
"""Real cross-language signatures. Public test keys only; no radio or app qualification."""
import subprocess
import sys


def run(binary, *arguments, accepted=True):
    result = subprocess.run([binary, *arguments], text=True, capture_output=True, timeout=15)
    if accepted and result.returncode != 0:
        raise RuntimeError(f"{binary} {arguments[0]} failed: {result.stderr}")
    if not accepted and result.returncode not in (1, 2):
        raise RuntimeError(f"{binary} did not cleanly reject an invalid guide signature (exit {result.returncode})")
    return result.stdout.strip()


def main():
    if len(sys.argv) not in (3, 4):
        raise ValueError("usage: verify_guide_signatures.py SWIFT_CLI KOTLIN_CLI [ROUNDS=8]")
    swift, kotlin = sys.argv[1:3]
    rounds = int(sys.argv[3]) if len(sys.argv) == 4 else 8
    if not 1 <= rounds <= 100:
        raise ValueError("rounds must be 1–100")
    expected = run(swift, "realtime-fixture")
    if not expected or expected != run(kotlin, "realtime-fixture"):
        raise RuntimeError("underlying encrypted frame differs between cores")
    for source, destination, label in [(swift, kotlin, "Swift→Kotlin"), (kotlin, swift, "Kotlin→Swift")]:
        for index in range(rounds):
            lines = run(source, "sign-guide").splitlines()
            if len(lines) != 2 or len(bytes.fromhex(lines[0])) != 65:
                raise RuntimeError("signer did not return a public key and signed packet")
            key, packet = lines
            if run(destination, "verify-guide", key, packet) != expected:
                raise RuntimeError("signature verification changed the encrypted frame")
            changed = bytearray.fromhex(packet)
            changed[8 + index % (len(changed) - 72)] ^= 1
            run(destination, "verify-guide", key, changed.hex(), accepted=False)
            run(destination, "verify-guide", key, packet[:-2], accepted=False)
        print(f"{label}: {rounds}/{rounds} real signatures; changed/truncated packets rejected", flush=True)
    print("Guide signature parity passed; app bootstrap and relay integration remain separate")


if __name__ == "__main__":
    main()
