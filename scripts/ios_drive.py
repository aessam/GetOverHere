#!/usr/bin/env python3
"""Drive GetOverHere on a physical iPhone through WebDriverAgent (scripts/wda.sh start first).

Run with tools/.venv/bin/python. Every step fails loudly with the visible element tree on a miss.
Commands: create NAME | end | join NAME | leave | lock | unlock | home | shot PATH | source
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
    parser.add_argument("command", choices=["create", "end", "join", "leave", "lock", "unlock", "home", "shot", "source"])
    parser.add_argument("argument", nargs="?")
    args = parser.parse_args()
    c = client()
    started = time.monotonic()
    if args.command in ("create", "join", "end", "leave"):
        session = c.session(BUNDLE) if args.command in ("create", "join") else c.session()
    if args.command == "create":
        need(session(name="Add"), "Add button").tap()
        field = need(session(placeholderValue="e.g., Tour Group, Lecture Hall"), "channel name field")
        field.set_text(args.argument)
        need(session(name="Create", className="XCUIElementTypeButton"), "Create button").tap()
        need(session(name="End Tour"), "End Tour (tour live)", timeout=30)
    elif args.command == "join":
        need(session(name="findNearbyTours"), "Find Nearby Tours").tap()
        need(session(nameContains=args.argument, className="XCUIElementTypeButton"), f"room {args.argument}", timeout=90).tap()
        need(session(name="LISTENING"), "LISTENING status", timeout=45)
    elif args.command == "end":
        need(session(name="End Tour"), "End Tour").tap()
    elif args.command == "leave":
        need(session(name="Leave"), "Leave").tap()
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
