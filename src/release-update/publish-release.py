#!/usr/bin/env python3
"""Upload architecture-specific LF Portable archives with GitHub CLI."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys


VERSION_PATTERN = re.compile(r"^\d+\.\d+\.\d+\.\d+$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Publish LFPortable-x64.zip and LFPortable-arm64.zip with gh.")
    parser.add_argument("--release-root", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository", default="riveryang6/lf-portable")
    parser.add_argument(
        "--draft",
        action="store_true",
        help="create a draft release instead of publishing it immediately",
    )
    return parser.parse_args()


def find_gh() -> str:
    for candidate in ("gh", "gh.exe"):
        resolved = shutil.which(candidate)
        if resolved:
            return resolved
    raise ValueError("GitHub CLI (gh or gh.exe) is not available on PATH")


def main() -> int:
    args = parse_args()
    if not VERSION_PATTERN.fullmatch(args.version):
        print("publish-release.py: --version must contain four numeric components", file=sys.stderr)
        return 1

    release_root = args.release_root.expanduser().resolve()
    archives = [release_root / f"LFPortable-{architecture}.zip" for architecture in ("x64", "arm64")]
    missing = [str(path) for path in archives if not path.is_file()]
    if missing:
        print("publish-release.py: release archive(s) are missing: " + ", ".join(missing), file=sys.stderr)
        return 1

    try:
        gh = find_gh()
    except ValueError as error:
        print(f"publish-release.py: {error}", file=sys.stderr)
        return 1

    command = [
        gh,
        "release",
        "create",
        f"v{args.version}",
        *(str(archive) for archive in archives),
        "--repo",
        args.repository,
        "--title",
        f"LF Portable {args.version}",
        "--generate-notes",
    ]
    if args.draft:
        command.append("--draft")
    try:
        subprocess.run(command, check=True)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"publish-release.py: gh release create failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
