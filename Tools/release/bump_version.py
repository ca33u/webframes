#!/usr/bin/env python3
"""Set MARKETING_VERSION and CURRENT_PROJECT_VERSION in every build
configuration of webframes.xcodeproj (they are duplicated six times).

    python3 Tools/release/bump_version.py 1.0.2 5
"""
import re
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2] / 'webframes.xcodeproj/project.pbxproj'


def main():
    if len(sys.argv) != 3 or not re.fullmatch(r'\d+(\.\d+)*', sys.argv[1]) or not sys.argv[2].isdigit():
        raise SystemExit(__doc__)
    version, build = sys.argv[1], sys.argv[2]
    text = PROJECT.read_text()
    builds = {int(b) for b in re.findall(r'CURRENT_PROJECT_VERSION = (\d+);', text)}
    if builds and int(build) <= max(builds):
        raise SystemExit(f'Build {build} must be greater than the current {max(builds)}.')
    text, versions = re.subn(r'MARKETING_VERSION = [^;]+;', f'MARKETING_VERSION = {version};', text)
    text, counts = re.subn(r'CURRENT_PROJECT_VERSION = \d+;', f'CURRENT_PROJECT_VERSION = {build};', text)
    if versions != 6 or counts != 6:
        raise SystemExit(f'Expected 6 of each setting, found {versions} MARKETING_VERSION and {counts} CURRENT_PROJECT_VERSION.')
    PROJECT.write_text(text)
    print(f'Web Frames {version} ({build}) in all 6 configurations. Rename "## Unreleased" in CHANGELOG.md to "## {version} ({build}) — <date>".')


if __name__ == '__main__':
    main()
