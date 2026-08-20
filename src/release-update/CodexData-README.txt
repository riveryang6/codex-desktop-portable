Codex Desktop Portable USB
==========================

Root layout
-----------
The visible USB root contains exactly:
  CodexPortable.exe
  CodexData\

Windows may create hidden system metadata such as System Volume Information.

Windows architecture support
-----------------------------
CodexPortable.exe is an x86 bootstrapper so it can start on x86, x64 and
Windows ARM systems. It selects one of these launcher cores automatically:
  CodexData\tools\launchers\CodexPortable.x86.exe
  CodexData\tools\launchers\CodexPortable.x64.exe
  CodexData\tools\launchers\CodexPortable.arm64.exe

The official Codex Desktop payloads currently published by OpenAI are x64 and
ARM64. The compact release stores them as the verified
CodexData\packages\LFPortable-x64.msix and
CodexData\packages\LFPortable-arm64.msix files. On the first manual start, the
launcher expands only the package matching the Windows architecture into its
derived runtime location. A 32-bit x86 or ARM Windows host can run the
bootstrapper and diagnostics, but startup stops with a clear message because no
official x86/ARM Desktop payload is published. The launcher never runs an
incompatible PE file as a workaround.

Quick start
-----------
1. Double-click CodexPortable.exe. Do not run CodexDesktop.exe or ChatGPT.exe
   directly. The launcher window is only the control surface; click
   "Start Codex" yourself after the payload and API state are ready.
2. Choose "Set custom API" and enter the Responses API base URL, model and key.
   This portable build does not provide OpenAI/ChatGPT account sign-in.
3. Click "Start Codex". The launcher hands off to the portable Codex process
   and exits. The launcher enforces one running instance per portable root:
   opening this same USB installation again while its portable Codex process is
   running exits silently. An independently installed official Codex Desktop
   may run at the same time and does not block this portable installation.
4. Use the portable Codex desktop window's top-right close button when
   finished, then safely eject the USB drive after its processes have exited.

Custom API and key storage
--------------------------
The key is stored in plaintext at
CodexData\data\secrets\api-key.txt so the package remains fully portable.
Anyone who obtains the USB drive can read and use that key; protect the drive
accordingly. The launcher passes the key only to the portable Codex process and
removes legacy authentication state. It never creates or retains auth.json.

The API Base URL must be a credential-free HTTPS URL. HTTP is accepted only for
localhost/127.0.0.1/::1 loopback endpoints. The model name is supplied to the
configured custom provider; the normal OpenAI endpoint and account login are
not used.

Permissions and elevation
-------------------------
On the first launch the portable launcher creates
CodexData\data\profile\.codex\config.toml with approval_policy = "never",
sandbox_mode = "danger-full-access" and model_reasoning_effort = "max". The
desktop starts in the config.toml permission mode; the root-level approval_policy
and sandbox_mode values in that file are authoritative. You may edit those
two values directly; valid edits are preserved on every later launch and when
the custom API settings are saved. The remaining launcher-managed entries are
regenerated to keep provider paths and offline plugins portable.
approval_policy accepts untrusted,
on-request or never; sandbox_mode accepts read-only, workspace-write or
danger-full-access. The launcher uses an asInvoker manifest and does not
request an administrator UAC prompt; it uses the current
Windows token and reports its actual elevation state. Running with
danger-full-access still permits Codex to modify files allowed by that Windows
token. Because this mode deliberately does not use the Windows Agent sandbox,
the portable UI does not run sandbox readiness/setup checks or block message
sending for missing machine-bound sandbox state.

Portable data
-------------
The launcher keeps Codex user configuration, custom-provider sessions, SQLite
state, the persistent Electron profile, logs, HOME and APPDATA in
CodexData\data. The Codex primary runtime is also preloaded there. Standard
first-run personalization/onboarding is disabled before the desktop starts,
including model-upgrade and feature announcements on a completely new profile.
The initial reasoning level is Max.

To avoid high-frequency random writes to the USB drive, disposable Chromium,
temporary, XDG, .NET bundle, npm, pip and uv caches use a per-session directory
under the host Windows TEMP folder. The launcher deletes that directory after
the portable process tree exits and removes abandoned session caches older than
two days on a later start. If the host cache cannot be created, Codex falls back
to the fully portable cache directories on the USB drive. API credentials,
configuration, task history and SQLite state are never placed in the host cache.

Custom-API mode also disables app-server remote control and analytics. Remote
control requires ChatGPT account authentication and otherwise causes continuous
authentication/WebSocket retries that add no capability to this build.

Bundled tools
-------------
  Node.js 24.14.0
  Python 3.12.13
  Git for Windows 2.53.0.windows.3
  pnpm 11.9.0
  .NET SDK 8.0.423 and shared runtime 8.0.29 (portable; required by the
  launcher/runtime toolchain)
  GitHub CLI 2.97.0
  Poppler and image conversion dependencies from the Codex runtime bundle

Updates
-------
LF releases are GitHub-only and contain LF-branded artifacts. Each stable
release has two offline assets: `LFPortable-x64.zip` and
`LFPortable-arm64.zip`. Download the asset matching the Windows host. Each
asset contains the common portable runtime and one official MSIX, with no
release descriptor, package manifest, checkpoint, or whole-tree digest record.
The launcher still validates the official package signature, OpenAI package
identity, architecture, and safe archive paths before installing it. Plugin
auto-update and in-product program update transactions are disabled; replace
the offline package and start it manually for a new release.

An architecture package contains the bootstrapper, three launcher cores, two
managed documentation files, the common runtime ZIP, and its matching MSIX.
The derived desktop payload, runtime, offline marketplace, required plugin
cache, and transaction staging are recreated from those packages on the next
manual start. USB sync removes only those derived paths and retired descriptor
files; other CodexData\data, logs, and unknown user entries are preserved.

Important limits
----------------
Portable application data does not mean a zero-trace host. Windows itself may
record execution in Defender/SmartScreen, Prefetch, event logs, DNS cache,
Recent items, graphics-driver caches, pagefile and similar OS-managed stores.
An abnormal host or launcher termination can also leave the disposable TEMP
cache until a later portable start cleans it. The custom API configuration and
plaintext key remain on the portable drive.

Opening a project on a host drive lets Codex read and modify that project, and
trusted projects may supply their own .codex/config.toml. Managed system policy
can also override user settings. These are intentional Codex/Windows behaviors,
not launcher data leakage.

Requirements
------------
Windows 10 version 2004 (build 19041) or later, x64 or ARM64. Keep several GB
free for first-run expansion and updates. Use compatibility rendering mode only
if the normal launch is blank or crashes; normal mode keeps Chromium GPU
acceleration and sandboxing enabled.
