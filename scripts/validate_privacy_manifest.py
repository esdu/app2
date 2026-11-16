#!/usr/bin/env python3
"""Check the reviewed uptime declaration and its source/bundle packaging.

Pass an app's PrivacyInfo.xcprivacy to validate a built simulator or archived
device app. With no argument, validate the source manifest. This is a narrow
regression check for issue #1, not Apple's distribution validation or a complete
required-reason API scanner.
"""
import argparse
from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "LittleMoments/Resources/PrivacyInfo.xcprivacy"
BOOT_TIME = "NSPrivacyAccessedAPICategorySystemBootTime"


def validate(path):
    with path.open("rb") as handle:
        manifest = plistlib.load(handle)
    with SOURCE.open("rb") as handle:
        source_manifest = plistlib.load(handle)
    if not isinstance(manifest, dict):
        raise ValueError("Privacy manifest must be a property-list dictionary")
    entries = manifest.get("NSPrivacyAccessedAPITypes", [])
    if not isinstance(entries, list) or any(not isinstance(entry, dict) for entry in entries):
        raise ValueError("NSPrivacyAccessedAPITypes must be an array of dictionaries")
    uptime_calls = sum(len(re.findall(r"\.systemUptime\b", swift.read_text()))
                       for swift in (ROOT / "LittleMoments").rglob("*.swift"))
    if uptime_calls:
        reasons = [entry.get("NSPrivacyAccessedAPITypeReasons", []) for entry in entries
                   if entry.get("NSPrivacyAccessedAPIType") == BOOT_TIME]
        if len(reasons) != 1 or not isinstance(reasons[0], list) or "35F9.1" not in reasons[0]:
            raise ValueError(f"{uptime_calls} systemUptime calls require {BOOT_TIME} reason 35F9.1")
    if manifest != source_manifest:
        raise ValueError("Packaged privacy manifest differs from the reviewed source manifest")
    print(f"Validated {path}: {uptime_calls} systemUptime calls covered; manifest matches source")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", nargs="?", type=Path, default=SOURCE)
    args = parser.parse_args()
    try:
        validate(args.manifest)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"Privacy validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
