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

The current LF contract requires all twelve local plugins: `sites`, `browser`,
`chrome`, `computer-use`, `latex`, `deep-research`, and `visualize` from
`openai-bundled`; plus `documents`, `pdf`, `presentations`, `spreadsheets`, and
`template-creator` from `openai-primary-runtime`. A cache entry is valid only
when its complete file and directory tree matches its local trusted source.
The sole runtime-generated exception is a direct `__pycache__` directory under
a trusted source directory containing only direct `.pyc` files. The launcher
also sets `PYTHONDONTWRITEBYTECODE=1` so new entries are not normally created.

To repair a stopped portable installation, first produce a plan:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Repair-PortablePluginCacheLayout.ps1 `
  -PortableRoot E:\
```

After checking the plan, run the same command with `-Execute`.  The script
copies from the bundled/offline trusted sources, stages with `robocopy`,
verifies the manifest and version directory, then atomically replaces only the
affected plugin entries.  Previous entries remain under
`CodexData/data/profile/.codex/plugins/repair-backups/<timestamp>`; user data,
secrets, sessions, and unknown cache entries are not deleted.

The release manifest generator now rejects a package unless both catalogs have
the expected plugin ids and version-directory layout.  This prevents a broken
portable package from being published or synchronized to the USB drive.

During USB synchronization the verified LFPortable-common.zip is replaced with
the launcher set, portable-release.json, and signed MSIX packages. The derived required plugin-cache
directories are invalidated so the next manual start recreates them from that
trusted archive. Other profile data, logs, updates, and unknown
cache entries are preserved. The sync command requires an explicit drive root
whose volume label is CODEX_USB; it does not write a persistent receipt or
checkpoint file.
