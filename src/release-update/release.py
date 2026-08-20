#!/usr/bin/env python3
"""Assemble architecture-specific, offline LF Portable release packages."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import zipfile


DOCUMENTATION_SOURCE = Path(os.path.abspath(__file__)).with_name("CodexData-README.txt")
VERSION_PATTERN = re.compile(r"^\d+\.\d+\.\d+\.\d+$")
ARCHITECTURES = ("x64", "arm64")

COMMON_FILES = (
    ("CodexPortable.exe", "launcher"),
    ("CodexData/README.txt", "documentation"),
    ("CodexData/THIRD_PARTY.txt", "base"),
    ("CodexData/tools/launchers/CodexPortable.x86.exe", "launcher"),
    ("CodexData/tools/launchers/CodexPortable.x64.exe", "launcher"),
    ("CodexData/tools/launchers/CodexPortable.arm64.exe", "launcher"),
    ("CodexData/packages/LFPortable-common.zip", "base"),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create offline, architecture-specific LF Portable release ZIPs."
    )
    parser.add_argument("--base-root", required=True, type=Path)
    parser.add_argument("--launcher-root", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument(
        "--architecture",
        choices=("both",) + ARCHITECTURES,
        default="both",
        help="package one architecture or both (default: both)",
    )
    return parser.parse_args()


REPARSE_POINT_ATTRIBUTE = 0x400


def reject_reparse_path(path: Path, label: str) -> None:
    """Reject symlinks/junctions in an input path before resolving it."""

    current = path.expanduser()
    while True:
        try:
            info = current.lstat()
        except FileNotFoundError:
            pass
        except OSError as error:
            raise ValueError(f"cannot inspect {label}: {current}: {error}") from error
        else:
            attributes = int(getattr(info, "st_file_attributes", 0))
            if stat.S_ISLNK(info.st_mode) or attributes & REPARSE_POINT_ATTRIBUTE:
                raise ValueError(f"{label} contains a symlink or reparse point: {current}")
        parent = current.parent
        if parent == current:
            return
        current = parent


def absolute(path: Path, label: str) -> Path:
    # abspath normalizes a relative spelling without resolving symlinks, so
    # reject_reparse_path can inspect every original path component first.
    candidate = Path(os.path.abspath(path.expanduser()))
    reject_reparse_path(candidate, label)
    return candidate


def require_regular_file(path: Path, label: str) -> Path:
    reject_reparse_path(path, label)
    try:
        # lstat avoids following a link introduced after the ancestor walk.
        info = path.lstat()
    except OSError as error:
        raise ValueError(f"required {label} is unavailable: {path}: {error}") from error
    if not stat.S_ISREG(info.st_mode) or int(getattr(info, "st_file_attributes", 0)) & REPARSE_POINT_ATTRIBUTE:
        raise ValueError(f"required {label} is missing or is not a regular file: {path}")
    return path


def require_launcher_version(path: Path, version: str) -> None:
    """Tie the requested release version to every shipped launcher binary."""

    data = path.read_bytes()
    if version.encode("ascii") not in data and version.encode("utf-16le") not in data:
        raise ValueError(f"launcher version {version} is not present in: {path}")


def source_files(base_root: Path, launcher_root: Path, architecture: str,
                 version: str) -> list[tuple[str, Path]]:
    roots = {"base": base_root, "documentation": DOCUMENTATION_SOURCE, "launcher": launcher_root}
    entries = list(COMMON_FILES)
    entries.append((f"CodexData/packages/LFPortable-{architecture}.msix", "base"))
    result: list[tuple[str, Path]] = []
    for relative_path, source_name in entries:
        root = roots[source_name]
        source = root if source_name == "documentation" else root / relative_path
        source = require_regular_file(source, f"{source_name} input {relative_path}")
        if source_name == "launcher" and relative_path.endswith(".exe"):
            require_launcher_version(source, version)
        result.append((relative_path, source))
    return result


def archive_release(release_root: Path, archive_path: Path, files: list[tuple[str, Path]]) -> None:
    with zipfile.ZipFile(archive_path, mode="x", compression=zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
        for relative_path, _ in files:
            # Packages are already compressed; storing them avoids a second multi-GB pass.
            compression = zipfile.ZIP_STORED if relative_path.endswith((".zip", ".msix")) else zipfile.ZIP_DEFLATED
            archive.write(release_root / relative_path, arcname=relative_path, compress_type=compression)


def create_architecture_release(
    base_root: Path, launcher_root: Path, output_root: Path, architecture: str,
    version: str,
) -> tuple[Path, Path]:
    files = source_files(base_root, launcher_root, architecture, version)
    release_root = output_root / f"LFPortable-{architecture}"
    archive_path = output_root / f"LFPortable-{architecture}.zip"
    if release_root.exists() or archive_path.exists():
        raise ValueError(f"release output already exists for {architecture}: {release_root}")
    release_root.mkdir(parents=True)
    for relative_path, source in files:
        destination = release_root / relative_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    archive_release(release_root, archive_path, files)
    return release_root, archive_path


def create_release(base_root: Path, launcher_root: Path, output_root: Path, version: str,
                   requested_architecture: str) -> None:
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError("--version must contain exactly four numeric components")
    base_root = absolute(base_root, "base root")
    launcher_root = absolute(launcher_root, "launcher root")
    output_root = absolute(output_root, "output root")
    if output_root.exists():
        raise ValueError(f"output root already exists: {output_root}")
    if output_root.parent.exists() and not output_root.parent.is_dir():
        raise ValueError(f"output parent is not a directory: {output_root.parent}")

    architectures = ARCHITECTURES if requested_architecture == "both" else (requested_architecture,)
    output_root.mkdir(parents=True)
    try:
        for architecture in architectures:
            release_root, archive_path = create_architecture_release(
                base_root, launcher_root, output_root, architecture, version
            )
            print(f"{architecture} release root: {release_root}")
            print(f"{architecture} archive: {archive_path}")
    except Exception:
        shutil.rmtree(output_root, ignore_errors=True)
        raise


def main() -> int:
    args = parse_args()
    try:
        create_release(args.base_root, args.launcher_root, args.output_root, args.version, args.architecture)
    except (OSError, ValueError, shutil.Error, zipfile.BadZipFile) as error:
        print(f"release.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
