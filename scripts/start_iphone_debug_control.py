#!/usr/bin/env python3
"""Launch the existing installed Debug app using public devicectl. No force-stop or trust-store edits."""
import argparse
import base64
import os
from pathlib import Path
import stat
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("device")
    parser.add_argument("credentials", type=Path)
    args = parser.parse_args()
    root = args.credentials.resolve()
    if stat.S_IMODE(root.stat().st_mode) & 0o077:
        parser.error("Credential directory must be owner-only")
    key = (root / "control.key").read_bytes()
    identity = (root / "identity.p12").read_bytes()
    if len(key) != 32 or not identity:
        parser.error("Invalid credential bundle")
    environment = os.environ.copy()
    environment.update({
        "DEVICECTL_CHILD_GOH_DEBUG_CONTROL": "1",
        "DEVICECTL_CHILD_GOH_DEBUG_CONTROL_KEY": base64.b64encode(key).decode(),
        "DEVICECTL_CHILD_GOH_DEBUG_CONTROL_IDENTITY": base64.b64encode(identity).decode(),
    })
    # Environment variables are not printed or passed in command arguments.
    subprocess.run(["/usr/bin/xcrun", "devicectl", "device", "process", "launch", "--device", args.device,
                    "--activate", "--payload-url", "goh-debug://panel", "com.aens.GetOverHere"],
                   env=environment, check=True, timeout=30)
    print("Debug launch requested. If the app was already running, quit it normally and run again.")


if __name__ == "__main__":
    main()
