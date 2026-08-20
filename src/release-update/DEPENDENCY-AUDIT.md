# Portable Dependency Audit

This audit covers the common runtime archive used by LF Portable 1.4.24.0:
`release/CodexData/packages/LFPortable-common.zip`. The archive is deliberately
self-contained. The launcher selects the copies below from the portable tree
and does not depend on a host installation, registry entry, or host `PATH` for
the supported runtime. This keeps USB and clean Windows Sandbox behavior
reproducible.

The inventory and sizes below were measured on 2026-08-19. Sizes are ZIP
compressed bytes reported by `zipinfo -l`; they are not a checksum, release
descriptor, or startup validation record.

## Current Inventory

| Bundle | Version observed | Compressed size | Evidence and decision |
| --- | --- | ---: | --- |
| Portable .NET SDK and shared runtimes | SDK 8.0.423; runtimes 8.0.29 | 237.49 MiB | `tools/dotnet/dotnet.exe` is a launcher prerequisite and `DOTNET_ROOT` is pinned to this tree. Keep the SDK for the current Codex tool surface; a runtime-only package needs separate USB and Sandbox testing. |
| Portable Python | 3.12.13 | 149.57 MiB | The launcher requires `.../dependencies/python/python.exe`. Documents, PDF, presentations, and spreadsheet skills invoke it and use bundled packages such as `pandas`, `numpy`, `pypdf`, `python-docx`, and `reportlab`. Keep it portable. |
| Portable Node.js and modules | 24.14.0 | 121.95 MiB | The launcher requires `.../dependencies/node/bin/node.exe`. Presentation, template-creator, spreadsheet/artifact tooling, and browser/CUA helpers use the portable Node path and modules. Keep it portable. |
| Git for Windows runtime | 2.53.0.3 | 44.53 MiB | The launcher requires `.../dependencies/native/git/cmd/git.exe` and exports `CODEX_PREFERRED_GIT_EXECUTABLE`. Keep the bundled DLLs and companion runtime. |
| Poppler helpers | bundled `pdfinfo`/`pdftoppm` | 37.48 MiB | The PDF skill explicitly uses `pdftoppm` and `pdfinfo`; the runtime supplies portable command wrappers. Do not fall back to an unpinned system Poppler on a clean host. |
| `libheif` and `jxrlib` image helpers | bundled native tools | 3.35 MiB + 2.23 MiB | The runtime's override commands expose these helpers for image conversion. They are small and remain part of the offline feature set. |
| GitHub CLI | 2.97.0 | 13.52 MiB | The desktop can start without it and bundled plugin scripts do not invoke `gh`, but the launcher currently requires `tools/gh/gh.exe` (or `tools/gh/bin/gh.exe`) and exposes it as a supported tool. Make it an explicitly optional pack only after changing that contract and testing both acceptance paths. |
| Primary-runtime plugin source and cache trees | current marketplace files | 3.92 MiB each | `data/profile/.codex/offline-marketplaces/openai-primary-runtime` is the offline source; the matching runtime plugin tree is also shipped. These are the five required primary plugins (`documents`, `pdf`, `presentations`, `spreadsheets`, `template-creator`), not a per-user derived cache. |

The archive has 26,489 entries, is 656,611,053 bytes (626.19 MiB) on disk,
and expands to about 1.71 GiB. The largest reducible groups are the SDK/packs,
Python feature packages, and Node modules. They are feature dependencies, not
unused copies that can be replaced with host installs without changing the
portable contract.

## What Can Change

* **Do not remove portable runtimes for this release.** `CommonPayloadComplete`
  and the execution-image checks require .NET, Node, Python, Git, `gh`, and the
  offline marketplace. The supported package must continue to run on a clean
  machine with no preinstalled developer tools.
* **Do not trim or repackage the signed MSIX.** Its Authenticode signature,
  `AppxManifest.xml`, publisher identity, architecture, and payload are checked
  together when the desktop package is prepared.
* **A future split-package experiment is reasonable.** A small core package
  could be paired with optional Office/PDF/Python, presentation/artifact-tool,
  and browser/CUA packs. Each pack must be independently usable offline and
  must be exercised from both `CODEX_USB` and Windows Sandbox before becoming a
  release format. Host-installed copies are not an acceptable substitute.
* **`gh` is the first optional candidate, not a major size win.** It saves only
  about 13.5 MiB and is still a current launcher prerequisite, so it stays in
  this release.

## Distribution Decision

The old combined archive contained both desktop MSIX files and approached the
2 GiB class limit. The release builder now emits architecture-specific offline
packages: `LFPortable-x64.zip` and `LFPortable-arm64.zip`. Each package carries
the common ZIP and only its matching official MSIX, while retaining all
portable feature libraries for clean-machine and Sandbox use.

The current bundled MSIX manifests are `OpenAI.Codex` version `26.814.5167.0`
for both x64 and ARM64 (the same version is advertised by the official
endpoint headers).

No library is downloaded, installed, or updated during first launch. The
supported USB/Sandbox release is therefore fully offline; a CDN is an optional
future distribution optimization, never a startup dependency or hidden
installation step.

## Mainland CDN Probe

The probe ran on 2026-08-19 from a mainland network using one 4 MiB HTTP Range
request per URL. Results are a point-in-time sample, not an SLA:

| Endpoint | HTTP result | TTFB | Total | Effective rate |
| --- | ---: | ---: | ---: | ---: |
| OpenAI MSIX x64 (`persistent.oaistatic.com`, Cloudflare SIN) | 206 | 1.672 s | 3.449 s | 1.16 MiB/s |
| OpenAI MSIX ARM64 (`persistent.oaistatic.com`, Cloudflare SIN) | 206 | 1.412 s | 2.690 s | 1.49 MiB/s |
| Node ZIP, `nodejs.org` | 206 | 0.517 s | 10.236 s | 0.39 MiB/s |
| Node ZIP, npm mirror | 206 | 0.212 s | 0.504 s | 7.93 MiB/s |
| Node ZIP, Tencent mirror | 206 | 0.095 s | 2.654 s | 1.51 MiB/s |
| Node ZIP, Alibaba mirror | 206 | 0.064 s | 0.330 s | 12.11 MiB/s |
| Node ZIP, Huawei mirror | 206 | 0.065 s | 0.247 s | 16.19 MiB/s |
| Node ZIP, USTC mirror | 403 | 1.096 s | 1.098 s | not usable |

Mainland mirrors can be fast for public upstream Node archives, but they cannot
host LF's private common ZIP or OpenAI's MSIX. Public GitHub proxy services are
not used: they have no distribution authorization, ownership, or predictable
service level. The official MSIX endpoint also does not meet the evidence bar
for promising a fast, stable mainland download.

An online edition would require LF-controlled mainland object storage/CDN,
authorized redistribution of every asset, Range support, and a tested fallback
to the offline package. Until those assets and tests exist, keep CDN code out of
startup and publish the offline architecture packages only.
