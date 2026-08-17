# LF Portable · Codex Desktop

Portable Windows launcher and release tooling for Codex Desktop, branded for LF.

## Contents

- `src/portable-launcher/` — x86 bootstrapper, x86/x64/ARM64 launcher sources, LF icons, and build scripts.
- `src/release-update/` — release staging, manifest generation, and plugin-cache repair scripts.
- `dist/` — launcher matrix only: x86, x64, ARM64, plus the x86 bootstrapper. It
  is not a runnable Release and intentionally contains no desktop payload,
  runtime, tools, user profile, or plugin cache.

## Build

Run from PowerShell on Windows with the .NET Framework 4.x reference assemblies and a .NET SDK installed:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\portable-launcher\build-launcher-matrix.ps1 -OutputRoot .\build\launcher-matrix
```

The build emits an x86 bootstrapper and launcher cores for x86, x64, and ARM64 Windows. Before each compiler invocation it fetches fresh metadata for the fixed official OpenAI x64 and ARM64 MSIX endpoints, verifies the signed packages in a repository-external cache, compiles a non-publishable x64 probe, and requires that probe to pass both package self-tests. No launcher output is promoted unless the two self-tests and a final official-version recheck pass. The source repository intentionally does not contain application payloads, user data, logs, credentials, or test captures.

## Release staging

Pass explicit `-SourceRoot`, `-DestinationRoot`, and `-ReleaseParentRoot` values to `src/release-update/New-PortableRelease.ps1`. The checked-in defaults are local, relative placeholders and do not refer to a personal drive or machine.

Release staging requires 7-Zip 24.09 or later. It creates the common runtime as a standard ZIP using maximum compatible Deflate without redundant directory entries, stores the already-compressed common ZIP and signed MSIX files in the outer release ZIP, and verifies both archives before publication. This avoids the size increase caused by zero-level Deflate around compressed payloads while preserving first-run extraction through Windows tooling.

`-SourceRoot` must be a clean, complete release source tree—not `dist/` and not a user USB copy. It supplies the bundled Node/Python/Git runtime, .NET SDK, GitHub CLI, and primary-runtime offline marketplace sources; it does not need a prebuilt plugin cache. The common ZIP omits that derived cache and the unused F# SDK subtree while retaining the C# and Visual Basic compilers. The transaction always builds a fresh launcher matrix from current source and obtains the signed x64/ARM64 desktop payloads only through the live official compatibility gate; a pre-existing `CodexData\app\current` tree is rejected. Passing `dist/` therefore fails immediately with a list of missing files instead of producing a false “release”.

The release build and USB deployment are separate gates. First publish a
compact Release from the verified staging source, then complete the zero-state
first-run validation in Windows Sandbox. Only a passing validation may be
synchronized to a `CODEX_USB` installation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\release-update\New-PortableRelease.ps1 `
  -SourceRoot <complete-release-source-root> -DestinationRoot <release-parent>\release `
  -ReleaseParentRoot <release-parent>
```

Create a new evidence directory and run the tracked Sandbox launcher against
that exact `release`; it maps only the canonical release and tools as read-only,
keeps networking disabled, and writes the result outside both Release and USB:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\release-update\Invoke-CompactFirstRunSandbox.ps1 `
  -SourceRoot <release-parent>\release -ManifestPath <release-parent>\portable-package-manifest.json `
  -EvidenceRoot <separate-fixed-disk>\lf-sandbox-evidence -Launch
```

After `sandbox-first-run-result.json` passes, invoke
`Sync-CodexPortableUsb.ps1` with that exact `release` root, manifest, and
evidence path. The synchronizer refuses another volume label, waits for
portable processes to exit, replaces only managed release content, invalidates
derived payload and runtime caches, and preserves user data, logs, updates, and
unknown entries.

The complete Release size is determined by the signed desktop payload and
bundled runtimes/tools; it is not the 1.21 MiB launcher-only `dist/` size. User
profiles, logs, credentials, transient caches, and USB data are excluded from
the canonical release staging tree.

LF release policy: the launcher's `Check for updates` action is the only program
update entry. Each stable GitHub Release publishes exactly one program asset:
`LFPortable-release.zip`, plus its GitHub SHA-256 digest. The archive contains
only the embedded `portable-package-manifest.json` and the ten canonical compact
release files; it never contains an expanded desktop payload, profile, key,
logs, or USB backup. The archive's `ReleaseVersion`, launcher set, and stable tag
must be the same four-part LF version (for example `v1.4.3.0`). Official MSIX
identity versions remain independently verified package metadata and do not set
the LF release version. The updater verifies the GitHub digest, embedded manifest,
and every archive entry before replacing the release. Runtime update checks and
plugin auto-update are disabled; publish updates only through the verified LF
staging flow.

After the source, four launcher binaries, canonical release, Sandbox evidence,
and USB copy all pass, commit and push the matching source and annotated
four-part tag. Publish the verified archive with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\release-update\Publish-GitHubRelease.ps1 `
  -ReleaseParentRoot <release-parent> -UsbRoot <CODEX_USB-drive-root> `
  -SandboxValidationResultPath <separate-fixed-disk>\lf-sandbox-evidence\sandbox-first-run-result.json
```

The publisher refuses to run until the four launchers in `dist`, the canonical
release, the outer ZIP, the named `CODEX_USB` device, and the Sandbox result all
match the same manifest. It rebuilds the current source matrix and compares all
four launcher binaries byte-for-byte, rechecks current official packages with
the packaged launcher, verifies both ZIP layers and their compression methods,
then confirms the remote `main` branch and annotated tag resolve to the local
commit. The uploaded draft first completes an authenticated round-trip; after
publication, a public round-trip must pass or the release is restored to draft.

The desktop permission selector starts in `config.toml` mode. Its initial
values are `approval_policy = "never"` and
`sandbox_mode = "danger-full-access"`; later valid edits to those root-level
keys are preserved by the launcher. New portable API configuration defaults its
model field to `gpt-5.6-terra`; an explicitly saved custom model remains unchanged.

## Sanitization

This distribution excludes debug screenshots, remote-control traces, USB backups, API keys, session data, generated logs, test payload trees, and machine-specific paths. Do not add credentials or user data to the project archive.
