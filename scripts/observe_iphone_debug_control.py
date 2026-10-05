#!/usr/bin/env python3
"""Run the opt-in visual observer using built device tests; no app.launch() in the test."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device")
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--screen", choices=["debug", "pointer"], default="debug")
    parser.add_argument("--result", required=True, type=Path)
    args = parser.parse_args()
    if args.result.exists():
        parser.error("Result path must be new")
    with args.manifest.open("rb") as file:
        manifest = plistlib.load(file)
    found = False
    for configuration in manifest["TestConfigurations"]:
        for target in configuration["TestTargets"]:
            if target.get("BlueprintName") == "GetOverHereUITests":
                target.setdefault("EnvironmentVariables", {}).update({
                    "GOH_OBSERVE_DEBUG_CONTROL": "1", "GOH_DEBUG_EXPECT_SCREEN": args.screen,
                })
                found = True
    if not found:
        parser.error("Manifest has no GetOverHereUITests target")
    # Same directory preserves __TESTROOT__ resolution. Never changes the original manifest.
    descriptor, name = tempfile.mkstemp(prefix="debug-observer-", suffix=".xctestrun", dir=args.manifest.parent)
    try:
        with os.fdopen(descriptor, "wb") as file:
            plistlib.dump(manifest, file)
        subprocess.run(["xcodebuild", "-quiet", "-xctestrun", name, "-destination", f"platform=iOS,id={args.device}",
                        "-parallel-testing-enabled", "NO", "-resultBundlePath", str(args.result),
                        "test-without-building", "-only-testing:GetOverHereUITests/GetOverHereUITests/testObserveExistingDebugControlSession"],
                       check=True)
    finally:
        Path(name).unlink()


if __name__ == "__main__":
    main()
