#!/usr/bin/env python3
"""Drive GetOverHere on a physical iPhone through WebDriverAgent (scripts/wda.sh start first).

Run with tools/.venv/bin/python. Visible text is matched by `label`; accessibility identifiers by `name`. Every miss fails loudly.
Commands: create NAME | end | join NAME | leave | pointer | import-pdf NAME | autolock VALUE | lock | unlock | home | shot PATH | source
"""
import argparse
import subprocess
import sys
import time
from pathlib import Path

import wda

BUNDLE = "com.aens.GetOverHere"
ROOT = Path(__file__).resolve().parent.parent


def client():
    url = subprocess.run([str(ROOT / "scripts/wda.sh"), "url"], capture_output=True, text=True, check=True).stdout.strip()
    return wda.Client(url)


def need(element, description, timeout=20.0):
    if not element.wait(timeout=timeout, raise_error=False):
        raise SystemExit(f"error: {description} not found within {timeout:.0f}s")
    return element


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["create", "end", "join", "leave", "pointer", "import-pdf", "autolock", "lock", "unlock", "home", "shot", "source"])
    parser.add_argument("argument", nargs="?")
    args = parser.parse_args()
    c = client()
    started = time.monotonic()
    if args.command in ("create", "join", "end", "leave", "pointer", "import-pdf"):
        # Never relaunch: that ends a live tour and detaches a `devicectl --console` log capture.
        c.app_activate(BUNDLE)
        session = c.session()
    if args.command == "create":
        field = session(className="XCUIElementTypeTextField")
        if not field.exists:
            need(session(label="Add"), "Add button").tap()
        field = need(field, "channel name field")
        field.set_text(args.argument)
        deadline = time.monotonic() + 5  # SwiftUI commits the binding asynchronously; Create is a no-op before that.
        while field.value != args.argument and time.monotonic() < deadline:
            time.sleep(0.1)
        if field.value != args.argument:
            raise SystemExit(f"error: channel name field shows {field.value!r}, expected {args.argument!r}")
        need(session(label="Create", className="XCUIElementTypeButton"), "Create button").tap()
        need(session(label="End Tour"), "End Tour (tour live)", timeout=30)
    elif args.command == "join":
        need(session(name="findNearbyTours"), "Find Nearby Tours").tap()
        need(session(labelContains=args.argument, className="XCUIElementTypeButton"), f"room {args.argument}", timeout=90).tap()
        need(session(label="LISTENING"), "LISTENING status", timeout=45)
    elif args.command == "pointer":
        need(session(label="Pointer", className="XCUIElementTypeButton"), "Pointer segment").tap()
    elif args.command == "import-pdf":
        # Guide only. The PDF must be in the app's Documents (Debug builds share it with Files).
        need(session(label="Slides", className="XCUIElementTypeButton"), "Slides segment").tap()
        if not session(label="Browse").exists:  # the picker may already be open from an earlier attempt
            need(session(label="Import PDF"), "Import PDF").tap()
        need(session(label="Browse"), "Files Browse tab").tap()
        target = session(labelContains=f"{args.argument}, pdf")  # the file cell, not its title text
        if not target.wait(timeout=3, raise_error=False):  # Browse resets to the Locations root
            need(session(label="On My iPhone"), "On My iPhone").tap()
            need(session(labelContains="GetOverHere,"), "GetOverHere folder").tap()
        need(target, f"file {args.argument}").tap()
        # "End Tour" stays visible behind the sheet; success is the picker closing.
        if not session(label="Browse").wait_gone(timeout=30):
            raise SystemExit("error: the document picker did not close after choosing the file")
    elif args.command == "end":
        need(session(label="End Tour"), "End Tour").tap()
    elif args.command == "leave":
        need(session(label="Leave"), "Leave").tap()
    elif args.command == "autolock":
        # Settings > Display & Brightness > Auto-Lock.
        settings = c.session("com.apple.Preferences")
        row = settings(label="Auto-Lock")
        if not row.wait(timeout=3, raise_error=False):  # Settings reopens on its last page
            for _ in range(4):
                back = settings(className="XCUIElementTypeNavigationBar").child(className="XCUIElementTypeButton")
                if settings(label="Display & Brightness").exists or not back.exists:
                    break
                back.tap()
            display = settings(label="Display & Brightness")
            for _ in range(6):
                if display.exists:
                    break
                c.swipe_up()
            need(display, "Display & Brightness").tap()
        row = need(row, "Auto-Lock row")
        row.tap()
        need(settings(label=args.argument), f"Auto-Lock option {args.argument}").tap()
        print(f"autolock now={args.argument!r} (record the old value yourself: the cell detail is not exposed)", flush=True)
        c.home()
    elif args.command == "lock":
        c.lock()
    elif args.command == "unlock":
        c.unlock()
    elif args.command == "home":
        c.home()
    elif args.command == "shot":
        c.screenshot(args.argument)
    elif args.command == "source":
        print(c.source())
    print(f"ok {args.command} {args.argument or ''} in {time.monotonic() - started:.1f}s", flush=True)


if __name__ == "__main__":
    sys.exit(main())
