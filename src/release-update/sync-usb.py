#!/usr/bin/env python3
"""Copy a portable release onto the explicitly labelled CODEX_USB volume."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from typing import Iterator


USB_LABEL = "CODEX_USB"
REPARSE_POINT_ATTRIBUTE = 0x400
WINDOWS_DRIVE_PATH = re.compile(r"^([A-Za-z]):(?:[\\/]|$)")
WSL_MOUNT_PATH = re.compile(r"^/mnt/([A-Za-z])(?:/|$)", re.IGNORECASE)
RELEASE_COMMON_FILES = (
    "CodexPortable.exe",
    "CodexData/README.txt",
    "CodexData/THIRD_PARTY.txt",
    "CodexData/tools/launchers/CodexPortable.x86.exe",
    "CodexData/tools/launchers/CodexPortable.x64.exe",
    "CodexData/tools/launchers/CodexPortable.arm64.exe",
    "CodexData/packages/LFPortable-common.zip",
)

# These are generated from the package files on the next Windows start.  Keep
# the list explicit so USB synchronization cannot remove user configuration,
# SQLite state, secrets, sessions, logs, or unknown files.
DERIVED_RELEASE_PATHS = (
    "CodexData/app",
    # Transaction staging is disposable; the launcher recreates this empty
    # directory before a runtime or desktop extraction when it is needed.
    "CodexData/updates",
    "CodexData/tools/desktop-payloads",
    "CodexData/tools/dotnet",
    "CodexData/tools/gh",
    "CodexData/data/profile/.cache/codex-runtimes/codex-primary-runtime",
    "CodexData/data/profile/.codex/offline-marketplaces/openai-primary-runtime",
    "CodexData/data/profile/.codex/plugins/cache/openai-bundled/sites",
    "CodexData/data/profile/.codex/plugins/cache/openai-bundled/browser",
    "CodexData/data/profile/.codex/plugins/cache/openai-bundled/chrome",
    "CodexData/data/profile/.codex/plugins/cache/openai-bundled/computer-use",
    "CodexData/data/profile/.codex/plugins/cache/openai-bundled/codex-app-tools",
    "CodexData/data/profile/.codex/plugins/cache/openai-bundled/latex",
    "CodexData/data/profile/.codex/plugins/cache/openai-bundled/deep-research",
    "CodexData/data/profile/.codex/plugins/cache/openai-bundled/visualize",
    "CodexData/data/profile/.codex/plugins/cache/openai-primary-runtime/documents",
    "CodexData/data/profile/.codex/plugins/cache/openai-primary-runtime/pdf",
    "CodexData/data/profile/.codex/plugins/cache/openai-primary-runtime/presentations",
    "CodexData/data/profile/.codex/plugins/cache/openai-primary-runtime/spreadsheets",
    "CodexData/data/profile/.codex/plugins/cache/openai-primary-runtime/template-creator",
    "CodexData/portable-release.json",
    "CodexData/portable-package-manifest.json",
    "portable-package-manifest.json",
)


class SyncError(RuntimeError):
    """A deployment precondition or copy operation failed."""


def reject_reparse_path(path: Path, label: str) -> None:
    """Reject symlinks and Windows reparse points in a managed path."""

    current = path.expanduser()
    while True:
        try:
            info = current.lstat()
        except FileNotFoundError:
            pass
        except OSError as error:
            raise SyncError(f"cannot inspect {label}: {current}: {error}") from error
        else:
            attributes = int(getattr(info, "st_file_attributes", 0))
            if stat.S_ISLNK(info.st_mode) or attributes & REPARSE_POINT_ATTRIBUTE:
                raise SyncError(f"{label} contains a symlink or reparse point: {current}")
        parent = current.parent
        if parent == current:
            return
        current = parent


def require_regular_file(path: Path, label: str) -> Path:
    """Require a regular, non-reparse file without following a link."""

    reject_reparse_path(path, label)
    try:
        info = path.lstat()
    except OSError as error:
        raise SyncError(f"required {label} is unavailable: {path}: {error}") from error
    attributes = int(getattr(info, "st_file_attributes", 0))
    if not stat.S_ISREG(info.st_mode) or attributes & REPARSE_POINT_ATTRIBUTE:
        raise SyncError(f"required {label} is missing or is not a regular file: {path}")
    return path


def non_negative_seconds(value: str) -> int:
    try:
        seconds = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a whole number of seconds") from error
    if seconds < 0:
        raise argparse.ArgumentTypeError("must be zero or greater")
    return seconds


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Synchronize a portable release to a CODEX_USB volume."
    )
    parser.add_argument("--source-root", required=True, help="release directory to copy")
    parser.add_argument("--usb-root", required=True, help="destination below CODEX_USB")
    parser.add_argument(
        "--wait-for-portable-exit-seconds",
        default=0,
        type=non_negative_seconds,
        help="seconds to wait for executables launched from the target (default: 0)",
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="perform the copy; omit this flag to print the planned operation",
    )
    return parser.parse_args()


def emit(value: dict[str, object]) -> None:
    print(json.dumps(value, ensure_ascii=True, separators=(",", ":")))


def local_path(raw_path: str) -> Path:
    """Map a Windows drive path to its normal WSL mount when needed."""

    if os.name != "nt":
        match = WINDOWS_DRIVE_PATH.match(raw_path)
        if match:
            remainder = raw_path[2:].lstrip("\\/").replace("\\", "/")
            return Path("/mnt") / match.group(1).lower() / remainder
    return Path(raw_path).expanduser()


def path_key(path: Path) -> str:
    """Return a comparison key that respects Windows-volume case behavior."""

    text = str(path)
    if os.name == "nt":
        return text.replace("/", "\\").rstrip("\\").casefold() or "\\"
    if WSL_MOUNT_PATH.match(text):
        return text.rstrip("/").casefold() or "/"
    return text.rstrip("/") or "/"


def is_same_or_child(path: Path, root: Path) -> bool:
    candidate = path_key(path)
    parent = path_key(root)
    if candidate == parent:
        return True
    separator = "\\" if os.name == "nt" else "/"
    return candidate.startswith(parent + separator)


def paths_overlap(first: Path, second: Path) -> bool:
    return is_same_or_child(first, second) or is_same_or_child(second, first)


def windows_path(raw_path: str, resolved_path: Path) -> str | None:
    """Return a drive-based Windows spelling, or None when it is unavailable."""

    direct_match = WINDOWS_DRIVE_PATH.match(raw_path)
    if direct_match:
        remainder = raw_path[2:].replace("/", "\\")
        if not remainder:
            remainder = "\\"
        if not remainder.startswith("\\"):
            return None
        return direct_match.group(1).upper() + ":" + remainder

    resolved_text = str(resolved_path)
    if os.name == "nt":
        native_match = WINDOWS_DRIVE_PATH.match(resolved_text)
        if native_match:
            return resolved_text.replace("/", "\\")
        return None

    mount_match = WSL_MOUNT_PATH.match(resolved_text)
    if not mount_match:
        return None
    remainder = resolved_text[len(mount_match.group(0)) :].replace("/", "\\")
    return mount_match.group(1).upper() + ":\\" + remainder


def decode_windows_unicode(output: bytes) -> str:
    if output.startswith(b"\xff\xfe"):
        output = output[2:]
    return output.decode("utf-16le", errors="replace")


def cmd_unicode(command: str, purpose: str) -> str:
    executable = shutil.which("cmd.exe")
    if executable is None:
        raise SyncError(f"cannot {purpose}: cmd.exe is unavailable")

    try:
        completed = subprocess.run(
            [executable, "/u", "/d", "/c", command],
            capture_output=True,
            check=False,
        )
    except OSError as error:
        raise SyncError(f"cannot {purpose}: {error}") from error

    if completed.returncode != 0:
        detail = decode_windows_unicode(completed.stderr or completed.stdout).strip()
        if detail:
            detail = detail.splitlines()[-1][:500]
            raise SyncError(f"cannot {purpose}: {detail}")
        raise SyncError(f"cannot {purpose}: cmd.exe exited with {completed.returncode}")
    return decode_windows_unicode(completed.stdout)


def ensure_codex_usb_volume(target_windows_path: str | None) -> None:
    if target_windows_path is None:
        raise SyncError(
            "cannot determine the USB volume for --usb-root; use /mnt/<drive>/... "
            "under WSL or an absolute Windows drive path"
        )

    match = WINDOWS_DRIVE_PATH.match(target_windows_path)
    if match is None:
        raise SyncError("cannot determine a Windows drive letter for --usb-root")
    drive_letter = match.group(1).upper()
    volume_output = cmd_unicode(f"vol {drive_letter}:", "inspect the USB volume label")
    exact_label = re.compile(
        rf"(?<![A-Za-z0-9_]){re.escape(USB_LABEL)}(?![A-Za-z0-9_])",
        re.IGNORECASE,
    )
    if exact_label.search(volume_output) is None:
        raise SyncError(
            f"cannot confirm that --usb-root is on a volume labelled {USB_LABEL}"
        )


PROCESS_HELPER_SOURCE = r"""var locator = new ActiveXObject("WbemScripting.SWbemLocator");
try {
  var service = locator.ConnectServer(".", "root\\cimv2");
  var processes = service.ExecQuery("SELECT ProcessId,Name,ExecutablePath FROM Win32_Process");
  var enumerator = new Enumerator(processes);
  for (; !enumerator.atEnd(); enumerator.moveNext()) {
    var process = enumerator.item();
    var executable = process.ExecutablePath;
    if (executable === null || executable === undefined) executable = "";
    WScript.StdOut.WriteLine(process.ProcessId + "\t" + process.Name + "\t" + executable);
  }
} catch (error) {
  WScript.StdErr.WriteLine(error.message);
  WScript.Quit(1);
}
"""


def windows_temp_directory() -> Path:
    output = cmd_unicode("echo %TEMP%", "locate a Windows temporary directory").strip()
    if not output or WINDOWS_DRIVE_PATH.match(output) is None:
        raise SyncError("cannot locate a Windows temporary directory")
    directory = local_path(output)
    if not directory.is_dir():
        raise SyncError("the Windows temporary directory is unavailable from this environment")
    return directory


@contextmanager
def native_process_helper() -> Iterator[str]:
    executable = shutil.which("cscript.exe")
    if executable is None:
        raise SyncError("cannot inspect running portable processes: cscript.exe is unavailable")

    descriptor, raw_path = tempfile.mkstemp(
        prefix="lf-portable-process-",
        suffix=".js",
        dir=windows_temp_directory(),
        text=True,
    )
    helper_path = Path(raw_path)
    try:
        with os.fdopen(descriptor, "w", encoding="ascii", newline="\n") as helper:
            helper.write(PROCESS_HELPER_SOURCE)
        helper_windows_path = windows_path(str(helper_path), helper_path.resolve())
        if helper_windows_path is None:
            raise SyncError("cannot expose the native process helper to Windows")
        yield helper_windows_path
    finally:
        try:
            helper_path.unlink(missing_ok=True)
        except OSError as error:
            raise SyncError(f"cannot remove the native process helper: {error}") from error


def windows_comparison_key(path: str) -> str:
    return path.replace("/", "\\").rstrip("\\").casefold()


def running_processes(
    target_windows_path: str,
    helper_windows_path: str,
) -> list[dict[str, str]]:
    executable = shutil.which("cscript.exe")
    assert executable is not None
    try:
        completed = subprocess.run(
            [executable, "//nologo", "//u", helper_windows_path],
            capture_output=True,
            check=False,
        )
    except OSError as error:
        raise SyncError(f"cannot inspect running portable processes: {error}") from error
    if completed.returncode != 0:
        detail = decode_windows_unicode(completed.stderr or completed.stdout).strip()
        if detail:
            detail = detail.splitlines()[-1][:500]
            raise SyncError(f"cannot inspect running portable processes: {detail}")
        raise SyncError(
            f"cannot inspect running portable processes: cscript.exe exited with {completed.returncode}"
        )

    root = windows_comparison_key(target_windows_path)
    prefix = root + "\\"
    matches = []
    for line in decode_windows_unicode(completed.stdout).splitlines():
        values = line.split("\t", 2)
        if len(values) != 3:
            raise SyncError("cannot inspect running portable processes: invalid helper output")
        process_id, name, executable_path = values
        full_path = windows_comparison_key(executable_path)
        # CodexDesktop.exe is copied into a fixed-disk execution image before
        # handoff. Its path is therefore intentionally outside the USB root;
        # the unique LF process name still identifies the portable desktop.
        # The official WindowsApps package uses ChatGPT.exe, so this does not
        # block the independently installed desktop.
        normalized_name = name.strip().casefold()
        portable_desktop = normalized_name in {"codexdesktop", "codexdesktop.exe"}
        if full_path == root or full_path.startswith(prefix) or portable_desktop:
            matches.append(
                {
                    "ProcessId": process_id,
                    "Name": name,
                    "ExecutablePath": executable_path,
                }
            )
    return matches


def describe_processes(processes: list[dict[str, str]]) -> str:
    details = []
    for process in processes:
        name = str(process.get("Name", "unknown"))
        process_id = str(process.get("ProcessId", "?"))
        executable = str(process.get("ExecutablePath", "unknown"))
        details.append(f"{name} (PID {process_id}): {executable}")
    return "; ".join(details)


def wait_for_processes_to_exit(target_windows_path: str, timeout_seconds: int) -> None:
    deadline = time.monotonic() + timeout_seconds
    with native_process_helper() as helper_windows_path:
        while True:
            processes = running_processes(target_windows_path, helper_windows_path)
            if not processes:
                return
            if timeout_seconds == 0 or time.monotonic() >= deadline:
                raise SyncError(
                    "portable executables are still running below --usb-root: "
                    + describe_processes(processes)
                )
            time.sleep(1)


def windows_join(root: str, relative_path: str) -> str:
    return root.rstrip("\\/") + "\\" + relative_path.replace("/", "\\")


def run_robocopy(
    source_windows_root: str,
    target_windows_root: str,
    relative_path: str,
) -> int:
    executable = shutil.which("robocopy.exe")
    if executable is None:
        raise SyncError("robocopy.exe is unavailable")
    parent, _, filename = relative_path.rpartition("/")
    source_directory = windows_join(source_windows_root, parent) if parent else source_windows_root
    target_directory = windows_join(target_windows_root, parent) if parent else target_windows_root
    try:
        completed = subprocess.run(
            [
                executable,
                source_directory,
                target_directory,
                filename,
                "/COPY:DAT",
                "/DCOPY:DAT",
                "/XJ",
                "/IS",
                "/R:0",
                "/W:0",
            ],
            capture_output=True,
            check=False,
            encoding="utf-8",
            errors="replace",
        )
    except OSError as error:
        raise SyncError(f"cannot run robocopy.exe: {error}") from error
    if completed.returncode > 7:
        detail = (completed.stderr or completed.stdout).strip()
        if detail:
            detail = detail.splitlines()[-1][:500]
            raise SyncError(f"robocopy failed with exit code {completed.returncode}: {detail}")
        raise SyncError(f"robocopy failed with exit code {completed.returncode}")
    return completed.returncode


def release_sources(source: Path) -> list[tuple[str, Path]]:
    reject_reparse_path(source, "source root")
    package_directory = source / "CodexData" / "packages"
    reject_reparse_path(package_directory, "source package directory")
    desktop_packages = sorted(package_directory.glob("LFPortable-*.msix"))
    if len(desktop_packages) != 1:
        raise SyncError(
            "the release must contain exactly one architecture-specific desktop package "
            "under CodexData/packages"
        )
    desktop_package = desktop_packages[0]
    if desktop_package.name not in {"LFPortable-x64.msix", "LFPortable-arm64.msix"}:
        raise SyncError(f"unsupported desktop package name: {desktop_package.name}")
    files = []
    relative_files = RELEASE_COMMON_FILES + (
        str(desktop_package.relative_to(source)).replace("\\", "/"),
    )
    for relative_path in relative_files:
        candidate = source / relative_path
        require_regular_file(candidate, f"release input {relative_path}")
        files.append((relative_path, candidate))
    return files


def validate_target_paths(target: Path, copied_files: list[tuple[str, Path]]) -> None:
    """Check every managed destination before any copy can modify the USB."""

    reject_reparse_path(target, "USB root")
    for relative_path, _ in copied_files:
        candidate = target / relative_path
        reject_reparse_path(candidate, f"USB destination {relative_path}")


def prune_obsolete_release_files(target: Path, copied_files: list[tuple[str, Path]]) -> list[str]:
    """Remove superseded packages and generated state, never user data."""

    reject_reparse_path(target, "USB root")
    copied_names = {relative_path for relative_path, _ in copied_files}
    package_directory = target / "CodexData" / "packages"
    reject_reparse_path(package_directory, "USB package directory")
    candidates: list[Path] = []
    if package_directory.is_dir():
        candidates.extend(package_directory.glob("LFPortable-*.msix"))
    removed = []
    for candidate in candidates:
        relative_path = str(candidate.relative_to(target)).replace("\\", "/")
        if relative_path in copied_names:
            continue
        require_regular_file(candidate, f"obsolete USB package {relative_path}")
        if candidate.name in {"LFPortable-x64.msix", "LFPortable-arm64.msix"}:
            candidate.unlink()
            removed.append(relative_path)
    for relative_path in DERIVED_RELEASE_PATHS:
        candidate = target / relative_path
        if not os.path.lexists(candidate):
            continue
        reject_reparse_path(candidate, f"obsolete USB path {relative_path}")
        if candidate.is_dir():
            shutil.rmtree(candidate)
        elif candidate.is_file():
            candidate.unlink()
        else:
            raise SyncError(f"refusing to remove an unsupported target: {relative_path}")
        removed.append(relative_path)
    return removed


def copy_without_deleting(files: list[tuple[str, Path]], target: Path) -> None:
    for relative_path, source_file in files:
        destination = target / relative_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_file, destination)


def execute(args: argparse.Namespace) -> None:
    source = Path(os.path.abspath(local_path(args.source_root)))
    target = Path(os.path.abspath(local_path(args.usb_root)))
    reject_reparse_path(source, "source root")
    reject_reparse_path(target, "USB root")
    if not source.is_dir():
        raise SyncError(f"--source-root is missing or is not a directory: {args.source_root}")
    if target.exists() and not target.is_dir():
        raise SyncError(f"--usb-root is a file or non-directory: {args.usb_root}")

    # Normalize spelling without resolving links.  The reparse walk above and
    # the managed-file checks below must inspect the actual path components,
    # not a destination reached by following a link.
    if paths_overlap(source, target):
        raise SyncError("--source-root and --usb-root must be distinct, non-overlapping directories")
    files = release_sources(source)

    source_windows_path = windows_path(args.source_root, source)
    target_windows_path = windows_path(args.usb_root, target)
    ensure_codex_usb_volume(target_windows_path)
    assert target_windows_path is not None
    wait_for_processes_to_exit(target_windows_path, args.wait_for_portable_exit_seconds)
    validate_target_paths(target, files)

    if source_windows_path is not None and shutil.which("robocopy.exe") is not None:
        exit_codes = []
        for relative_path, _ in files:
            wait_for_processes_to_exit(target_windows_path, args.wait_for_portable_exit_seconds)
            exit_codes.append(run_robocopy(source_windows_path, target_windows_path, relative_path))
        # Recheck immediately before deleting derived state. A desktop that
        # started during the copy must never be left running while its USB
        # payload is pruned.
        wait_for_processes_to_exit(target_windows_path, args.wait_for_portable_exit_seconds)
        removed = prune_obsolete_release_files(target, files)
        emit(
            {
                "action": "synced",
                "copy": "robocopy",
                "execute": True,
                "file_count": len(files),
                "robocopy_exit_codes": exit_codes,
                "removed_derived_paths": removed,
                "source_root": str(source),
                "usb_root": str(target),
            }
        )
        return

    wait_for_processes_to_exit(target_windows_path, args.wait_for_portable_exit_seconds)
    copy_without_deleting(files, target)
    wait_for_processes_to_exit(target_windows_path, args.wait_for_portable_exit_seconds)
    removed = prune_obsolete_release_files(target, files)
    emit(
        {
            "action": "synced",
            "copy": "shutil.copy2",
            "execute": True,
            "file_count": len(files),
            "removed_derived_paths": removed,
            "source_root": str(source),
            "usb_root": str(target),
        }
    )


def main() -> int:
    args = parse_args()
    if not args.execute:
        emit(
            {
                "action": "plan",
                "copy": "architecture-specific release files via robocopy when Windows paths are available; shutil.copy2 otherwise",
                "execute": False,
                "file_count": len(RELEASE_COMMON_FILES) + 1,
                "source_root": args.source_root,
                "target_data": "existing target entries are preserved",
                "usb_root": args.usb_root,
                "wait_for_portable_exit_seconds": args.wait_for_portable_exit_seconds,
            }
        )
        return 0
    try:
        execute(args)
    except (OSError, shutil.Error, SyncError) as error:
        print(f"sync-usb.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
