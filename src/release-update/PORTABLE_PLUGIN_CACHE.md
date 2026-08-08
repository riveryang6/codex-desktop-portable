# Portable plugin-cache recovery

The portable desktop does not accept a flat cache.  Each bundled plugin must
be stored below a catalog, plugin id, and version directory:

```text
CodexData/data/profile/.codex/plugins/cache/
  openai-bundled/<plugin>/<version>/...
  openai-primary-runtime/<plugin>/<version>/...
```

The version is read from `.codex-plugin/plugin.json`.  Copying the contents of
`resources/plugins/openai-bundled/plugins` directly into
`plugins/cache/openai-bundled` creates a non-empty but invalid cache and is the
reason the launcher reports that the plugin cache is incomplete.

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
