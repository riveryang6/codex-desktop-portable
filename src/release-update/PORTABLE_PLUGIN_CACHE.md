# Portable plugin-cache recovery

The portable desktop does not accept a flat cache.  Each bundled plugin must
be stored below a catalog, plugin id, and version directory:

```text
CodexData/data/profile/.codex/plugins/cache/
  openai-bundled/<plugin>/<manifest.version>/...
  openai-primary-runtime/<plugin>/<manifest.version>/...
```

The directory name must be the exact `version` read from
`.codex-plugin/plugin.json`; `latest` aliases are not valid. Copying the contents of
`resources/plugins/openai-bundled/plugins` directly into
`plugins/cache/openai-bundled` creates a non-empty but invalid cache and is the
reason the launcher reports that the plugin cache is incomplete.

The x64 LF contract requires all twelve local plugins: `sites`, `browser`,
`chrome`, `computer-use`, `latex`, `deep-research`, and `visualize` from
`openai-bundled`; plus `documents`, `pdf`, `presentations`, `spreadsheets`, and
`template-creator` from `openai-primary-runtime`. ARM64 requires the same
eleven local plugins except `latex`, which the official ARM64 desktop payload
does not ship. The compact common ZIP intentionally contains no plugin cache.
After the common archive and the matching signed MSIX are installed, the
launcher recreates each required cache entry from its local trusted source. A
required cache entry is valid only when its complete file and directory tree
matches that source.
The sole runtime-generated exception is a direct `__pycache__` directory under
a trusted source directory containing only direct `.pyc` files. The launcher
also sets `PYTHONDONTWRITEBYTECODE=1` so new entries are not normally created.

To repair a stopped portable installation, first produce a plan:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Repair-PortablePluginCacheLayout.ps1 `
  -PortableRoot E:\
```

After checking the plan, run the same command with `-Execute`. The script
requires exactly one installed, marker-verified x64 or ARM64 payload; it
rejects a missing, malformed, or ambiguous payload architecture rather than
copying from the wrong source. It copies from the bundled/offline trusted
sources, stages with `robocopy`, verifies the manifest and version directory,
then atomically replaces only the affected plugin entries. Previous entries remain under
`CodexData/data/profile/.codex/plugins/repair-backups/<timestamp>`; user data,
secrets, sessions, and unknown cache entries are not deleted.

The release manifest generator rejects a common archive that contains any
prebuilt plugin cache. It verifies all five primary-runtime plugin sources in
the offline marketplace and the required bundled plugin sources in each signed
MSIX, including `browser`, `chrome`, and `computer-use`. This prevents a broken
portable package from being published or synchronized to the USB drive.

During USB synchronization the verified LFPortable-common.zip is replaced with
the launcher set, portable-release.json, and signed MSIX packages. The derived required plugin-cache
directories are invalidated so the next manual start recreates them from the
offline marketplace and signed desktop package. Other profile data, logs, updates, and unknown
cache entries are preserved. The sync command requires an explicit drive root
whose volume label is CODEX_USB; it does not write a persistent receipt or
checkpoint file.
