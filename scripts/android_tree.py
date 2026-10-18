#!/usr/bin/env python3
"""Find a node in an Android `uiautomator dump` (stdin) and print its center "x y", or nothing.

An exact text/content-desc label wins; a substring match is only the fallback ("Leave" -> "Leave Channel").
Substring-first matching tapped the dialog subtitle "Create a channel..." instead of the "Create" button.
Usage: adb shell cat /sdcard/goh-ui.xml | scripts/android_tree.py LABEL
"""
import re
import sys


def labels(node):
    return re.findall(r'(?:text|content-desc)="([^"]*)"', node)


def main():
    needle = sys.argv[1]
    nodes = re.findall(r"<node [^>]*>", sys.stdin.read())
    match = next((n for n in nodes if needle in labels(n)), None) \
        or next((n for n in nodes if any(needle in label for label in labels(n))), None)
    if match:
        x1, y1, x2, y2 = map(int, re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', match).groups())
        print((x1 + x2) // 2, (y1 + y2) // 2)


if __name__ == "__main__":
    main()
