# codex-desktop-portable

Portable Windows launcher and release tooling for Codex Desktop.

## Contents

- `src/portable-launcher/` — x86 bootstrapper, x86/x64/ARM64 launcher sources, icons, and build scripts.
- `src/release-update/` — release staging, manifest generation, and plugin-cache repair scripts.
- `dist/` — current launcher matrix: x86, x64, ARM64, plus the x86 bootstrapper.

## Build

Run from PowerShell on Windows with the .NET Framework 4.x reference assemblies and a .NET SDK installed:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\portable-launcher\build-launcher-matrix.ps1 -OutputRoot .\build\launcher-matrix
```

The build emits an x86 bootstrapper and launcher cores for x86, x64, and ARM64 Windows. A complete desktop payload is required for a full runtime self-test; the source-only package intentionally does not contain application payloads, user data, logs, credentials, or test captures.

## Release staging

Pass explicit `-SourceRoot`, `-DestinationRoot`, and `-ReleaseParentRoot` values to `src/release-update/New-PortableRelease.ps1`. The checked-in defaults are local, relative placeholders and do not refer to a personal drive or machine.

## Sanitization

This distribution excludes debug screenshots, remote-control traces, USB backups, API keys, session data, generated logs, test payload trees, and machine-specific paths. Do not add credentials or user data to the project archive.
