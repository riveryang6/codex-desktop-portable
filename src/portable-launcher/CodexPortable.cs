// Codex Portable Launcher
// Build target: Windows x64, .NET Framework 4.8, C# 5 compatible.

using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using Microsoft.Win32.SafeHandles;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using System.Xml;

[assembly: AssemblyTitle("LF Portable")]
[assembly: AssemblyDescription("LF portable launcher and updater for Codex Desktop")]
[assembly: AssemblyCompany("LF")]
[assembly: AssemblyProduct("LF Portable")]
[assembly: AssemblyCopyright("Copyright (c) 2026")]
[assembly: AssemblyVersion("1.4.20.0")]
[assembly: AssemblyFileVersion("1.4.20.0")]
[assembly: ComVisible(false)]

namespace CodexPortable
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            // A loader failure from a briefly disconnected removable drive must
            // return an exit code to the launcher instead of blocking behind a
            // system-owned Application Error dialog.
            NativeMethods.SetErrorMode(NativeMethods.SemFailCriticalErrors |
                NativeMethods.SemNoGpFaultErrorBox);
            // This branch is intentionally before portable-root discovery. The
            // recovery helper runs from fixed local scratch after the launcher
            // has exited and must not touch a disconnected removable volume.
            if (args.Length > 0 && DesktopImageFailureWatch.IsWatchArgument(args[0]))
                return DesktopImageFailureWatch.Run(args);
            // JobRun.SelfTestRecoveryContract starts a short-lived child tree
            // without touching the portable layout. Keep this private branch
            // before layout discovery so the child can be launched even while
            // the parent is validating a transaction staging directory.
            if (args.Length == 1 && JobRun.IsSelfTestProcessArgument(args[0]))
                return JobRun.RunSelfTestProcess(args[0]);
            string rootOverride = null;
            int bootstrapperProcessId = 0;
            List<string> forwardedArgs = new List<string>();
            for (int i = 0; i < args.Length; i++)
            {
                if (string.Equals(args[i], "--portable-root", StringComparison.OrdinalIgnoreCase))
                {
                    if (i + 1 >= args.Length) return 41;
                    rootOverride = args[++i];
                }
                else if (args[i].StartsWith("--portable-root=", StringComparison.OrdinalIgnoreCase))
                {
                    rootOverride = args[i].Substring("--portable-root=".Length);
                }
                else if (string.Equals(args[i], "--bootstrapper-pid", StringComparison.OrdinalIgnoreCase))
                {
                    if (i + 1 >= args.Length || !int.TryParse(args[++i], NumberStyles.None,
                        CultureInfo.InvariantCulture, out bootstrapperProcessId) || bootstrapperProcessId <= 0) return 41;
                }
                else if (args[i].StartsWith("--bootstrapper-pid=", StringComparison.OrdinalIgnoreCase))
                {
                    if (!int.TryParse(args[i].Substring("--bootstrapper-pid=".Length), NumberStyles.None,
                        CultureInfo.InvariantCulture, out bootstrapperProcessId) || bootstrapperProcessId <= 0) return 41;
                }
                else forwardedArgs.Add(args[i]);
            }
            args = forwardedArgs.ToArray();
            PortableLayout layout = PortableLayout.FromExecutable(rootOverride);
            LauncherLocale.Load(layout);
            if (bootstrapperProcessId == Process.GetCurrentProcess().Id) return 41;

            if (args.Length == 1 && string.Equals(args[0], "--self-test", StringComparison.OrdinalIgnoreCase))
            {
                return SelfTest.Run(layout);
            }
            if ((args.Length == 2 || args.Length == 3) &&
                string.Equals(args[0], "--self-test-msix", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    int recoverySelfTest = JobRun.SelfTestRecoveryContractExitCode();
                    if (recoverySelfTest != 0) return recoverySelfTest;
                    PortableArchitecture expectedArchitecture = args.Length == 3 ?
                        ArchitectureInfo.ParseName(args[2]) : layout.Architecture;
                    if (expectedArchitecture == PortableArchitecture.Unknown) return 30;
                    AppUpdater.SelfTestMsix(layout, Path.GetFullPath(args[1]), expectedArchitecture);
                    return 0;
                }
                catch (Exception ex)
                {
                    SafeLog.TryWriteEvent(layout, "self-test-msix", ex.ToString());
                    return 30;
                }
            }
            if (args.Length == 3 &&
                string.Equals(args[0], "--stage-msix-payload", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    PortableArchitecture expectedArchitecture = ArchitectureInfo.ParseName(args[2]);
                    if (expectedArchitecture != PortableArchitecture.X64 &&
                        expectedArchitecture != PortableArchitecture.Arm64) return 34;
                    if (PortableProcess.IsDesktopRunning(layout)) return 3;
                    AppUpdater.StageVerifiedReleasePayload(layout, Path.GetFullPath(args[1]), expectedArchitecture);
                    return 0;
                }
                catch (Exception ex)
                {
                    SafeLog.TryWriteEvent(layout, "stage-msix-payload", ex.ToString());
                    return 34;
                }
            }
            if (args.Length == 2 && string.Equals(args[0], "--prepare-payload", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    PortableBranding.PreparePayload(Path.GetFullPath(args[1]));
                    return 0;
                }
                catch (Exception ex)
                {
                    SafeLog.TryWriteEvent(layout, "prepare-payload", ex.ToString());
                    return 31;
                }
            }
            if (args.Length == 1 && string.Equals(args[0], "--repair-plugin-cache", StringComparison.OrdinalIgnoreCase))
            {
                // Cache repair mutates the same tree used by the interactive
                // launcher. Serialize it with the per-portable-root mutex so a
                // command-line repair cannot race startup/update/rollback.
                bool repairMutexCreated;
                using (Mutex repairMutex = new Mutex(true, PortableProcess.GetMutexName(layout), out repairMutexCreated))
                {
                    if (!repairMutexCreated) return 2;
                    try
                    {
                        if (PortableProcess.IsDesktopRunning(layout)) return 3;
                        layout.EnsureDirectories();
                        if (PortableBundle.HasInstallPackages(layout))
                            PortableBundle.EnsureReady(layout);
                        int repaired = ProviderConfiguration.EnsureRequiredPluginCache(layout);
                        SafeLog.TryWriteEvent(layout, "plugin-cache-repair", "Verified required plugin cache; restored " +
                            repaired.ToString(CultureInfo.InvariantCulture) + " plugin(s). Command-line repair=true.");
                        return ProviderConfiguration.RequiredPluginCacheComplete(layout) ? 0 : 32;
                    }
                    catch (Exception ex)
                    {
                        SafeLog.TryWrite(layout, "plugin-cache-repair", ex);
                        SafeLog.TryWriteEvent(layout, "plugin-cache-repair-detail", ex.ToString());
                        return 32;
                    }
                }
            }

            // The launcher is a handoff tool, not a second desktop shell. If the
            // portable Codex process is already running, leave it alone and exit
            // without showing another launcher window.
            bool created;
            // Scope the launcher mutex to this normalized portable root. A fixed
            // name would let a test copy or another USB drive block this one.
            string mutexName = PortableProcess.GetMutexName(layout);
            using (Mutex mutex = new Mutex(true, mutexName, out created))
            {
                if (!created)
                {
                    return 2;
                }

                // Perform this check only after acquiring the mutex. Otherwise
                // two launchers can both observe a startup gap and proceed past
                // the preflight before either one serializes on the mutex.
                if (PortableProcess.IsDesktopRunning(layout)) return 3;

                try
                {
                    PortableBranding.InitializeProcessIdentity();
                    Application.EnableVisualStyles();
                    Application.SetCompatibleTextRenderingDefault(false);
                    Application.Run(new PortableForm(layout, bootstrapperProcessId));
                    return 0;
                }
                catch (Exception ex)
                {
                    SafeLog.TryWrite(layout, "fatal", ex);
                    MessageBox.Show(LauncherLocale.T("启动器发生错误。请使用“生成诊断”查看日志。\r\n\r\n错误类型：" + ex.GetType().Name,
                        "The launcher encountered an error. Create a diagnostic report.\r\n\r\nError type: " + ex.GetType().Name),
                        "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return 1;
                }
            }
        }
    }

    internal static class PortableProcess
    {
        internal static string GetMutexName(PortableLayout layout)
        {
            if (layout == null) throw new ArgumentNullException("layout");
            return GetMutexName(layout.Root);
        }

        // The detached local recovery helper cannot read the removable volume
        // after a device interruption. It receives the already-normalized root
        // identity from its parent and derives the same mutex name without I/O.
        internal static string GetMutexName(string portableRoot)
        {
            if (string.IsNullOrEmpty(portableRoot)) throw new ArgumentException("portableRoot");
            string root = Path.GetFullPath(portableRoot).TrimEnd('\\').ToUpperInvariant();
            byte[] input = Encoding.UTF8.GetBytes(root);
            byte[] digest = null;
            try
            {
                using (SHA256 sha = SHA256.Create()) digest = sha.ComputeHash(input);
                StringBuilder suffix = new StringBuilder(32);
                for (int i = 0; i < 16; i++) suffix.Append(digest[i].ToString("x2", CultureInfo.InvariantCulture));
                return "Local\\CodexPortable-Desktop-" + suffix.ToString();
            }
            finally
            {
                Array.Clear(input, 0, input.Length);
                if (digest != null) Array.Clear(digest, 0, digest.Length);
            }
        }

        // Serializes operations that replace directories shared with the
        // detached desktop process.  The UI mutex only covers the launcher
        // window lifetime; this second mutex must also cover the handoff and
        // command-line cache repair after the window has closed.
        internal static Mutex AcquireMutationMutex(PortableLayout layout, int timeoutMilliseconds)
        {
            if (layout == null) throw new ArgumentNullException("layout");
            return AcquireMutationMutex(layout.Root, timeoutMilliseconds);
        }

        internal static Mutex AcquireMutationMutex(string portableRoot, int timeoutMilliseconds)
        {
            if (timeoutMilliseconds < 0) throw new ArgumentOutOfRangeException("timeoutMilliseconds");
            Mutex mutex = new Mutex(false, GetMutexName(portableRoot) + "-mutation");
            bool acquired = false;
            try
            {
                try { acquired = mutex.WaitOne(timeoutMilliseconds, false); }
                catch (AbandonedMutexException) { acquired = true; }
                if (!acquired)
                {
                    mutex.Dispose();
                    return null;
                }
                return mutex;
            }
            catch
            {
                mutex.Dispose();
                throw;
            }
        }

        internal static void ReleaseMutationMutex(Mutex mutex)
        {
            if (mutex == null) return;
            try { mutex.ReleaseMutex(); }
            finally { mutex.Dispose(); }
        }

        internal static bool IsDesktopRunning(PortableLayout layout)
        {
            string portableDesktop;
            string officialDesktop;
            try
            {
                // Electron child processes use the same executable as the
                // desktop shell.  Restrict detection to those two executable
                // identities so bundled runtimes, Git and plugin helpers do
                // not make the launcher mistake unrelated work for Codex.
                portableDesktop = NormalizeExecutablePath(layout.AppExe);
                officialDesktop = NormalizeExecutablePath(layout.OfficialAppExe);
            }
            catch { return false; }

            int currentProcessId;
            try { currentProcessId = Process.GetCurrentProcess().Id; }
            catch { return false; }
            Process[] processes;
            try { processes = Process.GetProcesses(); }
            catch { return false; }
            for (int i = 0; i < processes.Length; i++)
            {
                Process process = processes[i];
                try
                {
                    if (process.Id == currentProcessId) continue;
                    string executable;
                    if (!TryGetExecutablePath(process, out executable))
                    {
                        // An elevated LF desktop can deny path inspection to a
                        // non-elevated launcher. Its unique executable name is
                        // sufficient to fail closed and avoid a duplicate start.
                        if (string.Equals(process.ProcessName, "CodexDesktop",
                            StringComparison.OrdinalIgnoreCase)) return true;
                        continue;
                    }
                    if (IsSameExecutablePath(executable, portableDesktop) ||
                        IsSameExecutablePath(executable, officialDesktop) ||
                        HostExecutionImage.IsExecutionPathForLayout(layout, executable)) return true;
                }
                catch { }
                finally { process.Dispose(); }
            }
            return false;
        }

        private static string NormalizeExecutablePath(string path)
        {
            return Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar);
        }

        private static bool IsSameExecutablePath(string candidate, string expected)
        {
            string full;
            try { full = Path.GetFullPath(candidate); }
            catch { return false; }
            return string.Equals(full.TrimEnd(Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar), expected, StringComparison.OrdinalIgnoreCase);
        }

        internal static bool IsAnyExecutableRunningUnderRoot(string executionRoot)
        {
            string root;
            try
            {
                root = NormalizeExecutablePath(executionRoot);
            }
            catch { return true; }
            Process[] processes;
            try { processes = Process.GetProcesses(); }
            catch { return true; }
            for (int i = 0; i < processes.Length; i++)
            {
                Process process = processes[i];
                try
                {
                    string executable;
                    if (TryGetExecutablePath(process, out executable))
                    {
                        string full;
                        try { full = NormalizeExecutablePath(executable); }
                        catch { return true; }
                        if (full.StartsWith(root + Path.DirectorySeparatorChar,
                            StringComparison.OrdinalIgnoreCase)) return true;
                    }
                    else
                    {
                        // A protected or cross-integrity LF runtime process can
                        // deny path inspection even though it still maps files
                        // from this image. Preserve the image for every runtime
                        // executable name that the portable payload can launch.
                        string name = process.ProcessName;
                        if (IsPotentialExecutionImageProcessName(name)) return true;
                    }
                }
                catch { }
                finally { process.Dispose(); }
            }
            return false;
        }

        internal static void TerminateExecutablesUnderRoot(string executionRoot)
        {
            string root;
            try { root = NormalizeExecutablePath(executionRoot); }
            catch { return; }
            Process[] processes;
            try { processes = Process.GetProcesses(); }
            catch { return; }
            int currentProcessId = Process.GetCurrentProcess().Id;
            for (int i = 0; i < processes.Length; i++)
            {
                Process process = processes[i];
                try
                {
                    if (process.Id == currentProcessId) continue;
                    string executable;
                    if (!TryGetExecutablePath(process, out executable)) continue;
                    string full;
                    try { full = NormalizeExecutablePath(executable); }
                    catch { continue; }
                    if (!full.StartsWith(root + Path.DirectorySeparatorChar,
                        StringComparison.OrdinalIgnoreCase)) continue;
                    try { process.Kill(); }
                    catch { }
                }
                catch { }
                finally { process.Dispose(); }
            }
        }

        private static bool IsPotentialExecutionImageProcessName(string name)
        {
            if (string.IsNullOrEmpty(name)) return false;
            string normalized = name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ?
                name.Substring(0, name.Length - 4) : name;
            string[] known = new string[] {
                "CodexDesktop", "codex", "node", "node_repl", "python", "pythonw",
                "git", "dotnet", "gh", "computer-use", "codex-computer-use"
            };
            for (int i = 0; i < known.Length; i++)
                if (string.Equals(normalized, known[i], StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        internal static bool TryGetExecutablePath(Process process, out string executable)
        {
            executable = null;
            try
            {
                ProcessModule module = process.MainModule;
                if (module != null && !string.IsNullOrEmpty(module.FileName))
                {
                    executable = module.FileName;
                    return true;
                }
            }
            catch { }

            IntPtr handle = IntPtr.Zero;
            try
            {
                handle = NativeMethods.OpenProcess(NativeMethods.ProcessQueryLimitedInformation,
                    false, unchecked((uint)process.Id));
                if (handle == IntPtr.Zero) return false;
                uint length = NativeMethods.MaximumProcessImagePath;
                StringBuilder buffer = new StringBuilder((int)length);
                if (!NativeMethods.QueryFullProcessImageName(handle, 0, buffer, ref length) ||
                    length == 0) return false;
                executable = buffer.ToString();
                return !string.IsNullOrEmpty(executable);
            }
            catch { return false; }
            finally
            {
                if (handle != IntPtr.Zero) NativeMethods.CloseHandle(handle);
            }
        }
    }

    internal static class PluginCacheRecovery
    {
        private const long MaxManifestBytes = 4L * 1024L * 1024L;

        private static string ToExtendedPath(string path)
        {
            if (path.StartsWith("\\\\?\\", StringComparison.Ordinal)) return path;
            string full;
            bool driveAbsolute = path.Length >= 3 && path[1] == ':' &&
                (path[2] == '\\' || path[2] == '/');
            bool uncAbsolute = path.StartsWith("\\\\", StringComparison.Ordinal);
            // Legacy .NET Framework may throw before GetFullPath can normalize an
            // already-absolute path longer than MAX_PATH.  All long paths reaching
            // this class are composed below a validated portable root, so retain the
            // absolute form and let the Win32 extended-path API handle it.
            if (path.Length >= 240 && (driveAbsolute || uncAbsolute))
                full = path.Replace('/', '\\');
            else full = Path.GetFullPath(path);
            // Keep ordinary paths ordinary.  Some older Windows/.NET combinations reject the
            // extended prefix for short paths unless the process manifest opts into long paths.
            if (full.Length < 240) return full;
            if (full.StartsWith("\\\\", StringComparison.Ordinal)) return "\\\\?\\UNC\\" + full.Substring(2);
            return "\\\\?\\" + full;
        }

        private static bool DirectoryExists(string path)
        {
            string extended = ToExtendedPath(path);
            try { if (Directory.Exists(extended)) return true; } catch { }
            uint attributes = NativeMethods.GetFileAttributes(extended);
            return attributes != NativeMethods.InvalidFileAttributes &&
                (attributes & (uint)FileAttributes.Directory) != 0;
        }

        private static bool FileExists(string path)
        {
            string extended = ToExtendedPath(path);
            try { if (File.Exists(extended)) return true; } catch { }
            uint attributes = NativeMethods.GetFileAttributes(extended);
            return attributes != NativeMethods.InvalidFileAttributes &&
                (attributes & (uint)FileAttributes.Directory) == 0;
        }

        private static bool IsReparsePoint(string path)
        {
            try
            {
                FileAttributes attributes = GetAttributes(ToNativePath(path));
                return (attributes & FileAttributes.ReparsePoint) != 0;
            }
            catch
            {
                // A path that cannot be inspected is not safe to treat as a
                // trusted cache entry. Callers use this as a fail-closed check.
                return true;
            }
        }

        private static void RejectExistingReparsePoint(string path, string label)
        {
            if (!DirectoryExists(path) && !FileExists(path)) return;
            if (IsReparsePoint(path))
                throw new IOException(label + " cannot be a reparse point: " + path);
        }

        private static string ToNativePath(string path)
        {
            string full = ToExtendedPath(path);
            if (full.StartsWith("\\\\?\\", StringComparison.Ordinal)) return full;
            if (full.StartsWith("\\\\", StringComparison.Ordinal)) return "\\\\?\\UNC\\" + full.Substring(2);
            return "\\\\?\\" + full;
        }

        private sealed class PluginDefinition
        {
            internal string PluginName;
            internal string MarketplaceName;
            internal string Version;
            internal string SourceRoot;
            internal string CacheCatalogRoot;
            internal string CacheBaseRoot;
            internal string CacheVersionRoot;
        }

        private sealed class PluginTreeFile
        {
            internal string Path;
            internal long Length;
            internal long LastWriteFileTime;
        }

        internal static bool RequiredPluginCacheComplete(PortableLayout layout, string[] requiredPlugins)
        {
            try
            {
                for (int i = 0; i < requiredPlugins.Length; i++)
                {
                    PluginDefinition definition = ReadDefinition(layout, requiredPlugins[i]);
                    if (!IsCachedVersionComplete(definition)) return false;
                }
                return true;
            }
            catch { return false; }
        }

        internal static int EnsureRequiredPlugins(PortableLayout layout, string[] requiredPlugins)
        {
            Mutex mutation = PortableProcess.AcquireMutationMutex(layout, 0);
            if (mutation == null)
                throw new IOException("Plugin cache recovery is already in progress for this portable root.");
            try
            {
                if (PortableProcess.IsDesktopRunning(layout))
                    throw new IOException("Plugin cache recovery is blocked while portable Codex Desktop is running.");
                int repaired = 0;
                for (int i = 0; i < requiredPlugins.Length; i++)
                {
                    PluginDefinition definition = ReadDefinition(layout, requiredPlugins[i]);
                    if (IsCachedVersionComplete(definition)) continue;
                    try
                    {
                        RepairOne(layout, definition);
                    }
                    catch (Exception ex)
                    {
                        string detail = ex.Message;
                        if (ex.InnerException != null) detail += " Inner=" + ex.InnerException.Message;
                        throw new IOException("Plugin recovery failed for " + requiredPlugins[i] + ": " + detail, ex);
                    }
                    if (!IsCachedVersionComplete(definition))
                        throw new InvalidDataException("Recovered plugin cache failed its manifest check: " + requiredPlugins[i]);
                    repaired++;
                }
                return repaired;
            }
            finally { PortableProcess.ReleaseMutationMutex(mutation); }
        }

        private static PluginDefinition ReadDefinition(PortableLayout layout, string pluginKey)
        {
            int separator = pluginKey.IndexOf('@');
            if (separator <= 0 || separator == pluginKey.Length - 1 || pluginKey.IndexOf('@', separator + 1) >= 0)
                throw new InvalidDataException("Invalid required plugin key: " + pluginKey);

            string pluginName = pluginKey.Substring(0, separator);
            string marketplaceName = pluginKey.Substring(separator + 1);
            string sourceRoot;
            if (string.Equals(marketplaceName, "openai-bundled", StringComparison.Ordinal))
            {
                sourceRoot = Path.Combine(layout.Resources, "plugins", marketplaceName, "plugins", pluginName);
            }
            else if (string.Equals(marketplaceName, "openai-primary-runtime", StringComparison.Ordinal))
            {
                sourceRoot = Path.Combine(layout.CodexHome, "offline-marketplaces", marketplaceName, "plugins", pluginName);
            }
            else throw new InvalidDataException("Required plugin uses an untrusted marketplace: " + pluginKey);

            if (!DirectoryExists(sourceRoot)) throw new DirectoryNotFoundException("Offline plugin source is missing: " + sourceRoot);
            if (IsReparsePoint(sourceRoot))
                throw new IOException("Offline plugin source cannot be a reparse point: " + sourceRoot);
            string sourceManifest = Path.Combine(sourceRoot, ".codex-plugin", "plugin.json");
            if (IsReparsePoint(Path.Combine(sourceRoot, ".codex-plugin")) || IsReparsePoint(sourceManifest))
                throw new IOException("Offline plugin manifest cannot be a reparse point: " + sourceManifest);
            string manifestName;
            string version;
            ReadManifestIdentity(sourceManifest, out manifestName, out version);
            if (!string.Equals(manifestName, pluginName, StringComparison.Ordinal))
                throw new InvalidDataException("Offline plugin manifest name does not match its marketplace entry: " + pluginKey);
            if (!IsSafeVersionSegment(version))
                throw new InvalidDataException("Offline plugin version is not a safe cache directory name: " + pluginKey);

            string pluginsRoot = Path.Combine(layout.CodexHome, "plugins");
            string cacheRoot = Path.Combine(pluginsRoot, "cache");
            string cacheCatalogRoot = Path.Combine(cacheRoot, marketplaceName);
            RejectExistingReparsePoint(pluginsRoot, "Plugin root");
            RejectExistingReparsePoint(cacheRoot, "Plugin cache root");
            RejectExistingReparsePoint(cacheCatalogRoot, "Plugin cache catalog");
            string cacheBaseRoot = Path.Combine(cacheCatalogRoot, pluginName);
            return new PluginDefinition {
                PluginName = pluginName,
                MarketplaceName = marketplaceName,
                Version = version,
                SourceRoot = sourceRoot,
                CacheBaseRoot = cacheBaseRoot,
                CacheVersionRoot = Path.Combine(cacheBaseRoot, version),
                CacheCatalogRoot = cacheCatalogRoot
            };
        }

        private static bool IsCachedVersionComplete(PluginDefinition definition)
        {
            if (!DirectoryExists(definition.CacheVersionRoot)) return false;
            if (IsReparsePoint(definition.CacheCatalogRoot) ||
                IsReparsePoint(definition.CacheBaseRoot) || IsReparsePoint(definition.CacheVersionRoot))
                return false;
            if (!CacheBaseHasOnlyExpectedVersion(definition)) return false;
            string manifest = Path.Combine(definition.CacheVersionRoot, ".codex-plugin", "plugin.json");
            if (!FileExists(manifest)) return false;
            if (IsReparsePoint(Path.Combine(definition.CacheVersionRoot, ".codex-plugin")) ||
                IsReparsePoint(manifest)) return false;
            try
            {
                string name;
                string version;
                ReadManifestIdentity(manifest, out name, out version);
                if (!string.Equals(name, definition.PluginName, StringComparison.Ordinal) ||
                    !string.Equals(version, definition.Version, StringComparison.Ordinal)) return false;
                return TreeMatchesTrustedSource(definition);
            }
            catch { return false; }
        }

        private static bool CacheBaseHasOnlyExpectedVersion(PluginDefinition definition)
        {
            string root = ToNativePath(definition.CacheBaseRoot);
            NativeMethods.WIN32_FIND_DATA data;
            IntPtr find = NativeMethods.FindFirstFile(root.TrimEnd('\\') + "\\*", out data);
            if (find == NativeMethods.InvalidHandleValue) return false;
            bool foundVersion = false;
            try
            {
                bool more = true;
                while (more)
                {
                    string name = data.cFileName;
                    if (name != "." && name != "..")
                    {
                        if ((data.dwFileAttributes & FileAttributes.ReparsePoint) != 0 ||
                            (data.dwFileAttributes & FileAttributes.Directory) == 0 ||
                            !string.Equals(name, definition.Version, StringComparison.OrdinalIgnoreCase))
                            return false;
                        if (foundVersion) return false;
                        foundVersion = true;
                    }
                    more = NativeMethods.FindNextFile(find, out data);
                    if (!more)
                    {
                        int error = Marshal.GetLastWin32Error();
                        if (error != 18) return false;
                    }
                }
                return foundVersion;
            }
            finally { NativeMethods.FindClose(find); }
        }

        // A cache is a byte-for-byte materialization of the local marketplace
        // source, not merely a versioned manifest.  Enumerate both complete
        // trees on every preflight so a deleted file can never use a cached
        // "complete" result. Hashes are only needed when file metadata differs:
        // CopyFileW preserves size and last-write FILETIME, which keeps normal
        // USB launches fast while still verifying every metadata anomaly.
        private static bool TreeMatchesTrustedSource(PluginDefinition definition)
        {
            PluginTreeSnapshot source = CollectTreeSnapshot(definition.SourceRoot);
            PluginTreeSnapshot cache = CollectTreeSnapshot(definition.CacheVersionRoot);
            HashSet<string> generatedDirectories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            foreach (string sourceDirectory in source.Directories)
                if (!cache.Directories.Contains(sourceDirectory)) return false;
            foreach (string cacheDirectory in cache.Directories)
            {
                if (source.Directories.Contains(cacheDirectory)) continue;
                if (!IsAllowedRuntimeGeneratedDirectory(cacheDirectory, source.Directories)) return false;
                generatedDirectories.Add(cacheDirectory);
            }

            foreach (KeyValuePair<string, PluginTreeFile> sourceFile in source.Files)
            {
                PluginTreeFile cached;
                if (!cache.Files.TryGetValue(sourceFile.Key, out cached)) return false;
                if (sourceFile.Value.Length != cached.Length) return false;
                if (sourceFile.Value.LastWriteFileTime != cached.LastWriteFileTime &&
                    !string.Equals(Sha256FileExtended(sourceFile.Value.Path), Sha256FileExtended(cached.Path),
                        StringComparison.OrdinalIgnoreCase)) return false;
            }
            foreach (KeyValuePair<string, PluginTreeFile> cached in cache.Files)
            {
                if (source.Files.ContainsKey(cached.Key)) continue;
                if (!IsAllowedRuntimeGeneratedFile(cached.Key, generatedDirectories)) return false;
            }
            return true;
        }

        private sealed class PluginTreeSnapshot
        {
            internal Dictionary<string, PluginTreeFile> Files;
            internal HashSet<string> Directories;
        }

        private static PluginTreeSnapshot CollectTreeSnapshot(string root)
        {
            string nativeRoot = ToNativePath(root);
            List<string> directories = new List<string>();
            List<string> files = new List<string>();
            CollectTree(nativeRoot, nativeRoot, directories, files);
            Dictionary<string, PluginTreeFile> treeFiles =
                new Dictionary<string, PluginTreeFile>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < files.Count; i++)
            {
                string path = files[i];
                string relative = RelativePath(nativeRoot, path);
                if (string.IsNullOrEmpty(relative) || treeFiles.ContainsKey(relative))
                    throw new InvalidDataException("Plugin tree contains an ambiguous file path: " + path);
                NativeMethods.WIN32_FILE_ATTRIBUTE_DATA attributes;
                if (!NativeMethods.GetFileAttributesEx(ToNativePath(path), 0, out attributes))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Plugin metadata query failed: " + path);
                if ((attributes.dwFileAttributes & FileAttributes.Directory) != 0 ||
                    (attributes.dwFileAttributes & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("Plugin tree file has unsafe attributes: " + path);
                treeFiles.Add(relative, new PluginTreeFile {
                    Path = path,
                    Length = ((long)attributes.nFileSizeHigh << 32) | attributes.nFileSizeLow,
                    LastWriteFileTime = ToFileTime(attributes.ftLastWriteTime)
                });
            }
            HashSet<string> treeDirectories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < directories.Count; i++)
            {
                string relative = RelativePath(nativeRoot, directories[i]);
                if (string.IsNullOrEmpty(relative) || !treeDirectories.Add(relative))
                    throw new InvalidDataException("Plugin tree contains an ambiguous directory path: " + directories[i]);
            }
            return new PluginTreeSnapshot { Files = treeFiles, Directories = treeDirectories };
        }

        private static bool IsAllowedRuntimeGeneratedDirectory(string relative,
            HashSet<string> sourceDirectories)
        {
            string parent;
            string name;
            SplitRelativePath(relative, out parent, out name);
            return string.Equals(name, "__pycache__", StringComparison.OrdinalIgnoreCase) &&
                (string.IsNullOrEmpty(parent) || sourceDirectories.Contains(parent));
        }

        private static bool IsAllowedRuntimeGeneratedFile(string relative,
            HashSet<string> generatedDirectories)
        {
            string parent;
            string name;
            SplitRelativePath(relative, out parent, out name);
            return generatedDirectories.Contains(parent) &&
                name.EndsWith(".pyc", StringComparison.OrdinalIgnoreCase);
        }

        private static void SplitRelativePath(string relative, out string parent, out string name)
        {
            int separator = relative.LastIndexOfAny(new char[] { '\\', '/' });
            if (separator < 0)
            {
                parent = "";
                name = relative;
                return;
            }
            parent = relative.Substring(0, separator);
            name = relative.Substring(separator + 1);
        }

        private static long ToFileTime(System.Runtime.InteropServices.ComTypes.FILETIME value)
        {
            return ((long)(uint)value.dwHighDateTime << 32) | (uint)value.dwLowDateTime;
        }

        private static bool IsSafeVersionSegment(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length > 128 || value == "." || value == ".." ||
                string.Equals(value, "latest", StringComparison.OrdinalIgnoreCase)) return false;
            for (int i = 0; i < value.Length; i++)
            {
                char c = value[i];
                if (!(char.IsLetterOrDigit(c) || c == '-' || c == '_' || c == '.' || c == '+')) return false;
            }
            return true;
        }

        internal static void ReadManifestIdentity(string path, out string name, out string version)
        {
            name = null;
            version = null;
            if (!FileExists(path)) throw new FileNotFoundException("Plugin manifest is missing.", path);
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = (int)MaxManifestBytes;
            string manifestText;
            using (FileStream stream = OpenFileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
                4096, FileOptions.SequentialScan))
            using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true))
            {
                if (stream.Length <= 0 || stream.Length > MaxManifestBytes)
                    throw new InvalidDataException("Plugin manifest size is invalid: " + path);
                manifestText = reader.ReadToEnd();
            }
            Dictionary<string, object> json = serializer.Deserialize<Dictionary<string, object>>(manifestText);
            object nameValue;
            object versionValue;
            if (json == null || !json.TryGetValue("name", out nameValue) || !json.TryGetValue("version", out versionValue))
                throw new InvalidDataException("Plugin manifest lacks name or version: " + path);
            name = Convert.ToString(nameValue, CultureInfo.InvariantCulture);
            version = Convert.ToString(versionValue, CultureInfo.InvariantCulture);
            if (string.IsNullOrEmpty(name) || string.IsNullOrEmpty(version))
                throw new InvalidDataException("Plugin manifest name or version is blank: " + path);
        }

        private static void RepairOne(PortableLayout layout, PluginDefinition definition)
        {
            if (PortableProcess.IsDesktopRunning(layout))
                throw new IOException("Plugin cache recovery is blocked while portable Codex Desktop is running.");
            string token = DateTime.UtcNow.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture) + "-" +
                Guid.NewGuid().ToString("N").Substring(0, 10);
            // Keep the transient staging name deliberately short.  Plugin assets can
            // contain very deep paths; a verbose staging prefix can push an otherwise
            // valid path past the legacy .NET Framework limit before the native
            // long-path fallback gets a chance to open it.
            string stagingToken = Guid.NewGuid().ToString("N").Substring(0, 8);
            string pluginsRoot = Path.Combine(layout.CodexHome, "plugins");
            string stagingRoot = Path.Combine(pluginsRoot, ".pr-" + stagingToken);
            string stagedBase = Path.Combine(stagingRoot, definition.MarketplaceName, definition.PluginName);
            string stagedVersion = Path.Combine(stagedBase, definition.Version);
            string repairBackupsRoot = Path.Combine(pluginsRoot, "repair-backups");
            string backupTokenRoot = Path.Combine(repairBackupsRoot, token);
            string backupBase = Path.Combine(backupTokenRoot,
                definition.MarketplaceName, definition.PluginName);
            string failedBase = Path.Combine(backupTokenRoot,
                definition.MarketplaceName, definition.PluginName + ".failed");
            bool targetMoved = false;
            bool activated = false;

            try
            {
                RejectExistingReparsePoint(pluginsRoot, "Plugin root");
                EnsureDirectory(stagedVersion);
                CopyDirectoryVerified(definition.SourceRoot, stagedVersion);
                PluginDefinition stagedDefinition = new PluginDefinition {
                    PluginName = definition.PluginName,
                    MarketplaceName = definition.MarketplaceName,
                    Version = definition.Version,
                    SourceRoot = definition.SourceRoot,
                    CacheCatalogRoot = Path.Combine(stagingRoot, definition.MarketplaceName),
                    CacheBaseRoot = stagedBase,
                    CacheVersionRoot = stagedVersion
                };
                if (!IsCachedVersionComplete(stagedDefinition))
                    throw new InvalidDataException("Staged plugin manifest did not validate: " + definition.PluginName);

                AssertTargetStillPresent(layout);
                if (PortableProcess.IsDesktopRunning(layout))
                    throw new IOException("Portable Codex Desktop started during plugin recovery; no cache replacement was attempted.");
                if (DirectoryExists(definition.CacheBaseRoot))
                {
                    AssertNoReparsePoints(definition.CacheBaseRoot);
                    EnsureDirectory(Path.GetDirectoryName(backupBase));
                    MoveDirectoryVerified(definition.CacheBaseRoot, backupBase);
                    targetMoved = true;
                }
                else if (FileExists(definition.CacheBaseRoot))
                {
                    throw new IOException("Plugin cache target is a file, not a directory: " + definition.CacheBaseRoot);
                }

                EnsureDirectory(Path.GetDirectoryName(definition.CacheBaseRoot));
                RejectExistingReparsePoint(pluginsRoot, "Plugin root");
                RejectExistingReparsePoint(Path.Combine(pluginsRoot, "cache"), "Plugin cache root");
                RejectExistingReparsePoint(definition.CacheCatalogRoot, "Plugin cache catalog");
                MoveDirectoryVerified(stagedBase, definition.CacheBaseRoot);
                activated = true;
                if (!IsCachedVersionComplete(definition))
                    throw new InvalidDataException("Activated plugin cache did not validate: " + definition.PluginName);
            }
            catch
            {
                try
                {
                    if (activated && DirectoryExists(definition.CacheBaseRoot) && !DirectoryExists(failedBase))
                    {
                        EnsureDirectory(Path.GetDirectoryName(failedBase));
                        MoveDirectoryVerified(definition.CacheBaseRoot, failedBase);
                    }
                    if (targetMoved && DirectoryExists(backupBase) && !DirectoryExists(definition.CacheBaseRoot))
                    {
                        MoveDirectoryVerified(backupBase, definition.CacheBaseRoot);
                    }
                }
                catch (Exception rollbackError)
                {
                    SafeLog.TryWrite(layout, "plugin-cache-repair-rollback", rollbackError);
                }
                throw;
            }
            finally
            {
                try
                {
                    if (DirectoryExists(stagingRoot)) IOUtil.DeleteDirectoryWithin(stagingRoot, pluginsRoot);
                }
                catch (Exception cleanupError) { SafeLog.TryWrite(layout, "plugin-cache-repair-cleanup", cleanupError); }
                if (activated && IsCachedVersionComplete(definition))
                {
                    try
                    {
                        if (DirectoryExists(backupTokenRoot))
                            IOUtil.DeleteDirectoryWithin(backupTokenRoot, pluginsRoot);
                        if (DirectoryExists(repairBackupsRoot))
                            NativeMethods.RemoveDirectory(ToNativePath(repairBackupsRoot));
                    }
                    catch (Exception cleanupError)
                    {
                        SafeLog.TryWrite(layout, "plugin-cache-repair-backup-cleanup", cleanupError);
                    }
                }
            }
        }

        private static void AssertTargetStillPresent(PortableLayout layout)
        {
            string root = Path.GetPathRoot(layout.Root);
            if (string.IsNullOrEmpty(root) || !DirectoryExists(root)) throw new IOException("Portable drive disappeared during plugin recovery.");
            if (!DirectoryExists(layout.CodexHome)) throw new IOException("Portable Codex data disappeared during plugin recovery.");
        }

        private static void MoveDirectoryVerified(string source, string destination)
        {
            string extendedSource = ToExtendedPath(source);
            string extendedDestination = ToExtendedPath(destination);
            Exception managedError = null;
            try
            {
                Directory.Move(extendedSource, extendedDestination);
            }
            catch (Exception ex)
            {
                managedError = ex;
                // .NET Framework's Directory.Move can reject an otherwise valid
                // extended path before reaching Win32. MoveFileW accepts the
                // same \?\ representation and keeps the operation atomic.
                if (!NativeMethods.MoveFile(extendedSource, extendedDestination))
                {
                    int error = Marshal.GetLastWin32Error();
                    throw new IOException("Plugin directory move failed: " + source + " -> " + destination,
                        new Win32Exception(error, managedError.Message));
                }
            }
            if (!DirectoryExists(destination) || DirectoryExists(source))
                throw new IOException("Plugin directory move could not be verified: " + source + " -> " + destination);
        }

        private static void AssertNoReparsePoints(string root)
        {
            if (!DirectoryExists(root)) return;
            string extendedRoot = ToNativePath(root);
            FileAttributes rootAttributes = GetAttributes(extendedRoot);
            if ((rootAttributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Reparse point is not allowed in plugin cache: " + root);
            List<string> directories = new List<string>();
            List<string> files = new List<string>();
            CollectTree(extendedRoot, extendedRoot, directories, files);
        }

        private static int CopyDirectoryVerified(string sourceRoot, string destinationRoot)
        {
            string extendedSourceRoot = ToNativePath(sourceRoot);
            List<string> sourceDirectories = new List<string>();
            List<string> sourceFiles = new List<string>();
            CollectTree(extendedSourceRoot, extendedSourceRoot, sourceDirectories, sourceFiles);
            sourceDirectories.Sort(StringComparer.OrdinalIgnoreCase);
            sourceFiles.Sort(delegate(string left, string right)
            {
                bool leftManifest = IsManifestPath(left, extendedSourceRoot);
                bool rightManifest = IsManifestPath(right, extendedSourceRoot);
                if (leftManifest != rightManifest) return leftManifest ? 1 : -1;
                return StringComparer.OrdinalIgnoreCase.Compare(left, right);
            });

            for (int i = 0; i < sourceDirectories.Count; i++)
            {
                string relative = RelativePath(extendedSourceRoot, sourceDirectories[i]);
                string destinationDirectory = Path.Combine(destinationRoot, relative);
                try { EnsureDirectory(destinationDirectory); }
                catch (Exception ex) { throw new IOException("Plugin directory create failed: " + destinationDirectory + "; " + ex.Message, ex); }
            }
            for (int i = 0; i < sourceFiles.Count; i++)
            {
                string relative = RelativePath(extendedSourceRoot, sourceFiles[i]);
                string destination = Path.Combine(destinationRoot, relative);
                string parent = ParentPath(destination);
                if (!string.IsNullOrEmpty(parent))
                {
                    try { EnsureDirectory(parent); }
                    catch (Exception ex) { throw new IOException("Plugin file parent create failed: " + parent + "; " + ex.Message, ex); }
                }
                CopyFileVerified(sourceFiles[i], destination);
            }
            return sourceFiles.Count;
        }

        // .NET Framework's managed Directory.CreateDirectory has a legacy path
        // parser which can reject a valid \\?\ long path with
        // ArgumentException (the failure is dependent on the process manifest and
        // CLR host).  Fall back to the Win32 wide-character API after recursively
        // creating the parent.  This keeps all actual I/O on the same extended-path
        // representation and works on removable volumes as well as local disks.
        private static void EnsureDirectory(string path)
        {
            if (string.IsNullOrEmpty(path)) throw new ArgumentException("Directory path is blank.", "path");
            string extended = ToExtendedPath(path);
            try
            {
                Directory.CreateDirectory(extended);
                return;
            }
            catch (ArgumentException) { }
            catch (NotSupportedException) { }
            catch (IOException) { }

            if (DirectoryExists(path)) return;
            string parent = ParentPath(path);
            if (!string.IsNullOrEmpty(parent) && !DirectoryExists(parent))
                EnsureDirectory(parent);
            if (!NativeMethods.CreateDirectory(extended, IntPtr.Zero))
            {
                int error = Marshal.GetLastWin32Error();
                if (error != 183 && !DirectoryExists(path))
                    throw new Win32Exception(error, "Long-path directory creation failed: " + path);
            }
            if (!DirectoryExists(path))
                throw new IOException("Long-path directory creation could not be verified: " + path);
        }

        private static string ParentPath(string path)
        {
            if (string.IsNullOrEmpty(path)) return null;
            int end = path.Length;
            while (end > 0 && (path[end - 1] == '\\' || path[end - 1] == '/')) end--;
            int separator = -1;
            for (int i = end - 1; i >= 0; i--)
            {
                if (path[i] == '\\' || path[i] == '/') { separator = i; break; }
            }
            if (separator < 0) return null;
            if (separator == 2 && end >= 3 && path[1] == ':') return path.Substring(0, 3);
            if (separator == 0) return path.Substring(0, 1);
            return path.Substring(0, separator);
        }

        private static void CollectTree(string root, string current, List<string> directories, List<string> files)
        {
            string nativeCurrent = ToNativePath(current);
            FileAttributes currentAttributes = GetAttributes(nativeCurrent);
            if ((currentAttributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Reparse point is not allowed in offline plugin source: " + current);
            NativeMethods.WIN32_FIND_DATA data;
            string pattern = nativeCurrent.TrimEnd('\\') + "\\*";
            IntPtr find = NativeMethods.FindFirstFile(pattern, out data);
            if (find == NativeMethods.InvalidHandleValue)
            {
                int firstError = Marshal.GetLastWin32Error();
                if (firstError == 2) return;
                throw new Win32Exception(firstError, "Long-path plugin enumeration failed: " + current);
            }
            try
            {
                bool more = true;
                while (more)
                {
                    string name = data.cFileName;
                    if (name != "." && name != "..")
                    {
                        string child = nativeCurrent.TrimEnd('\\') + "\\" + name;
                        FileAttributes attributes = data.dwFileAttributes;
                        if ((attributes & FileAttributes.ReparsePoint) != 0)
                            throw new IOException("Reparse point is not allowed in plugin tree: " + child);
                        if ((attributes & FileAttributes.Directory) != 0)
                        {
                            directories.Add(child);
                            CollectTree(root, child, directories, files);
                        }
                        else files.Add(child);
                    }
                    more = NativeMethods.FindNextFile(find, out data);
                    if (!more)
                    {
                        int error = Marshal.GetLastWin32Error();
                        if (error != 18) throw new Win32Exception(error, "Long-path plugin enumeration failed: " + current);
                    }
                }
            }
            finally { NativeMethods.FindClose(find); }
        }

        private static FileAttributes GetAttributes(string path)
        {
            uint attributes = NativeMethods.GetFileAttributes(path);
            if (attributes == NativeMethods.InvalidFileAttributes)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Long-path attribute query failed: " + path);
            return (FileAttributes)attributes;
        }

        private static bool IsManifestPath(string path, string root)
        {
            return string.Equals(RelativePath(root, path), Path.Combine(".codex-plugin", "plugin.json"), StringComparison.OrdinalIgnoreCase);
        }

        private static string RelativePath(string root, string path)
        {
            return path.Substring(root.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }

        private static void CopyFileVerified(string source, string destination)
        {
            try
            {
                string extendedSource = ToExtendedPath(source);
                string extendedDestination = ToExtendedPath(destination);
                if (!NativeMethods.CopyFile(extendedSource, extendedDestination, true))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "CopyFileW failed.");
                string sourceHash = Sha256FileExtended(source);
                string destinationHash = Sha256FileExtended(destination);
                if (!string.Equals(sourceHash, destinationHash, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Copied plugin file failed SHA-256 verification: " + source);
            }
            catch (Exception ex)
            {
                throw new IOException("Plugin file copy failed (" + ex.GetType().Name + ",0x" +
                    ex.HResult.ToString("X8", CultureInfo.InvariantCulture) + "): " + source + " -> " +
                    destination + "; " + ex.Message, ex);
            }
        }

        private static string Sha256FileExtended(string path)
        {
            byte[] hash;
            using (FileStream stream = OpenFileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
                1024 * 1024, FileOptions.SequentialScan))
            using (SHA256 sha = SHA256.Create()) hash = sha.ComputeHash(stream);
            StringBuilder result = new StringBuilder(hash.Length * 2);
            for (int i = 0; i < hash.Length; i++) result.Append(hash[i].ToString("x2", CultureInfo.InvariantCulture));
            CryptoUtil.Zero(hash);
            return result.ToString();
        }

        private static FileStream OpenFileStream(string path, FileMode mode, FileAccess access,
            FileShare share, int bufferSize, FileOptions options)
        {
            uint desiredAccess = 0;
            if ((access & FileAccess.Read) != 0) desiredAccess |= NativeMethods.GenericRead;
            if ((access & FileAccess.Write) != 0) desiredAccess |= NativeMethods.GenericWrite;
            uint shareMode = 0;
            if ((share & FileShare.Read) != 0) shareMode |= NativeMethods.FileShareRead;
            if ((share & FileShare.Write) != 0) shareMode |= NativeMethods.FileShareWrite;
            if ((share & FileShare.Delete) != 0) shareMode |= NativeMethods.FileShareDelete;
            uint disposition;
            switch (mode)
            {
                case FileMode.CreateNew: disposition = NativeMethods.CreateNew; break;
                case FileMode.Create: disposition = NativeMethods.CreateAlways; break;
                case FileMode.Open: disposition = NativeMethods.OpenExisting; break;
                case FileMode.OpenOrCreate: disposition = NativeMethods.OpenAlways; break;
                case FileMode.Truncate: disposition = NativeMethods.TruncateExisting; break;
                case FileMode.Append: disposition = NativeMethods.OpenAlways; break;
                default: throw new ArgumentOutOfRangeException("mode");
            }
            uint flags = NativeMethods.FileAttributeNormal;
            if ((options & FileOptions.SequentialScan) != 0) flags |= NativeMethods.FileFlagSequentialScan;
            if ((options & FileOptions.WriteThrough) != 0) flags |= NativeMethods.FileFlagWriteThrough;
            IntPtr raw = NativeMethods.CreateFile(ToExtendedPath(path), desiredAccess, shareMode,
                IntPtr.Zero, disposition, flags, IntPtr.Zero);
            if (raw == NativeMethods.InvalidHandleValue)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateFileW failed: " + path);
            SafeFileHandle handle = new SafeFileHandle(raw, true);
            try
            {
                FileStream result = new FileStream(handle, access, bufferSize, false);
                if (mode == FileMode.Append) result.Seek(0, SeekOrigin.End);
                return result;
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

    }

    internal enum PortableArchitecture
    {
        Unknown,
        X86,
        X64,
        Arm,
        Arm64
    }

    internal static class ArchitectureInfo
    {
        private const ushort ImageFileMachineI386 = 0x014c;
        private const ushort ImageFileMachineArm = 0x01c4;
        private const ushort ImageFileMachineAmd64 = 0x8664;
        private const ushort ImageFileMachineArm64 = 0xAA64;
        private const ushort ProcessorArchitectureIntel = 0;
        private const ushort ProcessorArchitectureArm = 5;
        private const ushort ProcessorArchitectureAmd64 = 9;
        private const ushort ProcessorArchitectureArm64 = 12;

        internal static PortableArchitecture Current
        {
            get
            {
                try
                {
                    ushort processMachine;
                    ushort nativeMachine;
                    if (NativeMethods.IsWow64Process2(NativeMethods.GetCurrentProcess(),
                        out processMachine, out nativeMachine))
                    {
                        ushort machine = nativeMachine == 0 ? processMachine : nativeMachine;
                        PortableArchitecture fromMachine = FromMachine(machine);
                        if (fromMachine != PortableArchitecture.Unknown) return fromMachine;
                    }
                }
                catch (EntryPointNotFoundException) { }
                catch (DllNotFoundException) { }
                catch (BadImageFormatException) { }

                try
                {
                    NativeMethods.SYSTEM_INFO info;
                    NativeMethods.GetNativeSystemInfo(out info);
                    PortableArchitecture fromSystem = FromProcessorArchitecture(info.wProcessorArchitecture);
                    if (fromSystem != PortableArchitecture.Unknown) return fromSystem;
                }
                catch (EntryPointNotFoundException) { }
                catch (DllNotFoundException) { }
                catch (BadImageFormatException) { }
                return Environment.Is64BitOperatingSystem ? PortableArchitecture.X64 : PortableArchitecture.X86;
            }
        }

        internal static string Name
        {
            get { return NameOf(Current); }
        }

        internal static string NameOf(PortableArchitecture architecture)
        {
            switch (architecture)
            {
                case PortableArchitecture.X86: return "x86";
                case PortableArchitecture.X64: return "x64";
                case PortableArchitecture.Arm: return "arm";
                case PortableArchitecture.Arm64: return "arm64";
                default: return "unknown";
            }
        }

        internal static PortableArchitecture ParseName(string name)
        {
            if (string.Equals(name, "x86", StringComparison.OrdinalIgnoreCase)) return PortableArchitecture.X86;
            if (string.Equals(name, "x64", StringComparison.OrdinalIgnoreCase)) return PortableArchitecture.X64;
            if (string.Equals(name, "arm", StringComparison.OrdinalIgnoreCase)) return PortableArchitecture.Arm;
            if (string.Equals(name, "arm64", StringComparison.OrdinalIgnoreCase)) return PortableArchitecture.Arm64;
            return PortableArchitecture.Unknown;
        }

        internal static bool HasOfficialDesktopPayload(PortableArchitecture architecture)
        {
            return architecture == PortableArchitecture.X64 || architecture == PortableArchitecture.Arm64;
        }

        internal static PortableArchitecture FromMachine(ushort machine)
        {
            switch (machine)
            {
                case ImageFileMachineI386: return PortableArchitecture.X86;
                case ImageFileMachineAmd64: return PortableArchitecture.X64;
                case ImageFileMachineArm: return PortableArchitecture.Arm;
                case ImageFileMachineArm64: return PortableArchitecture.Arm64;
                default: return PortableArchitecture.Unknown;
            }
        }

        private static PortableArchitecture FromProcessorArchitecture(ushort architecture)
        {
            switch (architecture)
            {
                case ProcessorArchitectureIntel: return PortableArchitecture.X86;
                case ProcessorArchitectureAmd64: return PortableArchitecture.X64;
                case ProcessorArchitectureArm: return PortableArchitecture.Arm;
                case ProcessorArchitectureArm64: return PortableArchitecture.Arm64;
                default: return PortableArchitecture.Unknown;
            }
        }

        internal static bool IsMachineCompatible(string executable, PortableArchitecture expected)
        {
            try
            {
                using (FileStream stream = File.OpenRead(executable))
                using (BinaryReader reader = new BinaryReader(stream))
                {
                    if (stream.Length < 64) return false;
                    stream.Seek(0x3c, SeekOrigin.Begin);
                    int peOffset = reader.ReadInt32();
                    if (peOffset < 0 || peOffset > stream.Length - 6) return false;
                    stream.Seek(peOffset + 4, SeekOrigin.Begin);
                    ushort machine = reader.ReadUInt16();
                    return FromMachine(machine) == expected;
                }
            }
            catch { return false; }
        }

        internal static bool IsLauncherFileName(string name)
        {
            return string.Equals(name, "CodexPortable.exe", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(name, "CodexPortable.x86.exe", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(name, "CodexPortable.x64.exe", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(name, "CodexPortable.arm.exe", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(name, "CodexPortable.arm64.exe", StringComparison.OrdinalIgnoreCase);
        }
    }

    internal sealed class PortableLayout
    {
        internal string Root;
        internal string DataRoot;
        internal PortableArchitecture Architecture;
        internal string ArchitectureName;
        internal string AppVariantRoot;
        internal string CurrentApp;
        internal string OfficialAppExe;
        internal string AppExe;
        internal string Resources;
        internal string CodexExe;
        internal string Profile;
        internal string CodexHome;
        internal string SqliteHome;
        internal string ElectronData;
        internal string Home;
        internal string AppData;
        internal string LocalAppData;
        internal string LocalAppDataLow;
        internal string Temp;
        internal string XdgConfig;
        internal string XdgCache;
        internal string XdgData;
        internal string XdgState;
        internal string Runtime;
        internal string Secrets;
        internal string Logs;
        internal string Updates;
        internal string ReleaseDescriptor;
        internal string VaultFile;
        internal string PlainKeyFile;
        internal string AuthFile;
        internal string EphemeralMarker;
        internal string AuthBackup;
        internal string ConfigFile;
        internal string GlobalStateFile;
        internal string GlobalStateBackup;
        internal string BaseUrlFile;
        internal string ModelFile;
        internal string LanguageFile;
        internal string Downloads;
        internal string ChromiumCache;
        internal string CrashDumps;
        internal string Tools;
        internal string Packages;
        internal string CommonPackage;
        internal string BundledDesktopPackage;
        internal string HostScratchRoot;
        internal string HostTemp;
        internal string HostXdgCache;
        internal string HostChromiumCache;
        internal string HostDotnetBundle;
        internal string HostNpmCache;
        internal string HostPipCache;
        internal string HostUvCache;

        internal static PortableLayout FromExecutable(string rootOverride = null)
        {
            string exe = Assembly.GetExecutingAssembly().Location;
            string root = string.IsNullOrEmpty(rootOverride) ?
                Path.GetFullPath(Path.GetDirectoryName(exe)) : Path.GetFullPath(rootOverride);
            if (!Directory.Exists(root)) throw new DirectoryNotFoundException("Portable root is missing: " + root);
            PortableLayout p = new PortableLayout();
            p.Root = root;
            p.DataRoot = Path.Combine(root, "CodexData");
            p.Tools = Path.Combine(p.DataRoot, "tools");
            p.Packages = Path.Combine(p.DataRoot, "packages");
            p.Architecture = ArchitectureInfo.Current;
            p.ArchitectureName = ArchitectureInfo.NameOf(p.Architecture);
            p.AppVariantRoot = p.Architecture == PortableArchitecture.X64 ?
                Path.Combine(p.DataRoot, "app") :
                Path.Combine(p.Tools, "desktop-payloads", p.ArchitectureName);
            p.CurrentApp = Path.Combine(p.AppVariantRoot, "current");
            // Keep the official MSIX payload name for signature/update compatibility,
            // but run a byte-identical Codex-named copy so the portable process is
            // distinguishable from an installed ChatGPT/Codex package.
            p.OfficialAppExe = Path.Combine(p.CurrentApp, "ChatGPT.exe");
            p.AppExe = Path.Combine(p.CurrentApp, PortableBranding.DesktopExecutableName);
            p.Resources = Path.Combine(p.CurrentApp, "resources");
            p.CodexExe = Path.Combine(p.Resources, "codex.exe");
            p.Profile = Path.Combine(p.DataRoot, "data", "profile");
            p.CodexHome = Path.Combine(p.Profile, ".codex");
            p.SqliteHome = Path.Combine(p.CodexHome, "sqlite");
            p.ElectronData = Path.Combine(p.Profile, "electron");
            // Keep homedir at Profile so Codex's default ~/.cache runtime path is portable.
            p.Home = p.Profile;
            p.AppData = Path.Combine(p.Profile, "appdata", "roaming");
            p.LocalAppData = Path.Combine(p.Profile, "appdata", "local");
            p.LocalAppDataLow = Path.Combine(p.Profile, "appdata", "locallow");
            p.Temp = Path.Combine(p.Profile, "temp");
            p.XdgConfig = Path.Combine(p.Profile, "xdg", "config");
            p.XdgCache = Path.Combine(p.Profile, "xdg", "cache");
            p.XdgData = Path.Combine(p.Profile, "xdg", "data");
            p.XdgState = Path.Combine(p.Profile, "xdg", "state");
            p.Runtime = Path.Combine(p.Profile, ".cache", "codex-runtimes", "codex-primary-runtime");
            p.CommonPackage = Path.Combine(p.Packages, "LFPortable-common.zip");
            p.BundledDesktopPackage = Path.Combine(p.Packages,
                "LFPortable-" + p.ArchitectureName + ".msix");
            p.Secrets = Path.Combine(p.DataRoot, "data", "secrets");
            p.Logs = Path.Combine(p.DataRoot, "logs");
            p.Updates = Path.Combine(p.DataRoot, "updates");
            p.ReleaseDescriptor = Path.Combine(p.DataRoot, "portable-release.json");
            p.VaultFile = Path.Combine(p.Secrets, "api-key.vault");
            p.PlainKeyFile = Path.Combine(p.Secrets, "api-key.txt");
            p.AuthFile = Path.Combine(p.CodexHome, "auth.json");
            p.EphemeralMarker = Path.Combine(p.Secrets, "ephemeral-auth.json");
            p.AuthBackup = Path.Combine(p.Secrets, "auth.previous.json");
            p.ConfigFile = Path.Combine(p.CodexHome, "config.toml");
            p.GlobalStateFile = Path.Combine(p.CodexHome, ".codex-global-state.json");
            p.GlobalStateBackup = p.GlobalStateFile + ".bak";
            p.BaseUrlFile = Path.Combine(p.DataRoot, "data", "config", "custom-api-url.txt");
            p.ModelFile = Path.Combine(p.DataRoot, "data", "config", "custom-model.txt");
            p.LanguageFile = Path.Combine(p.DataRoot, "data", "config", "launcher-language.txt");
            p.Downloads = Path.Combine(p.DataRoot, "data", "downloads");
            p.ChromiumCache = Path.Combine(p.Profile, "cache", "chromium");
            p.CrashDumps = Path.Combine(p.Logs, "crash-dumps");
            string hostLocalAppData = Environment.GetFolderPath(
                Environment.SpecialFolder.LocalApplicationData);
            p.HostScratchRoot = Path.Combine(hostLocalAppData, "LFPortable", "scratch",
                "session-" + Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture) + "-" + Guid.NewGuid().ToString("N"));
            p.HostTemp = Path.Combine(p.HostScratchRoot, "temp");
            p.HostXdgCache = Path.Combine(p.HostScratchRoot, "xdg-cache");
            p.HostChromiumCache = Path.Combine(p.HostScratchRoot, "chromium-cache");
            p.HostDotnetBundle = Path.Combine(p.HostScratchRoot, "dotnet-bundle");
            p.HostNpmCache = Path.Combine(p.HostScratchRoot, "npm-cache");
            p.HostPipCache = Path.Combine(p.HostScratchRoot, "pip-cache");
            p.HostUvCache = Path.Combine(p.HostScratchRoot, "uv-cache");
            return p;
        }

        internal void EnsureDirectories()
        {
            string[] dirs = new string[] {
                DataRoot, Path.Combine(DataRoot, "app"), Profile, CodexHome, SqliteHome,
                ElectronData, Home, AppData, LocalAppData, LocalAppDataLow, Temp,
                XdgConfig, XdgCache, XdgData, XdgState, Secrets, Logs, Updates,
                Path.Combine(Profile, "cache"), Path.Combine(Profile, "dotnet"),
                Path.Combine(Profile, "nuget"), Path.Combine(Profile, "gh"),
                Path.Combine(Profile, "npm"), Path.Combine(Profile, "pip"),
                Path.Combine(Profile, "cargo"), Path.Combine(Profile, "rustup")
                , Path.Combine(DataRoot, "data", "config"), Downloads, ChromiumCache, CrashDumps, Tools,
                Packages,
                AppVariantRoot
            };
            for (int i = 0; i < dirs.Length; i++)
                IOUtil.EnsureDirectoryWithinNoReparse(dirs[i], Root);
        }

        internal void EnsureConfig()
        {
            ProviderConfiguration.WriteDeterministicConfig(this);
        }

        internal void EnsureOnboardingSuppressed()
        {
            PortableOnboarding.EnsureSuppressed(this);
        }
    }

    internal enum FirstLaunchPreparationStage
    {
        ValidatingCommonPackage,
        ExtractingCommonRuntime,
        VerifyingCommonRuntime,
        InstallingCommonRuntime,
        CommonRuntimeReady,
        ValidatingDesktopPackage,
        ExtractingDesktopPackage,
        VerifyingAndBrandingDesktop,
        DesktopPayloadReady,
        VerifyingInstalledDesktop,
        VerifyingPluginCache,
        ValidatingHostExecutionImage,
        CopyingHostExecutionImage,
        HostExecutionImageReady,
        StartingDesktop,
        ConfirmingDesktopStart,
        DesktopStarted
    }

    internal sealed class FirstLaunchProgress
    {
        internal FirstLaunchPreparationStage Stage;
        internal long CompletedBytes;
        internal long TotalBytes;
        internal int CompletedFiles;
        internal int TotalFiles;

        internal FirstLaunchProgress(FirstLaunchPreparationStage stage)
            : this(stage, 0, 0, 0, 0)
        {
        }

        internal FirstLaunchProgress(FirstLaunchPreparationStage stage,
            long completedBytes, long totalBytes, int completedFiles, int totalFiles)
        {
            Stage = stage;
            CompletedBytes = completedBytes;
            TotalBytes = totalBytes;
            CompletedFiles = completedFiles;
            TotalFiles = totalFiles;
        }
    }

    internal static class PortableBundle
    {
        private const long MaximumExpandedBytes = 4L * 1024L * 1024L * 1024L;
        private const int MaximumEntries = 100000;
        private const int ExtractionTimeoutMinutes = 45;
        private const int ProgressReportIntervalMilliseconds = 125;
        private static readonly string[] CommonRoots = new string[] {
            "tools/dotnet",
            "tools/gh",
            "data/profile/.cache/codex-runtimes",
            "data/profile/.codex/offline-marketplaces"
        };

        private sealed class ActivatedRoot
        {
            internal string Destination;
            internal string Backup;
            internal bool ExistingMoved;
            internal bool NewMoved;
        }

        internal static bool HasInstallPackages(PortableLayout layout)
        {
            return File.Exists(layout.CommonPackage) && File.Exists(layout.BundledDesktopPackage);
        }

        internal static bool CommonPayloadComplete(PortableLayout layout)
        {
            return File.Exists(Path.Combine(layout.Tools, "dotnet", "dotnet.exe")) &&
                (File.Exists(Path.Combine(layout.Tools, "gh", "bin", "gh.exe")) ||
                    File.Exists(Path.Combine(layout.Tools, "gh", "gh.exe"))) &&
                File.Exists(Path.Combine(layout.Runtime, "dependencies", "node", "bin", "node.exe")) &&
                File.Exists(Path.Combine(layout.Runtime, "dependencies", "python", "python.exe")) &&
                File.Exists(Path.Combine(layout.Runtime, "dependencies", "native", "git", "cmd", "git.exe")) &&
                File.Exists(Path.Combine(layout.CodexHome, "offline-marketplaces", "openai-primary-runtime",
                    ".agents", "plugins", "marketplace.json"));
        }

        internal static void EnsureReady(PortableLayout layout)
        {
            EnsureReady(layout, null);
        }

        internal static void EnsureReady(PortableLayout layout,
            Action<FirstLaunchProgress> progress)
        {
            EnsureCommonPayload(layout, progress);
            if (!File.Exists(layout.OfficialAppExe))
                EnsureDesktopPayload(layout, progress);
        }

        internal static void EnsureCommonPayload(PortableLayout layout)
        {
            EnsureCommonPayload(layout, null);
        }

        internal static void EnsureCommonPayload(PortableLayout layout,
            Action<FirstLaunchProgress> progress)
        {
            if (CommonPayloadComplete(layout)) return;
            layout.EnsureDirectories();
            Mutex mutation = PortableProcess.AcquireMutationMutex(layout, 0);
            if (mutation == null)
                throw new IOException("Another portable installation or repair is in progress.");
            try
            {
                if (CommonPayloadComplete(layout)) return;
                if (PortableProcess.IsDesktopRunning(layout))
                    throw new IOException("Common runtime installation is blocked while Codex Desktop is running.");
                if (!File.Exists(layout.CommonPackage))
                    throw new FileNotFoundException("The bundled common runtime package is missing.", layout.CommonPackage);
                if (progress != null) progress(new FirstLaunchProgress(FirstLaunchPreparationStage.ValidatingCommonPackage));
                CommonArchiveInfo archiveInfo = ValidateCommonArchive(layout.CommonPackage);
                DriveInfo drive = new DriveInfo(Path.GetPathRoot(layout.DataRoot));
                if (drive.IsReady && drive.AvailableFreeSpace < archiveInfo.ExpandedBytes + 512L * 1024L * 1024L)
                    throw new IOException("Insufficient free space for the common portable runtime.");
                if (progress != null) progress(new FirstLaunchProgress(
                    FirstLaunchPreparationStage.ExtractingCommonRuntime, 0,
                    archiveInfo.ExpandedBytes, 0, archiveInfo.FileCount));
                InstallCommonArchive(layout, archiveInfo, progress);
                if (!CommonPayloadComplete(layout))
                    throw new InvalidDataException("The installed common runtime is incomplete.");
                if (progress != null) progress(new FirstLaunchProgress(FirstLaunchPreparationStage.CommonRuntimeReady));
            }
            finally { PortableProcess.ReleaseMutationMutex(mutation); }
        }

        internal static void EnsureDesktopPayload(PortableLayout layout)
        {
            EnsureDesktopPayload(layout, null);
        }

        internal static void EnsureDesktopPayload(PortableLayout layout,
            Action<FirstLaunchProgress> progress)
        {
            if (File.Exists(layout.OfficialAppExe)) return;
            if (!ArchitectureInfo.HasOfficialDesktopPayload(layout.Architecture))
                throw new PlatformNotSupportedException("No desktop package is available for this Windows architecture.");
            if (!File.Exists(layout.BundledDesktopPackage))
                throw new FileNotFoundException("The bundled desktop package is missing.", layout.BundledDesktopPackage);
            Mutex mutation = PortableProcess.AcquireMutationMutex(layout, 0);
            if (mutation == null)
                throw new IOException("Another portable installation or repair is in progress.");
            try
            {
                if (File.Exists(layout.OfficialAppExe)) return;
                if (PortableProcess.IsDesktopRunning(layout))
                    throw new IOException("Desktop installation is blocked while Codex Desktop is running.");
                AppUpdater.StageVerifiedReleasePayload(layout, layout.BundledDesktopPackage,
                    layout.Architecture, progress);
                // The caller always revalidates the installed tree immediately
                // before launch, after this mutation lock has been released.
            }
            finally { PortableProcess.ReleaseMutationMutex(mutation); }
        }

        private sealed class CommonArchiveInfo
        {
            internal long ExpandedBytes;
            internal int FileCount;
            internal Dictionary<string, long> Files;
        }

        internal sealed class ExecutionCommonArchiveInfo
        {
            internal long ExpandedBytes;
            internal int FileCount;
        }

        private sealed class ExecutionCommonRoot
        {
            internal string ArchiveRoot;
            internal string DestinationRoot;
        }

        // The local image contains only executables and runtimes.  Profile data
        // and offline marketplace content continue to live on the portable
        // volume, even while the program itself runs from the fixed disk.
        private static readonly ExecutionCommonRoot[] ExecutionCommonRoots = new ExecutionCommonRoot[] {
            new ExecutionCommonRoot { ArchiveRoot = "tools/dotnet", DestinationRoot = "tools/dotnet" },
            new ExecutionCommonRoot { ArchiveRoot = "tools/gh", DestinationRoot = "tools/gh" },
            new ExecutionCommonRoot {
                ArchiveRoot = "data/profile/.cache/codex-runtimes/codex-primary-runtime",
                DestinationRoot = "runtime"
            }
        };

        internal static ExecutionCommonArchiveInfo InspectExecutionImageArchive(string archivePath)
        {
            using (FileStream stream = new FileStream(archivePath, FileMode.Open, FileAccess.Read,
                FileShare.Read, 1024 * 1024, FileOptions.SequentialScan))
                return InspectExecutionImageArchive(stream);
        }

        internal static ExecutionCommonArchiveInfo InspectExecutionImageArchive(Stream archiveStream)
        {
            return CreateExecutionCommonArchiveInfo(ValidateCommonArchive(archiveStream));
        }

        internal static void ExtractExecutionImageArchive(string archivePath, string staging,
            ExecutionCommonArchiveInfo expected, Action<long, long, int, int> progress)
        {
            using (FileStream stream = new FileStream(archivePath, FileMode.Open, FileAccess.Read,
                FileShare.Read, 1024 * 1024, FileOptions.SequentialScan))
                ExtractExecutionImageArchive(stream, staging, expected, progress);
        }

        internal static void ExtractExecutionImageArchive(Stream archiveStream, string staging,
            ExecutionCommonArchiveInfo expected, Action<long, long, int, int> progress)
        {
            if (expected == null) throw new ArgumentNullException("expected");
            CommonArchiveInfo current = ValidateCommonArchive(archiveStream);
            ExecutionCommonArchiveInfo actual = CreateExecutionCommonArchiveInfo(current);
            if (actual.ExpandedBytes != expected.ExpandedBytes || actual.FileCount != expected.FileCount)
                throw new InvalidDataException("The common runtime package changed after verification.");
            AppUpdater.ExtractZipArchive(archiveStream, staging, expected.ExpandedBytes,
                expected.FileCount, MaximumExpandedBytes, MaximumEntries, progress,
                delegate(ZipArchiveEntry entry, bool directory)
                {
                    string relative = NormalizeArchivePath(entry.FullName);
                    return MapExecutionCommonPath(relative, directory);
                });
            AssertNoReparsePoints(staging);
            AssertExecutionCommonFiles(staging);
        }

        private static ExecutionCommonArchiveInfo CreateExecutionCommonArchiveInfo(CommonArchiveInfo archive)
        {
            if (archive == null) throw new ArgumentNullException("archive");
            long expandedBytes = 0;
            int fileCount = 0;
            foreach (KeyValuePair<string, long> file in archive.Files)
            {
                if (MapExecutionCommonPath(file.Key, false) == null) continue;
                if (file.Value < 0 || file.Value > MaximumExpandedBytes - expandedBytes)
                    throw new InvalidDataException("The execution-image common runtime exceeds its byte limit.");
                expandedBytes += file.Value;
                fileCount++;
            }
            if (expandedBytes <= 0 || fileCount <= 0)
                throw new InvalidDataException("The common runtime package has no execution-image content.");
            return new ExecutionCommonArchiveInfo {
                ExpandedBytes = expandedBytes,
                FileCount = fileCount
            };
        }

        private static string MapExecutionCommonPath(string relative, bool directory)
        {
            for (int i = 0; i < ExecutionCommonRoots.Length; i++)
            {
                ExecutionCommonRoot root = ExecutionCommonRoots[i];
                if (string.Equals(relative, root.ArchiveRoot, StringComparison.OrdinalIgnoreCase))
                    return directory ? root.DestinationRoot : null;
                if (relative.StartsWith(root.ArchiveRoot + "/", StringComparison.OrdinalIgnoreCase))
                    return root.DestinationRoot + relative.Substring(root.ArchiveRoot.Length);
            }
            return null;
        }

        private static void AssertExecutionCommonFiles(string root)
        {
            string[] required = new string[] {
                "tools/dotnet/dotnet.exe",
                "runtime/dependencies/node/bin/node.exe",
                "runtime/dependencies/python/python.exe",
                "runtime/dependencies/native/git/cmd/git.exe"
            };
            for (int i = 0; i < required.Length; i++)
            {
                string path = Path.Combine(root,
                    required[i].Replace('/', Path.DirectorySeparatorChar));
                if (!File.Exists(path))
                    throw new InvalidDataException("Execution-image common runtime is missing: " + required[i]);
            }
            if (!File.Exists(Path.Combine(root, "tools", "gh", "bin", "gh.exe")) &&
                !File.Exists(Path.Combine(root, "tools", "gh", "gh.exe")))
                throw new InvalidDataException("Execution-image common runtime is missing GitHub CLI.");
        }

        private static CommonArchiveInfo ValidateCommonArchive(string archivePath)
        {
            using (FileStream stream = new FileStream(archivePath, FileMode.Open, FileAccess.Read, FileShare.Read))
                return ValidateCommonArchive(stream);
        }

        private static CommonArchiveInfo ValidateCommonArchive(Stream stream)
        {
            if (stream == null) throw new ArgumentNullException("stream");
            if (!stream.CanRead || !stream.CanSeek)
                throw new ArgumentException("The common runtime package stream must be readable and seekable.",
                    "stream");
            if (stream.Length < 100L * 1024L * 1024L || stream.Length > MaximumExpandedBytes)
                throw new InvalidDataException("The bundled common runtime package size is invalid.");
            stream.Position = 0;
            try
            {
                using (ZipArchive archive = new ZipArchive(stream, ZipArchiveMode.Read, true))
                    return ValidateCommonArchiveEntries(archive);
            }
            finally { stream.Position = 0; }
        }

        private static CommonArchiveInfo ValidateCommonArchiveEntries(ZipArchive archive)
        {
            HashSet<string> paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            Dictionary<string, long> files = new Dictionary<string, long>(StringComparer.Ordinal);
            long expandedBytes = 0;
            int count = 0;
            int fileCount = 0;
            foreach (ZipArchiveEntry entry in archive.Entries)
            {
                count++;
                if (count > MaximumEntries) throw new InvalidDataException("The common runtime package has too many entries.");
                string relative = NormalizeArchivePath(entry.FullName);
                if (relative.Length == 0) continue;
                bool directory = entry.FullName.EndsWith("/", StringComparison.Ordinal) ||
                    entry.FullName.EndsWith("\\", StringComparison.Ordinal);
                ValidateCommonArchivePath(relative, directory);
                if (!IsAllowedCommonPath(relative, directory))
                    throw new InvalidDataException("Unexpected common runtime package entry: " + relative);
                if (!paths.Add(relative))
                    throw new InvalidDataException("Duplicate common runtime package entry: " + relative);
                AssertCommonArchiveEntryAttributes(entry, directory);
                if (!directory)
                {
                    if (entry.Length < 0 || entry.Length > MaximumExpandedBytes - expandedBytes)
                        throw new InvalidDataException("The common runtime package expands beyond its limit.");
                    expandedBytes += entry.Length;
                    fileCount++;
                    files.Add(relative, entry.Length);
                }
            }
            if (count == 0 || expandedBytes < 500L * 1024L * 1024L)
                throw new InvalidDataException("The common runtime package is incomplete.");
            return new CommonArchiveInfo {
                ExpandedBytes = expandedBytes,
                FileCount = fileCount,
                Files = files
            };
        }

        internal static string NormalizeArchivePath(string path)
        {
            string normalized = (path ?? "").Replace('\\', '/');
            while (normalized.StartsWith("./", StringComparison.Ordinal)) normalized = normalized.Substring(2);
            normalized = normalized.TrimEnd('/');
            if (normalized.Length == 0) return "";
            if (normalized.StartsWith("/", StringComparison.Ordinal) || normalized.IndexOf(':') >= 0)
                throw new InvalidDataException("The common runtime package contains an absolute path.");
            string[] segments = normalized.Split('/');
            for (int i = 0; i < segments.Length; i++)
                if (segments[i].Length == 0 || segments[i] == "." || segments[i] == "..")
                    throw new InvalidDataException("The common runtime package contains an unsafe path.");
            return normalized;
        }

        internal static bool IsAllowedCommonPath(string path, bool directory)
        {
            // Plugin caches are derived after both trusted source packages are
            // installed. The unused F# SDK subtree is omitted to keep the GitHub
            // release below its hard asset-size limit without removing C#/VB.
            if (IsExcludedCommonPath(path)) return false;
            for (int i = 0; i < CommonRoots.Length; i++)
            {
                string root = CommonRoots[i];
                if (path.StartsWith(root + "/", StringComparison.OrdinalIgnoreCase)) return true;
                if (directory && (path.Equals(root, StringComparison.OrdinalIgnoreCase) ||
                    root.StartsWith(path + "/", StringComparison.OrdinalIgnoreCase))) return true;
            }
            return false;
        }

        private static bool IsExcludedCommonPath(string path)
        {
            const string sdkPrefix = "tools/dotnet/sdk/";
            if (!path.StartsWith(sdkPrefix, StringComparison.OrdinalIgnoreCase)) return false;
            int versionEnd = path.IndexOf('/', sdkPrefix.Length);
            if (versionEnd < 0 || versionEnd == path.Length - 1) return false;
            string relative = path.Substring(versionEnd + 1);
            return relative.Equals("FSharp", StringComparison.OrdinalIgnoreCase) ||
                relative.StartsWith("FSharp/", StringComparison.OrdinalIgnoreCase);
        }

        private static void ValidateCommonArchivePath(string relative, bool directory)
        {
            string[] segments = relative.Split('/');
            for (int i = 0; i < segments.Length; i++)
            {
                string segment = segments[i];
                if (segment.Length == 0 || segment == "." || segment == ".." ||
                    segment.Length > 255 || segment.EndsWith(".", StringComparison.Ordinal) ||
                    segment.EndsWith(" ", StringComparison.Ordinal) ||
                    segment.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
                    IsReservedCommonWindowsName(segment))
                    throw new InvalidDataException("The common runtime package contains an unsafe Windows path.");
                if (directory || i < segments.Length - 1)
                    for (int c = 0; c < segment.Length; c++) if (segment[c] > 127)
                        throw new InvalidDataException("The common runtime package contains a non-ASCII directory name.");
            }
        }

        private static bool IsReservedCommonWindowsName(string value)
        {
            string stem = value;
            int dot = stem.IndexOf('.');
            if (dot >= 0) stem = stem.Substring(0, dot);
            stem = stem.ToUpperInvariant();
            if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" ||
                stem == "CLOCK$") return true;
            return stem.Length == 4 &&
                (stem.StartsWith("COM", StringComparison.Ordinal) ||
                 stem.StartsWith("LPT", StringComparison.Ordinal)) &&
                stem[3] >= '1' && stem[3] <= '9';
        }

        private static void AssertCommonArchiveEntryAttributes(ZipArchiveEntry entry,
            bool directory)
        {
            uint attributes = unchecked((uint)entry.ExternalAttributes);
            uint unixType = (attributes >> 16) & 0xF000;
            if (unixType == 0xA000 || (attributes & 0x400) != 0)
                throw new InvalidDataException("Links are not allowed in the common runtime package.");
            if (unixType != 0 && unixType != 0x8000 && unixType != 0x4000)
                throw new InvalidDataException("The common runtime package contains an unsupported entry type.");
            if (directory && unixType == 0x8000)
                throw new InvalidDataException("A common runtime directory entry has a file type.");
            if (!directory && unixType == 0x4000)
                throw new InvalidDataException("A common runtime file entry has a directory type.");
        }

        private static void InstallCommonArchive(PortableLayout layout, CommonArchiveInfo archiveInfo,
            Action<FirstLaunchProgress> progress)
        {
            string transaction = Path.Combine(layout.Updates, "common-" +
                Guid.NewGuid().ToString("N").Substring(0, 10));
            string staging = Path.Combine(transaction, "stage");
            string backupRoot = Path.Combine(transaction, "backup");
            string failedRoot = Path.Combine(transaction, "failed");
            List<ActivatedRoot> activated = new List<ActivatedRoot>();
            bool retain = false;
            try
            {
                Directory.CreateDirectory(staging);
                ExtractCommonArchiveWithTar(layout.CommonPackage, staging, archiveInfo, progress);
                if (progress != null) progress(new FirstLaunchProgress(FirstLaunchPreparationStage.VerifyingCommonRuntime));
                AssertNoReparsePoints(staging);
                AssertCommonFiles(staging);
                if (progress != null) progress(new FirstLaunchProgress(FirstLaunchPreparationStage.InstallingCommonRuntime));
                for (int i = 0; i < CommonRoots.Length; i++)
                {
                    string relative = CommonRoots[i].Replace('/', Path.DirectorySeparatorChar);
                    string source = Path.Combine(staging, relative);
                    string destination = Path.Combine(layout.DataRoot, relative);
                    RejectReparseAncestry(destination, layout.DataRoot);
                    string backup = Path.Combine(backupRoot, relative);
                    Directory.CreateDirectory(Path.GetDirectoryName(destination));
                    Directory.CreateDirectory(Path.GetDirectoryName(backup));
                    ActivatedRoot record = new ActivatedRoot { Destination = destination, Backup = backup };
                    activated.Add(record);
                    if (Directory.Exists(destination))
                    {
                        Directory.Move(destination, backup);
                        record.ExistingMoved = true;
                    }
                    Directory.Move(source, destination);
                    record.NewMoved = true;
                }
                AssertCommonFiles(layout.DataRoot);
            }
            catch (Exception installationError)
            {
                Exception rollbackError = null;
                for (int i = activated.Count - 1; i >= 0; i--)
                {
                    ActivatedRoot record = activated[i];
                    try
                    {
                        if (record.NewMoved && Directory.Exists(record.Destination))
                        {
                            string failed = Path.Combine(failedRoot, i.ToString(CultureInfo.InvariantCulture));
                            Directory.CreateDirectory(Path.GetDirectoryName(failed));
                            Directory.Move(record.Destination, failed);
                        }
                        if (record.ExistingMoved && Directory.Exists(record.Backup))
                        {
                            Directory.CreateDirectory(Path.GetDirectoryName(record.Destination));
                            Directory.Move(record.Backup, record.Destination);
                        }
                    }
                    catch (Exception ex) { rollbackError = ex; }
                }
                if (rollbackError != null)
                {
                    retain = true;
                    throw new IOException("Common runtime installation failed and rollback needs inspection at " +
                        transaction + ".", new AggregateException(installationError, rollbackError));
                }
                throw;
            }
            finally
            {
                if (!retain && Directory.Exists(transaction))
                    IOUtil.DeleteDirectoryWithin(transaction, layout.Updates);
            }
        }

        private static void ExtractCommonArchiveWithTar(string archivePath, string staging,
            CommonArchiveInfo expected, Action<FirstLaunchProgress> progress)
        {
            string tar = FindSystemTar();
            using (FileStream source = new FileStream(archivePath, FileMode.Open, FileAccess.Read,
                FileShare.Read, 1024 * 1024, FileOptions.SequentialScan))
            using (ZipArchive archive = new ZipArchive(source, ZipArchiveMode.Read, false))
            {
                CommonArchiveInfo current = ValidateCommonArchiveEntries(archive);
                AssertSameCommonArchive(expected, current);

                object sync = new object();
                HashSet<string> reportedFiles = new HashSet<string>(StringComparer.Ordinal);
                StringBuilder diagnostics = new StringBuilder();
                Stopwatch reporter = Stopwatch.StartNew();
                long completedBytes = 0;
                int completedFiles = 0;
                Action<string> receiveLine = delegate(string line)
                {
                    if (string.IsNullOrEmpty(line)) return;
                    bool shouldReport = false;
                    long reportBytes = 0;
                    int reportFiles = 0;
                    if (line.StartsWith("x ", StringComparison.Ordinal))
                    {
                        string relative;
                        try { relative = NormalizeArchivePath(line.Substring(2)); }
                        catch { relative = string.Empty; }
                        long length;
                        lock (sync)
                        {
                            if (relative.Length != 0 && current.Files.TryGetValue(relative, out length) &&
                                reportedFiles.Add(relative))
                            {
                                completedBytes = checked(completedBytes + length);
                                completedFiles++;
                                if (reporter.ElapsedMilliseconds >= ProgressReportIntervalMilliseconds ||
                                    completedFiles == current.FileCount)
                                {
                                    shouldReport = true;
                                    reportBytes = completedBytes;
                                    reportFiles = completedFiles;
                                    reporter.Restart();
                                }
                            }
                        }
                    }
                    else
                    {
                        lock (sync)
                        {
                            if (diagnostics.Length < 32768)
                            {
                                if (diagnostics.Length != 0) diagnostics.Append(" | ");
                                diagnostics.Append(line);
                            }
                        }
                    }
                    if (shouldReport && progress != null)
                        progress(new FirstLaunchProgress(
                            FirstLaunchPreparationStage.ExtractingCommonRuntime,
                            reportBytes, current.ExpandedBytes, reportFiles, current.FileCount));
                };

                ProcessStartInfo info = new ProcessStartInfo();
                info.FileName = tar;
                info.Arguments = "-xvf " + IOUtil.QuoteArgument(archivePath) + " -C " +
                    IOUtil.QuoteArgument(staging);
                info.WorkingDirectory = staging;
                info.UseShellExecute = false;
                info.CreateNoWindow = true;
                info.RedirectStandardOutput = true;
                info.RedirectStandardError = true;
                using (Process process = new Process())
                {
                    process.StartInfo = info;
                    process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e)
                    {
                        if (e.Data != null) receiveLine(e.Data);
                    };
                    process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
                    {
                        if (e.Data != null) receiveLine(e.Data);
                    };
                    if (!process.Start()) throw new InvalidOperationException("Windows tar.exe could not start.");
                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();
                    if (!process.WaitForExit(ExtractionTimeoutMinutes * 60 * 1000))
                    {
                        try { process.Kill(); } catch { }
                        try { process.WaitForExit(); } catch { }
                        throw new TimeoutException("Common runtime extraction timed out.");
                    }
                    process.WaitForExit();
                    if (process.ExitCode != 0)
                    {
                        string message;
                        lock (sync) { message = diagnostics.ToString(); }
                        throw new InvalidDataException("Windows tar.exe rejected the common runtime package" +
                            (message.Length == 0 ? "." : ": " + message));
                    }
                }
                AppUpdater.AssertExtractedTreeNoReparse(staging, current.ExpandedBytes,
                    current.FileCount);
                if (progress != null) progress(new FirstLaunchProgress(
                    FirstLaunchPreparationStage.ExtractingCommonRuntime,
                    current.ExpandedBytes, current.ExpandedBytes,
                    current.FileCount, current.FileCount));
            }
        }

        private static void AssertSameCommonArchive(CommonArchiveInfo expected,
            CommonArchiveInfo actual)
        {
            if (expected == null || actual == null || expected.ExpandedBytes != actual.ExpandedBytes ||
                expected.FileCount != actual.FileCount || expected.Files.Count != actual.Files.Count)
                throw new InvalidDataException("The common runtime package changed before extraction.");
            foreach (KeyValuePair<string, long> file in expected.Files)
            {
                long length;
                if (!actual.Files.TryGetValue(file.Key, out length) || length != file.Value)
                    throw new InvalidDataException("The common runtime package changed before extraction.");
            }
        }

        private static string FindSystemTar()
        {
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            if (!Environment.Is64BitProcess && Environment.Is64BitOperatingSystem)
            {
                string native = Path.Combine(windows, "Sysnative", "tar.exe");
                if (File.Exists(native)) return native;
            }
            string system = Path.Combine(windows, "System32", "tar.exe");
            if (File.Exists(system)) return system;
            throw new FileNotFoundException("Windows tar.exe is required for common runtime extraction.", system);
        }

        private static void AssertCommonFiles(string root)
        {
            string[] required = new string[] {
                "tools/dotnet/dotnet.exe",
                "data/profile/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe",
                "data/profile/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe",
                "data/profile/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/git/cmd/git.exe",
                "data/profile/.codex/offline-marketplaces/openai-primary-runtime/.agents/plugins/marketplace.json"
            };
            for (int i = 0; i < required.Length; i++)
            {
                string path = Path.Combine(root, required[i].Replace('/', Path.DirectorySeparatorChar));
                if (!File.Exists(path)) throw new InvalidDataException("Common runtime is missing: " + required[i]);
            }
            if (!File.Exists(Path.Combine(root, "tools", "gh", "bin", "gh.exe")) &&
                !File.Exists(Path.Combine(root, "tools", "gh", "gh.exe")))
                throw new InvalidDataException("Common runtime is missing GitHub CLI.");
        }

        private static void AssertNoReparsePoints(string root)
        {
            AppUpdater.AssertExtractedTreeNoReparse(root);
        }

        private static void RejectReparseAncestry(string path, string root)
        {
            string current = Path.GetFullPath(path).TrimEnd('\\');
            string limit = Path.GetFullPath(root).TrimEnd('\\');
            if (!current.Equals(limit, StringComparison.OrdinalIgnoreCase) &&
                !current.StartsWith(limit + "\\", StringComparison.OrdinalIgnoreCase))
                throw new IOException("Common runtime destination is outside the portable root.");
            while (current.Length >= limit.Length)
            {
                if (Directory.Exists(current) &&
                    (new DirectoryInfo(current).Attributes & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("Common runtime destination is beneath a reparse point: " + current);
                if (current.Equals(limit, StringComparison.OrdinalIgnoreCase)) break;
                current = Path.GetDirectoryName(current);
                if (string.IsNullOrEmpty(current)) break;
            }
        }
    }

    internal static class PortableOnboarding
    {
        private const int MaxGlobalStateBytes = 4 * 1024 * 1024;
        private const string PersistedAtomStateKey = "electron-persisted-atom-state";
        private const string OnboardingOverrideKey = "electron:onboarding-override";
        private const string ProjectlessCompletedKey = "electron:onboarding-projectless-completed";
        private const string WelcomePendingKey = "electron:onboarding-welcome-pending";
        private const string SeenModelUpgradeListKey = "seen-model-upgrade-list";
        private const string LatestModelSeenKey = "latest-model-seen";
        private const string CurrentModelUpgrade = ProviderConfiguration.DefaultModel;
        private const string AgentModeByHostIdKey = "agent-mode-by-host-id";
        private const string LocalHostId = "local";
        // The official desktop enum calls the "config.toml" UI mode "custom".
        // Writing "config.toml" here would be rejected by the desktop schema.
        private const string ConfigTomlAgentMode = "custom";
        private const string EnabledReasoningEffortsKey = "enabled-reasoning-efforts";
        private const string KnowledgeWorkAnnouncementKey = "has-seen-knowledge-work-announcement";
        private const string FastModeAnnouncementKey = "has-seen-fast-mode-announcement";
        private const string WorkPluginsAnnouncementKey = "has-seen-work-plugins-announcement";
        private const string WalletAnnouncementKey = "wallet-onboarding-announcement-dismissed-v1";
        private static readonly string[] SupportedReasoningEfforts = new string[] {
            "low", "medium", "high", "xhigh", "max", "ultra"
        };

        internal static void EnsureSuppressed(PortableLayout layout)
        {
            Directory.CreateDirectory(layout.CodexHome);
            Dictionary<string, object> state = ReadWithBackup(layout.GlobalStateFile,
                layout.GlobalStateBackup);
            Dictionary<string, object> atoms = GetOrCreateObject(state, PersistedAtomStateKey);
            bool changed = SetIfDifferent(atoms, OnboardingOverrideKey, "app");
            changed |= SetIfDifferent(atoms, ProjectlessCompletedKey, true);
            changed |= SetIfDifferent(atoms, WelcomePendingKey, false);
            changed |= SetIfDifferent(atoms, KnowledgeWorkAnnouncementKey, true);
            changed |= SetIfDifferent(atoms, FastModeAnnouncementKey, true);
            changed |= SetIfDifferent(atoms, WorkPluginsAnnouncementKey, true);
            changed |= SetIfDifferent(atoms, WalletAnnouncementKey, true);

            object latestModel;
            if (atoms.TryGetValue(LatestModelSeenKey, out latestModel))
            {
                string legacyModel = latestModel as string;
                if (!string.IsNullOrEmpty(legacyModel))
                    changed |= EnsureStringInArray(atoms, SeenModelUpgradeListKey, legacyModel);
            }
            changed |= EnsureStringInArray(atoms, SeenModelUpgradeListKey, CurrentModelUpgrade);
            changed |= SetIfDifferent(atoms, LatestModelSeenKey, null);

            Dictionary<string, object> agentModes = GetOrCreateObject(atoms,
                AgentModeByHostIdKey);
            changed |= SetIfDifferent(agentModes, LocalHostId, ConfigTomlAgentMode);
            for (int i = 0; i < SupportedReasoningEfforts.Length; i++)
                changed |= EnsureStringInArray(atoms, EnabledReasoningEffortsKey,
                    SupportedReasoningEfforts[i]);

            JavaScriptSerializer serializer = CreateSerializer();
            string json = serializer.Serialize(state);
            if (Encoding.UTF8.GetByteCount(json) > MaxGlobalStateBytes)
                throw new InvalidDataException("Codex global state is too large after onboarding suppression.");

            if (changed || !FileTextEquals(layout.GlobalStateFile, json))
                IOUtil.AtomicWriteText(layout.GlobalStateFile, json);
            if (changed || !FileTextEquals(layout.GlobalStateBackup, json))
                IOUtil.AtomicWriteText(layout.GlobalStateBackup, json);

            if (!IsSuppressed(layout))
                throw new InvalidDataException("Codex onboarding suppression state failed verification.");
        }

        internal static bool IsSuppressed(PortableLayout layout)
        {
            try
            {
                if (!File.Exists(layout.GlobalStateFile)) return false;
                Dictionary<string, object> state = ReadObject(layout.GlobalStateFile);
                object value;
                if (!state.TryGetValue(PersistedAtomStateKey, out value)) return false;
                Dictionary<string, object> atoms = value as Dictionary<string, object>;
                if (atoms == null) return false;
                object overrideValue;
                object completedValue;
                object pendingValue;
                object latestModel;
                object announcementValue;
                object agentModeValue;
                Dictionary<string, object> agentModes;
                return atoms.TryGetValue(OnboardingOverrideKey, out overrideValue) &&
                    string.Equals(overrideValue as string, "app", StringComparison.Ordinal) &&
                    atoms.TryGetValue(ProjectlessCompletedKey, out completedValue) &&
                    completedValue is bool && (bool)completedValue &&
                    atoms.TryGetValue(WelcomePendingKey, out pendingValue) &&
                    pendingValue is bool && !(bool)pendingValue &&
                    atoms.TryGetValue(KnowledgeWorkAnnouncementKey, out announcementValue) &&
                    announcementValue is bool && (bool)announcementValue &&
                    atoms.TryGetValue(FastModeAnnouncementKey, out announcementValue) &&
                    announcementValue is bool && (bool)announcementValue &&
                    atoms.TryGetValue(WorkPluginsAnnouncementKey, out announcementValue) &&
                    announcementValue is bool && (bool)announcementValue &&
                    atoms.TryGetValue(WalletAnnouncementKey, out announcementValue) &&
                    announcementValue is bool && (bool)announcementValue &&
                    ContainsStringInArray(atoms, SeenModelUpgradeListKey, CurrentModelUpgrade) &&
                    atoms.TryGetValue(LatestModelSeenKey, out latestModel) && latestModel == null &&
                    atoms.TryGetValue(AgentModeByHostIdKey, out agentModeValue) &&
                    (agentModes = agentModeValue as Dictionary<string, object>) != null &&
                    agentModes.TryGetValue(LocalHostId, out agentModeValue) &&
                    string.Equals(agentModeValue as string, ConfigTomlAgentMode,
                        StringComparison.Ordinal) &&
                    ContainsAllStringsInArray(atoms, EnabledReasoningEffortsKey,
                        SupportedReasoningEfforts);
            }
            catch { return false; }
        }

        private static Dictionary<string, object> ReadWithBackup(string primary, string backup)
        {
            Exception primaryError = null;
            if (File.Exists(primary))
            {
                try { return ReadObject(primary); }
                catch (Exception ex) { primaryError = ex; }
            }
            if (File.Exists(backup))
            {
                try { return ReadObject(backup); }
                catch (Exception ex)
                {
                    throw new InvalidDataException("Codex global state and backup are invalid.",
                        primaryError ?? ex);
                }
            }
            if (primaryError != null)
                throw new InvalidDataException("Codex global state is invalid and has no usable backup.",
                    primaryError);
            return new Dictionary<string, object>(StringComparer.Ordinal);
        }

        private static Dictionary<string, object> ReadObject(string path)
        {
            FileInfo info = new FileInfo(path);
            if (info.Length <= 0 || info.Length > MaxGlobalStateBytes)
                throw new InvalidDataException("Codex global state size is invalid.");
            object parsed = CreateSerializer().DeserializeObject(File.ReadAllText(path, Encoding.UTF8));
            Dictionary<string, object> result = parsed as Dictionary<string, object>;
            if (result == null) throw new InvalidDataException("Codex global state is not a JSON object.");
            return result;
        }

        private static JavaScriptSerializer CreateSerializer()
        {
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = MaxGlobalStateBytes;
            return serializer;
        }

        private static Dictionary<string, object> GetOrCreateObject(
            Dictionary<string, object> parent, string key)
        {
            object value;
            if (!parent.TryGetValue(key, out value) || value == null)
            {
                Dictionary<string, object> created =
                    new Dictionary<string, object>(StringComparer.Ordinal);
                parent[key] = created;
                return created;
            }
            Dictionary<string, object> existing = value as Dictionary<string, object>;
            if (existing == null)
                throw new InvalidDataException("Codex persisted atom state is not a JSON object.");
            return existing;
        }

        private static bool SetIfDifferent(Dictionary<string, object> values, string key,
            object expected)
        {
            object current;
            if (values.TryGetValue(key, out current) && object.Equals(current, expected)) return false;
            values[key] = expected;
            return true;
        }

        private static bool EnsureStringInArray(Dictionary<string, object> values, string key,
            string expected)
        {
            object current;
            List<object> items = new List<object>();
            if (values.TryGetValue(key, out current) && current != null)
            {
                IEnumerable enumerable = current as IEnumerable;
                if (enumerable == null || current is string)
                    throw new InvalidDataException("Codex persisted atom array has an invalid type: " + key);
                foreach (object item in enumerable)
                {
                    items.Add(item);
                    if (string.Equals(item as string, expected, StringComparison.Ordinal))
                        return false;
                }
            }
            items.Add(expected);
            values[key] = items.ToArray();
            return true;
        }

        private static bool ContainsStringInArray(Dictionary<string, object> values, string key,
            string expected)
        {
            object current;
            if (!values.TryGetValue(key, out current) || current == null || current is string)
                return false;
            IEnumerable enumerable = current as IEnumerable;
            if (enumerable == null) return false;
            foreach (object item in enumerable)
                if (string.Equals(item as string, expected, StringComparison.Ordinal)) return true;
            return false;
        }

        private static bool ContainsAllStringsInArray(Dictionary<string, object> values,
            string key, string[] expected)
        {
            for (int i = 0; i < expected.Length; i++)
                if (!ContainsStringInArray(values, key, expected[i])) return false;
            return true;
        }

        private static bool FileTextEquals(string path, string expected)
        {
            return File.Exists(path) &&
                string.Equals(File.ReadAllText(path, Encoding.UTF8), expected,
                    StringComparison.Ordinal);
        }
    }

    internal static class PortableBranding
    {
        internal const string DesktopExecutableName = "CodexDesktop.exe";
        internal const string AppUserModelId = "OpenAI.Codex.USB";
        private const string DarkIconResource = "CodexPortable.Branding.TrayDark.ico";
        private const string LightIconResource = "CodexPortable.Branding.TrayLight.ico";

        internal static void InitializeProcessIdentity()
        {
            try { NativeMethods.SetCurrentProcessExplicitAppUserModelID(AppUserModelId); }
            catch { }
        }

        internal static Icon LoadLauncherIcon()
        {
            try
            {
                Icon icon = Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location);
                if (icon != null) return icon;
            }
            catch { }
            return (Icon)SystemIcons.Application.Clone();
        }

        internal static void EnsurePortablePayload(PortableLayout layout)
        {
            // The release pipeline prepares and verifies the payload before it is
            // published. Normal startup only verifies the payload and never
            // rewrites the 200+ MiB ASAR on a USB volume. Package activation is
            // the sole path that may prepare a desktop payload.
            string official = layout.OfficialAppExe;
            string alias = layout.AppExe;
            string resources = layout.Resources;
            if (!File.Exists(official))
                throw new FileNotFoundException("Official Codex Desktop payload is missing.", official);
            if (!File.Exists(alias))
                throw new FileNotFoundException("Prepared Codex Desktop executable is missing.", alias);
            if (!Directory.Exists(resources))
                throw new DirectoryNotFoundException("Codex Desktop resources are missing.");
            string[] requiredFiles = new string[] {
                Path.Combine(resources, "app.asar"),
                Path.Combine(resources, "codex-tray.ico"),
                Path.Combine(resources, "chatgpt-tray-dark.ico"),
                Path.Combine(resources, "chatgpt-tray-light.ico"),
                Path.Combine(resources, "icon-chatgpt.ico"),
                Path.Combine(resources, "icon.ico"),
                Path.Combine(resources, "owl-electron-app.json")
            };
            for (int i = 0; i < requiredFiles.Length; i++)
                if (!File.Exists(requiredFiles[i]))
                    throw new FileNotFoundException("Prepared portable branding file is missing.", requiredFiles[i]);
            if (!IsPrepared(layout))
                throw new InvalidDataException("Existing Codex Desktop payload is not an LF-prepared, updater-disabled payload.");
        }

        internal static void PreparePayload(string payloadRoot)
        {
            string official = Path.Combine(payloadRoot, "ChatGPT.exe");
            if (!File.Exists(official)) throw new FileNotFoundException("Official Codex Desktop payload is missing.", official);

            string alias = Path.Combine(payloadRoot, DesktopExecutableName);
            EnsureByteIdenticalCopy(official, alias);

            string resources = Path.Combine(payloadRoot, "resources");
            if (!Directory.Exists(resources)) throw new DirectoryNotFoundException("Codex Desktop resources are missing.");
            InstallEmbeddedIcon(DarkIconResource, Path.Combine(resources, "codex-tray.ico"));
            InstallEmbeddedIcon(DarkIconResource, Path.Combine(resources, "chatgpt-tray-dark.ico"));
            InstallEmbeddedIcon(LightIconResource, Path.Combine(resources, "chatgpt-tray-light.ico"));
            InstallEmbeddedIcon(DarkIconResource, Path.Combine(resources, "icon-chatgpt.ico"));
            InstallEmbeddedIcon(DarkIconResource, Path.Combine(resources, "icon.ico"));
            AsarPortableBranding.EnsurePatched(Path.Combine(resources, "app.asar"));
            PrepareOwlMetadata(Path.Combine(resources, "owl-electron-app.json"));
        }

        internal static bool IsPrepared(PortableLayout layout)
        {
            return IsPrepared(layout.CurrentApp);
        }

        internal static bool IsPrepared(string payloadRoot)
        {
            return HasPreparedPayloadState(payloadRoot);
        }

        private static bool HasPreparedPayloadState(string payloadRoot)
        {
            try
            {
                if (!FilesEqual(Path.Combine(payloadRoot, "ChatGPT.exe"),
                    Path.Combine(payloadRoot, DesktopExecutableName))) return false;
                string resources = Path.Combine(payloadRoot, "resources");
                byte[] dark = ReadEmbeddedResource(DarkIconResource);
                byte[] light = ReadEmbeddedResource(LightIconResource);
                try
                {
                    return FileEqualsBytes(Path.Combine(resources, "codex-tray.ico"), dark) &&
                        FileEqualsBytes(Path.Combine(resources, "chatgpt-tray-dark.ico"), dark) &&
                        FileEqualsBytes(Path.Combine(resources, "chatgpt-tray-light.ico"), light) &&
                        FileEqualsBytes(Path.Combine(resources, "icon-chatgpt.ico"), dark) &&
                        FileEqualsBytes(Path.Combine(resources, "icon.ico"), dark) &&
                        AsarPortableBranding.IsPrepared(Path.Combine(resources, "app.asar")) &&
                        IsOwlMetadataPrepared(Path.Combine(resources, "owl-electron-app.json"));
                }
                finally
                {
                    Array.Clear(dark, 0, dark.Length);
                    Array.Clear(light, 0, light.Length);
                }
            }
            catch { return false; }
        }

        private static void PrepareOwlMetadata(string path)
        {
            string hash = ReadOwlRuntimeHash(path);
            string json = "{\"packagedFrom\":\"portable-release\",\"runtimeArchiveSha\":\"" +
                hash + "\",\"runtimeName\":\"owl\"}\r\n";
            IOUtil.AtomicWriteText(path, json);
            if (!IsOwlMetadataPrepared(path))
                throw new InvalidDataException("Portable desktop metadata verification failed.");
        }

        private static bool IsOwlMetadataPrepared(string path)
        {
            try
            {
                Dictionary<string, object> metadata = ReadOwlMetadata(path);
                object packagedFrom;
                object runtimeName;
                object runtimeHash;
                return metadata.Count == 3 &&
                    metadata.TryGetValue("packagedFrom", out packagedFrom) &&
                    string.Equals(packagedFrom as string, "portable-release", StringComparison.Ordinal) &&
                    metadata.TryGetValue("runtimeName", out runtimeName) &&
                    string.Equals(runtimeName as string, "owl", StringComparison.Ordinal) &&
                    metadata.TryGetValue("runtimeArchiveSha", out runtimeHash) &&
                    IsSha256(runtimeHash as string);
            }
            catch { return false; }
        }

        private static string ReadOwlRuntimeHash(string path)
        {
            Dictionary<string, object> metadata = ReadOwlMetadata(path);
            object runtimeName;
            object runtimeHash;
            if (!metadata.TryGetValue("runtimeName", out runtimeName) ||
                !string.Equals(runtimeName as string, "owl", StringComparison.Ordinal) ||
                !metadata.TryGetValue("runtimeArchiveSha", out runtimeHash) ||
                !IsSha256(runtimeHash as string))
                throw new InvalidDataException("Desktop runtime metadata is unsupported.");
            return ((string)runtimeHash).ToLowerInvariant();
        }

        private static Dictionary<string, object> ReadOwlMetadata(string path)
        {
            if (!File.Exists(path)) throw new FileNotFoundException("Desktop runtime metadata is missing.", path);
            FileInfo info = new FileInfo(path);
            if (info.Length <= 0 || info.Length > 1024 * 1024)
                throw new InvalidDataException("Desktop runtime metadata size is invalid.");
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = 1024 * 1024;
            Dictionary<string, object> metadata = serializer.DeserializeObject(
                File.ReadAllText(path, new UTF8Encoding(false, true))) as Dictionary<string, object>;
            if (metadata == null) throw new InvalidDataException("Desktop runtime metadata is not a JSON object.");
            return metadata;
        }

        private static bool IsSha256(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length != 64) return false;
            for (int i = 0; i < value.Length; i++) if (!Uri.IsHexDigit(value[i])) return false;
            return true;
        }

        private static void EnsureByteIdenticalCopy(string source, string target)
        {
            if (FilesEqual(source, target)) return;
            byte[] bytes = File.ReadAllBytes(source);
            try
            {
                if (File.Exists(target)) File.SetAttributes(target, FileAttributes.Normal);
                IOUtil.AtomicWriteBytes(target, bytes);
            }
            finally { Array.Clear(bytes, 0, bytes.Length); }
            if (!FilesEqual(source, target)) throw new IOException("Codex-named desktop payload verification failed.");
        }

        private static void InstallEmbeddedIcon(string resourceName, string target)
        {
            byte[] bytes = ReadEmbeddedResource(resourceName);
            try
            {
                if (FileEqualsBytes(target, bytes)) return;
                if (File.Exists(target)) File.SetAttributes(target, FileAttributes.Normal);
                IOUtil.AtomicWriteBytes(target, bytes);
                if (!FileEqualsBytes(target, bytes)) throw new IOException("Portable icon verification failed.");
            }
            finally { Array.Clear(bytes, 0, bytes.Length); }
        }

        private static byte[] ReadEmbeddedResource(string resourceName)
        {
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName))
            {
                if (stream == null || stream.Length <= 0 || stream.Length > 1024 * 1024)
                    throw new InvalidDataException("Portable icon resource is missing or invalid.");
                byte[] bytes = new byte[(int)stream.Length];
                int offset = 0;
                while (offset < bytes.Length)
                {
                    int count = stream.Read(bytes, offset, bytes.Length - offset);
                    if (count == 0) throw new EndOfStreamException("Portable icon resource is truncated.");
                    offset += count;
                }
                return bytes;
            }
        }

        private static bool FilesEqual(string first, string second)
        {
            if (!File.Exists(first) || !File.Exists(second)) return false;
            FileInfo a = new FileInfo(first);
            FileInfo b = new FileInfo(second);
            if (a.Length != b.Length) return false;
            using (FileStream x = File.OpenRead(first))
            using (FileStream y = File.OpenRead(second)) return StreamsEqual(x, y);
        }

        private static bool FileEqualsBytes(string path, byte[] expected)
        {
            if (!File.Exists(path) || new FileInfo(path).Length != expected.Length) return false;
            using (FileStream stream = File.OpenRead(path))
            {
                byte[] buffer = new byte[8192];
                int offset = 0;
                try
                {
                    while (offset < expected.Length)
                    {
                        int count = stream.Read(buffer, 0, Math.Min(buffer.Length, expected.Length - offset));
                        if (count == 0) return false;
                        for (int i = 0; i < count; i++) if (buffer[i] != expected[offset + i]) return false;
                        offset += count;
                    }
                    return stream.ReadByte() == -1;
                }
                finally { Array.Clear(buffer, 0, buffer.Length); }
            }
        }

        private static bool StreamsEqual(Stream first, Stream second)
        {
            byte[] a = new byte[64 * 1024];
            byte[] b = new byte[64 * 1024];
            try
            {
                while (true)
                {
                    int countA = first.Read(a, 0, a.Length);
                    int countB = second.Read(b, 0, b.Length);
                    if (countA != countB) return false;
                    if (countA == 0) return true;
                    for (int i = 0; i < countA; i++) if (a[i] != b[i]) return false;
                }
            }
            finally
            {
                Array.Clear(a, 0, a.Length);
                Array.Clear(b, 0, b.Length);
            }
        }
    }

    internal static class AsarPortableBranding
    {
        private const string PackagePath = "package.json";
        private const string BuildJavaScriptPrefix = ".vite/build/";
        // The desktop bundle centralizes every Windows/Store/Sparkle updater
        // decision in this environment gate. Keep the replacement the same
        // byte length so the ASAR data offsets and integrity header remain
        // stable while the portable payload fails closed.
        private const string OfficialSparkleGateText =
            "p=e=>e.CODEX_SPARKLE_ENABLED===`false`";
        private static readonly string PortableSparkleGateText =
            "p=e=>!0".PadRight(OfficialSparkleGateText.Length);
        private const string OfficialWorkerSparkleGateText =
            "jhe=e=>e.CODEX_SPARKLE_ENABLED===`false`";
        private static readonly string PortableWorkerSparkleGateText =
            "jhe=e=>!0".PadRight(OfficialWorkerSparkleGateText.Length);
        private const string OfficialUpdateMenuHandlerText =
            "}),enabled:!0,click:()=>{O5().info(`Check for updates requested via menu.`),u.checkForUpdates().then(()=>{if(u.hasUpdater())return;let e=u.getUnavailableReason()??`unknown`;O5().warning(`Desktop updater unavailable; init likely skipped.`,{safe:{reason:e},sensitive:{}}),l.dialog.showMessageBox({type:`info`,title:`Updates Unavailable`,message:`Automatic updates are unavailable right now.`,detail:`Updater initialization skipped: ${e}`})})}}";
        private static readonly string PortableUpdateMenuHandlerText =
            "}),visible:!1,click:()=>{}}".PadRight(OfficialUpdateMenuHandlerText.Length);
        private const string OfficialRecoveryStateText =
            "i=J(hbr);switch(n??i)";
        private static readonly string PortableRecoveryStateText =
            ("i=null;").PadRight(OfficialRecoveryStateText.Length - "switch(n??i)".Length) +
            "switch(n??i)";
        private const string OfficialUpdaterIdleStateText =
            "updateLifecycleState=`idle`";
        private const string PortableUpdaterIdleStateText =
            "updateLifecycleState=`none`";
        // Workspace dependencies have their own updater, independent of the
        // desktop Sparkle/Windows updater.  It polls the configured runtime
        // release and can rewrite the plugin marketplace/cache in the middle
        // of a portable session.  Keep the byte-preserving replacements tied
        // to the exact upstream implementation so an unrecognized bundle
        // fails closed instead of being partially patched.
        private const string OfficialRuntimeStaticDisabledReasonText =
            "getStaticDisabledReason(){return this.options.hostId===`local`?this.options.sharedObjectRepository?.get(`codex_runtimes_config`)==null?`runtime-config-missing`:c0(this.options.sharedObjectRepository?.get(`statsig_default_enable_features`))?null:`feature-gate-disabled`:`not-local-host`";
        private static readonly string PortableRuntimeStaticDisabledReasonText =
            "getStaticDisabledReason(){return`portable-runtime-updates-disabled`".
                PadRight(OfficialRuntimeStaticDisabledReasonText.Length);
        private const string OfficialRuntimeInstallGuardText =
            "async#e(e){if(!await this.isWorkspaceDependenciesFeatureEnabled(e))throw Error(`Codex dependencies are disabled in settings.`)}";
        private static readonly string PortableRuntimeInstallGuardText =
            "async#e(e){throw Error(`portable-runtime-updates-disabled`)}".
                PadRight(OfficialRuntimeInstallGuardText.Length);
        private const string OfficialRuntimeDebugMenuGateText =
            "E=o?(0,Q.jsx)(wr,{align:`end`,triggerButton:";
        private const string PortableRuntimeDebugMenuGateText =
            "E=0?(0,Q.jsx)(wr,{align:`end`,triggerButton:";
        private const string WorkspaceDependenciesSettingsFunctionText =
            "function pr(e){let t=(0,Or.c)(98),";
        private const string OfficialWorkspaceDependenciesSettingsPanelGateText =
            "a&&n.kind===`local`?(0,$.jsx)(fr,{hostId:t}):null";
        private const string PortableWorkspaceDependenciesSettingsPanelGateText =
            "0&&n.kind===`local`?(0,$.jsx)(fr,{hostId:t}):null";
        // Codex normally collapses a config.toml permission pair into a built-in
        // mode when their effective permissions are identical. LF keeps the
        // config-backed mode explicit so the UI and the execution source agree.
        private const string OfficialConfigModeEquivalenceText =
            "y=v?`guardian-approvals`:g";
        private static readonly string PortableConfigModeEquivalenceText =
            "y=null".PadRight(OfficialConfigModeEquivalenceText.Length);
        private const string OfficialConfigModeShortLabelText =
            "id:`composer.permissionsDropdown.custom.shortLabel`,defaultMessage:`Custom`,description:`Short trigger label for the custom approvals mode`";
        private static readonly string PortableConfigModeShortLabelText =
            "id:`composer.permissionsDropdown.custom.configToml`,defaultMessage:`config.toml`,description:`Trigger label for the custom approvals mode`".
                PadRight(OfficialConfigModeShortLabelText.Length);
        private const string OfficialConfigModeOptionLabelText =
            "id:`composer.permissionsDropdown.custom.optionLabel`,defaultMessage:`Custom (config.toml)`,description:`Dropdown option for the custom permissions mode`";
        private static readonly string PortableConfigModeOptionLabelText =
            "id:`composer.permissionsDropdown.custom.configLabel`,defaultMessage:`config.toml`,description:`Dropdown option for the custom permissions mode`".
                PadRight(OfficialConfigModeOptionLabelText.Length);
        // The current official bundle renders both labels in the picker and
        // in the composer control.  Every rendering must identify config.toml
        // as its source; a changed count is an upstream compatibility break.
        private const int ConfigModeShortLabelExpectedOccurrences = 2;
        private const int ConfigModeOptionLabelExpectedOccurrences = 2;
        // The desktop evaluates these bundled tools in both WebView eligibility
        // and the main-process reconciler. LF supplies the same local runtimes
        // without ChatGPT authentication, so both gates must keep the three
        // plugins available and let their local capability checks decide at use time.
        private const string OfficialBrowserPluginAvailabilityText =
            "function ami({isBrowserAgentGateEnabled:e,isBrowserSidebarEnabled:t,isBrowserUseEnabled:n,isLoading:r,runCodexInWsl:i,windowType:a}){return a===`chrome-extension`?`window-type-disabled`:r?`loading`:t?e?n?i?`wsl-disabled`:`available`:`config-requirement-disabled`:`statsig-disabled`:`browser-pane-disabled`}";
        private static readonly string PortableBrowserPluginAvailabilityText =
            "function ami({isBrowserAgentGateEnabled:e,isBrowserSidebarEnabled:t,isBrowserUseEnabled:n,isLoading:r,runCodexInWsl:i,windowType:a}){return`available`}".
                PadRight(OfficialBrowserPluginAvailabilityText.Length);
        private const string OfficialChromePluginAvailabilityText =
            "function tmi({isExternalBrowserUseFeatureEnabled:e,isExternalBrowserUseFeatureLoading:t,isExternalBrowserUseGateEnabled:n,runCodexInWsl:r,windowType:i}){return i===`chrome-extension`?`available`:t?`loading`:n?e?r?`wsl-disabled`:`available`:`config-requirement-disabled`:`statsig-disabled`}";
        private static readonly string PortableChromePluginAvailabilityText =
            "function tmi({isExternalBrowserUseFeatureEnabled:e,isExternalBrowserUseFeatureLoading:t,isExternalBrowserUseGateEnabled:n,runCodexInWsl:r,windowType:i}){return`available`}".
                PadRight(OfficialChromePluginAvailabilityText.Length);
        private const string OfficialComputerUsePluginAvailabilityText =
            "function Rpi({areRequiredFeaturesEnabled:e,enabled:t,isAnyFeatureLoading:n,isComputerUseGateEnabled:r,isHostCompatiblePlatform:i,isPlatformLoading:a,windowType:o}){return t?o===`electron`?r?a?`loading`:i?n?`loading`:e?`available`:`config-requirement-disabled`:`unsupported-platform`:`statsig-disabled`:`window-type-disabled`:`disabled`}";
        private static readonly string PortableComputerUsePluginAvailabilityText =
            "function Rpi({areRequiredFeaturesEnabled:e,enabled:t,isAnyFeatureLoading:n,isComputerUseGateEnabled:r,isHostCompatiblePlatform:i,isPlatformLoading:a,windowType:o}){return`available`}".
                PadRight(OfficialComputerUsePluginAvailabilityText.Length);
        private const string OfficialBrowserPluginReconcileAvailabilityText =
            "installWhenMissing:!0,name:n.vs,isAvailable:({features:e})=>e.inAppBrowserUseAllowed||e.externalBrowserUseAllowed";
        private static readonly string PortableBrowserPluginReconcileAvailabilityText =
            "installWhenMissing:!0,name:n.vs,isAvailable:()=>!0".
                PadRight(OfficialBrowserPluginReconcileAvailabilityText.Length);
        private const string OfficialChromePluginReconcileAvailabilityText =
            "name:s.u,syncInstallStateWithChromeExtension:!0,isAvailable:({buildFlavor:e,env:t,features:n})=>s.s(e,t)&&n.externalBrowserUseAllowed";
        private static readonly string PortableChromePluginReconcileAvailabilityText =
            "name:s.u,syncInstallStateWithChromeExtension:!0,isAvailable:()=>!0".
                PadRight(OfficialChromePluginReconcileAvailabilityText.Length);
        private const string OfficialComputerUsePluginReconcileAvailabilityText =
            "installWhenMissingRequiresOptIn:!0,name:n.xs,isAvailable:({features:e,platform:t})=>t===`win32`&&e.computerUse";
        private static readonly string PortableComputerUsePluginReconcileAvailabilityText =
            "installWhenMissingRequiresOptIn:!0,name:n.xs,isAvailable:()=>!0".
                PadRight(OfficialComputerUsePluginReconcileAvailabilityText.Length);
        private const string OfficialSunsetUpdateGateText = "if(qh(`2929582856`)){";
        private static readonly string PortableSunsetUpdateGateText =
            "if(!1".PadRight(OfficialSunsetUpdateGateText.Length - 2) + "){";
        private const string OfficialBrandText = "\"codexAppBrand\": \"chatgpt\"";
        private const string PortableBrandText = "\"codexAppBrand\": \"codex\"  ";
        private const string OfficialAumidText = "Prod:return`com.openai.codex`";
        private const string PortableAumidText = "Prod:return`OpenAI.Codex.USB`";
        private const string OfficialPortableUserDataResolverText =
            "function ee({appDataPath:e,buildFlavor:n,env:r}){let i=r.CODEX_ELECTRON_USER_DATA_PATH?.trim();if(i)return(0,o.resolve)(i);let a=(0,o.join)(e,t.Ia(n)),s=r.CODEX_ELECTRON_AGENT_RUN_ID?.trim()||null;return n===`agent`&&s!=null?(0,o.join)(a,`agent`,s):a}";
        private static readonly string PortableUserDataResolverText =
            "function ee({appDataPath:e,buildFlavor:n,env:r}){let i=r.CODEX_ELECTRON_USER_DATA_PATH?.trim();return i&&r.CODEX_PORTABLE_ROOT?(0,o.resolve)(i):(a.dialog.showErrorBox(`LF Portable`,`Open CodexPortable.exe from the USB drive.`),process.exit(1))}".
                PadRight(OfficialPortableUserDataResolverText.Length);
        private const string OfficialCloseToTrayText =
            "canHideLastWindowToTray?.()===!0&&!t){e.preventDefault(),P.hide();return}";
        private const string LegacyPortableCloseToTrayText =
            "canHideLastWindowToTray?.()&&!!0&&!t){e.preventDefault(),P.hide();return}";
        private const string PortableCloseToTrayText =
            "canHideLastWindowToTray?.()===!0&&!t){this.isAppQuitting=!0,l.app.quit()}";
        private const string PortableCloseElectronAliasText = "l=require(\"electron\")";
        private const string OfficialWindowsLastWindowText =
            "o.app.on(`window-all-closed`,()=>{process.platform!==`win32`";
        private const string PortableWindowsLastWindowText =
            "o.app.on(`window-all-closed`,()=>{process.platform===`win32`";
        private const string OfficialWindowsWindowIconSelectorText =
            "j=process.platform===`linux`?b5(i,e,T):null";
        private const string PortableWindowsWindowIconSelectorText =
            "j=process.platform===`win32`?b5(i,e,T):null";
        private const string OfficialWindowsWindowIconResolverText =
            "function b5(e,t,n=(0,p.join)(l.app.getAppPath(),`src`,`icons`)){let r=`${lS(e,t)}.png`;";
        private const string PortableWindowsWindowIconResolverText =
            "function b5(e,t,n=(0,p.join)(l.app.getAppPath(),`src`,`icons`)){let r=`${lS(e,t)}.ico`;";
        private const string WebviewAssetPrefix = "webview/assets/";
        private const string AppInitialAssetStem = "app-initial";
        private const string OnboardingPageAssetStem = "onboarding-page";
        private const string OfficialStandardOnboardingGateText =
            "shouldShowStandardOnboarding:v";
        private const string PortableStandardOnboardingGateText =
            "shouldShowStandardOnboarding:0";
        private const string OnboardingMessageIdPrefix =
            "electron.onboarding.conversationalOnboarding.";
        private const string OfficialOnboardingBrandText = "ChatGPT";
        private const string PortableOnboardingBrandText = "Codex";
        private const string OfficialOnboardingHeaderIconText =
            "p=c?(0,t9.jsx)(`div`,{className:`fixed inset-x-0 top-0 z-10 flex h-toolbar items-center justify-center bg-surface draggable select-none`,children:(0,t9.jsx)(Eh,{\"aria-hidden\":`true`,className:`pointer-events-none size-6 text-default`})}):null";
        private const string PortableOnboardingHeaderIconText =
            "p=0?(0,t9.jsx)(`div`,{className:`fixed inset-x-0 top-0 z-10 flex h-toolbar items-center justify-center bg-surface draggable select-none`,children:(0,t9.jsx)(Eh,{\"aria-hidden\":`true`,className:`pointer-events-none size-6 text-default`})}):null";
        private const string OfficialWindowsSetupOnboardingStateText = "dHs=Im(!1)";
        private const string PortableWindowsSetupOnboardingStateText = "dHs=Im(!0)";
        private const string OfficialWindowsSetupBannerGateText =
            "cr=nr!=null&&(rr||sr!=null||q.isEnabled&&at)";
        private static readonly string PortableWindowsSetupBannerGateText =
            "cr=!1".PadRight(OfficialWindowsSetupBannerGateText.Length);
        private const string OfficialWindowsSandboxReadinessGateText =
            "let i=t(YHs,e);";
        private static readonly string PortableWindowsSandboxReadinessGateText =
            "let i={};".PadRight(OfficialWindowsSandboxReadinessGateText.Length);
        private const string OfficialWindowsSandboxSetupPendingGateText =
            "isWindowsSandboxSetupPending:nr!=null&&at";
        private static readonly string PortableWindowsSandboxSetupPendingGateText =
            "isWindowsSandboxSetupPending:!1".
                PadRight(OfficialWindowsSandboxSetupPendingGateText.Length);
        private const int OnboardingBrandPaddingLength = 2;
        private const int ExpectedOnboardingLocaleEntries = 65;
        private const int ExpectedTranslatedOnboardingLocaleEntries = 64;
        // English defaults live in onboarding-page; the other 64 locale bundles carry translated values.
        private static readonly string[] TranslatedOnboardingAssetStems = new string[] {
            "am", "ar", "bg-BG", "bn-BD", "bs-BA", "ca-ES", "cs-CZ", "da-DK",
            "de-DE", "el-GR", "es-419", "es-ES", "et-EE", "fa", "fi-FI", "fr-CA",
            "fr-FR", "gu-IN", "hi-IN", "hr-HR", "hu-HU", "hy-AM", "id-ID", "is-IS",
            "it-IT", "ja-JP", "ka-GE", "kk", "kn-IN", "ko-KR", "lt", "lv-LV",
            "mk-MK", "ml", "mn", "mr-IN", "ms-MY", "my-MM", "nb-NO", "nl-NL",
            "pa", "pl-PL", "pt-BR", "pt-PT", "ro-RO", "ru-RU", "sk-SK", "sl-SI",
            "so-SO", "sq-AL", "sr-RS", "sv-SE", "sw-TZ", "ta-IN", "te-IN", "th-TH",
            "tl", "tr-TR", "uk-UA", "ur", "vi-VN", "zh-CN", "zh-HK", "zh-TW"
        };

        private sealed class IntegrityState
        {
            internal string Hash;
            internal readonly List<string> Blocks = new List<string>();
        }

        private sealed class AsarEntry
        {
            internal string Path;
            internal long Offset;
            internal int Size;
            internal string IntegrityHash;
            internal int BlockSize;
            internal readonly List<string> IntegrityBlocks = new List<string>();
        }

        private sealed class OnboardingEntryTarget
        {
            internal AsarEntry Entry;
            internal bool ContainsDefaultMessages;
        }

        private sealed class OnboardingLiteralTarget
        {
            internal bool IsPortable;
            internal int OpeningTickOffset;
            internal int BrandOffset;
        }

        private sealed class AsarArchive : IDisposable
        {
            internal readonly FileStream Stream;
            internal readonly long DataOffset;
            internal readonly int HeaderJsonLength;
            internal string HeaderJson;
            internal readonly List<AsarEntry> Entries = new List<AsarEntry>();
            internal readonly Dictionary<string, string> IntegrityReplacements =
                new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

            internal AsarArchive(string path, bool writable)
            {
                Stream = new FileStream(path, FileMode.Open, writable ? FileAccess.ReadWrite : FileAccess.Read,
                    FileShare.Read, 1024 * 1024, FileOptions.RandomAccess);
                byte[] prefix = new byte[16];
                ReadExact(Stream, prefix, 0, prefix.Length);
                uint sizePayloadLength = BitConverter.ToUInt32(prefix, 0);
                uint headerPickleLength = BitConverter.ToUInt32(prefix, 4);
                uint headerPayloadLength = BitConverter.ToUInt32(prefix, 8);
                uint headerJsonLength = BitConverter.ToUInt32(prefix, 12);
                if (sizePayloadLength != 4 || headerPickleLength < 8 ||
                    headerPayloadLength < 4 || headerJsonLength == 0 || headerJsonLength > 64 * 1024 * 1024 ||
                    16L + headerJsonLength > 8L + headerPickleLength)
                    throw new InvalidDataException("Unsupported Electron ASAR header.");

                DataOffset = 8L + headerPickleLength;
                HeaderJsonLength = checked((int)headerJsonLength);
                byte[] headerBytes = new byte[HeaderJsonLength];
                ReadExact(Stream, headerBytes, 0, headerBytes.Length);
                HeaderJson = new UTF8Encoding(false, true).GetString(headerBytes);

                JavaScriptSerializer serializer = new JavaScriptSerializer();
                serializer.MaxJsonLength = int.MaxValue;
                serializer.RecursionLimit = 512;
                Dictionary<string, object> header = serializer.Deserialize<Dictionary<string, object>>(HeaderJson);
                object filesObject;
                if (header == null || !header.TryGetValue("files", out filesObject))
                    throw new InvalidDataException("Electron ASAR file table is missing.");
                Dictionary<string, object> files = filesObject as Dictionary<string, object>;
                if (files == null) throw new InvalidDataException("Electron ASAR file table is invalid.");
                AddEntries(files, "");
            }

            private void AddEntries(Dictionary<string, object> files, string prefix)
            {
                foreach (KeyValuePair<string, object> pair in files)
                {
                    Dictionary<string, object> node = pair.Value as Dictionary<string, object>;
                    if (node == null) throw new InvalidDataException("Electron ASAR entry is invalid.");
                    string relative = prefix.Length == 0 ? pair.Key : prefix + "/" + pair.Key;
                    object childrenObject;
                    if (node.TryGetValue("files", out childrenObject))
                    {
                        Dictionary<string, object> children = childrenObject as Dictionary<string, object>;
                        if (children == null) throw new InvalidDataException("Electron ASAR directory is invalid.");
                        AddEntries(children, relative);
                        continue;
                    }

                    object offsetObject;
                    object sizeObject;
                    object integrityObject;
                    if (!node.TryGetValue("offset", out offsetObject) ||
                        !node.TryGetValue("size", out sizeObject) ||
                        !node.TryGetValue("integrity", out integrityObject)) continue;
                    long relativeOffset;
                    int size;
                    if (!long.TryParse(Convert.ToString(offsetObject, CultureInfo.InvariantCulture),
                            NumberStyles.None, CultureInfo.InvariantCulture, out relativeOffset) || relativeOffset < 0 ||
                        !int.TryParse(Convert.ToString(sizeObject, CultureInfo.InvariantCulture),
                            NumberStyles.None, CultureInfo.InvariantCulture, out size) || size < 0)
                        throw new InvalidDataException("Electron ASAR entry bounds are invalid.");
                    if (DataOffset + relativeOffset < DataOffset || DataOffset + relativeOffset + size > Stream.Length)
                        throw new InvalidDataException("Electron ASAR entry exceeds the archive.");

                    Dictionary<string, object> integrity = integrityObject as Dictionary<string, object>;
                    if (integrity == null) throw new InvalidDataException("Electron ASAR integrity metadata is invalid.");
                    object algorithmObject;
                    object hashObject;
                    object blockSizeObject;
                    object blocksObject;
                    if (!integrity.TryGetValue("algorithm", out algorithmObject) ||
                        !string.Equals(Convert.ToString(algorithmObject, CultureInfo.InvariantCulture), "SHA256",
                            StringComparison.OrdinalIgnoreCase) ||
                        !integrity.TryGetValue("hash", out hashObject) ||
                        !integrity.TryGetValue("blockSize", out blockSizeObject) ||
                        !integrity.TryGetValue("blocks", out blocksObject))
                        throw new InvalidDataException("Electron ASAR SHA-256 metadata is incomplete.");

                    int blockSize;
                    if (!int.TryParse(Convert.ToString(blockSizeObject, CultureInfo.InvariantCulture),
                            NumberStyles.None, CultureInfo.InvariantCulture, out blockSize) || blockSize <= 0)
                        throw new InvalidDataException("Electron ASAR block size is invalid.");
                    AsarEntry entry = new AsarEntry();
                    entry.Path = relative;
                    entry.Offset = DataOffset + relativeOffset;
                    entry.Size = size;
                    entry.IntegrityHash = NormalizeHash(Convert.ToString(hashObject, CultureInfo.InvariantCulture));
                    entry.BlockSize = blockSize;
                    IEnumerable blocks = blocksObject as IEnumerable;
                    if (blocks == null) throw new InvalidDataException("Electron ASAR block hashes are invalid.");
                    foreach (object block in blocks)
                        entry.IntegrityBlocks.Add(NormalizeHash(Convert.ToString(block, CultureInfo.InvariantCulture)));
                    int expectedBlocks = size == 0 ? 1 : checked((int)(((long)size + blockSize - 1) / blockSize));
                    if (entry.IntegrityBlocks.Count != expectedBlocks)
                        throw new InvalidDataException("Electron ASAR block hash count is invalid.");
                    Entries.Add(entry);
                }
            }

            internal AsarEntry FindRequiredEntry(string relativePath)
            {
                AsarEntry result = null;
                for (int i = 0; i < Entries.Count; i++)
                {
                    if (!string.Equals(Entries[i].Path, relativePath, StringComparison.Ordinal)) continue;
                    if (result != null) throw new InvalidDataException("Duplicate Electron ASAR entry: " + relativePath);
                    result = Entries[i];
                }
                if (result == null) throw new InvalidDataException("Electron ASAR entry is missing: " + relativePath);
                return result;
            }

            internal byte[] ReadEntry(AsarEntry entry)
            {
                byte[] bytes = new byte[entry.Size];
                Stream.Position = entry.Offset;
                ReadExact(Stream, bytes, 0, bytes.Length);
                return bytes;
            }

            internal void WriteEntry(AsarEntry entry, byte[] bytes)
            {
                if (!Stream.CanWrite || bytes.Length != entry.Size)
                    throw new InvalidOperationException("Electron ASAR entry cannot be rewritten.");
                Stream.Position = entry.Offset;
                Stream.Write(bytes, 0, bytes.Length);
            }

            internal void AddIntegrityReplacement(AsarEntry entry, IntegrityState replacement)
            {
                AddReplacement(entry.IntegrityHash, replacement.Hash);
                if (entry.IntegrityBlocks.Count != replacement.Blocks.Count)
                    throw new InvalidDataException("Electron ASAR block hashes changed shape.");
                for (int i = 0; i < entry.IntegrityBlocks.Count; i++)
                    AddReplacement(entry.IntegrityBlocks[i], replacement.Blocks[i]);
                // Keep the in-memory entry metadata in lockstep with the
                // bytes just written.  A minified bundle can contain several
                // targets in one entry; the next target must validate against
                // this newly patched integrity state before the header flush.
                entry.IntegrityHash = replacement.Hash;
                entry.IntegrityBlocks.Clear();
                entry.IntegrityBlocks.AddRange(replacement.Blocks);
            }

            private void AddReplacement(string original, string replacement)
            {
                if (string.Equals(original, replacement, StringComparison.OrdinalIgnoreCase)) return;
                string existing;
                if (IntegrityReplacements.TryGetValue(original, out existing) &&
                    !string.Equals(existing, replacement, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("Conflicting Electron ASAR integrity replacement.");
                IntegrityReplacements[original] = replacement;
            }

            internal void FlushHeader()
            {
                if (IntegrityReplacements.Count == 0) return;
                char[] rewritten = HeaderJson.ToCharArray();
                foreach (KeyValuePair<string, string> pair in IntegrityReplacements)
                {
                    int count = 0;
                    int index = 0;
                    while ((index = HeaderJson.IndexOf(pair.Key, index, StringComparison.OrdinalIgnoreCase)) >= 0)
                    {
                        for (int i = 0; i < pair.Key.Length; i++) rewritten[index + i] = pair.Value[i];
                        index += pair.Key.Length;
                        count++;
                    }
                    if (count == 0) throw new InvalidDataException("Electron ASAR integrity hash was not found in its header.");
                }
                string value = new string(rewritten);
                byte[] bytes = new UTF8Encoding(false, true).GetBytes(value);
                if (bytes.Length != HeaderJsonLength)
                    throw new InvalidDataException("Electron ASAR header length changed unexpectedly.");
                Stream.Position = 16;
                Stream.Write(bytes, 0, bytes.Length);
                Stream.Flush(true);
                HeaderJson = value;
                IntegrityReplacements.Clear();
            }

            public void Dispose()
            {
                Stream.Dispose();
            }
        }

        internal static void EnsurePatched(string asarPath)
        {
            if (!File.Exists(asarPath)) throw new FileNotFoundException("Electron app.asar is missing.", asarPath);
            FileAttributes attributes = File.GetAttributes(asarPath);
            if ((attributes & FileAttributes.ReadOnly) != 0)
                File.SetAttributes(asarPath, attributes & ~FileAttributes.ReadOnly);

            using (AsarArchive archive = new AsarArchive(asarPath, true))
            {
                int workspaceDependenciesSettingsFunctionEntries =
                    VerifyArchiveIntegrityAndCountJavaScriptPattern(archive,
                        WorkspaceDependenciesSettingsFunctionText);
                if (workspaceDependenciesSettingsFunctionEntries != 1)
                    throw new InvalidDataException(
                        "Electron workspace dependencies settings function is missing or ambiguous.");
                VerifyArchiveJavaScriptPatternState(archive, OfficialConfigModeShortLabelText,
                    PortableConfigModeShortLabelText, ConfigModeShortLabelExpectedOccurrences,
                    "Electron config.toml permission short-label state is invalid.");
                VerifyArchiveJavaScriptPatternState(archive, OfficialConfigModeOptionLabelText,
                    PortableConfigModeOptionLabelText, ConfigModeOptionLabelExpectedOccurrences,
                    "Electron config.toml permission option-label state is invalid.");
                int brandEntries = EnsurePattern(archive, archive.FindRequiredEntry(PackagePath),
                    OfficialBrandText, PortableBrandText);
                if (brandEntries != 1) throw new InvalidDataException("Electron package brand metadata is ambiguous.");

                int aumidEntries = 0;
                int portableUserDataResolverEntries = 0;
                int closeToTrayEntries = 0;
                int windowsLastWindowEntries = 0;
                int windowsWindowIconSelectorEntries = 0;
                int windowsWindowIconResolverEntries = 0;
                int sparkleGateEntries = 0;
                int workerSparkleGateEntries = 0;
                int updateMenuEntries = 0;
                int recoveryEntries = 0;
                int updaterIdleStateEntries = 0;
                int runtimeStaticDisabledReasonEntries = 0;
                int runtimeInstallGuardEntries = 0;
                int runtimeDebugMenuGateEntries = 0;
                int workspaceDependenciesSettingsPanelGateEntries = 0;
                int configModeEquivalenceEntries = 0;
                int configModeShortLabelEntries = 0;
                int configModeOptionLabelEntries = 0;
                int browserPluginAvailabilityEntries = 0;
                int chromePluginAvailabilityEntries = 0;
                int computerUsePluginAvailabilityEntries = 0;
                int browserPluginReconcileAvailabilityEntries = 0;
                int chromePluginReconcileAvailabilityEntries = 0;
                int computerUsePluginReconcileAvailabilityEntries = 0;
                int sunsetUpdateGateEntries = 0;
                for (int i = 0; i < archive.Entries.Count; i++)
                {
                    AsarEntry entry = archive.Entries[i];
                    if (entry.Path.EndsWith(".js", StringComparison.OrdinalIgnoreCase))
                    {
                        sparkleGateEntries += EnsurePattern(archive, entry,
                            OfficialSparkleGateText, PortableSparkleGateText);
                        workerSparkleGateEntries += EnsurePattern(archive, entry,
                            OfficialWorkerSparkleGateText, PortableWorkerSparkleGateText);
                        updateMenuEntries += EnsurePattern(archive, entry,
                            OfficialUpdateMenuHandlerText, PortableUpdateMenuHandlerText);
                        recoveryEntries += EnsurePattern(archive, entry,
                            OfficialRecoveryStateText, PortableRecoveryStateText);
                        updaterIdleStateEntries += EnsurePattern(archive, entry,
                            OfficialUpdaterIdleStateText, PortableUpdaterIdleStateText);
                        runtimeStaticDisabledReasonEntries += EnsurePattern(archive, entry,
                            OfficialRuntimeStaticDisabledReasonText,
                            PortableRuntimeStaticDisabledReasonText);
                        runtimeInstallGuardEntries += EnsurePattern(archive, entry,
                            OfficialRuntimeInstallGuardText, PortableRuntimeInstallGuardText);
                        runtimeDebugMenuGateEntries += EnsurePattern(archive, entry,
                            OfficialRuntimeDebugMenuGateText, PortableRuntimeDebugMenuGateText);
                        workspaceDependenciesSettingsPanelGateEntries += EnsurePattern(archive, entry,
                            OfficialWorkspaceDependenciesSettingsPanelGateText,
                            PortableWorkspaceDependenciesSettingsPanelGateText);
                        configModeEquivalenceEntries += EnsurePattern(archive, entry,
                            OfficialConfigModeEquivalenceText,
                            PortableConfigModeEquivalenceText);
                        configModeShortLabelEntries += EnsurePattern(archive, entry,
                            OfficialConfigModeShortLabelText, PortableConfigModeShortLabelText,
                            ConfigModeShortLabelExpectedOccurrences);
                        configModeOptionLabelEntries += EnsurePattern(archive, entry,
                            OfficialConfigModeOptionLabelText, PortableConfigModeOptionLabelText,
                            ConfigModeOptionLabelExpectedOccurrences);
                        browserPluginAvailabilityEntries += EnsurePattern(archive, entry,
                            OfficialBrowserPluginAvailabilityText,
                            PortableBrowserPluginAvailabilityText);
                        chromePluginAvailabilityEntries += EnsurePattern(archive, entry,
                            OfficialChromePluginAvailabilityText,
                            PortableChromePluginAvailabilityText);
                        computerUsePluginAvailabilityEntries += EnsurePattern(archive, entry,
                            OfficialComputerUsePluginAvailabilityText,
                            PortableComputerUsePluginAvailabilityText);
                        browserPluginReconcileAvailabilityEntries += EnsurePattern(archive, entry,
                            OfficialBrowserPluginReconcileAvailabilityText,
                            PortableBrowserPluginReconcileAvailabilityText);
                        chromePluginReconcileAvailabilityEntries += EnsurePattern(archive, entry,
                            OfficialChromePluginReconcileAvailabilityText,
                            PortableChromePluginReconcileAvailabilityText);
                        computerUsePluginReconcileAvailabilityEntries += EnsurePattern(archive, entry,
                            OfficialComputerUsePluginReconcileAvailabilityText,
                            PortableComputerUsePluginReconcileAvailabilityText);
                        sunsetUpdateGateEntries += EnsurePattern(archive, entry,
                            OfficialSunsetUpdateGateText, PortableSunsetUpdateGateText);
                        portableUserDataResolverEntries += EnsurePattern(archive, entry,
                            OfficialPortableUserDataResolverText,
                            PortableUserDataResolverText);
                    }
                    if (!entry.Path.StartsWith(BuildJavaScriptPrefix, StringComparison.Ordinal) ||
                        !entry.Path.EndsWith(".js", StringComparison.OrdinalIgnoreCase)) continue;
                    aumidEntries += EnsurePattern(archive, entry, OfficialAumidText, PortableAumidText);
                    closeToTrayEntries += EnsureDirectClosePattern(archive, entry);
                    windowsLastWindowEntries += EnsurePattern(archive, entry,
                        OfficialWindowsLastWindowText, PortableWindowsLastWindowText);
                    windowsWindowIconSelectorEntries += EnsurePattern(archive, entry,
                        OfficialWindowsWindowIconSelectorText, PortableWindowsWindowIconSelectorText);
                    windowsWindowIconResolverEntries += EnsurePattern(archive, entry,
                        OfficialWindowsWindowIconResolverText, PortableWindowsWindowIconResolverText);
                }
                if (aumidEntries == 0) throw new InvalidDataException("Electron portable AppUserModelID target is missing.");
                if (portableUserDataResolverEntries != 1)
                    throw new InvalidDataException(
                        "Electron portable user-data routing guard is missing or ambiguous.");
                if (closeToTrayEntries != 1)
                    throw new InvalidDataException("Electron close-to-tray target is missing or ambiguous.");
                if (windowsLastWindowEntries != 1)
                    throw new InvalidDataException("Electron Windows last-window target is missing or ambiguous.");
                if (windowsWindowIconSelectorEntries != 1 || windowsWindowIconResolverEntries != 1)
                    throw new InvalidDataException(
                        "Electron Windows main-window icon target is missing or ambiguous.");
                if (sparkleGateEntries != 1 || workerSparkleGateEntries != 1)
                    throw new InvalidDataException("Electron updater gate is missing or ambiguous.");
                if (updateMenuEntries != 1)
                    throw new InvalidDataException("Electron updater menu target is missing or ambiguous.");
                if (recoveryEntries != 1)
                    throw new InvalidDataException("Electron updater recovery target is missing or ambiguous.");
                if (updaterIdleStateEntries != 1)
                    throw new InvalidDataException("Electron updater lifecycle target is missing or ambiguous.");
                if (runtimeStaticDisabledReasonEntries != 1 || runtimeInstallGuardEntries != 1)
                    throw new InvalidDataException(
                        "Electron workspace runtime updater target is missing or ambiguous.");
                if (runtimeDebugMenuGateEntries != 1)
                    throw new InvalidDataException(
                        "Electron workspace runtime debug-menu target is missing or ambiguous.");
                if (workspaceDependenciesSettingsFunctionEntries != 1 ||
                    workspaceDependenciesSettingsPanelGateEntries != 1)
                    throw new InvalidDataException(
                        "Electron workspace dependencies settings targets are missing or ambiguous.");
                if (configModeEquivalenceEntries != 1 ||
                    configModeShortLabelEntries != ConfigModeShortLabelExpectedOccurrences ||
                    configModeOptionLabelEntries != ConfigModeOptionLabelExpectedOccurrences)
                    throw new InvalidDataException(
                        "Electron config.toml permission-mode target is missing or ambiguous.");
                if (browserPluginAvailabilityEntries != 1 || chromePluginAvailabilityEntries != 1 ||
                    computerUsePluginAvailabilityEntries != 1 ||
                    browserPluginReconcileAvailabilityEntries != 1 ||
                    chromePluginReconcileAvailabilityEntries != 1 ||
                    computerUsePluginReconcileAvailabilityEntries != 1)
                    throw new InvalidDataException(
                        "Electron portable plugin-availability target is missing or ambiguous.");
                if (sunsetUpdateGateEntries != 1)
                    throw new InvalidDataException(
                        "Electron forced-update page target is missing or ambiguous.");

                List<OnboardingEntryTarget> onboardingEntries = FindOnboardingEntries(archive);
                for (int i = 0; i < onboardingEntries.Count; i++)
                    EnsureOnboardingEntry(archive, onboardingEntries[i]);
                EnsureOnboardingHeaderIconEntry(archive, FindOnboardingHeaderIconEntry(archive));
                archive.FlushHeader();
            }
            if (!IsPrepared(asarPath)) throw new InvalidDataException("Electron portable branding verification failed.");
        }

        internal static bool IsPrepared(string asarPath)
        {
            return HasPreparedState(asarPath);
        }

        private static bool HasPreparedState(string asarPath)
        {
            try
            {
                using (AsarArchive archive = new AsarArchive(asarPath, false))
                {
                    AsarEntry package = archive.FindRequiredEntry(PackagePath);
                    byte[] packageBytes = archive.ReadEntry(package);
                    if (CountPattern(packageBytes, Encoding.UTF8.GetBytes(OfficialBrandText)) != 0 ||
                        CountPattern(packageBytes, Encoding.UTF8.GetBytes(PortableBrandText)) != 1 ||
                        !IntegrityMatches(package, ComputeIntegrity(packageBytes, package.BlockSize))) return false;

                    byte[] officialAumid = Encoding.UTF8.GetBytes(OfficialAumidText);
                    byte[] portableAumid = Encoding.UTF8.GetBytes(PortableAumidText);
                    byte[] officialPortableUserDataResolver =
                        Encoding.UTF8.GetBytes(OfficialPortableUserDataResolverText);
                    byte[] portableUserDataResolver =
                        Encoding.UTF8.GetBytes(PortableUserDataResolverText);
                    byte[] officialCloseToTray = Encoding.UTF8.GetBytes(OfficialCloseToTrayText);
                    byte[] legacyPortableCloseToTray = Encoding.UTF8.GetBytes(LegacyPortableCloseToTrayText);
                    byte[] portableCloseToTray = Encoding.UTF8.GetBytes(PortableCloseToTrayText);
                    byte[] portableCloseElectronAlias = Encoding.UTF8.GetBytes(PortableCloseElectronAliasText);
                    byte[] officialWindowsLastWindow = Encoding.UTF8.GetBytes(OfficialWindowsLastWindowText);
                    byte[] portableWindowsLastWindow = Encoding.UTF8.GetBytes(PortableWindowsLastWindowText);
                    byte[] officialWindowsWindowIconSelector =
                        Encoding.UTF8.GetBytes(OfficialWindowsWindowIconSelectorText);
                    byte[] portableWindowsWindowIconSelector =
                        Encoding.UTF8.GetBytes(PortableWindowsWindowIconSelectorText);
                    byte[] officialWindowsWindowIconResolver =
                        Encoding.UTF8.GetBytes(OfficialWindowsWindowIconResolverText);
                    byte[] portableWindowsWindowIconResolver =
                        Encoding.UTF8.GetBytes(PortableWindowsWindowIconResolverText);
                    int portableAumidOccurrences = 0;
                    int portableUserDataResolverOccurrences = 0;
                    int portableCloseToTrayOccurrences = 0;
                    int portableWindowsLastWindowOccurrences = 0;
                    int portableWindowsWindowIconSelectorOccurrences = 0;
                    int portableWindowsWindowIconResolverOccurrences = 0;
                    for (int i = 0; i < archive.Entries.Count; i++)
                    {
                        AsarEntry entry = archive.Entries[i];
                        if (!entry.Path.StartsWith(BuildJavaScriptPrefix, StringComparison.Ordinal) ||
                            !entry.Path.EndsWith(".js", StringComparison.OrdinalIgnoreCase)) continue;
                        byte[] bytes = archive.ReadEntry(entry);
                        int officialAumidCount = CountPattern(bytes, officialAumid);
                        int portableAumidCount = CountPattern(bytes, portableAumid);
                        int officialPortableUserDataResolverCount =
                            CountPattern(bytes, officialPortableUserDataResolver);
                        int portableUserDataResolverCount =
                            CountPattern(bytes, portableUserDataResolver);
                        int officialCloseToTrayCount = CountPattern(bytes, officialCloseToTray);
                        int legacyPortableCloseToTrayCount = CountPattern(bytes, legacyPortableCloseToTray);
                        int portableCloseToTrayCount = CountPattern(bytes, portableCloseToTray);
                        int officialWindowsLastWindowCount = CountPattern(bytes, officialWindowsLastWindow);
                        int portableWindowsLastWindowCount = CountPattern(bytes, portableWindowsLastWindow);
                        int officialWindowsWindowIconSelectorCount =
                            CountPattern(bytes, officialWindowsWindowIconSelector);
                        int portableWindowsWindowIconSelectorCount =
                            CountPattern(bytes, portableWindowsWindowIconSelector);
                        int officialWindowsWindowIconResolverCount =
                            CountPattern(bytes, officialWindowsWindowIconResolver);
                        int portableWindowsWindowIconResolverCount =
                            CountPattern(bytes, portableWindowsWindowIconResolver);
                        if (officialAumidCount != 0 ||
                            officialPortableUserDataResolverCount != 0 ||
                            officialCloseToTrayCount != 0 ||
                            legacyPortableCloseToTrayCount != 0 ||
                            officialWindowsLastWindowCount != 0 ||
                            officialWindowsWindowIconSelectorCount != 0 ||
                            officialWindowsWindowIconResolverCount != 0) return false;
                        if (portableAumidCount > 1 || portableUserDataResolverCount > 1 ||
                            portableCloseToTrayCount > 1 ||
                            portableWindowsLastWindowCount > 1 ||
                            portableWindowsWindowIconSelectorCount > 1 ||
                            portableWindowsWindowIconResolverCount > 1) return false;
                        if (portableAumidCount == 0 && portableUserDataResolverCount == 0 &&
                            portableCloseToTrayCount == 0 &&
                            portableWindowsLastWindowCount == 0 &&
                            portableWindowsWindowIconSelectorCount == 0 &&
                            portableWindowsWindowIconResolverCount == 0) continue;
                        if (portableCloseToTrayCount != 0 &&
                            CountPattern(bytes, portableCloseElectronAlias) != 1) return false;
                        portableAumidOccurrences += portableAumidCount;
                        portableUserDataResolverOccurrences += portableUserDataResolverCount;
                        portableCloseToTrayOccurrences += portableCloseToTrayCount;
                        portableWindowsLastWindowOccurrences += portableWindowsLastWindowCount;
                        portableWindowsWindowIconSelectorOccurrences +=
                            portableWindowsWindowIconSelectorCount;
                        portableWindowsWindowIconResolverOccurrences +=
                            portableWindowsWindowIconResolverCount;
                        if (!IntegrityMatches(entry, ComputeIntegrity(bytes, entry.BlockSize))) return false;
                    }
                    if (portableAumidOccurrences == 0 ||
                        portableUserDataResolverOccurrences != 1 ||
                        portableCloseToTrayOccurrences != 1 ||
                        portableWindowsLastWindowOccurrences != 1 ||
                        portableWindowsWindowIconSelectorOccurrences != 1 ||
                        portableWindowsWindowIconResolverOccurrences != 1) return false;

                    byte[] officialSparkleGate = Encoding.UTF8.GetBytes(OfficialSparkleGateText);
                    byte[] portableSparkleGate = Encoding.UTF8.GetBytes(PortableSparkleGateText);
                    byte[] officialWorkerSparkleGate = Encoding.UTF8.GetBytes(OfficialWorkerSparkleGateText);
                    byte[] portableWorkerSparkleGate = Encoding.UTF8.GetBytes(PortableWorkerSparkleGateText);
                    byte[] officialUpdateMenu = Encoding.UTF8.GetBytes(OfficialUpdateMenuHandlerText);
                    byte[] portableUpdateMenu = Encoding.UTF8.GetBytes(PortableUpdateMenuHandlerText);
                    byte[] officialRecovery = Encoding.UTF8.GetBytes(OfficialRecoveryStateText);
                    byte[] portableRecovery = Encoding.UTF8.GetBytes(PortableRecoveryStateText);
                    byte[] officialUpdaterIdleState = Encoding.UTF8.GetBytes(OfficialUpdaterIdleStateText);
                    byte[] portableUpdaterIdleState = Encoding.UTF8.GetBytes(PortableUpdaterIdleStateText);
                    byte[] officialRuntimeStaticDisabledReason =
                        Encoding.UTF8.GetBytes(OfficialRuntimeStaticDisabledReasonText);
                    byte[] portableRuntimeStaticDisabledReason =
                        Encoding.UTF8.GetBytes(PortableRuntimeStaticDisabledReasonText);
                    byte[] officialRuntimeInstallGuard =
                        Encoding.UTF8.GetBytes(OfficialRuntimeInstallGuardText);
                    byte[] portableRuntimeInstallGuard =
                        Encoding.UTF8.GetBytes(PortableRuntimeInstallGuardText);
                    byte[] officialRuntimeDebugMenuGate =
                        Encoding.UTF8.GetBytes(OfficialRuntimeDebugMenuGateText);
                    byte[] portableRuntimeDebugMenuGate =
                        Encoding.UTF8.GetBytes(PortableRuntimeDebugMenuGateText);
                    byte[] workspaceDependenciesSettingsFunction =
                        Encoding.UTF8.GetBytes(WorkspaceDependenciesSettingsFunctionText);
                    byte[] officialWorkspaceDependenciesSettingsPanelGate =
                        Encoding.UTF8.GetBytes(OfficialWorkspaceDependenciesSettingsPanelGateText);
                    byte[] portableWorkspaceDependenciesSettingsPanelGate =
                        Encoding.UTF8.GetBytes(PortableWorkspaceDependenciesSettingsPanelGateText);
                    byte[] officialConfigModeEquivalence =
                        Encoding.UTF8.GetBytes(OfficialConfigModeEquivalenceText);
                    byte[] portableConfigModeEquivalence =
                        Encoding.UTF8.GetBytes(PortableConfigModeEquivalenceText);
                    byte[] officialConfigModeShortLabel =
                        Encoding.UTF8.GetBytes(OfficialConfigModeShortLabelText);
                    byte[] portableConfigModeShortLabel =
                        Encoding.UTF8.GetBytes(PortableConfigModeShortLabelText);
                    byte[] officialConfigModeOptionLabel =
                        Encoding.UTF8.GetBytes(OfficialConfigModeOptionLabelText);
                    byte[] portableConfigModeOptionLabel =
                        Encoding.UTF8.GetBytes(PortableConfigModeOptionLabelText);
                    byte[] officialBrowserPluginAvailability =
                        Encoding.UTF8.GetBytes(OfficialBrowserPluginAvailabilityText);
                    byte[] portableBrowserPluginAvailability =
                        Encoding.UTF8.GetBytes(PortableBrowserPluginAvailabilityText);
                    byte[] officialChromePluginAvailability =
                        Encoding.UTF8.GetBytes(OfficialChromePluginAvailabilityText);
                    byte[] portableChromePluginAvailability =
                        Encoding.UTF8.GetBytes(PortableChromePluginAvailabilityText);
                    byte[] officialComputerUsePluginAvailability =
                        Encoding.UTF8.GetBytes(OfficialComputerUsePluginAvailabilityText);
                    byte[] portableComputerUsePluginAvailability =
                        Encoding.UTF8.GetBytes(PortableComputerUsePluginAvailabilityText);
                    byte[] officialBrowserPluginReconcileAvailability =
                        Encoding.UTF8.GetBytes(OfficialBrowserPluginReconcileAvailabilityText);
                    byte[] portableBrowserPluginReconcileAvailability =
                        Encoding.UTF8.GetBytes(PortableBrowserPluginReconcileAvailabilityText);
                    byte[] officialChromePluginReconcileAvailability =
                        Encoding.UTF8.GetBytes(OfficialChromePluginReconcileAvailabilityText);
                    byte[] portableChromePluginReconcileAvailability =
                        Encoding.UTF8.GetBytes(PortableChromePluginReconcileAvailabilityText);
                    byte[] officialComputerUsePluginReconcileAvailability =
                        Encoding.UTF8.GetBytes(OfficialComputerUsePluginReconcileAvailabilityText);
                    byte[] portableComputerUsePluginReconcileAvailability =
                        Encoding.UTF8.GetBytes(PortableComputerUsePluginReconcileAvailabilityText);
                    byte[] officialSunsetUpdateGate =
                        Encoding.UTF8.GetBytes(OfficialSunsetUpdateGateText);
                    byte[] portableSunsetUpdateGate =
                        Encoding.UTF8.GetBytes(PortableSunsetUpdateGateText);
                    int portableSparkleGateOccurrences = 0;
                    int portableWorkerSparkleGateOccurrences = 0;
                    int portableUpdateMenuOccurrences = 0;
                    int portableRecoveryOccurrences = 0;
                    int portableUpdaterIdleStateOccurrences = 0;
                    int portableRuntimeStaticDisabledReasonOccurrences = 0;
                    int portableRuntimeInstallGuardOccurrences = 0;
                    int portableRuntimeDebugMenuGateOccurrences = 0;
                    int workspaceDependenciesSettingsFunctionOccurrences = 0;
                    int officialWorkspaceDependenciesSettingsPanelGateOccurrences = 0;
                    int portableWorkspaceDependenciesSettingsPanelGateOccurrences = 0;
                    int portableConfigModeEquivalenceOccurrences = 0;
                    int portableConfigModeShortLabelOccurrences = 0;
                    int portableConfigModeOptionLabelOccurrences = 0;
                    int portableBrowserPluginAvailabilityOccurrences = 0;
                    int portableChromePluginAvailabilityOccurrences = 0;
                    int portableComputerUsePluginAvailabilityOccurrences = 0;
                    int portableBrowserPluginReconcileAvailabilityOccurrences = 0;
                    int portableChromePluginReconcileAvailabilityOccurrences = 0;
                    int portableComputerUsePluginReconcileAvailabilityOccurrences = 0;
                    int portableSunsetUpdateGateOccurrences = 0;
                    for (int i = 0; i < archive.Entries.Count; i++)
                    {
                        AsarEntry entry = archive.Entries[i];
                        if (!entry.Path.EndsWith(".js", StringComparison.OrdinalIgnoreCase)) continue;
                        byte[] bytes = archive.ReadEntry(entry);
                        int officialSparkleGateCount = CountPattern(bytes, officialSparkleGate);
                        int portableSparkleGateCount = CountPattern(bytes, portableSparkleGate);
                        int officialWorkerSparkleGateCount = CountPattern(bytes, officialWorkerSparkleGate);
                        int portableWorkerSparkleGateCount = CountPattern(bytes, portableWorkerSparkleGate);
                        int officialUpdateMenuCount = CountPattern(bytes, officialUpdateMenu);
                        int portableUpdateMenuCount = CountPattern(bytes, portableUpdateMenu);
                        int officialRecoveryCount = CountPattern(bytes, officialRecovery);
                        int portableRecoveryCount = CountPattern(bytes, portableRecovery);
                        int officialUpdaterIdleStateCount = CountPattern(bytes, officialUpdaterIdleState);
                        int portableUpdaterIdleStateCount = CountPattern(bytes, portableUpdaterIdleState);
                        int officialRuntimeStaticDisabledReasonCount =
                            CountPattern(bytes, officialRuntimeStaticDisabledReason);
                        int portableRuntimeStaticDisabledReasonCount =
                            CountPattern(bytes, portableRuntimeStaticDisabledReason);
                        int officialRuntimeInstallGuardCount =
                            CountPattern(bytes, officialRuntimeInstallGuard);
                        int portableRuntimeInstallGuardCount =
                            CountPattern(bytes, portableRuntimeInstallGuard);
                        int officialRuntimeDebugMenuGateCount =
                            CountPattern(bytes, officialRuntimeDebugMenuGate);
                        int portableRuntimeDebugMenuGateCount =
                            CountPattern(bytes, portableRuntimeDebugMenuGate);
                        int workspaceDependenciesSettingsFunctionCount =
                            CountPattern(bytes, workspaceDependenciesSettingsFunction);
                        int officialWorkspaceDependenciesSettingsPanelGateCount =
                            CountPattern(bytes, officialWorkspaceDependenciesSettingsPanelGate);
                        int portableWorkspaceDependenciesSettingsPanelGateCount =
                            CountPattern(bytes, portableWorkspaceDependenciesSettingsPanelGate);
                        int officialConfigModeEquivalenceCount =
                            CountPattern(bytes, officialConfigModeEquivalence);
                        int portableConfigModeEquivalenceCount =
                            CountPattern(bytes, portableConfigModeEquivalence);
                        int officialConfigModeShortLabelCount =
                            CountPattern(bytes, officialConfigModeShortLabel);
                        int portableConfigModeShortLabelCount =
                            CountPattern(bytes, portableConfigModeShortLabel);
                        int officialConfigModeOptionLabelCount =
                            CountPattern(bytes, officialConfigModeOptionLabel);
                        int portableConfigModeOptionLabelCount =
                            CountPattern(bytes, portableConfigModeOptionLabel);
                        int officialBrowserPluginAvailabilityCount =
                            CountPattern(bytes, officialBrowserPluginAvailability);
                        int portableBrowserPluginAvailabilityCount =
                            CountPattern(bytes, portableBrowserPluginAvailability);
                        int officialChromePluginAvailabilityCount =
                            CountPattern(bytes, officialChromePluginAvailability);
                        int portableChromePluginAvailabilityCount =
                            CountPattern(bytes, portableChromePluginAvailability);
                        int officialComputerUsePluginAvailabilityCount =
                            CountPattern(bytes, officialComputerUsePluginAvailability);
                        int portableComputerUsePluginAvailabilityCount =
                            CountPattern(bytes, portableComputerUsePluginAvailability);
                        int officialBrowserPluginReconcileAvailabilityCount =
                            CountPattern(bytes, officialBrowserPluginReconcileAvailability);
                        int portableBrowserPluginReconcileAvailabilityCount =
                            CountPattern(bytes, portableBrowserPluginReconcileAvailability);
                        int officialChromePluginReconcileAvailabilityCount =
                            CountPattern(bytes, officialChromePluginReconcileAvailability);
                        int portableChromePluginReconcileAvailabilityCount =
                            CountPattern(bytes, portableChromePluginReconcileAvailability);
                        int officialComputerUsePluginReconcileAvailabilityCount =
                            CountPattern(bytes, officialComputerUsePluginReconcileAvailability);
                        int portableComputerUsePluginReconcileAvailabilityCount =
                            CountPattern(bytes, portableComputerUsePluginReconcileAvailability);
                        int officialSunsetUpdateGateCount = CountPattern(bytes, officialSunsetUpdateGate);
                        int portableSunsetUpdateGateCount = CountPattern(bytes, portableSunsetUpdateGate);
                        if (officialSparkleGateCount != 0 || officialWorkerSparkleGateCount != 0 ||
                            officialUpdateMenuCount != 0 || officialRecoveryCount != 0 ||
                            officialUpdaterIdleStateCount != 0 ||
                            officialRuntimeStaticDisabledReasonCount != 0 ||
                            officialRuntimeInstallGuardCount != 0 ||
                            officialRuntimeDebugMenuGateCount != 0 ||
                            officialConfigModeEquivalenceCount != 0 ||
                            officialConfigModeShortLabelCount != 0 ||
                            officialConfigModeOptionLabelCount != 0 ||
                            officialBrowserPluginAvailabilityCount != 0 ||
                            officialChromePluginAvailabilityCount != 0 ||
                            officialComputerUsePluginAvailabilityCount != 0 ||
                            officialBrowserPluginReconcileAvailabilityCount != 0 ||
                            officialChromePluginReconcileAvailabilityCount != 0 ||
                            officialComputerUsePluginReconcileAvailabilityCount != 0 ||
                            officialSunsetUpdateGateCount != 0 ||
                            portableSparkleGateCount > 1 || portableWorkerSparkleGateCount > 1 ||
                            portableUpdateMenuCount > 1 || portableRecoveryCount > 1 ||
                            portableUpdaterIdleStateCount > 1 ||
                            portableRuntimeStaticDisabledReasonCount > 1 ||
                            portableRuntimeInstallGuardCount > 1 ||
                            portableRuntimeDebugMenuGateCount > 1 ||
                            workspaceDependenciesSettingsFunctionCount > 1 ||
                            officialWorkspaceDependenciesSettingsPanelGateCount > 1 ||
                            portableWorkspaceDependenciesSettingsPanelGateCount > 1 ||
                            portableConfigModeEquivalenceCount > 1 ||
                            portableConfigModeShortLabelCount > ConfigModeShortLabelExpectedOccurrences ||
                            portableConfigModeOptionLabelCount > ConfigModeOptionLabelExpectedOccurrences ||
                            portableBrowserPluginAvailabilityCount > 1 ||
                            portableChromePluginAvailabilityCount > 1 ||
                            portableComputerUsePluginAvailabilityCount > 1 ||
                            portableBrowserPluginReconcileAvailabilityCount > 1 ||
                            portableChromePluginReconcileAvailabilityCount > 1 ||
                            portableComputerUsePluginReconcileAvailabilityCount > 1 ||
                            portableSunsetUpdateGateCount > 1) return false;
                        if (portableSparkleGateCount == 0 && portableWorkerSparkleGateCount == 0 &&
                            portableUpdateMenuCount == 0 && portableRecoveryCount == 0 &&
                            portableUpdaterIdleStateCount == 0 &&
                            portableRuntimeStaticDisabledReasonCount == 0 &&
                            portableRuntimeInstallGuardCount == 0 &&
                            portableRuntimeDebugMenuGateCount == 0 &&
                            workspaceDependenciesSettingsFunctionCount == 0 &&
                            officialWorkspaceDependenciesSettingsPanelGateCount == 0 &&
                            portableWorkspaceDependenciesSettingsPanelGateCount == 0 &&
                            portableConfigModeEquivalenceCount == 0 &&
                            portableConfigModeShortLabelCount == 0 &&
                            portableConfigModeOptionLabelCount == 0 &&
                            portableBrowserPluginAvailabilityCount == 0 &&
                            portableChromePluginAvailabilityCount == 0 &&
                            portableComputerUsePluginAvailabilityCount == 0 &&
                            portableBrowserPluginReconcileAvailabilityCount == 0 &&
                            portableChromePluginReconcileAvailabilityCount == 0 &&
                            portableComputerUsePluginReconcileAvailabilityCount == 0 &&
                            portableSunsetUpdateGateCount == 0) continue;
                        if (!IntegrityMatches(entry, ComputeIntegrity(bytes, entry.BlockSize))) return false;
                        portableSparkleGateOccurrences += portableSparkleGateCount;
                        portableWorkerSparkleGateOccurrences += portableWorkerSparkleGateCount;
                        portableUpdateMenuOccurrences += portableUpdateMenuCount;
                        portableRecoveryOccurrences += portableRecoveryCount;
                        portableUpdaterIdleStateOccurrences += portableUpdaterIdleStateCount;
                        portableRuntimeStaticDisabledReasonOccurrences +=
                            portableRuntimeStaticDisabledReasonCount;
                        portableRuntimeInstallGuardOccurrences += portableRuntimeInstallGuardCount;
                        portableRuntimeDebugMenuGateOccurrences += portableRuntimeDebugMenuGateCount;
                        workspaceDependenciesSettingsFunctionOccurrences +=
                            workspaceDependenciesSettingsFunctionCount;
                        officialWorkspaceDependenciesSettingsPanelGateOccurrences +=
                            officialWorkspaceDependenciesSettingsPanelGateCount;
                        portableWorkspaceDependenciesSettingsPanelGateOccurrences +=
                            portableWorkspaceDependenciesSettingsPanelGateCount;
                        portableConfigModeEquivalenceOccurrences +=
                            portableConfigModeEquivalenceCount;
                        portableConfigModeShortLabelOccurrences +=
                            portableConfigModeShortLabelCount;
                        portableConfigModeOptionLabelOccurrences +=
                            portableConfigModeOptionLabelCount;
                        portableBrowserPluginAvailabilityOccurrences +=
                            portableBrowserPluginAvailabilityCount;
                        portableChromePluginAvailabilityOccurrences +=
                            portableChromePluginAvailabilityCount;
                        portableComputerUsePluginAvailabilityOccurrences +=
                            portableComputerUsePluginAvailabilityCount;
                        portableBrowserPluginReconcileAvailabilityOccurrences +=
                            portableBrowserPluginReconcileAvailabilityCount;
                        portableChromePluginReconcileAvailabilityOccurrences +=
                            portableChromePluginReconcileAvailabilityCount;
                        portableComputerUsePluginReconcileAvailabilityOccurrences +=
                            portableComputerUsePluginReconcileAvailabilityCount;
                        portableSunsetUpdateGateOccurrences += portableSunsetUpdateGateCount;
                    }
                    if (portableSparkleGateOccurrences != 1 ||
                        portableWorkerSparkleGateOccurrences != 1 ||
                        portableUpdateMenuOccurrences != 1 ||
                        portableRecoveryOccurrences != 1 ||
                        portableUpdaterIdleStateOccurrences != 1 ||
                        portableRuntimeStaticDisabledReasonOccurrences != 1 ||
                        portableRuntimeInstallGuardOccurrences != 1 ||
                        portableRuntimeDebugMenuGateOccurrences != 1 ||
                        portableConfigModeEquivalenceOccurrences != 1 ||
                        portableConfigModeShortLabelOccurrences != ConfigModeShortLabelExpectedOccurrences ||
                        portableConfigModeOptionLabelOccurrences != ConfigModeOptionLabelExpectedOccurrences ||
                        portableBrowserPluginAvailabilityOccurrences != 1 ||
                        portableChromePluginAvailabilityOccurrences != 1 ||
                        portableComputerUsePluginAvailabilityOccurrences != 1 ||
                        portableBrowserPluginReconcileAvailabilityOccurrences != 1 ||
                        portableChromePluginReconcileAvailabilityOccurrences != 1 ||
                        portableComputerUsePluginReconcileAvailabilityOccurrences != 1 ||
                        portableSunsetUpdateGateOccurrences != 1) return false;
                    if (workspaceDependenciesSettingsFunctionOccurrences != 1 ||
                        officialWorkspaceDependenciesSettingsPanelGateOccurrences != 0 ||
                        portableWorkspaceDependenciesSettingsPanelGateOccurrences != 1) return false;

                    List<OnboardingEntryTarget> onboardingEntries = FindOnboardingEntries(archive);
                    int officialStandardOnboardingOccurrences = 0;
                    int portableStandardOnboardingOccurrences = 0;
                    for (int i = 0; i < onboardingEntries.Count; i++)
                    {
                        OnboardingEntryTarget target = onboardingEntries[i];
                        byte[] bytes = archive.ReadEntry(target.Entry);
                        List<OnboardingLiteralTarget> literals = AnalyzeOnboardingEntry(bytes, target);
                        officialStandardOnboardingOccurrences += CountPattern(bytes,
                            Encoding.UTF8.GetBytes(OfficialStandardOnboardingGateText));
                        portableStandardOnboardingOccurrences += CountPattern(bytes,
                            Encoding.UTF8.GetBytes(PortableStandardOnboardingGateText));
                        if (!literals[0].IsPortable || !literals[1].IsPortable ||
                            !IntegrityMatches(target.Entry,
                                ComputeIntegrity(bytes, target.Entry.BlockSize))) return false;
                    }
                    if (officialStandardOnboardingOccurrences != 0 ||
                        portableStandardOnboardingOccurrences != 1) return false;

                    AsarEntry onboardingHeaderIcon = FindOnboardingHeaderIconEntry(archive);
                    byte[] onboardingHeaderIconBytes = archive.ReadEntry(onboardingHeaderIcon);
                    if (!HasOnboardingHeaderIconState(onboardingHeaderIconBytes, true) ||
                        !HasWindowsSetupOnboardingState(onboardingHeaderIconBytes, true) ||
                        !HasWindowsSetupBannerGateState(onboardingHeaderIconBytes, true) ||
                        !HasWindowsSandboxReadinessGateState(onboardingHeaderIconBytes, true) ||
                        !HasWindowsSandboxSetupPendingGateState(onboardingHeaderIconBytes, true) ||
                        !IntegrityMatches(onboardingHeaderIcon,
                            ComputeIntegrity(onboardingHeaderIconBytes,
                                onboardingHeaderIcon.BlockSize))) return false;
                    return true;
                }
            }
            catch { return false; }
        }

        private static List<OnboardingEntryTarget> FindOnboardingEntries(AsarArchive archive)
        {
            if (TranslatedOnboardingAssetStems.Length != ExpectedTranslatedOnboardingLocaleEntries ||
                ExpectedTranslatedOnboardingLocaleEntries + 1 != ExpectedOnboardingLocaleEntries)
                throw new InvalidDataException("Electron onboarding locale inventory is invalid.");

            List<OnboardingEntryTarget> result = new List<OnboardingEntryTarget>();
            for (int localeIndex = 0; localeIndex < TranslatedOnboardingAssetStems.Length; localeIndex++)
            {
                AsarEntry match = null;
                for (int entryIndex = 0; entryIndex < archive.Entries.Count; entryIndex++)
                {
                    AsarEntry candidate = archive.Entries[entryIndex];
                    if (!IsHashedWebviewAsset(candidate.Path,
                            TranslatedOnboardingAssetStems[localeIndex])) continue;
                    if (match != null)
                        throw new InvalidDataException("Electron onboarding locale asset is ambiguous: " +
                            TranslatedOnboardingAssetStems[localeIndex]);
                    match = candidate;
                }
                if (match == null)
                    throw new InvalidDataException("Electron onboarding locale asset is missing: " +
                        TranslatedOnboardingAssetStems[localeIndex]);
                OnboardingEntryTarget target = new OnboardingEntryTarget();
                target.Entry = match;
                target.ContainsDefaultMessages = false;
                result.Add(target);
            }

            AsarEntry onboardingPage = null;
            for (int i = 0; i < archive.Entries.Count; i++)
            {
                AsarEntry candidate = archive.Entries[i];
                if (!IsHashedWebviewAsset(candidate.Path, OnboardingPageAssetStem)) continue;
                if (onboardingPage != null)
                    throw new InvalidDataException("Electron onboarding default-message asset is ambiguous.");
                onboardingPage = candidate;
            }
            if (onboardingPage == null)
                throw new InvalidDataException("Electron onboarding default-message asset is missing.");
            OnboardingEntryTarget defaultMessages = new OnboardingEntryTarget();
            defaultMessages.Entry = onboardingPage;
            defaultMessages.ContainsDefaultMessages = true;
            result.Add(defaultMessages);

            if (result.Count != ExpectedOnboardingLocaleEntries)
                throw new InvalidDataException("Electron onboarding locale count changed unexpectedly.");
            return result;
        }

        private static bool IsHashedWebviewAsset(string path, string stem)
        {
            string prefix = WebviewAssetPrefix + stem + "-";
            const string extension = ".js";
            if (!path.StartsWith(prefix, StringComparison.Ordinal) ||
                !path.EndsWith(extension, StringComparison.OrdinalIgnoreCase)) return false;
            int hashLength = path.Length - prefix.Length - extension.Length;
            if (hashLength != 8) return false;
            for (int i = prefix.Length; i < prefix.Length + hashLength; i++)
            {
                char value = path[i];
                if ((value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') ||
                    (value >= '0' && value <= '9') || value == '-' || value == '_') continue;
                return false;
            }
            return true;
        }

        private static AsarEntry FindOnboardingHeaderIconEntry(AsarArchive archive)
        {
            AsarEntry result = null;
            for (int i = 0; i < archive.Entries.Count; i++)
            {
                AsarEntry candidate = archive.Entries[i];
                if (!IsHashedWebviewAsset(candidate.Path, AppInitialAssetStem)) continue;
                if (result != null)
                    throw new InvalidDataException("Electron onboarding header icon asset is ambiguous.");
                result = candidate;
            }
            if (result == null)
                throw new InvalidDataException("Electron onboarding header icon asset is missing.");
            return result;
        }

        private static void EnsureOnboardingHeaderIconEntry(AsarArchive archive, AsarEntry entry)
        {
            archive.FlushHeader();
            byte[] currentBytes = archive.ReadEntry(entry);
            bool iconIsOfficial = HasOnboardingHeaderIconState(currentBytes, false);
            bool iconIsPortable = HasOnboardingHeaderIconState(currentBytes, true);
            bool windowsSetupIsOfficial = HasWindowsSetupOnboardingState(currentBytes, false);
            bool windowsSetupIsPortable = HasWindowsSetupOnboardingState(currentBytes, true);
            bool bannerGateIsOfficial = HasWindowsSetupBannerGateState(currentBytes, false);
            bool bannerGateIsPortable = HasWindowsSetupBannerGateState(currentBytes, true);
            bool readinessGateIsOfficial = HasWindowsSandboxReadinessGateState(currentBytes, false);
            bool readinessGateIsPortable = HasWindowsSandboxReadinessGateState(currentBytes, true);
            bool setupPendingGateIsOfficial =
                HasWindowsSandboxSetupPendingGateState(currentBytes, false);
            bool setupPendingGateIsPortable =
                HasWindowsSandboxSetupPendingGateState(currentBytes, true);
            bool isOfficial = iconIsOfficial && windowsSetupIsOfficial && bannerGateIsOfficial &&
                readinessGateIsOfficial && setupPendingGateIsOfficial;
            bool isLegacyPortable = iconIsPortable && windowsSetupIsOfficial && bannerGateIsOfficial &&
                readinessGateIsOfficial && setupPendingGateIsOfficial;
            bool isOnboardingPortable = iconIsPortable && windowsSetupIsPortable && bannerGateIsOfficial &&
                readinessGateIsOfficial && setupPendingGateIsOfficial;
            bool isBannerPortable = iconIsPortable && windowsSetupIsPortable && bannerGateIsPortable &&
                readinessGateIsOfficial && setupPendingGateIsOfficial;
            bool isPortable = iconIsPortable && windowsSetupIsPortable && bannerGateIsPortable &&
                readinessGateIsPortable && setupPendingGateIsPortable;
            int recognizedStates = (isOfficial ? 1 : 0) + (isLegacyPortable ? 1 : 0) +
                (isOnboardingPortable ? 1 : 0) + (isBannerPortable ? 1 : 0) +
                (isPortable ? 1 : 0);
            if (recognizedStates != 1)
                throw new InvalidDataException(
                    "Electron onboarding header state is mixed, missing, or ambiguous: " + entry.Path);

            byte[] originalBytes = (byte[])currentBytes.Clone();
            if (iconIsPortable)
                ReplacePattern(originalBytes, Encoding.UTF8.GetBytes(PortableOnboardingHeaderIconText),
                    Encoding.UTF8.GetBytes(OfficialOnboardingHeaderIconText));
            if (windowsSetupIsPortable)
                ReplacePattern(originalBytes,
                    Encoding.UTF8.GetBytes(PortableWindowsSetupOnboardingStateText),
                    Encoding.UTF8.GetBytes(OfficialWindowsSetupOnboardingStateText));
            if (bannerGateIsPortable)
                ReplacePattern(originalBytes,
                    Encoding.UTF8.GetBytes(PortableWindowsSetupBannerGateText),
                    Encoding.UTF8.GetBytes(OfficialWindowsSetupBannerGateText));
            if (readinessGateIsPortable)
                ReplacePattern(originalBytes,
                    Encoding.UTF8.GetBytes(PortableWindowsSandboxReadinessGateText),
                    Encoding.UTF8.GetBytes(OfficialWindowsSandboxReadinessGateText));
            if (setupPendingGateIsPortable)
                ReplacePattern(originalBytes,
                    Encoding.UTF8.GetBytes(PortableWindowsSandboxSetupPendingGateText),
                    Encoding.UTF8.GetBytes(OfficialWindowsSandboxSetupPendingGateText));

            byte[] legacyPortableBytes = (byte[])originalBytes.Clone();
            ReplacePattern(legacyPortableBytes, Encoding.UTF8.GetBytes(OfficialOnboardingHeaderIconText),
                Encoding.UTF8.GetBytes(PortableOnboardingHeaderIconText));

            byte[] onboardingPortableBytes = (byte[])legacyPortableBytes.Clone();
            byte[] officialWindowsSetup = Encoding.UTF8.GetBytes(OfficialWindowsSetupOnboardingStateText);
            byte[] portableWindowsSetup = Encoding.UTF8.GetBytes(PortableWindowsSetupOnboardingStateText);
            if (officialWindowsSetup.Length != portableWindowsSetup.Length)
                throw new InvalidDataException(
                    "Electron Windows-setup onboarding replacement must preserve entry length.");
            ReplacePattern(onboardingPortableBytes, officialWindowsSetup, portableWindowsSetup);

            byte[] bannerPortableBytes = (byte[])onboardingPortableBytes.Clone();
            byte[] officialBannerGate = Encoding.UTF8.GetBytes(OfficialWindowsSetupBannerGateText);
            byte[] portableBannerGate = Encoding.UTF8.GetBytes(PortableWindowsSetupBannerGateText);
            if (officialBannerGate.Length != portableBannerGate.Length)
                throw new InvalidDataException(
                    "Electron Windows-setup banner gate replacement must preserve entry length.");
            ReplacePattern(bannerPortableBytes, officialBannerGate, portableBannerGate);

            byte[] readinessPortableBytes = (byte[])bannerPortableBytes.Clone();
            byte[] officialReadinessGate =
                Encoding.UTF8.GetBytes(OfficialWindowsSandboxReadinessGateText);
            byte[] portableReadinessGate =
                Encoding.UTF8.GetBytes(PortableWindowsSandboxReadinessGateText);
            if (officialReadinessGate.Length != portableReadinessGate.Length)
                throw new InvalidDataException(
                    "Electron Windows-sandbox readiness gate replacement must preserve entry length.");
            ReplacePattern(readinessPortableBytes, officialReadinessGate, portableReadinessGate);

            byte[] portableBytes = (byte[])readinessPortableBytes.Clone();
            byte[] officialSetupPendingGate =
                Encoding.UTF8.GetBytes(OfficialWindowsSandboxSetupPendingGateText);
            byte[] portableSetupPendingGate =
                Encoding.UTF8.GetBytes(PortableWindowsSandboxSetupPendingGateText);
            if (officialSetupPendingGate.Length != portableSetupPendingGate.Length)
                throw new InvalidDataException(
                    "Electron Windows-sandbox setup-pending gate replacement must preserve entry length.");
            ReplacePattern(portableBytes, officialSetupPendingGate, portableSetupPendingGate);

            if (!HasOnboardingHeaderIconState(originalBytes, false) ||
                !HasWindowsSetupOnboardingState(originalBytes, false) ||
                !HasWindowsSetupBannerGateState(originalBytes, false) ||
                !HasWindowsSandboxReadinessGateState(originalBytes, false) ||
                !HasWindowsSandboxSetupPendingGateState(originalBytes, false) ||
                !HasOnboardingHeaderIconState(legacyPortableBytes, true) ||
                !HasWindowsSetupOnboardingState(legacyPortableBytes, false) ||
                !HasWindowsSetupBannerGateState(legacyPortableBytes, false) ||
                !HasWindowsSandboxReadinessGateState(legacyPortableBytes, false) ||
                !HasWindowsSandboxSetupPendingGateState(legacyPortableBytes, false) ||
                !HasOnboardingHeaderIconState(onboardingPortableBytes, true) ||
                !HasWindowsSetupOnboardingState(onboardingPortableBytes, true) ||
                !HasWindowsSetupBannerGateState(onboardingPortableBytes, false) ||
                !HasWindowsSandboxReadinessGateState(onboardingPortableBytes, false) ||
                !HasWindowsSandboxSetupPendingGateState(onboardingPortableBytes, false) ||
                !HasOnboardingHeaderIconState(bannerPortableBytes, true) ||
                !HasWindowsSetupOnboardingState(bannerPortableBytes, true) ||
                !HasWindowsSetupBannerGateState(bannerPortableBytes, true) ||
                !HasWindowsSandboxReadinessGateState(bannerPortableBytes, false) ||
                !HasWindowsSandboxSetupPendingGateState(bannerPortableBytes, false) ||
                !HasOnboardingHeaderIconState(readinessPortableBytes, true) ||
                !HasWindowsSetupOnboardingState(readinessPortableBytes, true) ||
                !HasWindowsSetupBannerGateState(readinessPortableBytes, true) ||
                !HasWindowsSandboxReadinessGateState(readinessPortableBytes, true) ||
                !HasWindowsSandboxSetupPendingGateState(readinessPortableBytes, false) ||
                !HasOnboardingHeaderIconState(portableBytes, true) ||
                !HasWindowsSetupOnboardingState(portableBytes, true) ||
                !HasWindowsSetupBannerGateState(portableBytes, true) ||
                !HasWindowsSandboxReadinessGateState(portableBytes, true) ||
                !HasWindowsSandboxSetupPendingGateState(portableBytes, true))
                throw new InvalidDataException("Electron onboarding header transformation failed: " +
                    entry.Path);

            IntegrityState originalIntegrity = ComputeIntegrity(originalBytes, entry.BlockSize);
            IntegrityState legacyPortableIntegrity = ComputeIntegrity(legacyPortableBytes, entry.BlockSize);
            IntegrityState onboardingPortableIntegrity = ComputeIntegrity(onboardingPortableBytes,
                entry.BlockSize);
            IntegrityState bannerPortableIntegrity = ComputeIntegrity(bannerPortableBytes,
                entry.BlockSize);
            IntegrityState portableIntegrity = ComputeIntegrity(portableBytes, entry.BlockSize);
            // Repair either ordering of the entry write and header update after an interrupted prior run.
            bool headerIsOriginal = IntegrityMatches(entry, originalIntegrity);
            bool headerIsLegacyPortable = IntegrityMatches(entry, legacyPortableIntegrity);
            bool headerIsOnboardingPortable = IntegrityMatches(entry, onboardingPortableIntegrity);
            bool headerIsBannerPortable = IntegrityMatches(entry, bannerPortableIntegrity);
            bool headerIsPortable = IntegrityMatches(entry, portableIntegrity);
            if (!headerIsOriginal && !headerIsLegacyPortable && !headerIsOnboardingPortable &&
                !headerIsBannerPortable && !headerIsPortable)
                throw new InvalidDataException("Electron onboarding header entry failed integrity verification: " +
                    entry.Path);

            if (!isPortable) archive.WriteEntry(entry, portableBytes);
            if (!headerIsPortable) archive.AddIntegrityReplacement(entry, portableIntegrity);
        }

        private static bool HasOnboardingHeaderIconState(byte[] bytes, bool portable)
        {
            byte[] selectedIcon = Encoding.UTF8.GetBytes(portable ?
                PortableOnboardingHeaderIconText : OfficialOnboardingHeaderIconText);
            byte[] rejectedIcon = Encoding.UTF8.GetBytes(portable ?
                OfficialOnboardingHeaderIconText : PortableOnboardingHeaderIconText);
            return CountPattern(bytes, selectedIcon) == 1 && CountPattern(bytes, rejectedIcon) == 0;
        }

        private static bool HasWindowsSetupOnboardingState(byte[] bytes, bool portable)
        {
            byte[] selected = Encoding.UTF8.GetBytes(portable ?
                PortableWindowsSetupOnboardingStateText : OfficialWindowsSetupOnboardingStateText);
            byte[] rejected = Encoding.UTF8.GetBytes(portable ?
                OfficialWindowsSetupOnboardingStateText : PortableWindowsSetupOnboardingStateText);
            return CountPattern(bytes, selected) == 1 && CountPattern(bytes, rejected) == 0;
        }

        private static bool HasWindowsSetupBannerGateState(byte[] bytes, bool portable)
        {
            byte[] selected = Encoding.UTF8.GetBytes(portable ?
                PortableWindowsSetupBannerGateText : OfficialWindowsSetupBannerGateText);
            byte[] rejected = Encoding.UTF8.GetBytes(portable ?
                OfficialWindowsSetupBannerGateText : PortableWindowsSetupBannerGateText);
            return CountPattern(bytes, selected) == 1 && CountPattern(bytes, rejected) == 0;
        }

        private static bool HasWindowsSandboxReadinessGateState(byte[] bytes, bool portable)
        {
            byte[] selected = Encoding.UTF8.GetBytes(portable ?
                PortableWindowsSandboxReadinessGateText : OfficialWindowsSandboxReadinessGateText);
            byte[] rejected = Encoding.UTF8.GetBytes(portable ?
                OfficialWindowsSandboxReadinessGateText : PortableWindowsSandboxReadinessGateText);
            return CountPattern(bytes, selected) == 1 && CountPattern(bytes, rejected) == 0;
        }

        private static bool HasWindowsSandboxSetupPendingGateState(byte[] bytes, bool portable)
        {
            byte[] selected = Encoding.UTF8.GetBytes(portable ?
                PortableWindowsSandboxSetupPendingGateText :
                OfficialWindowsSandboxSetupPendingGateText);
            byte[] rejected = Encoding.UTF8.GetBytes(portable ?
                OfficialWindowsSandboxSetupPendingGateText :
                PortableWindowsSandboxSetupPendingGateText);
            return CountPattern(bytes, selected) == 1 && CountPattern(bytes, rejected) == 0;
        }

        private static void EnsureOnboardingEntry(AsarArchive archive, OnboardingEntryTarget target)
        {
            archive.FlushHeader();
            byte[] currentBytes = archive.ReadEntry(target.Entry);
            List<OnboardingLiteralTarget> currentLiterals = AnalyzeOnboardingEntry(currentBytes, target);
            bool isPortable = currentLiterals[0].IsPortable;
            if (currentLiterals[1].IsPortable != isPortable)
                throw new InvalidDataException("Electron onboarding entry contains mixed branding: " +
                    target.Entry.Path);

            byte[] officialGate = Encoding.UTF8.GetBytes(OfficialStandardOnboardingGateText);
            byte[] portableGate = Encoding.UTF8.GetBytes(PortableStandardOnboardingGateText);
            if (officialGate.Length != portableGate.Length)
                throw new InvalidDataException("Electron onboarding gate replacement must preserve entry length.");
            int officialGateCount = CountPattern(currentBytes, officialGate);
            int portableGateCount = CountPattern(currentBytes, portableGate);
            bool gateIsPortable = portableGateCount == 1;
            if (target.ContainsDefaultMessages)
            {
                if (officialGateCount + portableGateCount != 1)
                    throw new InvalidDataException(
                        "Electron standard-onboarding gate is missing, mixed, or ambiguous: " +
                        target.Entry.Path);
            }
            else if (officialGateCount != 0 || portableGateCount != 0)
                throw new InvalidDataException(
                    "Electron standard-onboarding gate appeared in a locale asset: " +
                    target.Entry.Path);

            byte[] originalBytes = (byte[])currentBytes.Clone();
            if (isPortable)
            {
                for (int i = 0; i < currentLiterals.Count; i++)
                    ConvertOnboardingLiteral(originalBytes, currentLiterals[i], false);
            }
            if (target.ContainsDefaultMessages && gateIsPortable)
                ReplacePattern(originalBytes, portableGate, officialGate);

            byte[] legacyPortableBytes = (byte[])originalBytes.Clone();
            List<OnboardingLiteralTarget> originalLiterals = AnalyzeOnboardingEntry(originalBytes, target);
            for (int i = 0; i < originalLiterals.Count; i++)
                ConvertOnboardingLiteral(legacyPortableBytes, originalLiterals[i], true);

            byte[] portableBytes = (byte[])legacyPortableBytes.Clone();
            if (target.ContainsDefaultMessages)
                ReplacePattern(portableBytes, officialGate, portableGate);

            ValidateOnboardingState(originalBytes, target, false);
            ValidateOnboardingState(legacyPortableBytes, target, true);
            ValidateOnboardingState(portableBytes, target, true);
            if (target.ContainsDefaultMessages)
            {
                if (!HasStandardOnboardingGateState(originalBytes, false) ||
                    !HasStandardOnboardingGateState(legacyPortableBytes, false) ||
                    !HasStandardOnboardingGateState(portableBytes, true))
                    throw new InvalidDataException(
                        "Electron standard-onboarding gate transformation failed: " +
                        target.Entry.Path);
            }
            IntegrityState originalIntegrity = ComputeIntegrity(originalBytes, target.Entry.BlockSize);
            IntegrityState legacyPortableIntegrity = ComputeIntegrity(legacyPortableBytes,
                target.Entry.BlockSize);
            IntegrityState portableIntegrity = ComputeIntegrity(portableBytes, target.Entry.BlockSize);
            // The legacy state is branding-only (through 1.2.4). Accept it so existing
            // portable payloads upgrade in place, while still rejecting unrecognized bytes.
            bool headerIsOriginal = IntegrityMatches(target.Entry, originalIntegrity);
            bool headerIsLegacyPortable = IntegrityMatches(target.Entry, legacyPortableIntegrity);
            bool headerIsPortable = IntegrityMatches(target.Entry, portableIntegrity);
            if (!headerIsOriginal && !headerIsLegacyPortable && !headerIsPortable)
                throw new InvalidDataException("Electron onboarding entry failed integrity verification: " +
                    target.Entry.Path);

            if (!isPortable || (target.ContainsDefaultMessages && !gateIsPortable))
                archive.WriteEntry(target.Entry, portableBytes);
            if (!headerIsPortable) archive.AddIntegrityReplacement(target.Entry, portableIntegrity);
        }

        private static bool HasStandardOnboardingGateState(byte[] bytes, bool portable)
        {
            byte[] official = Encoding.UTF8.GetBytes(OfficialStandardOnboardingGateText);
            byte[] patched = Encoding.UTF8.GetBytes(PortableStandardOnboardingGateText);
            return portable ? CountPattern(bytes, official) == 0 && CountPattern(bytes, patched) == 1 :
                CountPattern(bytes, official) == 1 && CountPattern(bytes, patched) == 0;
        }

        private static List<OnboardingLiteralTarget> AnalyzeOnboardingEntry(byte[] bytes,
            OnboardingEntryTarget entryTarget)
        {
            List<OnboardingLiteralTarget> result = new List<OnboardingLiteralTarget>();
            result.Add(FindOnboardingLiteral(bytes, "roleOnlyWelcomeIntroduction",
                entryTarget.ContainsDefaultMessages));
            result.Add(FindOnboardingLiteral(bytes, "welcomeIntroduction",
                entryTarget.ContainsDefaultMessages));
            return result;
        }

        private static OnboardingLiteralTarget FindOnboardingLiteral(byte[] bytes, string key,
            bool containsDefaultMessages)
        {
            string id = OnboardingMessageIdPrefix + key;
            string officialPrefix;
            string portablePrefix;
            if (containsDefaultMessages)
            {
                string common = key + ":{id:`" + id + "`,defaultMessage:";
                officialPrefix = common + "`";
                portablePrefix = common + "  `";
            }
            else
            {
                string common = "\"" + id + "\":";
                officialPrefix = common + "`";
                portablePrefix = common + "  `";
            }

            byte[] officialPrefixBytes = Encoding.UTF8.GetBytes(officialPrefix);
            byte[] portablePrefixBytes = Encoding.UTF8.GetBytes(portablePrefix);
            int officialCount = CountPattern(bytes, officialPrefixBytes);
            int portableCount = CountPattern(bytes, portablePrefixBytes);
            if (officialCount + portableCount != 1)
                throw new InvalidDataException("Electron onboarding message target is missing or ambiguous: " + id);

            bool isPortable = portableCount == 1;
            byte[] selectedPrefix = isPortable ? portablePrefixBytes : officialPrefixBytes;
            int prefixOffset = FindPattern(bytes, selectedPrefix, 0, bytes.Length);
            int openingTickOffset = prefixOffset + selectedPrefix.Length - 1;
            int closingTickOffset = FindTemplateLiteralEnd(bytes, openingTickOffset);
            byte[] officialBrand = Encoding.UTF8.GetBytes(OfficialOnboardingBrandText);
            byte[] portableBrand = Encoding.UTF8.GetBytes(PortableOnboardingBrandText);
            int officialBrandCount = CountPattern(bytes, officialBrand,
                openingTickOffset + 1, closingTickOffset);
            int portableBrandCount = CountPattern(bytes, portableBrand,
                openingTickOffset + 1, closingTickOffset);
            if ((!isPortable && (officialBrandCount != 1 || portableBrandCount != 0)) ||
                (isPortable && (officialBrandCount != 0 || portableBrandCount != 1)))
                throw new InvalidDataException("Electron onboarding message brand is invalid: " + id);

            OnboardingLiteralTarget result = new OnboardingLiteralTarget();
            result.IsPortable = isPortable;
            result.OpeningTickOffset = openingTickOffset;
            result.BrandOffset = FindPattern(bytes, isPortable ? portableBrand : officialBrand,
                openingTickOffset + 1, closingTickOffset);
            return result;
        }

        private static int FindTemplateLiteralEnd(byte[] bytes, int openingTickOffset)
        {
            if (openingTickOffset < 0 || openingTickOffset >= bytes.Length || bytes[openingTickOffset] != 0x60)
                throw new InvalidDataException("Electron onboarding message literal is invalid.");
            bool escaped = false;
            for (int i = openingTickOffset + 1; i < bytes.Length; i++)
            {
                byte value = bytes[i];
                if (escaped) { escaped = false; continue; }
                if (value == 0x5c) { escaped = true; continue; }
                if (value == 0x24 && i + 1 < bytes.Length && bytes[i + 1] == 0x7b)
                    throw new InvalidDataException("Electron onboarding message must be a static template literal.");
                if (value == 0x60) return i;
            }
            throw new InvalidDataException("Electron onboarding message literal is unterminated.");
        }

        private static void ConvertOnboardingLiteral(byte[] bytes, OnboardingLiteralTarget target,
            bool makePortable)
        {
            byte[] officialBrand = Encoding.UTF8.GetBytes(OfficialOnboardingBrandText);
            byte[] portableBrand = Encoding.UTF8.GetBytes(PortableOnboardingBrandText);
            if (officialBrand.Length - portableBrand.Length != OnboardingBrandPaddingLength)
                throw new InvalidDataException("Electron onboarding brand replacement length is invalid.");

            if (makePortable)
            {
                if (target.IsPortable || target.BrandOffset < target.OpeningTickOffset + 1 ||
                    target.BrandOffset + officialBrand.Length > bytes.Length)
                    throw new InvalidDataException("Electron onboarding official message bounds are invalid.");
                // Put the two compensating bytes in JavaScript syntax whitespace, outside the displayed value.
                Buffer.BlockCopy(bytes, target.OpeningTickOffset, bytes,
                    target.OpeningTickOffset + OnboardingBrandPaddingLength,
                    target.BrandOffset - target.OpeningTickOffset);
                for (int i = 0; i < OnboardingBrandPaddingLength; i++)
                    bytes[target.OpeningTickOffset + i] = 0x20;
                Buffer.BlockCopy(portableBrand, 0, bytes,
                    target.BrandOffset + OnboardingBrandPaddingLength, portableBrand.Length);
            }
            else
            {
                if (!target.IsPortable || target.OpeningTickOffset < OnboardingBrandPaddingLength ||
                    target.BrandOffset < target.OpeningTickOffset + 1 ||
                    target.BrandOffset + portableBrand.Length > bytes.Length)
                    throw new InvalidDataException("Electron onboarding portable message bounds are invalid.");
                int officialOpeningTickOffset = target.OpeningTickOffset - OnboardingBrandPaddingLength;
                Buffer.BlockCopy(bytes, target.OpeningTickOffset, bytes, officialOpeningTickOffset,
                    target.BrandOffset - target.OpeningTickOffset);
                Buffer.BlockCopy(officialBrand, 0, bytes,
                    target.BrandOffset - OnboardingBrandPaddingLength, officialBrand.Length);
            }
        }

        private static void ValidateOnboardingState(byte[] bytes, OnboardingEntryTarget target,
            bool expectedPortable)
        {
            List<OnboardingLiteralTarget> literals = AnalyzeOnboardingEntry(bytes, target);
            if (literals.Count != 2 || literals[0].IsPortable != expectedPortable ||
                literals[1].IsPortable != expectedPortable)
                throw new InvalidDataException("Electron onboarding message transformation failed: " +
                    target.Entry.Path);
        }

        private static int EnsureDirectClosePattern(AsarArchive archive, AsarEntry entry)
        {
            // A single minified entry can carry more than one independent
            // replacement (for example the update menu and runtime guard).
            // Commit an earlier entry transformation before validating the
            // next one, otherwise its current bytes would not match the
            // still-original integrity header.
            archive.FlushHeader();
            byte[] official = Encoding.UTF8.GetBytes(OfficialCloseToTrayText);
            byte[] legacyPortable = Encoding.UTF8.GetBytes(LegacyPortableCloseToTrayText);
            byte[] portable = Encoding.UTF8.GetBytes(PortableCloseToTrayText);
            byte[] electronAlias = Encoding.UTF8.GetBytes(PortableCloseElectronAliasText);
            if (official.Length != legacyPortable.Length || official.Length != portable.Length)
                throw new InvalidDataException("Electron direct-close replacements must preserve entry length.");

            byte[] currentBytes = archive.ReadEntry(entry);
            int officialCount = CountPattern(currentBytes, official);
            int legacyPortableCount = CountPattern(currentBytes, legacyPortable);
            int portableCount = CountPattern(currentBytes, portable);
            int stateCount = officialCount + legacyPortableCount + portableCount;
            if (stateCount == 0) return 0;
            if (officialCount > 1 || legacyPortableCount > 1 || portableCount > 1 || stateCount != 1)
                throw new InvalidDataException("Electron direct-close target is mixed or ambiguous: " + entry.Path);
            if (CountPattern(currentBytes, electronAlias) != 1)
                throw new InvalidDataException("Electron direct-close app alias is missing or ambiguous: " + entry.Path);

            byte[] originalBytes;
            byte[] legacyPortableBytes;
            byte[] portableBytes;
            if (officialCount == 1)
            {
                originalBytes = currentBytes;
                legacyPortableBytes = (byte[])currentBytes.Clone();
                portableBytes = (byte[])currentBytes.Clone();
                ReplacePattern(legacyPortableBytes, official, legacyPortable);
                ReplacePattern(portableBytes, official, portable);
            }
            else if (legacyPortableCount == 1)
            {
                legacyPortableBytes = currentBytes;
                originalBytes = (byte[])currentBytes.Clone();
                portableBytes = (byte[])currentBytes.Clone();
                ReplacePattern(originalBytes, legacyPortable, official);
                ReplacePattern(portableBytes, legacyPortable, portable);
            }
            else
            {
                portableBytes = currentBytes;
                originalBytes = (byte[])currentBytes.Clone();
                legacyPortableBytes = (byte[])currentBytes.Clone();
                ReplacePattern(originalBytes, portable, official);
                ReplacePattern(legacyPortableBytes, portable, legacyPortable);
            }

            if (CountPattern(originalBytes, official) != 1 ||
                CountPattern(originalBytes, legacyPortable) != 0 || CountPattern(originalBytes, portable) != 0 ||
                CountPattern(legacyPortableBytes, official) != 0 ||
                CountPattern(legacyPortableBytes, legacyPortable) != 1 ||
                CountPattern(legacyPortableBytes, portable) != 0 ||
                CountPattern(portableBytes, official) != 0 ||
                CountPattern(portableBytes, legacyPortable) != 0 || CountPattern(portableBytes, portable) != 1)
                throw new InvalidDataException("Electron direct-close transformation failed: " + entry.Path);

            IntegrityState originalIntegrity = ComputeIntegrity(originalBytes, entry.BlockSize);
            IntegrityState legacyPortableIntegrity = ComputeIntegrity(legacyPortableBytes, entry.BlockSize);
            IntegrityState portableIntegrity = ComputeIntegrity(portableBytes, entry.BlockSize);
            bool headerIsOriginal = IntegrityMatches(entry, originalIntegrity);
            bool headerIsLegacyPortable = IntegrityMatches(entry, legacyPortableIntegrity);
            bool headerIsPortable = IntegrityMatches(entry, portableIntegrity);
            if (!headerIsOriginal && !headerIsLegacyPortable && !headerIsPortable)
                throw new InvalidDataException("Electron direct-close entry failed integrity verification: " + entry.Path);

            if (portableCount != 1) archive.WriteEntry(entry, portableBytes);
            if (!headerIsPortable) archive.AddIntegrityReplacement(entry, portableIntegrity);
            return 1;
        }

        private static int VerifyArchiveIntegrityAndCountJavaScriptPattern(
            AsarArchive archive, string text)
        {
            byte[] pattern = Encoding.UTF8.GetBytes(text);
            int occurrences = 0;
            for (int i = 0; i < archive.Entries.Count; i++)
            {
                AsarEntry entry = archive.Entries[i];
                byte[] bytes = archive.ReadEntry(entry);
                if (!IntegrityMatches(entry, ComputeIntegrity(bytes, entry.BlockSize)))
                    throw new InvalidDataException(
                        "Electron ASAR entry failed integrity verification: " + entry.Path);
                if (entry.Path.EndsWith(".js", StringComparison.OrdinalIgnoreCase))
                    occurrences += CountPattern(bytes, pattern);
            }
            return occurrences;
        }

        private static void VerifyArchiveJavaScriptPatternState(AsarArchive archive,
            string officialText, string portableText, int expectedOccurrences, string errorMessage)
        {
            if (expectedOccurrences < 1)
                throw new InvalidDataException("Electron ASAR expected occurrence count is invalid.");
            byte[] official = Encoding.UTF8.GetBytes(officialText);
            byte[] portable = Encoding.UTF8.GetBytes(portableText);
            if (official.Length != portable.Length)
                throw new InvalidDataException("Portable ASAR replacements must preserve entry length.");
            int officialOccurrences = 0;
            int portableOccurrences = 0;
            for (int i = 0; i < archive.Entries.Count; i++)
            {
                AsarEntry entry = archive.Entries[i];
                if (!entry.Path.EndsWith(".js", StringComparison.OrdinalIgnoreCase)) continue;
                byte[] bytes = archive.ReadEntry(entry);
                if (!IntegrityMatches(entry, ComputeIntegrity(bytes, entry.BlockSize)))
                    throw new InvalidDataException(
                        "Electron ASAR entry failed integrity verification: " + entry.Path);
                officialOccurrences += CountPattern(bytes, official);
                portableOccurrences += CountPattern(bytes, portable);
            }
            if (!((officialOccurrences == expectedOccurrences && portableOccurrences == 0) ||
                (officialOccurrences == 0 && portableOccurrences == expectedOccurrences)))
                throw new InvalidDataException(errorMessage);
        }

        private static int EnsurePattern(AsarArchive archive, AsarEntry entry, string officialText,
            string portableText, int maximumOccurrences = 1)
        {
            // Multiple fixed-length patches may share one ASAR entry.  Flush
            // pending integrity replacements before reading it so each patch
            // validates against the header that describes the bytes on disk.
            archive.FlushHeader();
            if (maximumOccurrences < 1)
                throw new InvalidDataException("Electron ASAR patch occurrence limit is invalid.");
            byte[] official = Encoding.UTF8.GetBytes(officialText);
            byte[] portable = Encoding.UTF8.GetBytes(portableText);
            if (official.Length != portable.Length)
                throw new InvalidDataException("Portable ASAR replacements must preserve entry length.");
            byte[] bytes = archive.ReadEntry(entry);
            int officialCount = CountPattern(bytes, official);
            int portableCount = CountPattern(bytes, portable);
            if (officialCount == 0 && portableCount == 0) return 0;
            if (officialCount > maximumOccurrences || portableCount > maximumOccurrences)
                throw new InvalidDataException("Electron ASAR patch target is ambiguous: " + entry.Path);
            if (officialCount != 0 && portableCount != 0)
                throw new InvalidDataException("Electron ASAR patch state is mixed.");

            IntegrityState current = ComputeIntegrity(bytes, entry.BlockSize);
            if (officialCount != 0)
            {
                ReplacePattern(bytes, official, portable);
                IntegrityState patched = ComputeIntegrity(bytes, entry.BlockSize);
                if (IntegrityMatches(entry, current))
                {
                    archive.WriteEntry(entry, bytes);
                    archive.AddIntegrityReplacement(entry, patched);
                }
                else if (IntegrityMatches(entry, patched))
                {
                    archive.WriteEntry(entry, bytes);
                }
                else throw new InvalidDataException("Electron ASAR entry failed integrity verification: " + entry.Path);
            }
            else if (!IntegrityMatches(entry, current))
            {
                byte[] restored = (byte[])bytes.Clone();
                ReplacePattern(restored, portable, official);
                IntegrityState original = ComputeIntegrity(restored, entry.BlockSize);
                if (!IntegrityMatches(entry, original))
                    throw new InvalidDataException("Electron ASAR entry contains unrecognized changes: " + entry.Path);
                archive.AddIntegrityReplacement(entry, current);
            }
            return officialCount != 0 ? officialCount : portableCount;
        }

        private static IntegrityState ComputeIntegrity(byte[] bytes, int blockSize)
        {
            IntegrityState result = new IntegrityState();
            using (SHA256 sha = SHA256.Create()) result.Hash = ToHex(sha.ComputeHash(bytes));
            if (bytes.Length == 0)
            {
                result.Blocks.Add(result.Hash);
                return result;
            }
            for (int offset = 0; offset < bytes.Length; offset += blockSize)
            {
                int count = Math.Min(blockSize, bytes.Length - offset);
                using (SHA256 sha = SHA256.Create()) result.Blocks.Add(ToHex(sha.ComputeHash(bytes, offset, count)));
            }
            return result;
        }

        private static bool IntegrityMatches(AsarEntry entry, IntegrityState actual)
        {
            if (!string.Equals(entry.IntegrityHash, actual.Hash, StringComparison.OrdinalIgnoreCase) ||
                entry.IntegrityBlocks.Count != actual.Blocks.Count) return false;
            for (int i = 0; i < entry.IntegrityBlocks.Count; i++)
                if (!string.Equals(entry.IntegrityBlocks[i], actual.Blocks[i], StringComparison.OrdinalIgnoreCase)) return false;
            return true;
        }

        private static int CountPattern(byte[] bytes, byte[] pattern)
        {
            return CountPattern(bytes, pattern, 0, bytes.Length);
        }

        private static int CountPattern(byte[] bytes, byte[] pattern, int start, int endExclusive)
        {
            if (pattern.Length == 0 || start < 0 || endExclusive < start || endExclusive > bytes.Length)
                throw new ArgumentOutOfRangeException("Invalid byte-pattern search bounds.");
            int count = 0;
            for (int i = start; i <= endExclusive - pattern.Length; )
            {
                int j = 0;
                while (j < pattern.Length && bytes[i + j] == pattern[j]) j++;
                if (j == pattern.Length) { count++; i += pattern.Length; }
                else i++;
            }
            return count;
        }

        private static int FindPattern(byte[] bytes, byte[] pattern, int start, int endExclusive)
        {
            if (pattern.Length == 0 || start < 0 || endExclusive < start || endExclusive > bytes.Length)
                throw new ArgumentOutOfRangeException("Invalid byte-pattern search bounds.");
            for (int i = start; i <= endExclusive - pattern.Length; i++)
            {
                int j = 0;
                while (j < pattern.Length && bytes[i + j] == pattern[j]) j++;
                if (j == pattern.Length) return i;
            }
            return -1;
        }

        private static void ReplacePattern(byte[] bytes, byte[] original, byte[] replacement)
        {
            if (original.Length != replacement.Length) throw new ArgumentException("Pattern lengths differ.");
            for (int i = 0; i <= bytes.Length - original.Length; )
            {
                int j = 0;
                while (j < original.Length && bytes[i + j] == original[j]) j++;
                if (j != original.Length) { i++; continue; }
                Buffer.BlockCopy(replacement, 0, bytes, i, replacement.Length);
                i += replacement.Length;
            }
        }

        private static string NormalizeHash(string value)
        {
            value = (value ?? "").Trim();
            if (value.Length != 64) throw new InvalidDataException("Electron ASAR SHA-256 hash is invalid.");
            for (int i = 0; i < value.Length; i++)
                if (!Uri.IsHexDigit(value[i])) throw new InvalidDataException("Electron ASAR SHA-256 hash is invalid.");
            return value.ToLowerInvariant();
        }

        private static string ToHex(byte[] bytes)
        {
            return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant();
        }

        private static void ReadExact(Stream stream, byte[] buffer, int offset, int count)
        {
            while (count > 0)
            {
                int read = stream.Read(buffer, offset, count);
                if (read == 0) throw new EndOfStreamException("Electron ASAR is truncated.");
                offset += read;
                count -= read;
            }
        }
    }

    internal static class LauncherLocale
    {
        private static bool chinese;

        internal static bool IsChinese { get { return chinese; } }

        internal static void Load(PortableLayout layout)
        {
            string saved = null;
            try
            {
                if (File.Exists(layout.LanguageFile))
                    saved = File.ReadAllText(layout.LanguageFile, Encoding.UTF8).Trim();
            }
            catch { }

            if (string.Equals(saved, "zh-CN", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(saved, "zh", StringComparison.OrdinalIgnoreCase))
            {
                chinese = true;
                return;
            }
            if (string.Equals(saved, "en-US", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(saved, "en", StringComparison.OrdinalIgnoreCase))
            {
                chinese = false;
                return;
            }

            CultureInfo culture = CultureInfo.CurrentUICulture;
            if (culture == null || string.IsNullOrEmpty(culture.TwoLetterISOLanguageName))
                culture = CultureInfo.InstalledUICulture;
            chinese = culture != null &&
                string.Equals(culture.TwoLetterISOLanguageName, "zh", StringComparison.OrdinalIgnoreCase);
        }

        internal static void Save(PortableLayout layout, bool useChinese)
        {
            layout.EnsureDirectories();
            IOUtil.AtomicWriteText(layout.LanguageFile, useChinese ? "zh-CN\r\n" : "en-US\r\n");
            chinese = useChinese;
        }

        internal static string T(string zh, string en)
        {
            return chinese ? zh : en;
        }
    }

    internal sealed class PortableForm : Form
    {
        private const int StartupInitializationStepTotal = 6;
        private const int DesktopStartupConfirmationMilliseconds = 9000;
        // Keep recovery step 3 visible across the CIM process/path checks that
        // run between cross-process UI samples. This bounded delay applies
        // only after an actual image fault and before the one permitted retry.
        private const int RecoveryReadyStageMinimumDisplayMilliseconds = 2000;
        private const uint StatusInPageError = 0xC0000006;
        private readonly PortableLayout layout;
        private readonly int bootstrapperProcessId;
        private readonly Label status;
        private readonly Label details;
        private readonly ProgressBar progress;
        private readonly Label progressText;
        private readonly CheckBox compatibility;
        private readonly List<Button> actionButtons;
        private Label actionsTitleLabel;
        private Label languageLabel;
        private ComboBox languageSelector;
        private JobRun activeRun;
        private bool busy;
        private bool startWorkflowRunning;
        private bool closingAfterConfirm;
        private bool formIsClosing;
        private bool portablePayloadChecked;
        private bool startupStatePrepared;
        private bool startupInitializationRunning;
        private bool requiredPluginCacheValidated;
        private Task<StartupInitialization> startupTask;
        private bool closeRequestedDuringStartup;
        private bool updatingLanguage;
        private bool launchNeedsCommonRuntime;
        private bool launchNeedsDesktopPackage;
        private bool launchNeedsHostExecutionImage;
        private bool desktopImageRecoveryProgressMode;
        private int launchStepTotal;
        private bool automaticUpdateCheckStarted;

        private sealed class StartupInitialization
        {
            internal bool SupportedArchitecture;
            internal bool PayloadPresent;
            internal bool BundledPayloadAvailable;
            internal bool ApiConfigured;
        }

        private sealed class DesktopStartupExitException : Exception
        {
            internal readonly uint ExitCode;

            internal DesktopStartupExitException(uint exitCode)
                : base("Codex Desktop exited during startup with status 0x" +
                    exitCode.ToString("X8", CultureInfo.InvariantCulture) + ".")
            {
                ExitCode = exitCode;
            }
        }

        internal PortableForm(PortableLayout p, int bootstrapperPid)
        {
            layout = p;
            bootstrapperProcessId = bootstrapperPid;
            LauncherLocale.Load(layout);
            Text = "LF Portable · Codex";
            Icon = PortableBranding.LoadLauncherIcon();
            ShowIcon = true;
            ShowInTaskbar = true;
            Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Regular, GraphicsUnit.Point);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = true;
            ClientSize = new Size(860, 520);
            BackColor = Color.FromArgb(246, 248, 251);

            // The launcher uses native WinForms controls so opening it remains
            // lightweight on removable media.
            Color ink = Color.FromArgb(15, 23, 42);
            Color muted = Color.FromArgb(100, 116, 139);
            Color railColor = Color.FromArgb(15, 29, 48);
            Color accent = Color.FromArgb(94, 234, 212);
            Color surface = Color.White;
            Color border = Color.FromArgb(220, 228, 238);
            int contentLeft = 252;
            int contentWidth = 576;

            Panel rail = new Panel();
            rail.Location = new Point(0, 0);
            rail.Size = new Size(220, ClientSize.Height);
            rail.BackColor = railColor;
            Controls.Add(rail);

            Panel railAccent = new Panel();
            railAccent.Location = new Point(0, 0);
            railAccent.Size = new Size(4, ClientSize.Height);
            railAccent.BackColor = accent;
            rail.Controls.Add(railAccent);

            PictureBox brandMark = new PictureBox();
            brandMark.Location = new Point(30, 34);
            brandMark.Size = new Size(62, 62);
            brandMark.BackColor = Color.Transparent;
            brandMark.SizeMode = PictureBoxSizeMode.Zoom;
            using (Icon launcherIcon = PortableBranding.LoadLauncherIcon())
            {
                brandMark.Image = launcherIcon.ToBitmap();
            }
            rail.Controls.Add(brandMark);

            Label railTitle = new Label();
            railTitle.Text = "LF";
            railTitle.Font = new Font(Font.FontFamily, 24F, FontStyle.Bold);
            railTitle.ForeColor = Color.White;
            railTitle.AutoSize = true;
            railTitle.Location = new Point(30, 119);
            rail.Controls.Add(railTitle);

            languageLabel = new Label();
            languageLabel.Text = LauncherLocale.T("界面语言", "Language");
            languageLabel.Font = new Font(Font.FontFamily, 8F, FontStyle.Bold);
            languageLabel.ForeColor = Color.FromArgb(183, 196, 211);
            languageLabel.AutoSize = true;
            languageLabel.Location = new Point(32, 420);
            rail.Controls.Add(languageLabel);

            languageSelector = new ComboBox();
            languageSelector.DropDownStyle = ComboBoxStyle.DropDownList;
            languageSelector.FlatStyle = FlatStyle.Flat;
            languageSelector.Font = new Font(Font.FontFamily, 9F);
            languageSelector.Items.Add("中文");
            languageSelector.Items.Add("English");
            languageSelector.SelectedIndex = LauncherLocale.IsChinese ? 0 : 1;
            languageSelector.Location = new Point(32, 442);
            languageSelector.Size = new Size(154, 26);
            languageSelector.SelectedIndexChanged += delegate
            {
                if (updatingLanguage || languageSelector.SelectedIndex < 0) return;
                bool previous = LauncherLocale.IsChinese;
                try
                {
                    LauncherLocale.Save(layout, languageSelector.SelectedIndex == 0);
                    ApplyLanguage();
                }
                catch (Exception ex)
                {
                    SafeLog.TryWrite(layout, "language", ex);
                    updatingLanguage = true;
                    try { languageSelector.SelectedIndex = previous ? 0 : 1; }
                    finally { updatingLanguage = false; }
                    MessageBox.Show(LauncherLocale.T("语言设置无法保存。请检查 U 盘是否可写。", "The language setting could not be saved. Check that the USB drive is writable."),
                        "LF Portable", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            };
            rail.Controls.Add(languageSelector);

            Label title = new Label();
            title.Text = "LF Portable";
            title.Font = new Font(Font.FontFamily, 19F, FontStyle.Bold);
            title.ForeColor = ink;
            title.AutoSize = true;
            title.Location = new Point(contentLeft, 42);
            Controls.Add(title);

            Panel statusCard = new Panel();
            statusCard.Location = new Point(contentLeft, 92);
            statusCard.Size = new Size(contentWidth, 104);
            statusCard.BackColor = surface;
            statusCard.Paint += delegate(object sender, PaintEventArgs e)
            {
                using (Pen pen = new Pen(border))
                    e.Graphics.DrawRectangle(pen, 0, 0, statusCard.Width - 1, statusCard.Height - 1);
                using (Brush brush = new SolidBrush(Color.FromArgb(13, 148, 136)))
                    e.Graphics.FillRectangle(brush, 0, 0, 4, statusCard.Height);
            };
            Controls.Add(statusCard);

            status = new Label();
            status.Text = LauncherLocale.T("检查便携环境", "Checking portable environment");
            status.Font = new Font(Font.FontFamily, 11F, FontStyle.Bold);
            status.ForeColor = ink;
            status.Location = new Point(22, 15);
            status.Size = new Size(contentWidth - 42, 28);
            statusCard.Controls.Add(status);

            details = new Label();
            details.ForeColor = muted;
            details.Location = new Point(22, 47);
            details.Size = new Size(contentWidth - 42, 38);
            details.AutoEllipsis = true;
            statusCard.Controls.Add(details);

            Label actionsTitle = actionsTitleLabel = new Label();
            actionsTitle.Text = LauncherLocale.T("操作", "Actions");
            actionsTitle.Font = new Font(Font.FontFamily, 9F, FontStyle.Bold);
            actionsTitle.ForeColor = muted;
            actionsTitle.AutoSize = true;
            actionsTitle.Location = new Point(contentLeft, 218);
            Controls.Add(actionsTitle);

            actionButtons = new List<Button>();
            AddButton(LauncherLocale.T("启动 Codex", "Start Codex"), contentLeft, 246, StartClicked, true);
            AddButton(LauncherLocale.T("设置 API", "Configure API"), contentLeft + 296, 246, SetKeyClicked, false);
            AddButton(LauncherLocale.T("清除 API", "Clear API"), contentLeft, 298, ClearKeyClicked, false);
            AddButton(LauncherLocale.T("检查更新", "Check for updates"), contentLeft + 296, 298, UpdateClicked, false);
            AddButton(LauncherLocale.T("生成诊断", "Create diagnostics"), contentLeft, 350, DiagnosticsClicked, false);
            AddButton(LauncherLocale.T("打开资料目录", "Open data folder"), contentLeft + 296, 350, OpenDataClicked, false);

            compatibility = new CheckBox();
            compatibility.Text = LauncherLocale.T("兼容模式", "Compatibility mode");
            compatibility.ForeColor = muted;
            compatibility.AutoSize = true;
            compatibility.Location = new Point(contentLeft + 296, 417);
            Controls.Add(compatibility);

            progress = new ProgressBar();
            progress.Location = new Point(contentLeft, 480);
            progress.Size = new Size(contentWidth, 7);
            progress.Style = ProgressBarStyle.Continuous;
            Controls.Add(progress);

            progressText = new Label();
            progressText.ForeColor = muted;
            progressText.Location = new Point(contentLeft, 452);
            progressText.Size = new Size(contentWidth, 20);
            progressText.TextAlign = ContentAlignment.MiddleRight;
            Controls.Add(progressText);

            FormClosing += FormIsClosing;
            Shown += FormShown;
        }

        private void AddButton(string text, int x, int y, EventHandler handler, bool primary)
        {
            Button b = new Button();
            b.Text = text;
            b.Size = new Size(280, 44);
            b.Location = new Point(x, y);
            b.Font = new Font(Font.FontFamily, primary ? 10F : 9F, primary ? FontStyle.Bold : FontStyle.Regular);
            b.TextAlign = ContentAlignment.MiddleLeft;
            b.Padding = new Padding(16, 0, 8, 0);
            b.Cursor = Cursors.Hand;
            b.FlatStyle = FlatStyle.Flat;
            b.UseVisualStyleBackColor = false;
            b.TabStop = false;
            b.FlatAppearance.BorderSize = primary ? 0 : 1;
            if (primary)
            {
                b.BackColor = Color.FromArgb(13, 148, 136);
                b.ForeColor = Color.White;
                b.FlatAppearance.MouseOverBackColor = Color.FromArgb(11, 124, 114);
                b.FlatAppearance.MouseDownBackColor = Color.FromArgb(8, 101, 94);
            }
            else
            {
                b.BackColor = Color.White;
                b.ForeColor = Color.FromArgb(30, 41, 59);
                b.FlatAppearance.BorderColor = Color.FromArgb(203, 213, 225);
                b.FlatAppearance.MouseOverBackColor = Color.FromArgb(241, 245, 249);
                b.FlatAppearance.MouseDownBackColor = Color.FromArgb(226, 232, 240);
            }
            b.MouseEnter += delegate
            {
                if (!b.Enabled) return;
                b.BackColor = primary ? Color.FromArgb(11, 124, 114) : Color.FromArgb(241, 245, 249);
            };
            b.MouseLeave += delegate
            {
                b.BackColor = primary ? Color.FromArgb(13, 148, 136) : Color.White;
            };
            b.Click += handler;
            Controls.Add(b);
            actionButtons.Add(b);
        }

        private void ApplyLanguage()
        {
            updatingLanguage = true;
            try
            {
                languageLabel.Text = LauncherLocale.T("界面语言", "Language");
                actionsTitleLabel.Text = LauncherLocale.T("操作", "Actions");
                actionButtons[0].Text = LauncherLocale.T("启动 Codex", "Start Codex");
                actionButtons[1].Text = LauncherLocale.T("设置 API", "Configure API");
                actionButtons[2].Text = LauncherLocale.T("清除 API", "Clear API");
                actionButtons[3].Text = LauncherLocale.T("检查更新", "Check for updates");
                actionButtons[4].Text = LauncherLocale.T("生成诊断", "Create diagnostics");
                actionButtons[5].Text = LauncherLocale.T("打开资料目录", "Open data folder");
                compatibility.Text = LauncherLocale.T("兼容模式", "Compatibility mode");
            }
            finally { updatingLanguage = false; }

            if (!busy)
            {
                if (startupStatePrepared) RefreshStatus(LauncherLocale.T("就绪", "Ready"));
                else status.Text = LauncherLocale.T("检查便携环境", "Checking portable environment");
            }
        }

        private async void FormShown(object sender, EventArgs e)
        {
            if (formIsClosing || busy) return;
            startupInitializationRunning = true;
            SetBusy(true, null);
            ApplyStartupInitializationProgress(0, "检查数据目录", "Checking data directories",
                "创建并验证便携数据目录", "Creating and validating portable data directories");
            try
            {
                // Initialization touches a portable drive and may parse several JSON
                // manifests. Keep the UI responsive while preserving the same
                // validation order on a worker thread.
                startupTask = Task.Run(delegate
                {
                    StartupInitialization result = new StartupInitialization();
                    layout.EnsureDirectories();
                    ReportStartupInitializationProgress(1, "清理旧登录数据", "Cleaning legacy sign-in data",
                        "移除旧版遗留的登录文件", "Removing sign-in files left by older versions");
                    ProviderConfiguration.CleanupLegacyAuthentication(layout);
                    ReportStartupInitializationProgress(2, "检查启动配置", "Checking startup configuration",
                        "创建并验证 config.toml", "Creating and validating config.toml");
                    layout.EnsureConfig();
                    ReportStartupInitializationProgress(3, "检查首次运行配置", "Checking first-run configuration",
                        "验证首次运行设置", "Validating first-run settings");
                    layout.EnsureOnboardingSuppressed();
                    ReportStartupInitializationProgress(4, "检查 Windows 架构", "Checking Windows architecture",
                        "确认当前系统可用的 Codex 程序包", "Finding the Codex package for this system");
                    result.SupportedArchitecture = ArchitectureInfo.HasOfficialDesktopPayload(layout.Architecture);
                    result.BundledPayloadAvailable = result.SupportedArchitecture &&
                        PortableBundle.HasInstallPackages(layout);
                    ReportStartupInitializationProgress(5, "检查 LF 发布包", "Checking LF release package",
                        "确认桌面程序与 API 配置", "Checking the desktop payload and API configuration");
                    result.PayloadPresent = result.SupportedArchitecture &&
                        (File.Exists(layout.OfficialAppExe) || result.BundledPayloadAvailable);
                    result.ApiConfigured = ProviderConfiguration.HasCompleteApiConfiguration(layout);
                    return result;
                });
                StartupInitialization initialization = await startupTask;
                startupTask = null;
                ApplyStartupInitializationProgress(StartupInitializationStepTotal,
                    "便携环境检查完成", "Portable environment checks complete", string.Empty, string.Empty);
                startupInitializationRunning = false;

                if (formIsClosing || IsDisposed || Disposing) return;
                if (closeRequestedDuringStartup)
                {
                    CloseAfterStartupInitialization();
                    return;
                }
                startupStatePrepared = true;
                SetBusy(false, null);
                if (!initialization.SupportedArchitecture)
                {
                    status.Text = LauncherLocale.T("不支持的 Windows 架构", "Unsupported Windows architecture");
                    details.Text = string.Empty;
                    StartAutomaticUpdateCheck();
                    return;
                }
                if (!initialization.PayloadPresent)
                {
                    status.Text = LauncherLocale.T("Codex Desktop 不完整", "Codex Desktop is incomplete");
                    details.Text = string.Empty;
                    StartAutomaticUpdateCheck();
                    return;
                }
                if (initialization.BundledPayloadAvailable && !File.Exists(layout.OfficialAppExe))
                {
                    RefreshStatus(LauncherLocale.T("就绪", "Ready"));
                    StartAutomaticUpdateCheck();
                    return;
                }
                if (initialization.ApiConfigured)
                {
                    RefreshStatus(LauncherLocale.T("就绪", "Ready"));
                }
                else
                {
                    RefreshStatus(LauncherLocale.T("API 未设置", "API not configured"));
                }
                StartAutomaticUpdateCheck();
            }
            catch (Exception ex)
            {
                startupTask = null;
                startupInitializationRunning = false;
                if (closeRequestedDuringStartup)
                {
                    CloseAfterStartupInitialization();
                    return;
                }
                if (formIsClosing || IsDisposed || Disposing) return;
                SetBusy(false, null);
                SafeLog.TryWrite(layout, "initialization", ex);
                status.Text = LauncherLocale.T("便携环境检查失败", "Portable environment check failed");
                details.Text = string.Empty;
            }
        }

        private void CloseAfterStartupInitialization()
        {
            try { ProviderConfiguration.CleanupLegacyAuthentication(layout); }
            catch (Exception ex) { SafeLog.TryWrite(layout, "startup-close-cleanup", ex); }
            try { PortableScratch.Cleanup(layout); }
            catch (Exception ex) { SafeLog.TryWrite(layout, "startup-close-scratch", ex); }
            formIsClosing = true;
            closingAfterConfirm = true;
            try { BeginInvoke(new MethodInvoker(delegate { if (!IsDisposed) Close(); })); }
            catch { }
        }

        private void RefreshStatus(string prefix)
        {
            string version = AppUpdater.ReadInstalledVersion(layout);
            status.Text = prefix;
            details.Text = LauncherLocale.T("版本：" + version, "Version: " + version);
        }

        private void ReportStartupInitializationProgress(int completedSteps, string zhStatus,
            string enStatus, string zhDetails, string enDetails)
        {
            if (!InvokeRequired)
            {
                ApplyStartupInitializationProgress(completedSteps, zhStatus, enStatus,
                    zhDetails, enDetails);
                return;
            }
            try
            {
                BeginInvoke(new MethodInvoker(delegate
                {
                    ApplyStartupInitializationProgress(completedSteps, zhStatus, enStatus,
                        zhDetails, enDetails);
                }));
            }
            catch (InvalidOperationException) { }
        }

        private void ApplyStartupInitializationProgress(int completedSteps, string zhStatus,
            string enStatus, string zhDetails, string enDetails)
        {
            if (!startupInitializationRunning || formIsClosing || IsDisposed || Disposing) return;
            int boundedCompleted = Math.Max(0, Math.Min(StartupInitializationStepTotal, completedSteps));
            progress.Style = ProgressBarStyle.Continuous;
            progress.Value = boundedCompleted * 100 / StartupInitializationStepTotal;
            progressText.Text = LauncherLocale.T("已完成 " + boundedCompleted.ToString(
                CultureInfo.InvariantCulture) + "/" + StartupInitializationStepTotal.ToString(
                CultureInfo.InvariantCulture) + " 项",
                boundedCompleted.ToString(CultureInfo.InvariantCulture) + "/" +
                StartupInitializationStepTotal.ToString(CultureInfo.InvariantCulture) +
                " checks complete");
            status.Text = LauncherLocale.T(zhStatus, enStatus);
            details.Text = LauncherLocale.T(zhDetails, enDetails);
            AppendPendingCloseNotice();
        }

        private void AppendPendingCloseNotice()
        {
            if (!closeRequestedDuringStartup) return;
            string currentStage = status.Text ?? string.Empty;
            string notice = currentStage.Length == 0 ?
                LauncherLocale.T("完成当前步骤后自动关闭启动器",
                    "The launcher will close after the current step finishes") :
                LauncherLocale.T("完成“" + currentStage + "”后自动关闭启动器",
                    "The launcher will close after \"" + currentStage + "\" finishes");
            details.Text = string.IsNullOrEmpty(details.Text) ? notice : details.Text + " · " + notice;
        }

        private void SetBusy(bool value, string message)
        {
            busy = value;
            for (int i = 0; i < actionButtons.Count; i++) actionButtons[i].Enabled = !value;
            compatibility.Enabled = !value;
            if (languageSelector != null) languageSelector.Enabled = !value;
            if (message != null) status.Text = message;
            if (!value)
            {
                progress.Style = ProgressBarStyle.Continuous;
                progress.Value = 0;
                progressText.Text = string.Empty;
            }
        }

        private async void StartAutomaticUpdateCheck()
        {
            if (automaticUpdateCheckStarted || formIsClosing || IsDisposed || Disposing) return;
            automaticUpdateCheckStarted = true;
            Task<AppUpdater.UpdateCheckResult> task = AppUpdater.CheckForAutomaticUpdatesAsync(layout);
            try
            {
                AppUpdater.UpdateCheckResult check = await task;
                if (formIsClosing || IsDisposed || Disposing || busy ||
                    check.Status != AppUpdater.UpdateCheckStatus.NewerRelease) return;
                status.Text = LauncherLocale.T("发现新版本", "Update available");
                details.Text = LauncherLocale.T("当前 " + check.InstalledVersion.ToString() +
                    " · 最新 " + check.AvailableVersion.ToString(),
                    "Current " + check.InstalledVersion.ToString() + " · Latest " +
                    check.AvailableVersion.ToString());
                SafeLog.TryWriteEvent(layout, "update-check", "Automatic check found LF release " +
                    check.AvailableVersion.ToString() + ".");
            }
            catch (Exception ex)
            {
                // Automatic checks must never interrupt launcher use. The manual
                // action reports the same network or validation error explicitly.
                SafeLog.TryWrite(layout, "automatic-update-check", ex);
            }
        }

        private void BeginLaunchProgressPlan(bool needsCommonRuntime, bool needsDesktopPackage,
            bool needsHostExecutionImage)
        {
            launchNeedsCommonRuntime = needsCommonRuntime;
            launchNeedsDesktopPackage = needsDesktopPackage;
            launchNeedsHostExecutionImage = needsHostExecutionImage;
            desktopImageRecoveryProgressMode = false;
            launchStepTotal = (needsCommonRuntime ? 4 : 0) +
                (needsDesktopPackage ? 3 : 0) +
                (needsHostExecutionImage ? 3 : 0) + 3;
            progress.Value = 0;
            progressText.Text = LauncherLocale.T("共 " + launchStepTotal.ToString(
                CultureInfo.InvariantCulture) + " 步", launchStepTotal.ToString(
                CultureInfo.InvariantCulture) + " steps");
        }

        private void SetStepProgress(int step, int totalSteps, int stepPercent, bool showPercent)
        {
            if (step <= 0 || totalSteps <= 0) return;
            int boundedPercent = Math.Max(0, Math.Min(100, stepPercent));
            int value = (int)Math.Min(100L,
                (((long)step - 1L) * 100L + boundedPercent) / totalSteps);
            progress.Style = ProgressBarStyle.Continuous;
            progress.Value = Math.Max(progress.Value, value);
            string text = LauncherLocale.T("第 " + step.ToString(CultureInfo.InvariantCulture) +
                "/" + totalSteps.ToString(CultureInfo.InvariantCulture) + " 步",
                "Step " + step.ToString(CultureInfo.InvariantCulture) + " of " +
                totalSteps.ToString(CultureInfo.InvariantCulture));
            if (showPercent) text += " · " + boundedPercent.ToString(
                CultureInfo.InvariantCulture) + "%";
            progressText.Text = text;
        }

        private async void StartClicked(object sender, EventArgs e)
        {
            if (busy || activeRun != null) return;
            closeRequestedDuringStartup = false;
            if (PortableProcess.IsDesktopRunning(layout))
            {
                closingAfterConfirm = true;
                formIsClosing = true;
                try { ProviderConfiguration.CleanupLegacyAuthentication(layout); } catch { }
                try { PortableScratch.Cleanup(layout); } catch { }
                Close();
                return;
            }
            if (!ArchitectureInfo.HasOfficialDesktopPayload(layout.Architecture))
            {
                MessageBox.Show(LauncherLocale.T("检测到 Windows 架构为 " + layout.ArchitectureName + "。更新当前仅提供 x64 和 arm64 版本。",
                    "This Windows architecture is " + layout.ArchitectureName + ". Updates currently support x64 and arm64 only."),
                    "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            if (!File.Exists(layout.OfficialAppExe) && !PortableBundle.HasInstallPackages(layout))
            {
                MessageBox.Show(LauncherLocale.T("未找到完整的 LF 发布包。", "The complete LF release package was not found."), "LF Portable", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            if (!ProviderConfiguration.HasCompleteApiConfiguration(layout))
            {
                MessageBox.Show(LauncherLocale.T("请先设置 API URL、API Key 和模型。", "Configure the API URL, API key and model before starting."),
                    LauncherLocale.T("需要自定义 API", "Custom API required"), MessageBoxButtons.OK, MessageBoxIcon.Warning);
                SetKeyClicked(this, EventArgs.Empty);
                return;
            }
            bool needsCommonRuntime = !PortableBundle.CommonPayloadComplete(layout);
            bool needsDesktopPackage = !File.Exists(layout.OfficialAppExe);
            startWorkflowRunning = true;
            SetBusy(true, null);
            BeginLaunchProgressPlan(needsCommonRuntime, needsDesktopPackage, true);
            if (needsDesktopPackage || needsCommonRuntime)
            {
                try
                {
                    ReportFirstLaunchPreparationStage(needsCommonRuntime ?
                        FirstLaunchPreparationStage.ValidatingCommonPackage :
                        FirstLaunchPreparationStage.ValidatingDesktopPackage);
                    await Task.Run(delegate
                    {
                        PortableBundle.EnsureReady(layout, ReportFirstLaunchPreparationStage);
                    });
                    startupStatePrepared = true;
                }
                catch (Exception ex)
                {
                    SafeLog.TryWrite(layout, "provision", ex);
                    if (CompleteCloseRequestDuringStart()) return;
                    SetBusy(false, null);
                    MessageBox.Show(LauncherLocale.T("首次启动准备失败。错误类型：" + ex.GetType().Name + "。请检查 U 盘空间和连接。",
                        "First-launch preparation failed. Error type: " + ex.GetType().Name + ". Check USB space and connection."), "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    RefreshStatus(LauncherLocale.T("首次启动包安装失败", "First-launch package installation failed"));
                    FinishStartWorkflow();
                    return;
                }
            }
            if (CompleteCloseRequestDuringStart()) return;
            try
            {
                // Staging verifies the tree before activation, but the mutation
                // lock is released before this point. Revalidate the installed
                // tree immediately before handing off to the desktop process.
                ReportFirstLaunchPreparationStage(FirstLaunchPreparationStage.VerifyingInstalledDesktop);
                await Task.Run(delegate { EnsurePortablePayloadOnce(); });
                if (CompleteCloseRequestDuringStart()) return;
            }
            catch (Exception ex)
            {
                SafeLog.TryWrite(layout, "portable-branding", ex);
                if (CompleteCloseRequestDuringStart()) return;
                SetBusy(false, null);
                MessageBox.Show(LauncherLocale.T("无法校验 Codex 品牌与完整性。请生成诊断日志。",
                    "Unable to verify Codex branding and integrity. Create a diagnostic report."),
                    "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                RefreshStatus(LauncherLocale.T("Codex 完整性校验失败", "Codex integrity verification failed"));
                FinishStartWorkflow();
                return;
            }
            if (!File.Exists(layout.AppExe))
            {
                MessageBox.Show(LauncherLocale.T("应用文件不完整。", "The application files are incomplete."), "LF Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                FinishStartWorkflow();
                return;
            }
            if (!ArchitectureInfo.IsMachineCompatible(layout.OfficialAppExe, layout.Architecture) ||
                !ArchitectureInfo.IsMachineCompatible(layout.AppExe, layout.Architecture))
            {
                MessageBox.Show(LauncherLocale.T("已安装的 Codex Desktop 包与 Windows 架构（" + layout.ArchitectureName + "）不匹配。启动前请更新便携包。",
                    "The installed Codex Desktop payload does not match this Windows architecture (" + layout.ArchitectureName + "). Update the portable payload before starting."),
                    "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                FinishStartWorkflow();
                return;
            }
            if (!File.Exists(layout.CodexExe))
            {
                MessageBox.Show(LauncherLocale.T("应用文件不完整。", "The application files are incomplete."), "LF Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                FinishStartWorkflow();
                return;
            }
            if (!ArchitectureInfo.IsMachineCompatible(layout.CodexExe, layout.Architecture))
            {
                MessageBox.Show(LauncherLocale.T("内置 Codex CLI 与 Windows 架构（" + layout.ArchitectureName + "）不匹配。启动前请更新便携包。",
                    "The bundled Codex CLI does not match this Windows architecture (" + layout.ArchitectureName + "). Update the portable payload before starting."),
                    "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                FinishStartWorkflow();
                return;
            }
            try
            {
                ReportFirstLaunchPreparationStage(FirstLaunchPreparationStage.VerifyingPluginCache);
                int repairedPlugins = await Task.Run(delegate { return EnsureRequiredPluginCache(); });
                if (repairedPlugins > 0)
                    SafeLog.TryWriteEvent(layout, "plugin-cache-repair", "Restored " +
                        repairedPlugins.ToString(CultureInfo.InvariantCulture) + " required plugin(s) before launch.");
                if (CompleteCloseRequestDuringStart()) return;
            }
            catch (Exception ex)
            {
                SafeLog.TryWrite(layout, "plugin-cache-repair", ex);
                if (CompleteCloseRequestDuringStart()) return;
                SetBusy(false, null);
                MessageBox.Show(LauncherLocale.T("必需插件缓存不完整，自动恢复失败。请确认 U 盘连接稳定后重试。\r\n\r\n错误类型：" + ex.GetType().Name,
                    "The required plugin cache is incomplete and recovery failed. Check the USB connection and retry.\r\n\r\nError type: " + ex.GetType().Name),
                    "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                FinishStartWorkflow();
                return;
            }
            // Plugin cache validation above is a full source/tree comparison.
            // Avoid immediately traversing the same USB tree again here, but
            // still perform the inexpensive executable and marketplace checks.
            string missingPrerequisite = PortableEnvironment.FindMissingPrerequisite(layout,
                !requiredPluginCacheValidated);
            if (missingPrerequisite != null)
            {
                MessageBox.Show(LauncherLocale.T("便携运行库或插件不完整，禁止启动：\r\n" + missingPrerequisite,
                    "The portable runtime or plugin cache is incomplete; startup is blocked:\r\n" + missingPrerequisite), "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                FinishStartWorkflow();
                return;
            }

            PortableExecutionLayout execution = null;
            try
            {
                execution = await Task.Run(delegate
                {
                    return HostExecutionImage.EnsureReady(layout, false,
                        ReportFirstLaunchPreparationStage);
                });
                if (CompleteCloseRequestDuringStart()) return;
            }
            catch (Exception ex)
            {
                SafeLog.TryWrite(layout, "execution-image", ex);
                if (CompleteCloseRequestDuringStart()) return;
                SetBusy(false, null);
                MessageBox.Show(LauncherLocale.T(
                    "无法准备本机执行镜像。为避免 USB 映像读取错误，LF 不会直接从 U 盘运行 Codex。请确认 U 盘连接稳定且系统盘至少有 5 GB 可用空间后重试。\r\n\r\n错误类型：" + ex.GetType().Name,
                    "Unable to prepare the local execution image. To prevent USB mapped-image failures, LF will not run Codex directly from the removable drive. Check the USB connection and keep at least 5 GB free on the system drive, then retry.\r\n\r\nError type: " + ex.GetType().Name),
                    "LF Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                RefreshStatus(LauncherLocale.T("本机执行镜像准备失败",
                    "Local execution image preparation failed"));
                FinishStartWorkflow();
                return;
            }

            string apiKey = null;
            string baseUrl = null;
            string model = null;
            string recoveryHelper = null;
            bool preserveHostScratchAfterHandoff = false;
            try
            {
                if (!ProviderConfiguration.TryReadRequiredConfiguration(layout, out baseUrl, out apiKey, out model))
                {
                    MessageBox.Show(LauncherLocale.T("必须先设置有效的 API URL、API Key 和模型，Codex 才能启动。",
                        "Set a valid API URL, API key and model before starting Codex."),
                        LauncherLocale.T("需要自定义 API", "Custom API required"), MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    FinishStartWorkflow();
                    SetKeyClicked(this, EventArgs.Empty);
                    return;
                }

                if (!startupStatePrepared)
                {
                    layout.EnsureDirectories();
                    ProviderConfiguration.CleanupLegacyAuthentication(layout);
                }
                // First-run package expansion can create profile content after the
                // window's background initialization. Reassert the config-backed
                // permission mode immediately before starting Desktop.
                layout.EnsureConfig();
                layout.EnsureOnboardingSuppressed();
                startupStatePrepared = true;

                // Keep high-churn temporary/cache writes off the removable drive.
                // The session directory is intentionally retained after a
                // successful handoff and removed by stale-session maintenance on
                // a later launcher run.
                bool hostScratchEnabled = PortableScratch.TryPrepare(layout);
                if (!hostScratchEnabled)
                    throw new IOException("A local scratch directory is required; startup will not fall back to high-churn USB caches.");
                recoveryHelper = DesktopImageFailureWatch.PrepareHelper(layout);
                List<string> launchArguments = new List<string>();
                launchArguments.Add(IOUtil.QuoteArgument("--user-data-dir=" + layout.ElectronData));
                launchArguments.Add(IOUtil.QuoteArgument("--disk-cache-dir=" + PortableScratch.ActiveChromiumCache(layout)));
                launchArguments.Add(IOUtil.QuoteArgument("--crash-dumps-dir=" + layout.CrashDumps));
                launchArguments.Add(IOUtil.QuoteArgument("--download-default-directory=" + layout.Downloads));
                launchArguments.Add("--no-first-run");
                launchArguments.Add("--no-default-browser-check");
                if (compatibility.Checked)
                {
                    launchArguments.Add("--disable-gpu");
                    launchArguments.Add("--disable-gpu-compositing");
                }
                string arguments = string.Join(" ", launchArguments.ToArray());
                apiKey = null;
                baseUrl = null;
                model = null;
                bool imageRecoveryAttempted = false;
                while (true)
                {
                    ReportFirstLaunchPreparationStage(FirstLaunchPreparationStage.StartingDesktop);
                    Mutex launchMutation = PortableProcess.AcquireMutationMutex(layout, 0);
                    if (launchMutation == null)
                        throw new IOException("Another portable start or plugin-cache repair is in progress.");
                    Win32Exception processCreateFailure = null;
                    try
                    {
                        if (PortableProcess.IsDesktopRunning(layout))
                            throw new IOException("Codex Desktop started before handoff; launch was cancelled.");
                        try { activeRun = StartDesktopProcess(arguments, execution); }
                        catch (Win32Exception ex) { processCreateFailure = ex; }
                    }
                    finally
                    {
                        PortableProcess.ReleaseMutationMutex(launchMutation);
                    }
                    if (processCreateFailure != null)
                    {
                        if (!IsRecoverableDesktopImageStartFailure(processCreateFailure) ||
                            imageRecoveryAttempted) throw processCreateFailure;
                        imageRecoveryAttempted = true;
                        SafeLog.TryWriteEvent(layout, "start-create-failure",
                            "Codex process creation failed with Win32=" +
                            processCreateFailure.NativeErrorCode.ToString(CultureInfo.InvariantCulture) +
                            "; preparing a local execution image.");
                        await RevalidatePluginCacheAfterDesktopImageFailure();
                        if (CompleteCloseRequestDuringStart()) return;
                        BeginDesktopImageRecoveryProgressPlan();
                        execution = await Task.Run(delegate
                        {
                            return HostExecutionImage.EnsureReady(layout, true,
                                ReportFirstLaunchPreparationStage);
                        });
                        if (CompleteCloseRequestDuringStart()) return;
                        await HoldRecoveryReadyStageVisibleAsync();
                        if (CompleteCloseRequestDuringStart()) return;
                        SafeLog.TryWriteEvent(layout, "desktop-self-repair",
                            "Prepared a verified local execution image after a process-creation I/O failure; retrying once.");
                        continue;
                    }

                    SafeLog.TryWriteEvent(layout, "start-attempt", "Codex process tree created. Host scratch=enabled; execution=local-image; remote control=disabled.");
                    JobRun run = activeRun;
                    ReportFirstLaunchPreparationStage(FirstLaunchPreparationStage.ConfirmingDesktopStart);
                    uint earlyExitCode = 0;
                    bool exitedDuringStartup = await Task.Run(delegate
                    {
                        return run.TryGetEarlyExit(DesktopStartupConfirmationMilliseconds,
                            out earlyExitCode);
                    });
                    DesktopImageFailureWatch committedLateFailureWatch = null;
                    if (DesktopHandoffWasCancelled(run))
                    {
                        if (object.ReferenceEquals(activeRun, run))
                        {
                            activeRun = null;
                            try { run.StopProcessTree(); }
                            finally { try { run.Dispose(); } catch { } }
                        }
                        CompleteCloseRequestDuringStart();
                        return;
                    }
                    if (!exitedDuringStartup)
                    {
                        DesktopImageFailureWatch lateFailureWatch = null;
                        bool handoffCancelled = false;
                        try
                        {
                            PortableExecutionLayout watchExecution = execution;
                            uint watchProcessId = run.ProcessId;
                            string watchHelper = recoveryHelper;
                            lateFailureWatch = await Task.Run(delegate
                            {
                                return DesktopImageFailureWatch.Start(layout, watchExecution,
                                    watchProcessId, watchHelper);
                            });
                            handoffCancelled = DesktopHandoffWasCancelled(run);
                            if (!handoffCancelled && lateFailureWatch == null)
                            {
                                // The root exited while the local helper was
                                // being staged. Keep ownership in this window
                                // and use the ordinary one-retry recovery path.
                                exitedDuringStartup = run.TryGetEarlyExit(0, out earlyExitCode);
                                if (!exitedDuringStartup)
                                    throw new IOException("The desktop recovery helper could not attach to the running Codex process.");
                            }
                            else if (!handoffCancelled)
                            {
                                DesktopImageFailureWatch preparingWatch = lateFailureWatch;
                                await Task.Run(delegate { preparingWatch.Prepare(); });
                                handoffCancelled = DesktopHandoffWasCancelled(run);
                                if (!handoffCancelled)
                                {
                                    if (!lateFailureWatch.IsTargetAlive())
                                    {
                                        exitedDuringStartup = run.TryGetEarlyExit(0, out earlyExitCode);
                                        if (!exitedDuringStartup)
                                            throw new IOException("The desktop recovery helper lost the verified Codex process before handoff.");
                                    }
                                    else
                                    {
                                        handoffCancelled = DesktopHandoffWasCancelled(run);
                                        if (!handoffCancelled)
                                        {
                                            // The helper must acknowledge that it consumed commit
                                            // and is armed before this job releases the root process.
                                            // Otherwise a launcher close could leave a late image
                                            // fault with no verified recovery owner.
                                            DesktopImageFailureWatch committingWatch = lateFailureWatch;
                                            await Task.Run(delegate { committingWatch.Commit(); });
                                            handoffCancelled = DesktopHandoffWasCancelled(run);
                                            if (!handoffCancelled)
                                            {
                                                exitedDuringStartup = !run.TryDetachAfterStartup(out earlyExitCode);
                                                if (exitedDuringStartup)
                                                {
                                                    // The helper owns the committed target now, but
                                                    // this process still owns its job. Drain the job
                                                    // and wait for the helper before any rebuild uses
                                                    // the same local-image mutation mutex.
                                                    committedLateFailureWatch = lateFailureWatch;
                                                    lateFailureWatch = null;
                                                }
                                                else
                                                {
                                                    bool cancellationAfterDetach = DesktopHandoffWasCancelled(run);
                                                    lateFailureWatch.Dispose();
                                                    lateFailureWatch = null;
                                                    if (cancellationAfterDetach)
                                                    {
                                                        if (object.ReferenceEquals(activeRun, run)) activeRun = null;
                                                        try { run.Dispose(); } catch { }
                                                        CompleteCloseRequestDuringStart();
                                                        return;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        finally
                        {
                            if (lateFailureWatch != null) lateFailureWatch.Dispose();
                        }
                        if (handoffCancelled)
                        {
                            if (object.ReferenceEquals(activeRun, run))
                            {
                                activeRun = null;
                                try { run.StopProcessTree(); }
                                finally { try { run.Dispose(); } catch { } }
                            }
                            CompleteCloseRequestDuringStart();
                            return;
                        }
                    }
                    if (exitedDuringStartup)
                    {
                        // A terminated root process does not imply that Electron's
                        // renderer/utility descendants have finished tearing down.
                        // Wait for the whole job before touching the execution image;
                        // otherwise a still-mapped DLL can make the replacement race
                        // with file cleanup and turn a recoverable image fault into a
                        // second, nondeterministic startup failure.
                        try
                        {
                            await Task.Run(delegate
                            {
                                run.TerminateProcessTreeAndWait(
                                    JobRun.ProcessTreeTerminationTimeoutMilliseconds);
                            });
                            if (committedLateFailureWatch != null)
                            {
                                DesktopImageFailureWatch completedWatch = committedLateFailureWatch;
                                await Task.Run(delegate
                                {
                                    completedWatch.WaitForCompletionAfterTargetExit();
                                });
                            }
                        }
                        finally
                        {
                            if (committedLateFailureWatch != null)
                            {
                                committedLateFailureWatch.Dispose();
                                committedLateFailureWatch = null;
                            }
                        }
                        run.Dispose();
                        activeRun = null;
                        SafeLog.TryWriteEvent(layout, "start-exit", "Codex exited during startup with status 0x" +
                            earlyExitCode.ToString("X8", CultureInfo.InvariantCulture) + ".");
                        if (!IsRecoverableDesktopImageExit(earlyExitCode) || imageRecoveryAttempted)
                            throw new DesktopStartupExitException(earlyExitCode);

                        imageRecoveryAttempted = true;
                        await RevalidatePluginCacheAfterDesktopImageFailure();
                        if (CompleteCloseRequestDuringStart()) return;
                        BeginDesktopImageRecoveryProgressPlan();
                        execution = await Task.Run(delegate
                        {
                            return HostExecutionImage.EnsureReady(layout, true,
                                ReportFirstLaunchPreparationStage);
                        });
                        if (CompleteCloseRequestDuringStart()) return;
                        await HoldRecoveryReadyStageVisibleAsync();
                        if (CompleteCloseRequestDuringStart()) return;
                        SafeLog.TryWriteEvent(layout, "desktop-self-repair",
                            "Prepared a verified local execution image without modifying USB data; retrying once.");
                        if (CompleteCloseRequestDuringStart()) return;
                        continue;
                    }

                    // The job has been detached only after a final zero-timeout
                    // liveness check. Dispose now releases its remaining handles.
                    activeRun = null;
                    run.Dispose();
                    preserveHostScratchAfterHandoff = hostScratchEnabled;
                    CleanupLegacyAuthenticationAfterRun();
                    SafeLog.TryWriteEvent(layout, "start", "Codex startup confirmation passed.");
                    SafeLog.TryWriteEvent(layout, "handoff", "Codex process tree detached; launcher exiting.");
                    ReportFirstLaunchPreparationStage(FirstLaunchPreparationStage.DesktopStarted);
                    closingAfterConfirm = true;
                    formIsClosing = true;
                    try { Close(); } catch { }
                    return;
                }
            }
            catch (DesktopStartupExitException ex)
            {
                JobRun failedRun = activeRun;
                activeRun = null;
                if (failedRun != null)
                {
                    try { failedRun.StopProcessTree(); }
                    finally { try { failedRun.Dispose(); } catch { } }
                }
                CleanupLegacyAuthenticationAfterRun();
                SafeLog.TryWrite(layout, "start", ex);
                if (formIsClosing || IsDisposed || Disposing) return;
                SetBusy(false, null);
                string code = "0x" + ex.ExitCode.ToString("X8", CultureInfo.InvariantCulture);
                MessageBox.Show(LauncherLocale.T(
                    "Codex 在启动确认阶段退出（" + code + "）。若自动重建后仍出现 0xc0000006，说明 U 盘连接或介质仍在发生 I/O 中断；Codex 未启动。",
                    "Codex exited during startup confirmation (" + code + "). If 0xc0000006 persists after automatic rebuild, the USB connection or media is still interrupting I/O; Codex was not started."),
                    "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                RefreshStatus(LauncherLocale.T("启动确认失败", "Startup confirmation failed"));
            }
            catch (Exception ex)
            {
                JobRun failedRun = activeRun;
                activeRun = null;
                if (failedRun != null)
                {
                    try { failedRun.StopProcessTree(); }
                    finally { try { failedRun.Dispose(); } catch (Exception disposeError) { SafeLog.TryWrite(layout, "cleanup", disposeError); } }
                }
                CleanupLegacyAuthenticationAfterRun();
                SafeLog.TryWrite(layout, "start", ex);
                if (formIsClosing || IsDisposed || Disposing) return;
                SetBusy(false, null);
                MessageBox.Show(LauncherLocale.T("启动失败。错误类型：" + ex.GetType().Name + "。请生成诊断日志。", "Startup failed. Error type: " + ex.GetType().Name + ". Create a diagnostic report."), "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                RefreshStatus(LauncherLocale.T("启动失败", "Startup failed"));
            }
            finally
            {
                if (apiKey != null) apiKey = null;
                if (!preserveHostScratchAfterHandoff) PortableScratch.Cleanup(layout);
                FinishStartWorkflow();
            }
        }

        private void FinishStartWorkflow()
        {
            startWorkflowRunning = false;
            bool shouldClose = closeRequestedDuringStartup;
            if (!shouldClose && !formIsClosing && !IsDisposed && !Disposing) SetBusy(false, null);
            launchNeedsCommonRuntime = false;
            launchNeedsDesktopPackage = false;
            launchNeedsHostExecutionImage = false;
            desktopImageRecoveryProgressMode = false;
            launchStepTotal = 0;
            if (shouldClose && !formIsClosing && !IsDisposed && !Disposing)
                CloseAfterStartupInitialization();
        }

        private bool CompleteCloseRequestDuringStart()
        {
            if (!closeRequestedDuringStartup) return false;
            FinishStartWorkflow();
            return true;
        }

        private async Task HoldRecoveryReadyStageVisibleAsync()
        {
            if (!desktopImageRecoveryProgressMode || !startWorkflowRunning ||
                formIsClosing || IsDisposed || Disposing) return;
            // EnsureReady reports this stage from its worker thread. Re-apply it
            // on the UI thread after the task completes so the state cannot be
            // overwritten by a queued earlier callback, then yield through a
            // bounded, determinate display window before step 4 starts.
            ReportFirstLaunchPreparationStage(FirstLaunchPreparationStage.HostExecutionImageReady);
            await Task.Delay(RecoveryReadyStageMinimumDisplayMilliseconds);
        }

        private bool DesktopHandoffWasCancelled(JobRun run)
        {
            return closeRequestedDuringStartup || formIsClosing || IsDisposed || Disposing ||
                !object.ReferenceEquals(activeRun, run);
        }

        private void ReportFirstLaunchPreparationStage(FirstLaunchProgress progressUpdate)
        {
            if (!InvokeRequired)
            {
                ApplyFirstLaunchPreparationStage(progressUpdate);
                return;
            }
            try
            {
                BeginInvoke(new MethodInvoker(delegate
                {
                    ApplyFirstLaunchPreparationStage(progressUpdate);
                }));
            }
            catch (InvalidOperationException) { }
        }

        private void ReportFirstLaunchPreparationStage(FirstLaunchPreparationStage stage)
        {
            ReportFirstLaunchPreparationStage(new FirstLaunchProgress(stage));
        }

        private void ApplyFirstLaunchPreparationStage(FirstLaunchProgress progressUpdate)
        {
            if (!startWorkflowRunning || formIsClosing || IsDisposed || Disposing) return;
            FirstLaunchPreparationStage stage = progressUpdate.Stage;
            int step = LaunchStepFor(stage);
            if (step <= 0 || launchStepTotal <= 0) return;
            bool measured = (stage == FirstLaunchPreparationStage.ExtractingCommonRuntime ||
                stage == FirstLaunchPreparationStage.ExtractingDesktopPackage ||
                stage == FirstLaunchPreparationStage.ValidatingHostExecutionImage ||
                stage == FirstLaunchPreparationStage.CopyingHostExecutionImage) &&
                (progressUpdate.TotalBytes > 0 || progressUpdate.TotalFiles > 0);
            bool completed = stage == FirstLaunchPreparationStage.CommonRuntimeReady ||
                stage == FirstLaunchPreparationStage.DesktopPayloadReady ||
                stage == FirstLaunchPreparationStage.HostExecutionImageReady ||
                stage == FirstLaunchPreparationStage.DesktopStarted;
            int stepPercent = completed ? 100 : measured ? MeasuredProgressPercent(progressUpdate) : 0;
            SetStepProgress(step, launchStepTotal, stepPercent, measured);
            switch (stage)
            {
                case FirstLaunchPreparationStage.ValidatingCommonPackage:
                    status.Text = LauncherLocale.T("校验便携运行库", "Validating portable runtime");
                    details.Text = LauncherLocale.T("检查压缩包结构、完整性和可用空间", "Checking package structure, integrity, and free space");
                    break;
                case FirstLaunchPreparationStage.ExtractingCommonRuntime:
                    status.Text = LauncherLocale.T("展开便携运行库", "Extracting portable runtime");
                    details.Text = LauncherLocale.T("解压运行时与离线插件", "Extracting runtime and offline plugins");
                    break;
                case FirstLaunchPreparationStage.VerifyingCommonRuntime:
                    status.Text = LauncherLocale.T("复核便携运行库", "Verifying portable runtime");
                    details.Text = LauncherLocale.T("检查已解压的运行库与插件", "Checking the extracted runtime and plugins");
                    break;
                case FirstLaunchPreparationStage.InstallingCommonRuntime:
                    status.Text = LauncherLocale.T("安装便携运行库", "Installing portable runtime");
                    details.Text = LauncherLocale.T("激活运行库与离线插件", "Activating the runtime and offline plugins");
                    break;
                case FirstLaunchPreparationStage.CommonRuntimeReady:
                    status.Text = LauncherLocale.T("便携运行库已就绪", "Portable runtime ready");
                    details.Text = string.Empty;
                    break;
                case FirstLaunchPreparationStage.ValidatingDesktopPackage:
                    status.Text = LauncherLocale.T("校验 Codex 安装包", "Validating Codex package");
                    details.Text = LauncherLocale.T("检查签名、版本和系统架构", "Checking signature, version, and system architecture");
                    break;
                case FirstLaunchPreparationStage.ExtractingDesktopPackage:
                    status.Text = LauncherLocale.T("展开 Codex", "Extracting Codex");
                    details.Text = LauncherLocale.T("解压桌面程序文件", "Extracting desktop application files");
                    break;
                case FirstLaunchPreparationStage.VerifyingAndBrandingDesktop:
                    status.Text = LauncherLocale.T("校验并应用 LF 品牌", "Verifying and applying LF branding");
                    details.Text = LauncherLocale.T("校验完整性并应用 LF 品牌", "Verifying integrity and applying LF branding");
                    break;
                case FirstLaunchPreparationStage.DesktopPayloadReady:
                    status.Text = LauncherLocale.T("Codex Desktop 已就绪", "Codex Desktop ready");
                    details.Text = string.Empty;
                    break;
                case FirstLaunchPreparationStage.VerifyingInstalledDesktop:
                    status.Text = LauncherLocale.T("复核 Codex", "Verifying Codex");
                    details.Text = LauncherLocale.T("检查 LF 品牌与更新屏蔽", "Checking LF branding and updater blocking");
                    break;
                case FirstLaunchPreparationStage.VerifyingPluginCache:
                    status.Text = LauncherLocale.T("校验插件缓存", "Verifying plugin cache");
                    details.Text = LauncherLocale.T("检查并按需恢复必需插件", "Checking and repairing required plugins if needed");
                    break;
                case FirstLaunchPreparationStage.ValidatingHostExecutionImage:
                    status.Text = LauncherLocale.T("检查本机执行镜像", "Validating local execution image");
                    details.Text = LauncherLocale.T("校验发布归档、签名和本机可用空间", "Checking release archives, signatures, and local free space");
                    break;
                case FirstLaunchPreparationStage.CopyingHostExecutionImage:
                    status.Text = LauncherLocale.T("从发布包重建本机执行镜像", "Rebuilding local execution image from release packages");
                    details.Text = LauncherLocale.T("程序和运行时来自已验证归档；数据库仍保留在 U 盘", "Extracting verified program archives; databases remain on USB");
                    break;
                case FirstLaunchPreparationStage.HostExecutionImageReady:
                    status.Text = LauncherLocale.T("本机执行镜像已就绪", "Local execution image ready");
                    details.Text = LauncherLocale.T("即将使用 U 盘数据目录启动", "Starting with the USB data directories");
                    break;
                case FirstLaunchPreparationStage.StartingDesktop:
                    status.Text = LauncherLocale.T("启动 Codex", "Starting Codex");
                    details.Text = LauncherLocale.T("创建便携运行环境", "Creating the portable runtime environment");
                    break;
                case FirstLaunchPreparationStage.ConfirmingDesktopStart:
                    status.Text = LauncherLocale.T("确认 Codex 启动", "Confirming Codex startup");
                    details.Text = LauncherLocale.T("最多等待 9 秒，检查映像读取与早期退出", "Waiting up to 9 seconds for image loading and early-exit checks");
                    break;
                case FirstLaunchPreparationStage.DesktopStarted:
                    status.Text = LauncherLocale.T("Codex 已启动", "Codex started");
                    details.Text = string.Empty;
                    break;
            }
            if (measured) details.Text = FormatExtractionProgress(progressUpdate);
            AppendPendingCloseNotice();
        }

        private int LaunchStepFor(FirstLaunchPreparationStage stage)
        {
            if (desktopImageRecoveryProgressMode)
            {
                switch (stage)
                {
                    case FirstLaunchPreparationStage.ValidatingHostExecutionImage: return 1;
                    case FirstLaunchPreparationStage.CopyingHostExecutionImage: return 2;
                    case FirstLaunchPreparationStage.HostExecutionImageReady: return 3;
                    case FirstLaunchPreparationStage.StartingDesktop:
                    case FirstLaunchPreparationStage.ConfirmingDesktopStart:
                    case FirstLaunchPreparationStage.DesktopStarted: return 4;
                    default: return 0;
                }
            }
            int offset = 0;
            if (launchNeedsCommonRuntime)
            {
                switch (stage)
                {
                    case FirstLaunchPreparationStage.ValidatingCommonPackage: return offset + 1;
                    case FirstLaunchPreparationStage.ExtractingCommonRuntime: return offset + 2;
                    case FirstLaunchPreparationStage.VerifyingCommonRuntime: return offset + 3;
                    case FirstLaunchPreparationStage.InstallingCommonRuntime:
                    case FirstLaunchPreparationStage.CommonRuntimeReady: return offset + 4;
                }
                offset += 4;
            }
            if (launchNeedsDesktopPackage)
            {
                switch (stage)
                {
                    case FirstLaunchPreparationStage.ValidatingDesktopPackage: return offset + 1;
                    case FirstLaunchPreparationStage.ExtractingDesktopPackage: return offset + 2;
                    case FirstLaunchPreparationStage.VerifyingAndBrandingDesktop:
                    case FirstLaunchPreparationStage.DesktopPayloadReady: return offset + 3;
                }
                offset += 3;
            }
            switch (stage)
            {
                case FirstLaunchPreparationStage.VerifyingInstalledDesktop: return offset + 1;
                case FirstLaunchPreparationStage.VerifyingPluginCache: return offset + 2;
            }
            offset += 2;
            if (launchNeedsHostExecutionImage)
            {
                switch (stage)
                {
                    case FirstLaunchPreparationStage.ValidatingHostExecutionImage: return offset + 1;
                    case FirstLaunchPreparationStage.CopyingHostExecutionImage: return offset + 2;
                    case FirstLaunchPreparationStage.HostExecutionImageReady: return offset + 3;
                }
                offset += 3;
            }
            switch (stage)
            {
                case FirstLaunchPreparationStage.StartingDesktop:
                case FirstLaunchPreparationStage.ConfirmingDesktopStart:
                case FirstLaunchPreparationStage.DesktopStarted: return offset + 1;
                default: return 0;
            }
        }

        private static int MeasuredProgressPercent(FirstLaunchProgress update)
        {
            return MeasuredProgressPercent(update.CompletedBytes, update.TotalBytes,
                update.CompletedFiles, update.TotalFiles);
        }

        private static int MeasuredProgressPercent(long completedBytes, long totalBytes,
            int completedFiles, int totalFiles)
        {
            int percent = 0;
            if (totalBytes > 0)
                percent = (int)Math.Min(100L, Math.Max(0L,
                    completedBytes * 100L / totalBytes));
            else if (totalFiles > 0)
                percent = Math.Min(100, Math.Max(0,
                    completedFiles * 100 / totalFiles));
            bool complete = (totalFiles <= 0 || completedFiles >= totalFiles) &&
                (totalBytes <= 0 || completedBytes >= totalBytes);
            if (!complete && percent >= 100) percent = 99;
            return complete ? 100 : percent;
        }

        private static string FormatExtractionProgress(FirstLaunchProgress update)
        {
            return FormatTransferProgress(update.CompletedBytes, update.TotalBytes,
                update.CompletedFiles, update.TotalFiles);
        }

        private static string FormatTransferProgress(long completedBytes, long totalBytes,
            int completedFiles, int totalFiles)
        {
            string fileProgress = completedFiles.ToString("N0", CultureInfo.CurrentCulture) +
                " / " + totalFiles.ToString("N0", CultureInfo.CurrentCulture) +
                LauncherLocale.T(" 个文件", " files");
            if (totalBytes <= 0) return fileProgress;
            return fileProgress + " · " + FormatByteCount(completedBytes) + " / " +
                FormatByteCount(totalBytes);
        }

        private static string FormatByteCount(long value)
        {
            double amount = Math.Max(0L, value);
            string unit = "B";
            if (amount >= 1024.0)
            {
                amount /= 1024.0;
                unit = "KB";
            }
            if (amount >= 1024.0)
            {
                amount /= 1024.0;
                unit = "MB";
            }
            if (amount >= 1024.0)
            {
                amount /= 1024.0;
                unit = "GB";
            }
            return amount.ToString(amount >= 100.0 ? "0" : amount >= 10.0 ? "0.0" : "0.00",
                CultureInfo.CurrentCulture) + " " + unit;
        }

        private int EnsureRequiredPluginCache()
        {
            // This is intentionally a full source/tree comparison. Cache the
            // result only for this open launcher window so the immediately
            // following prerequisite check does not rescan every plugin file.
            if (ProviderConfiguration.RequiredPluginCacheComplete(layout))
            {
                requiredPluginCacheValidated = true;
                return 0;
            }
            int repaired = ProviderConfiguration.EnsureRequiredPluginCache(layout);
            if (!ProviderConfiguration.RequiredPluginCacheComplete(layout))
                throw new InvalidDataException("Required plugin cache is still incomplete after recovery.");
            requiredPluginCacheValidated = true;
            return repaired;
        }

        private async Task RevalidatePluginCacheAfterDesktopImageFailure()
        {
            // The same removable-drive interruption that kills Electron can
            // invalidate a plugin file after the initial preflight. Never carry
            // the in-window validation result across a mapped-image failure.
            requiredPluginCacheValidated = false;
            ReportFirstLaunchPreparationStage(FirstLaunchPreparationStage.VerifyingPluginCache);
            int repaired = await Task.Run(delegate { return EnsureRequiredPluginCache(); });
            if (repaired > 0)
                SafeLog.TryWriteEvent(layout, "plugin-cache-repair", "Restored " +
                    repaired.ToString(CultureInfo.InvariantCulture) +
                    " required plugin(s) before the single desktop recovery retry.");
            string missingPrerequisite = PortableEnvironment.FindMissingPrerequisite(layout,
                !requiredPluginCacheValidated);
            if (missingPrerequisite != null)
                throw new InvalidDataException("Portable prerequisites changed during desktop recovery: " +
                    missingPrerequisite);
        }

        private void EnsurePortablePayloadOnce()
        {
            if (portablePayloadChecked) return;
            PortableBranding.EnsurePortablePayload(layout);
            portablePayloadChecked = true;
        }

        private void InvalidatePayloadPreflight()
        {
            portablePayloadChecked = false;
            requiredPluginCacheValidated = false;
        }

        private static bool IsRecoverableDesktopImageExit(uint exitCode)
        {
            return exitCode == StatusInPageError;
        }

        private static bool IsRecoverableDesktopImageStartFailure(Win32Exception error)
        {
            switch (error.NativeErrorCode)
            {
                case 2:    // ERROR_FILE_NOT_FOUND
                case 3:    // ERROR_PATH_NOT_FOUND
                case 21:   // ERROR_NOT_READY
                case 23:   // ERROR_CRC
                case 31:   // ERROR_GEN_FAILURE
                case 126:  // ERROR_MOD_NOT_FOUND
                case 193:  // ERROR_BAD_EXE_FORMAT
                case 1117: // ERROR_IO_DEVICE
                case 1167: // ERROR_DEVICE_NOT_CONNECTED
                case 1392: // ERROR_FILE_CORRUPT
                case 1393: // ERROR_DISK_CORRUPT
                    return true;
                default:
                    return false;
            }
        }

        private JobRun StartDesktopProcess(string arguments,
            PortableExecutionLayout execution)
        {
            if (execution == null)
                throw new InvalidOperationException("A verified local execution image is required.");
            string baseUrl;
            string apiKey;
            string model;
            if (!ProviderConfiguration.TryReadRequiredConfiguration(layout, out baseUrl, out apiKey, out model))
                throw new InvalidDataException("Portable API configuration disappeared before desktop startup.");
            Dictionary<string, string> environment = PortableEnvironment.Build(layout, execution, apiKey);
            try
            {
                return JobRun.Start(execution.AppExe, arguments, execution.AppRoot, environment);
            }
            finally
            {
                environment.Remove(ProviderConfiguration.ApiKeyEnvironmentVariable);
                apiKey = null;
                baseUrl = null;
                model = null;
            }
        }

        private void BeginDesktopImageRecoveryProgressPlan()
        {
            // The original start has failed conclusively. Start a new, explicit
            // four-step recovery plan rather than leaving an indeterminate spinner.
            launchNeedsCommonRuntime = false;
            launchNeedsDesktopPackage = false;
            launchNeedsHostExecutionImage = true;
            desktopImageRecoveryProgressMode = true;
            launchStepTotal = 4;
            progress.Style = ProgressBarStyle.Continuous;
            progress.Value = 0;
            progressText.Text = LauncherLocale.T("第 1/4 步", "Step 1 of 4");
            status.Text = LauncherLocale.T("恢复 Codex Desktop", "Recovering Codex Desktop");
            details.Text = LauncherLocale.T("检测到磁盘映像读取失败，正在构建本机执行镜像", "A mapped-image read failed; building a local execution image");
        }

        private void SetKeyClicked(object sender, EventArgs e)
        {
            if (busy) return;
            KeySetupResult result = KeySetupDialog.Ask(this,
                ProviderConfiguration.ReadEffectiveBaseUrl(layout),
                ProviderConfiguration.ReadEffectiveModel(layout),
                ProviderConfiguration.ReadStoredApiKey(layout));
            if (result == null) return;
            try
            {
                SetBusy(true, LauncherLocale.T("正在保存自定义 API…", "Saving custom API…"));
                layout.EnsureDirectories();
                ProviderConfiguration.Save(layout, result.BaseUrl, result.Model, result.ApiKey);
                SafeLog.TryWriteEvent(layout, "custom-api-set", "Custom API URL, key and model saved in portable data.");
                MessageBox.Show(LauncherLocale.T("自定义 API 已保存。", "Custom API saved."), "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                SafeLog.TryWrite(layout, "key-set", ex);
                MessageBox.Show(LauncherLocale.T("无法保存自定义 API。错误类型：" + ex.GetType().Name, "Unable to save custom API. Error type: " + ex.GetType().Name), "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                result.Clear();
                SetBusy(false, null);
                RefreshStatus(LauncherLocale.T("就绪", "Ready"));
            }
        }

        private void ClearKeyClicked(object sender, EventArgs e)
        {
            if (busy) return;
            if (MessageBox.Show(LauncherLocale.T("将清除 API URL、API Key 和模型；清除后 Codex 禁止启动。是否继续？", "This clears the API URL, API key and model; Codex cannot start until they are configured again. Continue?"), LauncherLocale.T("清除 API 配置", "Clear API configuration"),
                    MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
            try
            {
                IOUtil.DeleteFileIfExists(layout.VaultFile);
                IOUtil.DeleteFileIfExists(layout.PlainKeyFile);
                IOUtil.DeleteFileIfExists(layout.BaseUrlFile);
                IOUtil.DeleteFileIfExists(layout.ModelFile);
                ProviderConfiguration.CleanupLegacyAuthentication(layout);
                if (Directory.Exists(layout.CrashDumps)) IOUtil.DeleteDirectoryWithin(layout.CrashDumps, layout.Logs);
                Directory.CreateDirectory(layout.CrashDumps);
                layout.EnsureConfig();
                SafeLog.TryWriteEvent(layout, "custom-api-clear", "Custom API settings cleared.");
                RefreshStatus(LauncherLocale.T("自定义 API 已清除", "Custom API cleared"));
            }
            catch (Exception ex)
            {
                SafeLog.TryWrite(layout, "key-clear", ex);
                MessageBox.Show(LauncherLocale.T("清除失败。错误类型：" + ex.GetType().Name, "Clear failed. Error type: " + ex.GetType().Name), "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private async void UpdateClicked(object sender, EventArgs e)
        {
            if (busy || activeRun != null) return;
            try
            {
                SetBusy(true, null);
                details.Text = string.Empty;
                ApplyUpdateCheckProgress(new AppUpdater.UpdateCheckProgress(
                    AppUpdater.UpdateCheckProgressStage.ContactingReleaseService));
                Progress<AppUpdater.UpdateCheckProgress> checkReporter =
                    new Progress<AppUpdater.UpdateCheckProgress>(ApplyUpdateCheckProgress);
                AppUpdater.UpdateCheckResult check = await AppUpdater.CheckForUpdatesAsync(layout,
                    checkReporter);
                if (check.Status == AppUpdater.UpdateCheckStatus.NoRelease)
                {
                    SafeLog.TryWriteEvent(layout, "update-check", "No stable release is published.");
                    MessageBox.Show(LauncherLocale.T("当前没有可用更新。", "No update is currently available."),
                        LauncherLocale.T("检查更新", "Check for updates"), MessageBoxButtons.OK, MessageBoxIcon.Information);
                    RefreshStatus(LauncherLocale.T("没有可用更新", "No update available"));
                    return;
                }
                if (check.Status == AppUpdater.UpdateCheckStatus.UpToDate)
                {
                    SafeLog.TryWriteEvent(layout, "update-check", "Installed version is current: " + check.InstalledVersion.ToString() + ".");
                    MessageBox.Show(LauncherLocale.T("已是最新版本：" + check.InstalledVersion.ToString(),
                        "Already up to date: " + check.InstalledVersion.ToString()),
                        LauncherLocale.T("检查更新", "Check for updates"), MessageBoxButtons.OK, MessageBoxIcon.Information);
                    RefreshStatus(LauncherLocale.T("已是最新版本", "Up to date"));
                    return;
                }
                if (check.Status == AppUpdater.UpdateCheckStatus.Downgrade)
                {
                    SafeLog.TryWriteEvent(layout, "update-check", "Published version " + check.AvailableVersion.ToString() +
                        " is older than installed version " + check.InstalledVersion.ToString() + ".");
                    MessageBox.Show(LauncherLocale.T("当前版本 " + check.InstalledVersion.ToString() + " 高于已发布版本 " + check.AvailableVersion.ToString() + "，不会降级。",
                        "Installed version " + check.InstalledVersion.ToString() + " is newer than published version " + check.AvailableVersion.ToString() + "; no downgrade will occur."),
                        LauncherLocale.T("检查更新", "Check for updates"), MessageBoxButtons.OK, MessageBoxIcon.Information);
                    RefreshStatus(LauncherLocale.T("无需更新", "No update needed"));
                    return;
                }
                if (check.Status == AppUpdater.UpdateCheckStatus.MissingAsset)
                {
                    SafeLog.TryWriteEvent(layout, "update-check", "Release " + check.AvailableVersion.ToString() +
                        " has no LFPortable-release.zip asset.");
                    MessageBox.Show(LauncherLocale.T("发现版本 " + check.AvailableVersion.ToString() + "，但完整 LF 发布包不可用。",
                        "Version " + check.AvailableVersion.ToString() + " is published, but its complete LF release package is unavailable."),
                        LauncherLocale.T("检查更新", "Check for updates"), MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    RefreshStatus(LauncherLocale.T("完整发布包不可用", "Complete release unavailable"));
                    return;
                }
                if (check.Status == AppUpdater.UpdateCheckStatus.CurrentVersionUnknown)
                {
                    SafeLog.TryWriteEvent(layout, "update-check", "Installed LF release descriptor or managed files are invalid; update blocked.");
                    MessageBox.Show(LauncherLocale.T("无法确认当前版本，已停止更新。", "The installed version cannot be verified, so updating was stopped."),
                        LauncherLocale.T("检查更新", "Check for updates"), MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    RefreshStatus(LauncherLocale.T("无法确认当前版本", "Installed version unknown"));
                    return;
                }

                string currentVersion = check.InstalledVersion == null ?
                    LauncherLocale.T("未安装", "not installed") : check.InstalledVersion.ToString();
                if (MessageBox.Show(LauncherLocale.T("发现新版本 " + check.AvailableVersion.ToString() + "。\r\n当前版本：" + currentVersion + "\r\n\r\n是否下载并安装？",
                    "Version " + check.AvailableVersion.ToString() + " is available.\r\nCurrent version: " + currentVersion + "\r\n\r\nDownload and install it?"),
                    LauncherLocale.T("检查更新", "Check for updates"), MessageBoxButtons.YesNo, MessageBoxIcon.Question,
                    MessageBoxDefaultButton.Button2) != DialogResult.Yes)
                {
                    SafeLog.TryWriteEvent(layout, "update-check", "Update " + check.AvailableVersion.ToString() + " was declined.");
                    RefreshStatus(LauncherLocale.T("已取消更新", "Update cancelled"));
                    return;
                }

                status.Text = LauncherLocale.T("下载更新", "Downloading update");
                details.Text = currentVersion + " → " + check.AvailableVersion.ToString();
                progress.Value = 0;
                progressText.Text = LauncherLocale.T("第 1/5 步", "Step 1 of 5");
                Progress<AppUpdater.UpdateProgress> reporter = new Progress<AppUpdater.UpdateProgress>(
                    delegate(AppUpdater.UpdateProgress value)
                {
                    ApplyUpdateProgress(value, currentVersion, check.AvailableVersion);
                });
                AppUpdater.UpdateInstallResult installed = await AppUpdater.InstallUpdateAsync(layout, check,
                    reporter, Process.GetCurrentProcess().Id, bootstrapperProcessId);
                if (!installed.HelperStarted)
                    throw new InvalidOperationException("LF release apply helper did not start.");
                SafeLog.TryWriteEvent(layout, "update", AppUpdater.UpdateChannel +
                    " full release staged; apply helper started for version " +
                    installed.Version.ToString() + ".");
                closingAfterConfirm = true;
                formIsClosing = true;
                try { ProviderConfiguration.CleanupLegacyAuthentication(layout); } catch { }
                try { PortableScratch.Cleanup(layout); } catch { }
                Close();
                return;
            }
            catch (DowngradeRefusedException ex)
            {
                SafeLog.TryWrite(layout, "update-policy", ex);
                MessageBox.Show(LauncherLocale.T("版本状态已改变，未执行更新。请重新检查。", "Version state changed; no update was installed. Check again."),
                    "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Information);
                RefreshStatus(LauncherLocale.T("无需更新", "No update needed"));
            }
            catch (WebException ex)
            {
                SafeLog.TryWrite(layout, "update-check", ex);
                MessageBox.Show(LauncherLocale.T("无法连接更新服务。请检查网络后重试。", "Unable to reach the update service. Check the network and try again."),
                    LauncherLocale.T("检查更新", "Check for updates"), MessageBoxButtons.OK, MessageBoxIcon.Error);
                RefreshStatus(LauncherLocale.T("检查更新失败", "Update check failed"));
            }
            catch (InvalidDataException ex)
            {
                SafeLog.TryWrite(layout, "update-validation", ex);
                MessageBox.Show(LauncherLocale.T("更新信息或安装包验证失败，当前版本未改变。", "Release information or package validation failed; the installed version is unchanged."),
                    LauncherLocale.T("检查更新", "Check for updates"), MessageBoxButtons.OK, MessageBoxIcon.Error);
                RefreshStatus(LauncherLocale.T("更新验证失败", "Update validation failed"));
            }
            catch (Exception ex)
            {
                SafeLog.TryWrite(layout, "update", ex);
                MessageBox.Show(LauncherLocale.T("检查或安装更新失败，当前版本未改变。", "Checking or installing the update failed; the installed version is unchanged."),
                    "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                RefreshStatus(LauncherLocale.T("更新失败", "Update failed"));
            }
            finally
            {
                progress.Style = ProgressBarStyle.Continuous;
                SetBusy(false, null);
            }
        }

        private void ApplyUpdateCheckProgress(AppUpdater.UpdateCheckProgress update)
        {
            if (formIsClosing || IsDisposed || Disposing || update == null) return;
            const int totalSteps = 4;
            int step;
            bool complete = false;
            switch (update.Stage)
            {
                case AppUpdater.UpdateCheckProgressStage.ContactingReleaseService:
                    step = 1;
                    status.Text = LauncherLocale.T("连接 GitHub Release", "Connecting to GitHub Releases");
                    details.Text = LauncherLocale.T("获取 LF 最新稳定版", "Requesting the latest stable LF release");
                    break;
                case AppUpdater.UpdateCheckProgressStage.ValidatingReleaseMetadata:
                    step = 2;
                    status.Text = LauncherLocale.T("验证发布信息", "Validating release information");
                    details.Text = LauncherLocale.T("核对版本标签与完整发布包", "Checking the version tag and complete release asset");
                    break;
                case AppUpdater.UpdateCheckProgressStage.ReadingInstalledVersion:
                    step = 3;
                    status.Text = LauncherLocale.T("读取当前 LF 版本", "Reading the installed LF version");
                    details.Text = LauncherLocale.T("核对本机发布描述", "Checking the local release descriptor");
                    break;
                case AppUpdater.UpdateCheckProgressStage.ComparingVersions:
                    step = 4;
                    status.Text = LauncherLocale.T("比较版本", "Comparing versions");
                    details.Text = LauncherLocale.T("确定是否有较新的稳定版", "Determining whether a newer stable release exists");
                    break;
                case AppUpdater.UpdateCheckProgressStage.Complete:
                    step = 4;
                    complete = true;
                    status.Text = LauncherLocale.T("更新检查完成", "Update check complete");
                    details.Text = string.Empty;
                    break;
                default:
                    throw new ArgumentOutOfRangeException("update");
            }
            SetStepProgress(step, totalSteps, complete ? 100 : 0, complete);
        }

        private void ApplyUpdateProgress(AppUpdater.UpdateProgress update,
            string currentVersion, Version availableVersion)
        {
            if (formIsClosing || IsDisposed || Disposing || update == null) return;
            const int totalSteps = 6;
            int step;
            string versionLine = currentVersion + " → " + availableVersion.ToString();
            switch (update.Stage)
            {
                case AppUpdater.UpdateProgressStage.VerifyingInstalledRelease:
                    step = 1;
                    status.Text = LauncherLocale.T("校验当前版本", "Verifying the installed version");
                    break;
                case AppUpdater.UpdateProgressStage.DownloadingRelease:
                    step = 2;
                    status.Text = LauncherLocale.T("下载更新", "Downloading update");
                    break;
                case AppUpdater.UpdateProgressStage.VerifyingReleaseDownload:
                    step = 3;
                    status.Text = LauncherLocale.T("校验下载文件", "Verifying downloaded release");
                    break;
                case AppUpdater.UpdateProgressStage.StagingRelease:
                    step = 4;
                    status.Text = LauncherLocale.T("校验并展开更新包", "Verifying and extracting update");
                    break;
                case AppUpdater.UpdateProgressStage.BackingUpCurrentRelease:
                    step = 5;
                    status.Text = LauncherLocale.T("备份当前版本", "Backing up current version");
                    break;
                case AppUpdater.UpdateProgressStage.PreparingInstaller:
                    step = 6;
                    status.Text = LauncherLocale.T("准备安装", "Preparing installation");
                    break;
                case AppUpdater.UpdateProgressStage.InstallerReady:
                    step = 6;
                    status.Text = LauncherLocale.T("安装程序已启动", "Installer started");
                    break;
                default:
                    throw new ArgumentOutOfRangeException("update");
            }
            bool measured = update.TotalBytes > 0 || update.TotalFiles > 0;
            bool completed = update.Stage == AppUpdater.UpdateProgressStage.InstallerReady;
            int percent = completed ? 100 : measured ? MeasuredProgressPercent(
                update.CompletedBytes, update.TotalBytes, update.CompletedFiles, update.TotalFiles) : 0;
            SetStepProgress(step, totalSteps, percent, measured);
            details.Text = measured ? versionLine + " · " + FormatTransferProgress(
                update.CompletedBytes, update.TotalBytes, update.CompletedFiles, update.TotalFiles) :
                versionLine;
        }

        private void DiagnosticsClicked(object sender, EventArgs e)
        {
            try
            {
                string path = Diagnostics.Create(layout);
                MessageBox.Show(LauncherLocale.T("诊断已保存：\r\n" + path, "Diagnostics saved:\r\n" + path), "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(LauncherLocale.T("无法生成诊断。错误类型：" + ex.GetType().Name, "Unable to create diagnostics. Error type: " + ex.GetType().Name), "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void OpenDataClicked(object sender, EventArgs e)
        {
            try
            {
                layout.EnsureDirectories();
                Process.Start(new ProcessStartInfo("explorer.exe", "/e," + IOUtil.QuoteArgument(layout.DataRoot)) { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                SafeLog.TryWrite(layout, "open-data", ex);
                MessageBox.Show(LauncherLocale.T("无法打开资料目录。", "Unable to open the data folder."), "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void FormIsClosing(object sender, FormClosingEventArgs e)
        {
            if (closingAfterConfirm) return;
            if (activeRun == null && ((startupTask != null && !startupTask.IsCompleted) ||
                startWorkflowRunning))
            {
                // Do not terminate the process in the middle of an atomic config or
                // release extraction/transactional plugin repair. Keep the UI alive
                // until the current worker operation completes, then close safely.
                closeRequestedDuringStartup = true;
                e.Cancel = true;
                AppendPendingCloseNotice();
                return;
            }
            if (activeRun == null)
            {
                formIsClosing = true;
                try { ProviderConfiguration.CleanupLegacyAuthentication(layout); } catch { }
                PortableScratch.Cleanup(layout);
                return;
            }
            DialogResult answer = MessageBox.Show(LauncherLocale.T("关闭启动器会同时结束由它启动的 Codex 进程。是否继续？", "Closing the launcher will also stop the Codex process it started. Continue?"),
                LauncherLocale.T("Codex 正在运行", "Codex is running"), MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
            if (answer != DialogResult.Yes)
            {
                e.Cancel = true;
                return;
            }
            closingAfterConfirm = true;
            formIsClosing = true;
            try
            {
                JobRun run = activeRun;
                activeRun = null;
                run.StopProcessTree();
                run.Dispose();
                CleanupLegacyAuthenticationAfterRun();
                PortableScratch.Cleanup(layout);
            }
            catch { }
        }

        private void CleanupLegacyAuthenticationAfterRun()
        {
            Exception lastError = null;
            for (int attempt = 0; attempt < 20; attempt++)
            {
                try
                {
                    ProviderConfiguration.CleanupLegacyAuthentication(layout);
                    return;
                }
                catch (Exception ex)
                {
                    lastError = ex;
                    if (attempt < 19) Thread.Sleep(100);
                }
            }
            if (lastError != null) SafeLog.TryWrite(layout, "cleanup", lastError);
        }
    }
}

namespace CodexPortable
{
    internal static class SelfTest
    {
        internal static int Run(PortableLayout layout)
        {
            try
            {
                if (!Directory.Exists(layout.DataRoot)) return 10;
                layout.EnsureDirectories();
                if (PortableBundle.HasInstallPackages(layout))
                    PortableBundle.EnsureReady(layout);
                string previousApprovalPolicy = null;
                string previousSandboxMode = null;
                string previousFollowUpQueueMode = null;
                bool hadPermissionSettings = false;
                bool hadFollowUpQueueMode = false;
                if (File.Exists(layout.ConfigFile))
                {
                    try
                    {
                        string previousConfig = File.ReadAllText(layout.ConfigFile, Encoding.UTF8);
                        hadPermissionSettings = ProviderConfiguration.TryReadPermissionSettings(previousConfig,
                            out previousApprovalPolicy, out previousSandboxMode);
                        hadFollowUpQueueMode = ProviderConfiguration.TryReadFollowUpQueueMode(previousConfig,
                            out previousFollowUpQueueMode);
                    }
                    catch
                    {
                        hadPermissionSettings = false;
                        hadFollowUpQueueMode = false;
                    }
                }
                ProviderConfiguration.CleanupLegacyAuthentication(layout);
                ProviderConfiguration.WriteDeterministicConfig(layout);
                layout.EnsureOnboardingSuppressed();
                if (!ArchitectureInfo.HasOfficialDesktopPayload(layout.Architecture)) return 29;
                if (!File.Exists(layout.OfficialAppExe)) return 11;
                PortableBranding.EnsurePortablePayload(layout);
                if (!File.Exists(layout.AppExe)) return 11;
                if (!ArchitectureInfo.IsMachineCompatible(layout.OfficialAppExe, layout.Architecture) ||
                    !ArchitectureInfo.IsMachineCompatible(layout.AppExe, layout.Architecture)) return 29;
                // The official MSIX is Authenticode-verified before extraction, but its
                // inner ChatGPT.exe is not individually signed.  Preparation proves the
                // Codex-named executable is byte-identical to that verified payload.
                if (!PortableBranding.IsPrepared(layout)) return 25;
                if (!File.Exists(layout.CodexExe)) return 12;
                if (!ArchitectureInfo.IsMachineCompatible(layout.CodexExe, layout.Architecture)) return 29;
                if (!Directory.Exists(layout.Runtime) ||
                    !File.Exists(Path.Combine(layout.Runtime, "dependencies", "node", "bin", "node.exe")) ||
                    !File.Exists(Path.Combine(layout.Runtime, "dependencies", "python", "python.exe")) ||
                    !File.Exists(Path.Combine(layout.Runtime, "dependencies", "native", "git", "cmd", "git.exe"))) return 13;
                if (!File.Exists(layout.ConfigFile)) return 14;
                string config = File.ReadAllText(layout.ConfigFile, Encoding.UTF8);
                string configuredApprovalPolicy;
                string configuredSandboxMode;
                string configuredFollowUpQueueMode;
                if (!ProviderConfiguration.TryReadPermissionSettings(config,
                    out configuredApprovalPolicy, out configuredSandboxMode) ||
                    !ProviderConfiguration.TryReadFollowUpQueueMode(config,
                    out configuredFollowUpQueueMode)) return 14;
                if (!ProviderConfiguration.SelfTestPermissionConfiguration() ||
                    !ProviderConfiguration.SelfTestFollowUpQueueModeConfiguration() ||
                    (hadPermissionSettings &&
                    (!string.Equals(previousApprovalPolicy, configuredApprovalPolicy, StringComparison.Ordinal) ||
                     !string.Equals(previousSandboxMode, configuredSandboxMode, StringComparison.Ordinal))) ||
                    (hadFollowUpQueueMode ?
                    !string.Equals(previousFollowUpQueueMode, configuredFollowUpQueueMode, StringComparison.Ordinal) :
                    !string.Equals(configuredFollowUpQueueMode,
                        ProviderConfiguration.DefaultFollowUpQueueMode, StringComparison.Ordinal))) return 14;
                int analyticsSection = config.IndexOf("[analytics]", StringComparison.OrdinalIgnoreCase);
                if (config.IndexOf("model_provider = \"portable_custom\"", StringComparison.OrdinalIgnoreCase) < 0 ||
                    config.IndexOf(ProviderConfiguration.DeveloperInstructionsConfigLine, StringComparison.OrdinalIgnoreCase) < 0 ||
                    config.IndexOf("chatgpt_base_url = \"http://127.0.0.1:9\"", StringComparison.OrdinalIgnoreCase) < 0 ||
                    config.IndexOf(ProviderConfiguration.ReasoningEffortConfigLine, StringComparison.OrdinalIgnoreCase) < 0 ||
                    !ProviderConfiguration.IsValidApprovalPolicy(configuredApprovalPolicy) ||
                    !ProviderConfiguration.IsValidSandboxMode(configuredSandboxMode) ||
                    !ProviderConfiguration.IsValidFollowUpQueueMode(configuredFollowUpQueueMode) ||
                    config.IndexOf("cli_auth_credentials_store = \"file\"", StringComparison.OrdinalIgnoreCase) < 0 ||
                    config.IndexOf("env_key = \"CODEX_PORTABLE_API_KEY\"", StringComparison.OrdinalIgnoreCase) < 0 ||
                    config.IndexOf("wire_api = \"responses\"", StringComparison.OrdinalIgnoreCase) < 0 ||
                    config.IndexOf("requires_openai_auth = false", StringComparison.OrdinalIgnoreCase) < 0 ||
                    config.IndexOf("shell_environment_policy", StringComparison.OrdinalIgnoreCase) < 0 ||
                    config.IndexOf("exclude", StringComparison.OrdinalIgnoreCase) < 0 ||
                    analyticsSection < 0 ||
                    config.IndexOf("enabled = false", analyticsSection, StringComparison.OrdinalIgnoreCase) < 0 ||
                    ProviderConfiguration.CountConfiguredPlugins(config, layout.Architecture) !=
                    ProviderConfiguration.RequiredPluginCount(layout.Architecture)) return 14;
                if (!PortableOnboarding.IsSuppressed(layout)) return 27;
                if (File.Exists(layout.AuthFile) || File.Exists(layout.EphemeralMarker) || File.Exists(layout.AuthBackup) || File.Exists(layout.VaultFile)) return 15;
                if (!RootContainsOnlyPortableEntries(layout)) return 16;
                if (!AllDirectoryNamesAscii(layout.DataRoot)) return 17;
                if (!ArchitectureInfo.IsLauncherFileName(Path.GetFileName(Assembly.GetExecutingAssembly().Location))) return 18;
                bool ghExists = File.Exists(Path.Combine(layout.Tools, "gh", "bin", "gh.exe")) || File.Exists(Path.Combine(layout.Tools, "gh", "gh.exe"));
                if (!File.Exists(Path.Combine(layout.Tools, "dotnet", "dotnet.exe")) || !ghExists) return 20;
                if (!File.Exists(Path.Combine(layout.Resources, "plugins", "openai-bundled", ".agents", "plugins", "marketplace.json")) ||
                    !File.Exists(Path.Combine(layout.CodexHome, "offline-marketplaces", "openai-primary-runtime", ".agents", "plugins", "marketplace.json"))) return 22;
                if (!ProviderConfiguration.RequiredPluginCacheComplete(layout)) return 23;
                int elevationError;
                TokenElevationState elevation = WindowsTokenElevation.Query(out elevationError);
                if (elevation == TokenElevationState.Unavailable || elevationError != 0) return 24;
                Dictionary<string, string> brandEnvironment = PortableEnvironment.Build(layout, null);
                string desktopBrand;
                bool brandConfigured = brandEnvironment.TryGetValue(PortableEnvironment.DesktopBrandEnvironmentVariable, out desktopBrand) &&
                    string.Equals(desktopBrand, PortableEnvironment.DesktopBrand, StringComparison.Ordinal);
                string remoteControlDisabled;
                bool remoteControlSuppressed = brandEnvironment.TryGetValue(PortableEnvironment.RemoteControlDisabledEnvironmentVariable, out remoteControlDisabled) &&
                    string.Equals(remoteControlDisabled, "1", StringComparison.Ordinal);
                string desktopUpdaterEnabled;
                bool desktopUpdaterSuppressed = brandEnvironment.TryGetValue(PortableEnvironment.DesktopUpdaterDisabledEnvironmentVariable, out desktopUpdaterEnabled) &&
                    string.Equals(desktopUpdaterEnabled, "false", StringComparison.Ordinal);
                brandEnvironment.Clear();
                if (!brandConfigured) return 26;
                if (!remoteControlSuppressed) return 28;
                if (!desktopUpdaterSuppressed) return 36;
                string marker = Path.Combine(layout.CurrentApp, ".portable-package.txt");
                if (!File.Exists(marker)) return 21;
                string[] markerLines = File.ReadAllLines(marker, Encoding.UTF8);
                Version markerVersion;
                if (markerLines.Length < 4 || !string.Equals(markerLines[0].Trim(), AppUpdater.ExpectedName, StringComparison.Ordinal) ||
                    !string.Equals(markerLines[1].Trim(), AppUpdater.ExpectedPublisher, StringComparison.Ordinal) ||
                    !Version.TryParse(markerLines[2].Trim(), out markerVersion) ||
                    !string.Equals(markerLines[3].Trim(), ArchitectureInfo.NameOf(layout.Architecture), StringComparison.OrdinalIgnoreCase)) return 21;
                if (!AppUpdater.SelfTestUpdatePolicy()) return 33;
                if (!HostExecutionImage.SelfTestContract(layout)) return 35;
                if (!JobRun.SelfTestRecoveryContract()) return 37;
                return 0;
            }
            catch (Exception ex)
            {
                SafeLog.TryWrite(layout, "self-test", ex);
                SafeLog.TryWriteEvent(layout, "self-test-detail", ex.ToString());
                return 19;
            }
        }

        private static bool RootContainsOnlyPortableEntries(PortableLayout layout)
        {
            string launcher = Path.GetFullPath(Assembly.GetExecutingAssembly().Location);
                        string bootstrap = Path.GetFullPath(Path.Combine(layout.Root, "CodexPortable.exe"));
            string data = Path.GetFullPath(layout.DataRoot);
            string[] entries = Directory.GetFileSystemEntries(layout.Root);
            for (int i = 0; i < entries.Length; i++)
            {
                string full = Path.GetFullPath(entries[i]);
                if (string.Equals(full, launcher, StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(full, bootstrap, StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(full, data, StringComparison.OrdinalIgnoreCase)) continue;
                FileAttributes attributes = File.GetAttributes(full);
                if ((attributes & (FileAttributes.Hidden | FileAttributes.System)) != 0) continue;
                return false;
            }
            return true;
        }

        private static bool AllDirectoryNamesAscii(string root)
        {
            Stack<string> pending = new Stack<string>();
            pending.Push(ToExtendedPath(root));
            while (pending.Count > 0)
            {
                string current = pending.Pop().TrimEnd('\\');
                NativeMethods.WIN32_FIND_DATA data;
                IntPtr find = NativeMethods.FindFirstFile(current + "\\*", out data);
                if (find == NativeMethods.InvalidHandleValue)
                {
                    int firstError = Marshal.GetLastWin32Error();
                    if (firstError == 2 || firstError == 3) continue;
                    throw new Win32Exception(firstError, "Portable directory enumeration failed.");
                }
                try
                {
                    bool more = true;
                    while (more)
                    {
                        string name = data.cFileName;
                        FileAttributes attributes = data.dwFileAttributes;
                        if (name != "." && name != ".." &&
                            (attributes & FileAttributes.Directory) != 0)
                        {
                            for (int c = 0; c < name.Length; c++)
                                if (name[c] > 127) return false;
                            if ((attributes & FileAttributes.ReparsePoint) == 0)
                                pending.Push(current + "\\" + name);
                        }
                        more = NativeMethods.FindNextFile(find, out data);
                    }
                    int nextError = Marshal.GetLastWin32Error();
                    if (nextError != 18)
                        throw new Win32Exception(nextError, "Portable directory enumeration failed.");
                }
                finally
                {
                    NativeMethods.FindClose(find);
                }
            }
            return true;
        }

        private static string ToExtendedPath(string path)
        {
            if (path.StartsWith("\\\\?\\", StringComparison.Ordinal)) return path;
            string full = Path.GetFullPath(path).Replace('/', '\\');
            if (full.StartsWith("\\\\", StringComparison.Ordinal))
                return "\\\\?\\UNC\\" + full.Substring(2);
            return "\\\\?\\" + full;
        }
    }

    internal enum TokenElevationState
    {
        Unavailable = -1,
        Standard = 0,
        Elevated = 1
    }

    internal static class WindowsTokenElevation
    {
        private const uint TokenQuery = 0x0008;
        private const int TokenElevationInformationClass = 20;

        internal static TokenElevationState Query(out int nativeError)
        {
            nativeError = 0;
            IntPtr token = IntPtr.Zero;
            try
            {
                if (!NativeMethods.OpenProcessToken(NativeMethods.GetCurrentProcess(), TokenQuery, out token))
                {
                    nativeError = Marshal.GetLastWin32Error();
                    return TokenElevationState.Unavailable;
                }

                NativeMethods.TOKEN_ELEVATION elevation;
                uint returnedLength;
                uint expectedLength = (uint)Marshal.SizeOf(typeof(NativeMethods.TOKEN_ELEVATION));
                if (!NativeMethods.GetTokenInformation(token, TokenElevationInformationClass, out elevation,
                    expectedLength, out returnedLength))
                {
                    nativeError = Marshal.GetLastWin32Error();
                    return TokenElevationState.Unavailable;
                }
                if (returnedLength < expectedLength)
                {
                    nativeError = 13; // ERROR_INVALID_DATA
                    return TokenElevationState.Unavailable;
                }
                return elevation.TokenIsElevated == 0 ? TokenElevationState.Standard : TokenElevationState.Elevated;
            }
            catch (DllNotFoundException ex)
            {
                nativeError = ex.HResult;
                return TokenElevationState.Unavailable;
            }
            catch (EntryPointNotFoundException ex)
            {
                nativeError = ex.HResult;
                return TokenElevationState.Unavailable;
            }
            catch (BadImageFormatException ex)
            {
                nativeError = ex.HResult;
                return TokenElevationState.Unavailable;
            }
            finally
            {
                if (token != IntPtr.Zero) NativeMethods.CloseHandle(token);
            }
        }
    }

    internal static class Diagnostics
    {
        internal static string Create(PortableLayout layout)
        {
            layout.EnsureDirectories();
            StringBuilder text = new StringBuilder();
            text.AppendLine("Codex Portable diagnostics");
            text.AppendLine("GeneratedUtc=" + DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture));
            text.AppendLine("LauncherVersion=" + Assembly.GetExecutingAssembly().GetName().Version.ToString());
            text.AppendLine("OperatingSystem=" + Environment.OSVersion.VersionString);
            text.AppendLine("WindowsArchitecture=" + layout.ArchitectureName);
            text.AppendLine("OfficialDesktopPayloadAvailable=" + ArchitectureInfo.HasOfficialDesktopPayload(layout.Architecture).ToString(CultureInfo.InvariantCulture));
            text.AppendLine("Is64BitOS=" + Environment.Is64BitOperatingSystem.ToString(CultureInfo.InvariantCulture));
            text.AppendLine("Is64BitProcess=" + Environment.Is64BitProcess.ToString(CultureInfo.InvariantCulture));
            int elevationError;
            TokenElevationState elevation = WindowsTokenElevation.Query(out elevationError);
            text.AppendLine("ProcessTokenElevation=" + elevation.ToString());
            if (elevation == TokenElevationState.Unavailable)
                text.AppendLine("ProcessTokenElevationError=" + elevationError.ToString(CultureInfo.InvariantCulture));
            text.AppendLine("ClrVersion=" + Environment.Version.ToString());
            text.AppendLine("Root=" + layout.Root);
            try
            {
                DriveInfo drive = new DriveInfo(Path.GetPathRoot(layout.Root));
                text.AppendLine("DriveType=" + drive.DriveType.ToString());
                text.AppendLine("DriveFormat=" + drive.DriveFormat);
                text.AppendLine("DriveFreeBytes=" + drive.AvailableFreeSpace.ToString(CultureInfo.InvariantCulture));
            }
            catch (Exception ex) { text.AppendLine("DriveInfoError=" + ex.GetType().Name); }

            text.AppendLine("InstalledVersion=" + AppUpdater.ReadInstalledVersion(layout));
            AppendFile(text, "CodexDesktop", layout.AppExe, false);
            AppendFile(text, "OfficialCodexPayload", layout.OfficialAppExe, false);
            text.AppendLine("DesktopPayloadTrust=Signed MSIX plus pinned identity verified before extraction");
            text.AppendLine("PortableDesktopProcessName=" + PortableBranding.DesktopExecutableName);
            text.AppendLine("PortableBrandingPrepared=" + PortableBranding.IsPrepared(layout).ToString(CultureInfo.InvariantCulture));
            AppendFile(text, "CodexCli", layout.CodexExe, false);
            text.AppendLine("RuntimeDirectory=" + Directory.Exists(layout.Runtime).ToString(CultureInfo.InvariantCulture));
            AppendFile(text, "RuntimeNode", Path.Combine(layout.Runtime, "dependencies", "node", "bin", "node.exe"), false);
            AppendFile(text, "RuntimePython", Path.Combine(layout.Runtime, "dependencies", "python", "python.exe"), false);
            AppendFile(text, "RuntimeGit", Path.Combine(layout.Runtime, "dependencies", "native", "git", "cmd", "git.exe"), false);
            AppendFile(text, "PortableDotnet", Path.Combine(layout.Tools, "dotnet", "dotnet.exe"), false);
            AppendFile(text, "PortableGh", File.Exists(Path.Combine(layout.Tools, "gh", "bin", "gh.exe")) ?
                Path.Combine(layout.Tools, "gh", "bin", "gh.exe") : Path.Combine(layout.Tools, "gh", "gh.exe"), false);
            text.AppendLine("ConfigExists=" + File.Exists(layout.ConfigFile).ToString(CultureInfo.InvariantCulture));
            if (File.Exists(layout.ConfigFile))
            {
                string config = File.ReadAllText(layout.ConfigFile, Encoding.UTF8);
                text.AppendLine("ConfigCustomProvider=" + config.Contains("model_provider = \"portable_custom\"").ToString(CultureInfo.InvariantCulture));
                text.AppendLine("ConfigChatGptBackendBlocked=" + config.Contains("chatgpt_base_url = \"http://127.0.0.1:9\"").ToString(CultureInfo.InvariantCulture));
                text.AppendLine("ConfigNoOpenAiAuth=" + config.Contains("requires_openai_auth = false").ToString(CultureInfo.InvariantCulture));
                text.AppendLine("ConfigResponsesWireApi=" + config.Contains("wire_api = \"responses\"").ToString(CultureInfo.InvariantCulture));
                text.AppendLine("ConfigReasoningEffortMax=" + config.Contains(ProviderConfiguration.ReasoningEffortConfigLine).ToString(CultureInfo.InvariantCulture));
                string configuredApprovalPolicy;
                string configuredSandboxMode;
                bool permissionsValid = ProviderConfiguration.TryReadPermissionSettings(config,
                    out configuredApprovalPolicy, out configuredSandboxMode);
                text.AppendLine("ConfigPermissionsValid=" + permissionsValid.ToString(CultureInfo.InvariantCulture));
                text.AppendLine("ConfigApprovalPolicy=" + (configuredApprovalPolicy ?? "<invalid>"));
                text.AppendLine("ConfigSandboxMode=" + (configuredSandboxMode ?? "<invalid>"));
                string configuredFollowUpQueueMode;
                bool followUpQueueModeValid = ProviderConfiguration.TryReadFollowUpQueueMode(config,
                    out configuredFollowUpQueueMode);
                text.AppendLine("ConfigFollowUpQueueModeValid=" +
                    followUpQueueModeValid.ToString(CultureInfo.InvariantCulture));
                text.AppendLine("ConfigFollowUpQueueMode=" + (configuredFollowUpQueueMode ?? "<invalid>"));
                // Retain these booleans as quick checks for the default profile,
                // while the effective values above reflect config.toml authority.
                text.AppendLine("ConfigDangerFullAccess=" +
                    (permissionsValid && string.Equals(configuredSandboxMode, ProviderConfiguration.DefaultSandboxMode,
                        StringComparison.Ordinal)).ToString(CultureInfo.InvariantCulture));
                text.AppendLine("ConfigApprovalNever=" +
                    (permissionsValid && string.Equals(configuredApprovalPolicy, ProviderConfiguration.DefaultApprovalPolicy,
                        StringComparison.Ordinal)).ToString(CultureInfo.InvariantCulture));
                int analyticsSection = config.IndexOf("[analytics]", StringComparison.OrdinalIgnoreCase);
                text.AppendLine("ConfigAnalyticsDisabled=" + (analyticsSection >= 0 &&
                    config.IndexOf("enabled = false", analyticsSection, StringComparison.OrdinalIgnoreCase) >= 0).ToString(CultureInfo.InvariantCulture));
                text.AppendLine("ConfiguredPluginCount=" + ProviderConfiguration.CountConfiguredPlugins(
                    config, layout.Architecture).ToString(CultureInfo.InvariantCulture));
            }
            text.AppendLine("DefaultApprovalPolicy=" + ProviderConfiguration.DefaultApprovalPolicy);
            text.AppendLine("DefaultSandboxMode=" + ProviderConfiguration.DefaultSandboxMode);
            text.AppendLine("DefaultReasoningEffort=" + ProviderConfiguration.DefaultReasoningEffort);
            text.AppendLine("DefaultFollowUpQueueMode=" + ProviderConfiguration.DefaultFollowUpQueueMode);
            text.AppendLine("DesktopOnboardingSuppressed=" + PortableOnboarding.IsSuppressed(layout).ToString(CultureInfo.InvariantCulture));
            text.AppendLine("DesktopAppBrand=" + PortableEnvironment.DesktopBrand);
            text.AppendLine("DesktopAppUserModelId=" + PortableBranding.AppUserModelId);
            text.AppendLine("DesktopUpdaterPolicy=LF launcher only; CODEX_SPARKLE_ENABLED=false");
            Dictionary<string, string> diagnosticEnvironment = PortableEnvironment.Build(layout, null);
            string remoteControlDisabled;
            text.AppendLine("RemoteControlDisabled=" +
                (diagnosticEnvironment.TryGetValue(PortableEnvironment.RemoteControlDisabledEnvironmentVariable, out remoteControlDisabled) &&
                string.Equals(remoteControlDisabled, "1", StringComparison.Ordinal)).ToString(CultureInfo.InvariantCulture));
            diagnosticEnvironment.Clear();
            text.AppendLine("PerformanceScratchPolicy=host-temp-per-session; clean-on-exit; portable fallback on failure");
            text.AppendLine("PlaintextApiKeyConfigured=" + (!string.IsNullOrEmpty(ProviderConfiguration.ReadStoredApiKey(layout))).ToString(CultureInfo.InvariantCulture));
            text.AppendLine("CustomBaseUrlConfigured=" + (!string.IsNullOrEmpty(ProviderConfiguration.ReadEffectiveBaseUrl(layout))).ToString(CultureInfo.InvariantCulture));
            text.AppendLine("CustomModelConfigured=" + (!string.IsNullOrEmpty(ProviderConfiguration.ReadEffectiveModel(layout))).ToString(CultureInfo.InvariantCulture));
            text.AppendLine("AuthJsonAbsent=" + (!File.Exists(layout.AuthFile)).ToString(CultureInfo.InvariantCulture));
            text.AppendLine("LegacyVaultAbsent=" + (!File.Exists(layout.VaultFile)).ToString(CultureInfo.InvariantCulture));
            text.AppendLine("RequiredPluginCacheComplete=" + ProviderConfiguration.RequiredPluginCacheComplete(layout).ToString(CultureInfo.InvariantCulture));
            text.AppendLine("SelfTestExitCode=" + SelfTest.Run(layout).ToString(CultureInfo.InvariantCulture));
            text.AppendLine("SignaturePolicy=WinVerifyTrust plus pinned MSIX identity/publisher/architecture manifest");
            text.AppendLine("RedirectedVariableNames=CODEX_APP_BRAND,CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED,CODEX_ELECTRON_USER_DATA_PATH,CODEX_HOME,CODEX_SQLITE_HOME,CODEX_PORTABLE_ROOT,CODEX_PORTABLE_API_KEY,HOME,USERPROFILE,APPDATA,LOCALAPPDATA,LOCALAPPDATALOW,TEMP,TMP,TMPDIR,XDG_CONFIG_HOME,XDG_CACHE_HOME,XDG_DATA_HOME,XDG_STATE_HOME,DOTNET_CLI_HOME,DOTNET_BUNDLE_EXTRACT_BASE_DIR,DOTNET_ROOT,GH_CONFIG_DIR,NPM_CONFIG_CACHE,PIP_CACHE_DIR,UV_CACHE_DIR");
            text.AppendLine("ChromiumPaths=electron-user-data-portable,session-cache-host-temp,logs-crash-dumps-portable,data-downloads-portable");
            text.AppendLine("SecretValuesIncluded=false");

            string file = Path.Combine(layout.Logs, "diagnostics-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture) + ".txt");
            IOUtil.AtomicWriteText(file, text.ToString());
            return file;
        }

        private static void AppendFile(StringBuilder text, string name, string path, bool signature)
        {
            bool exists = File.Exists(path);
            text.AppendLine(name + "Exists=" + exists.ToString(CultureInfo.InvariantCulture));
            if (!exists) return;
            try
            {
                FileInfo info = new FileInfo(path);
                text.AppendLine(name + "Bytes=" + info.Length.ToString(CultureInfo.InvariantCulture));
                string version = FileVersionInfo.GetVersionInfo(path).FileVersion;
                text.AppendLine(name + "FileVersion=" + (version ?? ""));
                if (signature) text.AppendLine(name + "TrustedSignature=" + SignatureVerifier.Verify(path).ToString(CultureInfo.InvariantCulture));
            }
            catch (Exception ex) { text.AppendLine(name + "InfoError=" + ex.GetType().Name); }
        }
    }

    internal static class SafeLog
    {
        internal static void TryWrite(PortableLayout layout, string operation, Exception error)
        {
            TryWriteEvent(layout, operation, "Failure type=" + error.GetType().Name + ", hresult=" +
                error.HResult.ToString("X8", CultureInfo.InvariantCulture) + ", message=" + error.Message + ".");
        }

        internal static void TryWriteEvent(PortableLayout layout, string operation, string message)
        {
            try
            {
                Directory.CreateDirectory(layout.Logs);
                string file = Path.Combine(layout.Logs, "launcher-" + DateTime.UtcNow.ToString("yyyyMMdd", CultureInfo.InvariantCulture) + ".log");
                string safeOperation = Sanitize(operation);
                string safeMessage = Sanitize(message);
                string line = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) + " [" + safeOperation + "] " + safeMessage + Environment.NewLine;
                File.AppendAllText(file, line, new UTF8Encoding(false));
            }
            catch { }
        }

        private static string Sanitize(string value)
        {
            if (value == null) return "";
            string clean = value.Replace("\r", " ").Replace("\n", " ");
            return clean.Length <= 500 ? clean : clean.Substring(0, 500);
        }
    }

    internal static class PortableScratch
    {
        private const string ScratchProductDirectory = "LFPortable";
        private const string ScratchDirectory = "scratch";
        private const string SessionPrefix = "session-";
        private const string RecoveryHelperPrefix = "LFRecovery-";

        internal static bool TryPrepare(PortableLayout layout)
        {
            try
            {
                string baseRoot = GetValidatedBaseRoot(layout, true);
                string current = GetVerifiedSessionRoot(layout, baseRoot, true);
                EnsureConfiguredSessionDirectory(layout.HostTemp, current, "temp", true);
                EnsureConfiguredSessionDirectory(layout.HostXdgCache, current, "xdg-cache", true);
                EnsureConfiguredSessionDirectory(layout.HostChromiumCache, current, "chromium-cache", true);
                EnsureConfiguredSessionDirectory(layout.HostDotnetBundle, current, "dotnet-bundle", true);
                EnsureConfiguredSessionDirectory(layout.HostNpmCache, current, "npm-cache", true);
                EnsureConfiguredSessionDirectory(layout.HostPipCache, current, "pip-cache", true);
                EnsureConfiguredSessionDirectory(layout.HostUvCache, current, "uv-cache", true);
                // Stale session cleanup is maintenance work.  Creating the current
                // scratch tree is the only launch-critical operation, so defer the
                // potentially expensive recursive deletes until after startup.
                Task.Run(delegate { CleanupStaleSessions(layout, baseRoot, current); });
                return true;
            }
            catch (Exception ex)
            {
                SafeLog.TryWrite(layout, "performance-cache", ex);
                Cleanup(layout);
                return false;
            }
        }

        private static void CleanupStaleSessions(PortableLayout layout, string baseRoot, string current)
        {
            try
            {
                EnsureFixedDirectoryChain(baseRoot, false);
                string[] stale = Directory.GetDirectories(baseRoot, "session-*");
                DateTime cutoff = DateTime.UtcNow.AddDays(-2);
                for (int i = 0; i < stale.Length; i++)
                {
                    string candidate = NormalizeDirectoryPath(stale[i]);
                    if (string.Equals(candidate, current, StringComparison.OrdinalIgnoreCase)) continue;
                    try
                    {
                        ValidateSessionRoot(baseRoot, candidate, false);
                        if (Directory.GetLastWriteTimeUtc(candidate) < cutoff)
                        {
                            ValidateSessionRoot(baseRoot, candidate, false);
                            IOUtil.DeleteDirectoryWithin(candidate, baseRoot);
                        }
                    }
                    catch { }
                }
            }
            catch (Exception ex)
            {
                SafeLog.TryWrite(layout, "performance-cache-cleanup", ex);
            }
        }

        internal static bool IsPrepared(PortableLayout layout)
        {
            try
            {
                string baseRoot = GetValidatedBaseRoot(layout, false);
                string sessionRoot = GetVerifiedSessionRoot(layout, baseRoot, false);
                EnsureConfiguredSessionDirectory(layout.HostTemp, sessionRoot, "temp", false);
                EnsureConfiguredSessionDirectory(layout.HostXdgCache, sessionRoot, "xdg-cache", false);
                EnsureConfiguredSessionDirectory(layout.HostChromiumCache, sessionRoot, "chromium-cache", false);
                EnsureConfiguredSessionDirectory(layout.HostDotnetBundle, sessionRoot, "dotnet-bundle", false);
                EnsureConfiguredSessionDirectory(layout.HostNpmCache, sessionRoot, "npm-cache", false);
                EnsureConfiguredSessionDirectory(layout.HostPipCache, sessionRoot, "pip-cache", false);
                EnsureConfiguredSessionDirectory(layout.HostUvCache, sessionRoot, "uv-cache", false);
                return true;
            }
            catch { return false; }
        }

        internal static string ActiveChromiumCache(PortableLayout layout)
        {
            return IsPrepared(layout) ? layout.HostChromiumCache : layout.ChromiumCache;
        }

        internal static void Cleanup(PortableLayout layout)
        {
            try
            {
                string baseRoot = GetValidatedBaseRoot(layout, false);
                string sessionRoot = GetVerifiedSessionRoot(layout, baseRoot, false);
                IOUtil.DeleteDirectoryWithin(sessionRoot, baseRoot);
            }
            catch { }
        }

        internal static string ValidateRecoveryHelperPath(PortableLayout layout,
            string helperPath, bool requireExists)
        {
            if (string.IsNullOrEmpty(helperPath))
                throw new ArgumentException("The desktop recovery helper path is missing.", "helperPath");
            string sessionRoot = GetVerifiedSessionRoot(layout);
            string helperFull = NormalizeDirectoryPath(helperPath);
            string helperParent = Path.GetDirectoryName(helperFull);
            string helperName = Path.GetFileName(helperFull);
            if (!string.Equals(NormalizeDirectoryPath(helperParent), sessionRoot,
                    StringComparison.OrdinalIgnoreCase) ||
                !helperName.StartsWith(RecoveryHelperPrefix, StringComparison.OrdinalIgnoreCase) ||
                !helperName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ||
                helperName.Length <= RecoveryHelperPrefix.Length + 4)
                throw new InvalidOperationException("The desktop recovery helper path is unsafe.");

            uint attributes = NativeMethods.GetFileAttributes(helperFull);
            if (attributes == NativeMethods.InvalidFileAttributes)
            {
                int error = Marshal.GetLastWin32Error();
                if (!requireExists && (error == 2 || error == 3)) return helperFull;
                throw new Win32Exception(error, "Unable to verify the desktop recovery helper.");
            }
            FileAttributes fileAttributes = (FileAttributes)attributes;
            if ((fileAttributes & FileAttributes.Directory) != 0 ||
                (fileAttributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("The desktop recovery helper must be a regular file.");
            return helperFull;
        }

        private static string GetVerifiedSessionRoot(PortableLayout layout)
        {
            string baseRoot = GetValidatedBaseRoot(layout, false);
            return GetVerifiedSessionRoot(layout, baseRoot, false);
        }

        private static string GetVerifiedSessionRoot(PortableLayout layout, string baseRoot,
            bool create)
        {
            if (layout == null) throw new ArgumentNullException("layout");
            return ValidateSessionRoot(baseRoot, layout.HostScratchRoot, create);
        }

        private static string GetValidatedBaseRoot(PortableLayout layout, bool create)
        {
            if (layout == null) throw new ArgumentNullException("layout");
            string hostLocalAppData = Environment.GetFolderPath(
                Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrEmpty(hostLocalAppData))
                throw new InvalidOperationException("The host local application-data directory is unavailable.");
            string expectedBase = NormalizeDirectoryPath(Path.Combine(hostLocalAppData,
                ScratchProductDirectory, ScratchDirectory));
            string scratch = NormalizeDirectoryPath(layout.HostScratchRoot);
            string configuredBase = NormalizeDirectoryPath(Path.GetDirectoryName(scratch));
            string portableRoot = NormalizeDirectoryPath(layout.Root);
            if (!string.Equals(expectedBase, configuredBase, StringComparison.OrdinalIgnoreCase) ||
                IsSameOrDescendant(scratch, portableRoot))
                throw new InvalidOperationException("Invalid host scratch path.");
            EnsureFixedDirectoryChain(expectedBase, create);
            return expectedBase;
        }

        private static string ValidateSessionRoot(string baseRoot, string sessionPath, bool create)
        {
            string normalizedBase = NormalizeDirectoryPath(baseRoot);
            string session = NormalizeDirectoryPath(sessionPath);
            string sessionParent = Path.GetDirectoryName(session);
            string sessionName = Path.GetFileName(session);
            if (!string.Equals(NormalizeDirectoryPath(sessionParent), normalizedBase,
                    StringComparison.OrdinalIgnoreCase) ||
                !sessionName.StartsWith(SessionPrefix, StringComparison.OrdinalIgnoreCase) ||
                sessionName.Length <= SessionPrefix.Length)
                throw new InvalidOperationException("The host scratch session path is unsafe.");
            EnsureFixedDirectoryChain(session, create);
            return session;
        }

        private static void EnsureConfiguredSessionDirectory(string configuredPath,
            string sessionRoot, string name, bool create)
        {
            string expected = NormalizeDirectoryPath(Path.Combine(sessionRoot, name));
            string configured = NormalizeDirectoryPath(configuredPath);
            if (!string.Equals(expected, configured, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The host scratch child path is unsafe.");
            EnsureFixedDirectoryChain(expected, create);
        }

        private static void EnsureFixedDirectoryChain(string path, bool create)
        {
            string target = NormalizeDirectoryPath(path);
            string volumeRoot = Path.GetPathRoot(target);
            if (string.IsNullOrEmpty(volumeRoot))
                throw new InvalidOperationException("The host scratch volume is unavailable.");
            DriveInfo drive = new DriveInfo(volumeRoot);
            if (!drive.IsReady || drive.DriveType != DriveType.Fixed)
                throw new InvalidOperationException("The host scratch directory must be on a fixed local volume.");

            string root = NormalizeDirectoryPath(volumeRoot);
            EnsureRegularFixedDirectory(root, false);
            if (!string.Equals(target, root, StringComparison.OrdinalIgnoreCase))
            {
                string relative = target.Substring(root.Length).TrimStart(
                    Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                string[] segments = relative.Split(new char[] {
                    Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar
                }, StringSplitOptions.RemoveEmptyEntries);
                string current = root;
                for (int i = 0; i < segments.Length; i++)
                {
                    current = Path.Combine(current, segments[i]);
                    EnsureRegularFixedDirectory(current, create);
                }
            }
            // Directory.CreateDirectory can traverse more than one level. Recheck
            // the whole chain after a creating pass before it is used for scratch data.
            if (create) EnsureFixedDirectoryChain(target, false);
        }

        private static void EnsureRegularFixedDirectory(string path, bool create)
        {
            uint attributes = NativeMethods.GetFileAttributes(path);
            if (attributes == NativeMethods.InvalidFileAttributes)
            {
                int error = Marshal.GetLastWin32Error();
                if (!create || (error != 2 && error != 3))
                    throw new Win32Exception(error, "Unable to verify the host scratch directory.");
                Directory.CreateDirectory(path);
                attributes = NativeMethods.GetFileAttributes(path);
                if (attributes == NativeMethods.InvalidFileAttributes)
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Unable to create the host scratch directory.");
            }
            FileAttributes directoryAttributes = (FileAttributes)attributes;
            if ((directoryAttributes & FileAttributes.Directory) == 0 ||
                (directoryAttributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Host scratch directories cannot be reparse points.");
        }

        private static string NormalizeDirectoryPath(string path)
        {
            if (string.IsNullOrEmpty(path)) throw new ArgumentException("Directory path is missing.", "path");
            string full = Path.GetFullPath(path);
            string volumeRoot = Path.GetPathRoot(full);
            if (string.IsNullOrEmpty(volumeRoot)) throw new InvalidOperationException("Directory path has no volume root.");
            if (string.Equals(full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                volumeRoot.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                StringComparison.OrdinalIgnoreCase)) return volumeRoot;
            return full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }

        private static bool IsSameOrDescendant(string candidate, string root)
        {
            if (string.Equals(candidate, root, StringComparison.OrdinalIgnoreCase)) return true;
            string prefix = root.EndsWith("\\", StringComparison.Ordinal) ? root : root + "\\";
            return candidate.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
        }
    }

    internal static class IOUtil
    {
        internal static void EnsureDirectoryWithinNoReparse(string path, string allowedRoot)
        {
            string root = NormalizeDirectoryPath(allowedRoot);
            string target = NormalizeDirectoryPath(path);
            if (!target.Equals(root, StringComparison.OrdinalIgnoreCase) &&
                !target.StartsWith(root + Path.DirectorySeparatorChar,
                    StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Directory is outside the portable root: " + target);

            EnsureRegularDirectory(root, false);
            if (target.Equals(root, StringComparison.OrdinalIgnoreCase)) return;
            string relative = target.Substring(root.Length).TrimStart(
                Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            string current = root;
            string[] segments = relative.Split(new char[] {
                Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar
            }, StringSplitOptions.RemoveEmptyEntries);
            for (int i = 0; i < segments.Length; i++)
            {
                current = Path.Combine(current, segments[i]);
                EnsureRegularDirectory(current, true);
            }
        }

        private static string NormalizeDirectoryPath(string path)
        {
            string full = Path.GetFullPath(path);
            string volumeRoot = Path.GetPathRoot(full);
            if (!string.IsNullOrEmpty(volumeRoot) && string.Equals(
                full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                volumeRoot.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                StringComparison.OrdinalIgnoreCase)) return volumeRoot;
            return full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }

        private static void EnsureRegularDirectory(string path, bool create)
        {
            if (File.Exists(path) && !Directory.Exists(path))
                throw new IOException("Portable directory path is a file: " + path);
            if (!Directory.Exists(path))
            {
                if (!create)
                    throw new DirectoryNotFoundException("Portable root is missing: " + path);
                Directory.CreateDirectory(path);
            }
            FileAttributes attributes = File.GetAttributes(path);
            if ((attributes & FileAttributes.Directory) == 0 ||
                (attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Portable directories cannot be reparse points: " + path);
        }

        internal static void AtomicWriteText(string path, string text)
        {
            AtomicWriteBytes(path, new UTF8Encoding(false).GetBytes(text));
        }

        internal static void AtomicWriteSensitiveText(string path, string text)
        {
            byte[] bytes = new UTF8Encoding(false).GetBytes(text);
            try { AtomicWriteBytes(path, bytes); }
            finally { CryptoUtil.Zero(bytes); }
        }

        internal static void AtomicWriteBytes(string path, byte[] bytes)
        {
            string directory = Path.GetDirectoryName(path);
            Directory.CreateDirectory(directory);
            string temporary = Path.Combine(directory, ".write-" + Guid.NewGuid().ToString("N") + ".tmp");
            using (FileStream stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(true);
            }
            try
            {
                AtomicReplaceFile(temporary, path);
            }
            finally { TryDelete(temporary); }
        }

        internal static void AtomicReplaceFile(string temporary, string path)
        {
            if (!File.Exists(temporary))
                throw new FileNotFoundException("Atomic replacement source is missing.", temporary);
            string directory = Path.GetDirectoryName(path);
            string temporaryDirectory = Path.GetDirectoryName(temporary);
            if (string.IsNullOrEmpty(directory) || string.IsNullOrEmpty(temporaryDirectory) ||
                !string.Equals(Path.GetFullPath(directory).TrimEnd('\\'),
                    Path.GetFullPath(temporaryDirectory).TrimEnd('\\'),
                    StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Atomic replacement files must share one directory.");
            Directory.CreateDirectory(directory);
            if (!File.Exists(path))
            {
                File.Move(temporary, path);
                return;
            }
            try
            {
                File.Replace(temporary, path, null, true);
                return;
            }
            catch (PlatformNotSupportedException) { }
            catch (IOException) { }

            string old = Path.Combine(directory, ".old-" + Guid.NewGuid().ToString("N") + ".tmp");
            File.Move(path, old);
            try
            {
                File.Move(temporary, path);
                TryDelete(old);
            }
            catch
            {
                if (!File.Exists(path) && File.Exists(old)) File.Move(old, path);
                throw;
            }
        }

        internal static void TryDelete(string path)
        {
            try
            {
                if (File.Exists(path))
                {
                    File.SetAttributes(path, FileAttributes.Normal);
                    File.Delete(path);
                }
            }
            catch { }
        }

        internal static void DeleteFileIfExists(string path)
        {
            if (!File.Exists(path)) return;
            File.SetAttributes(path, FileAttributes.Normal);
            File.Delete(path);
            if (File.Exists(path)) throw new IOException("File deletion did not complete.");
        }

        internal static void DeleteDirectoryWithin(string target, string allowedRoot)
        {
            string targetFull = Path.GetFullPath(target).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            string rootFull = Path.GetFullPath(allowedRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (targetFull.Length <= rootFull.Length || !targetFull.StartsWith(rootFull + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Refusing unsafe directory deletion.");
            if (Directory.Exists(targetFull))
            {
                string extended = targetFull.StartsWith("\\\\", StringComparison.Ordinal) ?
                    "\\\\?\\UNC\\" + targetFull.Substring(2) : "\\\\?\\" + targetFull;
                DeleteDirectoryLongPath(extended);
            }
        }

        private static void DeleteDirectoryLongPath(string extendedDirectory)
        {
            NativeMethods.WIN32_FIND_DATA data;
            IntPtr find = NativeMethods.FindFirstFile(extendedDirectory + "\\*", out data);
            if (find != new IntPtr(-1))
            {
                try
                {
                    bool more = true;
                    while (more)
                    {
                        string name = data.cFileName;
                        if (name != "." && name != "..")
                        {
                            string child = extendedDirectory + "\\" + name;
                            bool isDirectory = (data.dwFileAttributes & FileAttributes.Directory) != 0;
                            bool isReparse = (data.dwFileAttributes & FileAttributes.ReparsePoint) != 0;
                            if (isDirectory && !isReparse) DeleteDirectoryLongPath(child);
                            else if (isDirectory)
                            {
                                NativeMethods.SetFileAttributes(child, FileAttributes.Normal);
                                if (!NativeMethods.RemoveDirectory(child)) ThrowDeleteError();
                            }
                            else
                            {
                                NativeMethods.SetFileAttributes(child, FileAttributes.Normal);
                                if (!NativeMethods.DeleteFile(child)) ThrowDeleteError();
                            }
                        }
                        more = NativeMethods.FindNextFile(find, out data);
                        if (!more)
                        {
                            int error = Marshal.GetLastWin32Error();
                            if (error != 18) throw new Win32Exception(error, "Long-path enumeration failed.");
                        }
                    }
                }
                finally { NativeMethods.FindClose(find); }
            }
            else
            {
                int error = Marshal.GetLastWin32Error();
                if (error != 2 && error != 3) throw new Win32Exception(error, "Long-path enumeration failed.");
            }
            NativeMethods.SetFileAttributes(extendedDirectory, FileAttributes.Normal);
            if (!NativeMethods.RemoveDirectory(extendedDirectory))
            {
                int error = Marshal.GetLastWin32Error();
                if (error != 2 && error != 3) throw new Win32Exception(error, "Long-path directory removal failed.");
            }
        }

        private static void ThrowDeleteError()
        {
            int error = Marshal.GetLastWin32Error();
            if (error != 2 && error != 3) throw new Win32Exception(error, "Long-path deletion failed.");
        }

        internal static string Sha256File(string path)
        {
            byte[] hash;
            using (FileStream stream = File.OpenRead(path))
            using (SHA256 sha = SHA256.Create()) hash = sha.ComputeHash(stream);
            StringBuilder result = new StringBuilder(hash.Length * 2);
            for (int i = 0; i < hash.Length; i++) result.Append(hash[i].ToString("x2", CultureInfo.InvariantCulture));
            CryptoUtil.Zero(hash);
            return result.ToString();
        }

        internal static string QuoteArgument(string argument)
        {
            if (argument.Length > 0 && argument.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0) return argument;
            StringBuilder result = new StringBuilder();
            result.Append('"');
            int slashes = 0;
            for (int i = 0; i < argument.Length; i++)
            {
                char c = argument[i];
                if (c == '\\') { slashes++; continue; }
                if (c == '"')
                {
                    result.Append('\\', slashes * 2 + 1);
                    result.Append('"');
                    slashes = 0;
                    continue;
                }
                result.Append('\\', slashes);
                slashes = 0;
                result.Append(c);
            }
            result.Append('\\', slashes * 2);
            result.Append('"');
            return result.ToString();
        }
    }
}

namespace CodexPortable
{
    internal static class SignatureVerifier
    {
        private static readonly Guid GenericVerifyV2 = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");

        internal static bool Verify(string path)
        {
            return Verify(path, IntPtr.Zero);
        }

        internal static bool Verify(string path, FileStream stream)
        {
            if (stream == null) throw new ArgumentNullException("stream");
            if (!stream.CanRead || !stream.CanSeek)
                throw new ArgumentException("The signature-verification stream must be readable and seekable.",
                    "stream");
            SafeFileHandle handle = stream.SafeFileHandle;
            if (handle.IsInvalid || handle.IsClosed)
                throw new ObjectDisposedException("stream");
            bool addedReference = false;
            stream.Position = 0;
            try
            {
                handle.DangerousAddRef(ref addedReference);
                return Verify(path, handle.DangerousGetHandle());
            }
            finally
            {
                if (addedReference) handle.DangerousRelease();
                stream.Position = 0;
            }
        }

        private static bool Verify(string path, IntPtr fileHandle)
        {
            NativeMethods.WINTRUST_FILE_INFO fileInfo = new NativeMethods.WINTRUST_FILE_INFO();
            fileInfo.cbStruct = (uint)Marshal.SizeOf(typeof(NativeMethods.WINTRUST_FILE_INFO));
            fileInfo.pcwszFilePath = path;
            fileInfo.hFile = fileHandle;
            fileInfo.pgKnownSubject = IntPtr.Zero;

            IntPtr fileInfoPointer = Marshal.AllocCoTaskMem(Marshal.SizeOf(typeof(NativeMethods.WINTRUST_FILE_INFO)));
            try
            {
                Marshal.StructureToPtr(fileInfo, fileInfoPointer, false);
                NativeMethods.WINTRUST_DATA data = new NativeMethods.WINTRUST_DATA();
                data.cbStruct = (uint)Marshal.SizeOf(typeof(NativeMethods.WINTRUST_DATA));
                data.dwUIChoice = 2;               // WTD_UI_NONE
                data.fdwRevocationChecks = 0;       // WTD_REVOKE_NONE
                data.dwUnionChoice = 1;             // WTD_CHOICE_FILE
                data.pFile = fileInfoPointer;
                data.dwStateAction = 0;
                data.dwProvFlags = 0;
                data.dwUIContext = 0;
                Guid action = GenericVerifyV2;
                return NativeMethods.WinVerifyTrust(IntPtr.Zero, ref action, ref data) == 0;
            }
            finally
            {
                Marshal.DestroyStructure(fileInfoPointer, typeof(NativeMethods.WINTRUST_FILE_INFO));
                Marshal.FreeCoTaskMem(fileInfoPointer);
            }
        }
    }

    internal sealed class JobRun : IDisposable
    {
        internal const int ProcessTreeTerminationTimeoutMilliseconds = 15000;
        internal const int ProcessTreeTerminationPollMilliseconds = 50;
        private const int SelfTestChildLifetimeMilliseconds = 30000;
        internal const string SelfTestChildArgument = "--jobrun-self-test-child";
        private readonly object sync = new object();
        private IntPtr jobHandle;
        private IntPtr processHandle;
        internal readonly uint ProcessId;
        private bool terminationRequested;

        private JobRun(IntPtr job, IntPtr process, uint processId)
        {
            jobHandle = job;
            processHandle = process;
            ProcessId = processId;
        }

        internal static JobRun Start(string executable, string arguments, string workingDirectory, Dictionary<string, string> environment)
        {
            return Start(executable, arguments, workingDirectory, environment, 0);
        }

        private static JobRun Start(string executable, string arguments, string workingDirectory,
            Dictionary<string, string> environment, uint additionalCreationFlags)
        {
            IntPtr job = NativeMethods.CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to create process job.");
            IntPtr environmentBlock = IntPtr.Zero;
            int environmentBlockLength = 0;
            NativeMethods.PROCESS_INFORMATION processInfo = new NativeMethods.PROCESS_INFORMATION();
            bool created = false;
            try
            {
                NativeMethods.JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = new NativeMethods.JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                limits.BasicLimitInformation.LimitFlags = 0x00002000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                int limitsLength = Marshal.SizeOf(typeof(NativeMethods.JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
                IntPtr limitsPointer = Marshal.AllocHGlobal(limitsLength);
                try
                {
                    Marshal.StructureToPtr(limits, limitsPointer, false);
                    if (!NativeMethods.SetInformationJobObject(job, 9, limitsPointer, (uint)limitsLength))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to configure process job.");
                }
                finally { Marshal.FreeHGlobal(limitsPointer); }

                environmentBlock = BuildEnvironmentBlock(environment, out environmentBlockLength);
                NativeMethods.STARTUPINFO startup = new NativeMethods.STARTUPINFO();
                startup.cb = (uint)Marshal.SizeOf(typeof(NativeMethods.STARTUPINFO));
                StringBuilder command = new StringBuilder(IOUtil.QuoteArgument(executable));
                if (!string.IsNullOrEmpty(arguments)) command.Append(" ").Append(arguments);
                uint flags = 0x00000004 | 0x00000400 | additionalCreationFlags; // CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT
                created = NativeMethods.CreateProcess(executable, command, IntPtr.Zero, IntPtr.Zero, false, flags,
                    environmentBlock, workingDirectory, ref startup, out processInfo);
                if (!created) throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to create Codex process.");
                if (!NativeMethods.AssignProcessToJobObject(job, processInfo.hProcess))
                {
                    NativeMethods.TerminateProcess(processInfo.hProcess, 1);
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to contain Codex process tree.");
                }
                if (NativeMethods.ResumeThread(processInfo.hThread) == 0xFFFFFFFF)
                {
                    NativeMethods.TerminateProcess(processInfo.hProcess, 1);
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to resume Codex process.");
                }
                NativeMethods.CloseHandle(processInfo.hThread);
                processInfo.hThread = IntPtr.Zero;
                JobRun result = new JobRun(job, processInfo.hProcess, processInfo.dwProcessId);
                job = IntPtr.Zero;
                processInfo.hProcess = IntPtr.Zero;
                return result;
            }
            finally
            {
                if (environmentBlock != IntPtr.Zero)
                {
                    byte[] zeros = new byte[environmentBlockLength];
                    Marshal.Copy(zeros, 0, environmentBlock, zeros.Length);
                    Array.Clear(zeros, 0, zeros.Length);
                    Marshal.FreeHGlobal(environmentBlock);
                }
                if (processInfo.hThread != IntPtr.Zero) NativeMethods.CloseHandle(processInfo.hThread);
                if (processInfo.hProcess != IntPtr.Zero) NativeMethods.CloseHandle(processInfo.hProcess);
                if (job != IntPtr.Zero) NativeMethods.CloseHandle(job);
            }
        }

        private static IntPtr BuildEnvironmentBlock(Dictionary<string, string> environment, out int byteLength)
        {
            List<string> entries = new List<string>();
            foreach (KeyValuePair<string, string> pair in environment)
            {
                if (pair.Key.Length == 0 || pair.Key[0] == '=' || pair.Key.IndexOf('\0') >= 0 || pair.Value.IndexOf('\0') >= 0) continue;
                entries.Add(pair.Key + "=" + pair.Value);
            }
            entries.Sort(StringComparer.OrdinalIgnoreCase);
            string block = string.Join("\0", entries.ToArray()) + "\0\0";
            byte[] bytes = Encoding.Unicode.GetBytes(block);
            byteLength = bytes.Length;
            IntPtr pointer = Marshal.AllocHGlobal(bytes.Length);
            Marshal.Copy(bytes, 0, pointer, bytes.Length);
            Array.Clear(bytes, 0, bytes.Length);
            return pointer;
        }

        internal static bool IsSelfTestProcessArgument(string argument)
        {
            return string.Equals(argument, SelfTestChildArgument, StringComparison.OrdinalIgnoreCase);
        }

        internal static int RunSelfTestProcess(string argument)
        {
            if (!string.Equals(argument, SelfTestChildArgument, StringComparison.OrdinalIgnoreCase)) return 1;
            Thread.Sleep(SelfTestChildLifetimeMilliseconds);
            return 0;
        }

        internal static int SelfTestRecoveryContractExitCode()
        {
            JobRun run = null;
            try
            {
                string executable = Assembly.GetExecutingAssembly().Location;
                string workingDirectory = Path.GetDirectoryName(executable);
                Dictionary<string, string> environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables())
                {
                    string name = entry.Key as string;
                    string value = entry.Value as string;
                    if (!string.IsNullOrEmpty(name) && value != null) environment[name] = value;
                }
                run = Start(executable, SelfTestChildArgument, workingDirectory, environment);
                if (!run.WaitForActiveProcessCount(1, ProcessTreeTerminationTimeoutMilliseconds)) return 71;
                run.TerminateProcessTreeAndWait(ProcessTreeTerminationTimeoutMilliseconds);
                uint exitCode;
                if (!run.TryGetEarlyExit(ProcessTreeTerminationTimeoutMilliseconds, out exitCode)) return 72;
                if (exitCode != 0) return 73;
                return run.GetActiveProcessCount() == 0 ? 0 : 74;
            }
            catch
            {
                return 75;
            }
            finally
            {
                if (run != null)
                {
                    try { run.StopProcessTree(); } catch { }
                    try { run.Dispose(); } catch { }
                }
            }
        }

        internal static bool SelfTestRecoveryContract()
        {
            return SelfTestRecoveryContractExitCode() == 0;
        }

        private bool WaitForActiveProcessCount(uint minimum, int timeoutMilliseconds)
        {
            if (minimum == 0) return true;
            if (timeoutMilliseconds < 0) throw new ArgumentOutOfRangeException("timeoutMilliseconds");
            Stopwatch timer = Stopwatch.StartNew();
            while (true)
            {
                if (GetActiveProcessCount() >= minimum) return true;
                if (timer.ElapsedMilliseconds >= timeoutMilliseconds) return false;
                long remaining = timeoutMilliseconds - timer.ElapsedMilliseconds;
                int delay = (int)Math.Min((long)ProcessTreeTerminationPollMilliseconds,
                    Math.Max(1L, remaining));
                Thread.Sleep(delay);
            }
        }

        private uint GetActiveProcessCount()
        {
            lock (sync)
            {
                if (jobHandle == IntPtr.Zero) return 0;
                return QueryActiveProcessCountLocked();
            }
        }

        private uint QueryActiveProcessCountLocked()
        {
            int size = Marshal.SizeOf(typeof(NativeMethods.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
            IntPtr pointer = Marshal.AllocHGlobal(size);
            try
            {
                uint returned;
                if (!NativeMethods.QueryInformationJobObject(jobHandle, 1, pointer,
                    (uint)size, out returned))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Unable to query Codex process-tree state.");
                }
                if (returned < (uint)size)
                    throw new InvalidDataException("Windows returned an incomplete process-tree state.");
                NativeMethods.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting =
                    (NativeMethods.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)Marshal.PtrToStructure(
                        pointer, typeof(NativeMethods.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
                return accounting.ActiveProcesses;
            }
            finally
            {
                Marshal.FreeHGlobal(pointer);
            }
        }

        internal void TerminateProcessTreeAndWait(int timeoutMilliseconds)
        {
            if (timeoutMilliseconds < 0) throw new ArgumentOutOfRangeException("timeoutMilliseconds");
            lock (sync)
            {
                if (jobHandle == IntPtr.Zero) return;
                if (!terminationRequested)
                {
                    if (!NativeMethods.TerminateJobObject(jobHandle, 0))
                        throw new Win32Exception(Marshal.GetLastWin32Error(),
                            "Unable to terminate Codex process tree.");
                    terminationRequested = true;
                }

                Stopwatch timer = Stopwatch.StartNew();
                while (true)
                {
                    uint activeProcesses = QueryActiveProcessCountLocked();
                    if (activeProcesses == 0) return;
                    if (timer.ElapsedMilliseconds >= timeoutMilliseconds)
                        throw new TimeoutException("Codex process tree did not exit before the recovery timeout.");
                    long remaining = timeoutMilliseconds - timer.ElapsedMilliseconds;
                    int delay = (int)Math.Min((long)ProcessTreeTerminationPollMilliseconds,
                        Math.Max(1L, remaining));
                    Thread.Sleep(delay);
                }
            }
        }

        internal void StopProcessTree()
        {
            lock (sync)
            {
                if (jobHandle == IntPtr.Zero || terminationRequested) return;
                if (!NativeMethods.TerminateJobObject(jobHandle, 0))
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Unable to terminate Codex process tree.");
                terminationRequested = true;
            }
        }

        // The launcher must not report success merely because CreateProcess
        // succeeded. A mapped-image I/O failure happens after that point and
        // otherwise looks like a successful handoff.
        internal bool TryGetEarlyExit(int timeoutMilliseconds, out uint exitCode)
        {
            if (timeoutMilliseconds < 0) throw new ArgumentOutOfRangeException("timeoutMilliseconds");
            IntPtr waitHandle = IntPtr.Zero;
            try
            {
                lock (sync)
                {
                    if (processHandle == IntPtr.Zero)
                        throw new InvalidOperationException("Codex process handle is unavailable.");
                    if (!NativeMethods.DuplicateHandle(NativeMethods.GetCurrentProcess(), processHandle,
                        NativeMethods.GetCurrentProcess(), out waitHandle, 0, false,
                        NativeMethods.DuplicateSameAccess))
                        throw new Win32Exception(Marshal.GetLastWin32Error(),
                            "Unable to duplicate the Codex process handle.");
                }
                uint result = NativeMethods.WaitForSingleObject(waitHandle,
                    unchecked((uint)timeoutMilliseconds));
                if (result == NativeMethods.WaitTimeout)
                {
                    exitCode = 0;
                    return false;
                }
                if (result != NativeMethods.WaitObject0)
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Unable to wait for Codex startup.");
                if (!NativeMethods.GetExitCodeProcess(waitHandle, out exitCode))
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Unable to read Codex startup exit code.");
                return true;
            }
            finally
            {
                if (waitHandle != IntPtr.Zero) NativeMethods.CloseHandle(waitHandle);
            }
        }

        internal bool TryDetachAfterStartup(out uint exitCode)
        {
            lock (sync)
            {
                exitCode = 0;
                if (jobHandle == IntPtr.Zero || processHandle == IntPtr.Zero)
                    throw new InvalidOperationException("Codex process ownership is unavailable.");
                uint wait = NativeMethods.WaitForSingleObject(processHandle, 0);
                if (wait == NativeMethods.WaitObject0)
                {
                    if (!NativeMethods.GetExitCodeProcess(processHandle, out exitCode))
                        throw new Win32Exception(Marshal.GetLastWin32Error(),
                            "Unable to read Codex startup exit code.");
                    return false;
                }
                if (wait != NativeMethods.WaitTimeout)
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Unable to confirm Codex startup.");
                NativeMethods.JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = new NativeMethods.JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                limits.BasicLimitInformation.LimitFlags = 0;
                int size = Marshal.SizeOf(typeof(NativeMethods.JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
                IntPtr pointer = Marshal.AllocHGlobal(size);
                try
                {
                    Marshal.StructureToPtr(limits, pointer, false);
                    if (!NativeMethods.SetInformationJobObject(jobHandle, 9, pointer, (uint)size))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to detach Codex process tree.");
                }
                finally { Marshal.FreeHGlobal(pointer); }
                NativeMethods.CloseHandle(jobHandle);
                jobHandle = IntPtr.Zero;
                if (processHandle != IntPtr.Zero)
                {
                    NativeMethods.CloseHandle(processHandle);
                    processHandle = IntPtr.Zero;
                }
                return true;
            }
        }

        public void Dispose()
        {
            lock (sync)
            {
                if (jobHandle != IntPtr.Zero)
                {
                    if (!terminationRequested)
                    {
                        NativeMethods.TerminateJobObject(jobHandle, 0);
                        terminationRequested = true;
                    }
                    NativeMethods.CloseHandle(jobHandle);
                    jobHandle = IntPtr.Zero;
                }
                if (processHandle != IntPtr.Zero)
                {
                    NativeMethods.CloseHandle(processHandle);
                    processHandle = IntPtr.Zero;
                }
            }
        }
    }

    internal static class NativeMethods
    {
        internal const uint InvalidFileAttributes = 0xFFFFFFFF;
        internal static readonly IntPtr InvalidHandleValue = new IntPtr(-1);
        internal const uint GenericRead = 0x80000000;
        internal const uint GenericWrite = 0x40000000;
        internal const uint FileShareRead = 0x00000001;
        internal const uint FileShareWrite = 0x00000002;
        internal const uint FileShareDelete = 0x00000004;
        internal const uint CreateNew = 1;
        internal const uint CreateAlways = 2;
        internal const uint OpenExisting = 3;
        internal const uint OpenAlways = 4;
        internal const uint TruncateExisting = 5;
        internal const uint FileAttributeNormal = 0x00000080;
        internal const uint FileFlagWriteThrough = 0x80000000;
        internal const uint FileFlagSequentialScan = 0x08000000;
        internal const uint ProcessQueryLimitedInformation = 0x1000;
        internal const uint MaximumProcessImagePath = 32768;
        internal const uint WaitObject0 = 0;
        internal const uint WaitTimeout = 258;
        internal const uint DuplicateSameAccess = 0x00000002;
        internal const uint SemFailCriticalErrors = 0x0001;
        internal const uint SemNoGpFaultErrorBox = 0x0002;

        [StructLayout(LayoutKind.Sequential)]
        internal struct SYSTEM_INFO
        {
            internal ushort wProcessorArchitecture;
            internal ushort wReserved;
            internal uint dwPageSize;
            internal IntPtr lpMinimumApplicationAddress;
            internal IntPtr lpMaximumApplicationAddress;
            internal UIntPtr dwActiveProcessorMask;
            internal uint dwNumberOfProcessors;
            internal uint dwProcessorType;
            internal uint dwAllocationGranularity;
            internal ushort wProcessorLevel;
            internal ushort wProcessorRevision;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct WINTRUST_FILE_INFO
        {
            internal uint cbStruct;
            [MarshalAs(UnmanagedType.LPWStr)] internal string pcwszFilePath;
            internal IntPtr hFile;
            internal IntPtr pgKnownSubject;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct WINTRUST_DATA
        {
            internal uint cbStruct;
            internal IntPtr pPolicyCallbackData;
            internal IntPtr pSIPClientData;
            internal uint dwUIChoice;
            internal uint fdwRevocationChecks;
            internal uint dwUnionChoice;
            internal IntPtr pFile;
            internal uint dwStateAction;
            internal IntPtr hWVTStateData;
            internal IntPtr pwszURLReference;
            internal uint dwProvFlags;
            internal uint dwUIContext;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct STARTUPINFO
        {
            internal uint cb;
            internal IntPtr lpReserved;
            internal IntPtr lpDesktop;
            internal IntPtr lpTitle;
            internal uint dwX;
            internal uint dwY;
            internal uint dwXSize;
            internal uint dwYSize;
            internal uint dwXCountChars;
            internal uint dwYCountChars;
            internal uint dwFillAttribute;
            internal uint dwFlags;
            internal ushort wShowWindow;
            internal ushort cbReserved2;
            internal IntPtr lpReserved2;
            internal IntPtr hStdInput;
            internal IntPtr hStdOutput;
            internal IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct PROCESS_INFORMATION
        {
            internal IntPtr hProcess;
            internal IntPtr hThread;
            internal uint dwProcessId;
            internal uint dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct TOKEN_ELEVATION
        {
            internal uint TokenIsElevated;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            internal long PerProcessUserTimeLimit;
            internal long PerJobUserTimeLimit;
            internal uint LimitFlags;
            internal UIntPtr MinimumWorkingSetSize;
            internal UIntPtr MaximumWorkingSetSize;
            internal uint ActiveProcessLimit;
            internal UIntPtr Affinity;
            internal uint PriorityClass;
            internal uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct IO_COUNTERS
        {
            internal ulong ReadOperationCount;
            internal ulong WriteOperationCount;
            internal ulong OtherOperationCount;
            internal ulong ReadTransferCount;
            internal ulong WriteTransferCount;
            internal ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            internal JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            internal IO_COUNTERS IoInfo;
            internal UIntPtr ProcessMemoryLimit;
            internal UIntPtr JobMemoryLimit;
            internal UIntPtr PeakProcessMemoryUsed;
            internal UIntPtr PeakJobMemoryUsed;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
        {
            internal ulong TotalUserTime;
            internal ulong TotalKernelTime;
            internal ulong ThisPeriodTotalUserTime;
            internal ulong ThisPeriodTotalKernelTime;
            internal uint TotalPageFaultCount;
            internal uint TotalProcesses;
            internal uint ActiveProcesses;
            internal uint TotalTerminatedProcesses;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct WIN32_FIND_DATA
        {
            internal FileAttributes dwFileAttributes;
            internal System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime;
            internal System.Runtime.InteropServices.ComTypes.FILETIME ftLastAccessTime;
            internal System.Runtime.InteropServices.ComTypes.FILETIME ftLastWriteTime;
            internal uint nFileSizeHigh;
            internal uint nFileSizeLow;
            internal uint dwReserved0;
            internal uint dwReserved1;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] internal string cFileName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] internal string cAlternateFileName;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct WIN32_FILE_ATTRIBUTE_DATA
        {
            internal FileAttributes dwFileAttributes;
            internal System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime;
            internal System.Runtime.InteropServices.ComTypes.FILETIME ftLastAccessTime;
            internal System.Runtime.InteropServices.ComTypes.FILETIME ftLastWriteTime;
            internal uint nFileSizeHigh;
            internal uint nFileSizeLow;
        }

        [DllImport("wintrust.dll", ExactSpelling = true, SetLastError = true, CharSet = CharSet.Unicode)]
        internal static extern int WinVerifyTrust(IntPtr hwnd, [In] ref Guid actionId, [In] ref WINTRUST_DATA data);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern IntPtr CreateJobObject(IntPtr securityAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetInformationJobObject(IntPtr job, int informationClass, IntPtr information, uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool QueryInformationJobObject(IntPtr job, int informationClass,
            IntPtr information, uint informationLength, out uint returnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CreateProcess(string applicationName, StringBuilder commandLine, IntPtr processAttributes,
            IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint creationFlags, IntPtr environment,
            string currentDirectory, ref STARTUPINFO startupInfo, out PROCESS_INFORMATION processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern uint ResumeThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

        [DllImport("kernel32.dll")]
        internal static extern uint SetErrorMode(uint mode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool DuplicateHandle(IntPtr sourceProcessHandle,
            IntPtr sourceHandle, IntPtr targetProcessHandle, out IntPtr targetHandle,
            uint desiredAccess, [MarshalAs(UnmanagedType.Bool)] bool inheritHandle,
            uint options);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern IntPtr OpenProcess(uint desiredAccess,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandle, uint processId);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool QueryFullProcessImageName(IntPtr processHandle, uint flags,
            StringBuilder executablePath, ref uint size);

        [DllImport("kernel32.dll")]
        internal static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool IsWow64Process2(IntPtr process, out ushort processMachine,
            out ushort nativeMachine);

        [DllImport("kernel32.dll")]
        internal static extern void GetNativeSystemInfo(out SYSTEM_INFO systemInfo);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetTokenInformation(IntPtr tokenHandle, int tokenInformationClass,
            out TOKEN_ELEVATION tokenInformation, uint tokenInformationLength, out uint returnLength);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        internal static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern IntPtr FindFirstFile(string fileName, out WIN32_FIND_DATA findFileData);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CreateDirectory(string pathName, IntPtr securityAttributes);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern uint GetFileAttributes(string name);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetFileAttributesEx(string name, int infoLevel,
            out WIN32_FILE_ATTRIBUTE_DATA fileData);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetVolumeInformation(string rootPathName,
            StringBuilder volumeNameBuffer, uint volumeNameSize, out uint volumeSerialNumber,
            out uint maximumComponentLength, out uint fileSystemFlags,
            StringBuilder fileSystemNameBuffer, uint fileSystemNameSize);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern IntPtr CreateFile(string fileName, uint desiredAccess, uint shareMode,
            IntPtr securityAttributes, uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetFileTime(SafeFileHandle file, IntPtr creationTime,
            IntPtr lastAccessTime, ref System.Runtime.InteropServices.ComTypes.FILETIME lastWriteTime);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CopyFile(string existingFileName, string newFileName,
            [MarshalAs(UnmanagedType.Bool)] bool failIfExists);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool MoveFile(string existingFileName, string newFileName);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool FindNextFile(IntPtr findFile, out WIN32_FIND_DATA findFileData);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool FindClose(IntPtr findFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool DeleteFile(string fileName);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool RemoveDirectory(string pathName);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetFileAttributes(string fileName, FileAttributes fileAttributes);
    }
}

namespace CodexPortable
{
    internal static class ProviderConfiguration
    {
        internal const string ProviderId = "portable_custom";
        internal const string ApiKeyEnvironmentVariable = "CODEX_PORTABLE_API_KEY";
        internal const string DefaultApprovalPolicy = "never";
        internal const string DefaultSandboxMode = "danger-full-access";
        internal const string DefaultReasoningEffort = "max";
        internal const string DefaultModel = "gpt-5.6-terra";
        internal const string DefaultFollowUpQueueMode = "steer";
        internal const string DefaultDeveloperInstructions =
            "Codex Portable 默认规则：\n" +
            "1. 不编写任何 checkpoint 或 hash 相关代码，避免流程扩大或复杂化。\n" +
            "2. 不保留兼容性代码或历史性代码，直接实现当前目标。\n" +
            "3. 所需工具统一安装并使用，不因工具未安装而绕过流程或引入额外复杂步骤。";
        internal static string ApprovalPolicyConfigLine { get { return "approval_policy = " + QuoteToml(DefaultApprovalPolicy); } }
        internal static string SandboxModeConfigLine { get { return "sandbox_mode = " + QuoteToml(DefaultSandboxMode); } }
        internal static string ReasoningEffortConfigLine { get { return "model_reasoning_effort = " + QuoteToml(DefaultReasoningEffort); } }
        internal static string DeveloperInstructionsConfigLine { get { return "developer_instructions = " + QuoteToml(DefaultDeveloperInstructions); } }
        private const string UnconfiguredBaseUrl = "https://invalid.invalid/v1";
        private const string SecretExcludes = "[\"OPENAI_API_KEY\", \"CODEX_API_KEY\", \"CODEX_PORTABLE_API_KEY\", \"OPENAI_BASE_URL\", \"CODEX_APP_SERVER_OPENAI_BASE_URL\", \"ANTHROPIC_API_KEY\", \"AZURE_OPENAI_API_KEY\", \"AWS_ACCESS_KEY_ID\", \"AWS_SECRET_ACCESS_KEY\", \"AWS_SESSION_TOKEN\", \"GITHUB_TOKEN\", \"GH_TOKEN\"]";
        private static readonly string[] X64BundledPluginNames = new string[] {
            "sites", "browser", "chrome", "computer-use", "latex", "deep-research", "visualize"
        };
        private static readonly string[] Arm64BundledPluginNames = new string[] {
            "sites", "browser", "chrome", "computer-use", "deep-research", "visualize"
        };
        private static readonly string[] PrimaryRuntimePluginNames = new string[] {
            "documents", "pdf", "presentations", "spreadsheets", "template-creator"
        };
        private static readonly string[] NoRequiredPlugins = new string[0];
        private static readonly string[] X64RequiredPlugins = BuildRequiredPlugins(X64BundledPluginNames);
        private static readonly string[] Arm64RequiredPlugins = BuildRequiredPlugins(Arm64BundledPluginNames);

        private static string[] BuildRequiredPlugins(string[] bundledPluginNames)
        {
            string[] result = new string[bundledPluginNames.Length + PrimaryRuntimePluginNames.Length];
            int index = 0;
            for (int i = 0; i < bundledPluginNames.Length; i++)
                result[index++] = bundledPluginNames[i] + "@openai-bundled";
            for (int i = 0; i < PrimaryRuntimePluginNames.Length; i++)
                result[index++] = PrimaryRuntimePluginNames[i] + "@openai-primary-runtime";
            return result;
        }

        private static string[] SelectRequiredPlugins(PortableArchitecture architecture)
        {
            switch (architecture)
            {
                case PortableArchitecture.X64: return X64RequiredPlugins;
                case PortableArchitecture.Arm64: return Arm64RequiredPlugins;
                default: return NoRequiredPlugins;
            }
        }

        private static string[] SelectRequiredBundledPluginNames(PortableArchitecture architecture)
        {
            switch (architecture)
            {
                case PortableArchitecture.X64: return X64BundledPluginNames;
                case PortableArchitecture.Arm64: return Arm64BundledPluginNames;
                default:
                    throw new InvalidDataException("No official bundled-plugin contract exists for architecture: " +
                        ArchitectureInfo.NameOf(architecture));
            }
        }

        internal static string[] GetRequiredPlugins(PortableArchitecture architecture)
        {
            return (string[])SelectRequiredPlugins(architecture).Clone();
        }

        internal static string[] GetRequiredBundledPluginNames(PortableArchitecture architecture)
        {
            return (string[])SelectRequiredBundledPluginNames(architecture).Clone();
        }

        internal static bool TryNormalizeBaseUrl(string input, out string normalized)
        {
            normalized = null;
            string value = (input ?? "").Trim();
            if (value.Length == 0 || value.Length > 2048) return false;
            if (value.IndexOf('\r') >= 0 || value.IndexOf('\n') >= 0 || value.IndexOf('\0') >= 0) return false;
            Uri uri;
            if (!Uri.TryCreate(value, UriKind.Absolute, out uri)) return false;
            bool https = string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase);
            bool loopbackHttp = string.Equals(uri.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) && uri.IsLoopback;
            if (!https && !loopbackHttp) return false;
            if (string.IsNullOrEmpty(uri.Host) || !string.IsNullOrEmpty(uri.UserInfo) ||
                !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment)) return false;
            normalized = uri.AbsoluteUri.TrimEnd('/');
            return normalized.Length > 0;
        }

        internal static bool IsValidModel(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length > 200) return false;
            for (int i = 0; i < value.Length; i++) if (char.IsWhiteSpace(value[i]) || char.IsControl(value[i])) return false;
            return true;
        }

        internal static bool IsValidApiKey(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length > 1024) return false;
            for (int i = 0; i < value.Length; i++) if (char.IsWhiteSpace(value[i]) || char.IsControl(value[i])) return false;
            return true;
        }

        // These two settings are Codex's permission contract.  The launcher
        // supplies defaults only when config.toml has no valid root-level
        // value; once a user or Codex writes a valid value, it remains the
        // source of truth across portable starts and API saves.
        internal static bool IsValidApprovalPolicy(string value)
        {
            return string.Equals(value, "untrusted", StringComparison.Ordinal) ||
                string.Equals(value, "on-request", StringComparison.Ordinal) ||
                string.Equals(value, "never", StringComparison.Ordinal);
        }

        internal static bool IsValidSandboxMode(string value)
        {
            return string.Equals(value, "read-only", StringComparison.Ordinal) ||
                string.Equals(value, "workspace-write", StringComparison.Ordinal) ||
                string.Equals(value, "danger-full-access", StringComparison.Ordinal);
        }

        internal static bool IsValidFollowUpQueueMode(string value)
        {
            return string.Equals(value, "queue", StringComparison.Ordinal) ||
                string.Equals(value, "steer", StringComparison.Ordinal) ||
                string.Equals(value, "interrupt", StringComparison.Ordinal);
        }

        // Read only the root table.  A permission key under a project/profile
        // table is a different TOML setting and must not silently become the
        // portable default.
        internal static bool TryReadPermissionSettings(string config,
            out string approvalPolicy, out string sandboxMode)
        {
            approvalPolicy = null;
            sandboxMode = null;
            if (string.IsNullOrEmpty(config)) return false;
            bool root = true;
            bool approvalSeen = false;
            bool sandboxSeen = false;
            bool valid = true;
            using (StringReader reader = new StringReader(config))
            {
                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    string trimmed = line.Trim();
                    if (trimmed.Length == 0 || trimmed[0] == '#') continue;
                    if (trimmed[0] == '[')
                    {
                        root = false;
                        continue;
                    }
                    if (!root) continue;
                    int equals = trimmed.IndexOf('=');
                    if (equals <= 0) continue;
                    string key = trimmed.Substring(0, equals).Trim();
                    if (!string.Equals(key, "approval_policy", StringComparison.Ordinal) &&
                        !string.Equals(key, "sandbox_mode", StringComparison.Ordinal)) continue;
                    string value;
                    if (!TryParseTomlString(trimmed.Substring(equals + 1).Trim(), out value))
                    {
                        valid = false;
                        continue;
                    }
                    if (string.Equals(key, "approval_policy", StringComparison.Ordinal))
                    {
                        if (approvalSeen || !IsValidApprovalPolicy(value))
                        {
                            valid = false;
                            continue;
                        }
                        approvalSeen = true;
                        approvalPolicy = value;
                    }
                    else
                    {
                        if (sandboxSeen || !IsValidSandboxMode(value))
                        {
                            valid = false;
                            continue;
                        }
                        sandboxSeen = true;
                        sandboxMode = value;
                    }
                }
            }
            return valid && approvalSeen && sandboxSeen;
        }

        // This setting is deliberately read from the exact desktop table. A
        // same-named key in another TOML table must not change the portable
        // user's follow-up behavior.
        internal static bool TryReadFollowUpQueueMode(string config, out string mode)
        {
            mode = null;
            if (string.IsNullOrEmpty(config)) return false;
            bool desktop = false;
            bool seen = false;
            bool valid = true;
            using (StringReader reader = new StringReader(config))
            {
                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    string trimmed = line.Trim();
                    if (trimmed.Length == 0 || trimmed[0] == '#') continue;
                    if (trimmed[0] == '[')
                    {
                        desktop = string.Equals(trimmed, "[desktop]", StringComparison.Ordinal);
                        continue;
                    }
                    if (!desktop) continue;
                    int equals = trimmed.IndexOf('=');
                    if (equals <= 0) continue;
                    string key = trimmed.Substring(0, equals).Trim();
                    if (!string.Equals(key, "followUpQueueMode", StringComparison.Ordinal)) continue;
                    string value;
                    if (!TryParseTomlString(trimmed.Substring(equals + 1).Trim(), out value) ||
                        seen || !IsValidFollowUpQueueMode(value))
                    {
                        valid = false;
                        continue;
                    }
                    seen = true;
                    mode = value;
                }
            }
            return valid && seen;
        }

        internal static bool SelfTestPermissionConfiguration()
        {
            string approval;
            string sandbox;
            string custom = "# user controlled\r\napproval_policy = \"on-request\" # keep\r\nsandbox_mode = 'workspace-write'\r\n[analytics]\r\nenabled = false\r\n";
            if (!TryReadPermissionSettings(custom, out approval, out sandbox) ||
                !string.Equals(approval, "on-request", StringComparison.Ordinal) ||
                !string.Equals(sandbox, "workspace-write", StringComparison.Ordinal)) return false;
            string nested = "[profile]\r\napproval_policy = \"never\"\r\nsandbox_mode = \"read-only\"\r\n";
            return !TryReadPermissionSettings(nested, out approval, out sandbox);
        }

        internal static bool SelfTestFollowUpQueueModeConfiguration()
        {
            string mode;
            string valid = "[desktop]\r\nfollowUpQueueMode = \"interrupt\"\r\n";
            if (!TryReadFollowUpQueueMode(valid, out mode) ||
                !string.Equals(mode, "interrupt", StringComparison.Ordinal)) return false;
            string duplicate = "[desktop]\r\nfollowUpQueueMode = \"steer\"\r\n" +
                "followUpQueueMode = \"queue\"\r\n";
            return !TryReadFollowUpQueueMode(duplicate, out mode);
        }

        internal static void Save(PortableLayout layout, string baseUrl, string model, string apiKey)
        {
            string normalized;
            model = (model ?? "").Trim();
            apiKey = (apiKey ?? "").Trim();
            if (!TryNormalizeBaseUrl(baseUrl, out normalized)) throw new InvalidDataException("Invalid custom API base URL.");
            if (!IsValidModel(model)) throw new InvalidDataException("Invalid custom API model.");
            if (!IsValidApiKey(apiKey)) throw new InvalidDataException("Invalid custom API key.");
            layout.EnsureDirectories();
            IOUtil.AtomicWriteText(layout.BaseUrlFile, normalized + "\r\n");
            IOUtil.AtomicWriteText(layout.ModelFile, model + "\r\n");
            IOUtil.AtomicWriteSensitiveText(layout.PlainKeyFile, apiKey + "\r\n");
            CleanupLegacyAuthentication(layout);
            WriteDeterministicConfig(layout);
        }

        internal static string ReadEffectiveBaseUrl(PortableLayout layout)
        {
            try
            {
                if (!File.Exists(layout.BaseUrlFile)) return null;
                string normalized;
                return TryNormalizeBaseUrl(File.ReadAllText(layout.BaseUrlFile, Encoding.UTF8).Trim(), out normalized) ? normalized : null;
            }
            catch { return null; }
        }

        internal static string ReadEffectiveModel(PortableLayout layout)
        {
            try
            {
                if (!File.Exists(layout.ModelFile)) return DefaultModel;
                string value = File.ReadAllText(layout.ModelFile, Encoding.UTF8).Trim();
                return IsValidModel(value) ? value : DefaultModel;
            }
            catch { return DefaultModel; }
        }

        internal static string ReadStoredApiKey(PortableLayout layout)
        {
            try
            {
                if (!File.Exists(layout.PlainKeyFile)) return null;
                string value = File.ReadAllText(layout.PlainKeyFile, Encoding.UTF8).Trim();
                return IsValidApiKey(value) ? value : null;
            }
            catch { return null; }
        }

        internal static bool TryReadRequiredConfiguration(PortableLayout layout, out string baseUrl, out string apiKey, out string model)
        {
            baseUrl = ReadEffectiveBaseUrl(layout);
            model = ReadEffectiveModel(layout);
            apiKey = ReadStoredApiKey(layout);
            return baseUrl != null && model != null && apiKey != null;
        }

        internal static bool HasCompleteApiConfiguration(PortableLayout layout)
        {
            string baseUrl;
            string apiKey;
            string model;
            bool complete = TryReadRequiredConfiguration(layout, out baseUrl, out apiKey, out model);
            apiKey = null;
            return complete;
        }

        internal static void CleanupLegacyAuthentication(PortableLayout layout)
        {
            IOUtil.DeleteFileIfExists(layout.AuthFile);
            IOUtil.DeleteFileIfExists(layout.EphemeralMarker);
            IOUtil.DeleteFileIfExists(layout.AuthBackup);
            IOUtil.DeleteFileIfExists(Path.Combine(layout.DataRoot, "data", "config", "openai-base-url.txt"));
            if (File.Exists(layout.PlainKeyFile)) IOUtil.DeleteFileIfExists(layout.VaultFile);
        }

        internal static void WriteDeterministicConfig(PortableLayout layout)
        {
            Directory.CreateDirectory(layout.CodexHome);
            string baseUrl = ReadEffectiveBaseUrl(layout) ?? UnconfiguredBaseUrl;
            string model = ReadEffectiveModel(layout);
            string approvalPolicy = DefaultApprovalPolicy;
            string sandboxMode = DefaultSandboxMode;
            string followUpQueueMode = DefaultFollowUpQueueMode;
            try
            {
                if (File.Exists(layout.ConfigFile))
                {
                    string existingConfig = File.ReadAllText(layout.ConfigFile, Encoding.UTF8);
                    string existingApprovalPolicy;
                    string existingSandboxMode;
                    // Preserve each valid permission independently so a
                    // partially written config cannot erase the other edit.
                    TryReadPermissionSettings(existingConfig, out existingApprovalPolicy,
                        out existingSandboxMode);
                    if (existingApprovalPolicy != null) approvalPolicy = existingApprovalPolicy;
                    if (existingSandboxMode != null) sandboxMode = existingSandboxMode;
                    string existingFollowUpQueueMode;
                    if (TryReadFollowUpQueueMode(existingConfig, out existingFollowUpQueueMode))
                        followUpQueueMode = existingFollowUpQueueMode;
                }
            }
            catch { }
            string[] requiredPlugins = GetRequiredPlugins(layout.Architecture);
            string bundledMarketplace = Path.Combine(layout.Resources, "plugins", "openai-bundled");
            string primaryMarketplace = Path.Combine(layout.CodexHome, "offline-marketplaces", "openai-primary-runtime");
            StringBuilder text = new StringBuilder();
            text.AppendLine("# Managed by LF Portable. approval_policy and sandbox_mode remain config.toml settings.");
            text.AppendLine("model = " + QuoteToml(model));
            text.AppendLine("model_provider = " + QuoteToml(ProviderId));
            text.AppendLine(DeveloperInstructionsConfigLine);
            text.AppendLine(ReasoningEffortConfigLine);
            text.AppendLine("chatgpt_base_url = \"http://127.0.0.1:9\"");
            text.AppendLine("approval_policy = " + QuoteToml(approvalPolicy));
            text.AppendLine("sandbox_mode = " + QuoteToml(sandboxMode));
            text.AppendLine("check_for_update_on_startup = false");
            text.AppendLine("cli_auth_credentials_store = \"file\"");
            text.AppendLine();
            text.AppendLine("[desktop]");
            text.AppendLine("followUpQueueMode = " + QuoteToml(followUpQueueMode));
            text.AppendLine();
            text.AppendLine("[analytics]");
            text.AppendLine("enabled = false");
            text.AppendLine();
            text.AppendLine("[shell_environment_policy]");
            text.AppendLine("inherit = \"all\"");
            text.AppendLine("ignore_default_excludes = false");
            text.AppendLine("exclude = " + SecretExcludes);
            text.AppendLine("experimental_use_profile = false");
            text.AppendLine();
            text.AppendLine("[model_providers." + ProviderId + "]");
            text.AppendLine("name = \"Portable Custom Responses API\"");
            text.AppendLine("base_url = " + QuoteToml(baseUrl));
            text.AppendLine("env_key = " + QuoteToml(ApiKeyEnvironmentVariable));
            text.AppendLine("wire_api = \"responses\"");
            text.AppendLine("requires_openai_auth = false");
            text.AppendLine();
            text.AppendLine("[features]");
            text.AppendLine("plugins = true");
            text.AppendLine("remote_plugin = false");
            text.AppendLine("in_app_updates = false");
            text.AppendLine();
            text.AppendLine("[marketplaces.openai-bundled]");
            text.AppendLine("source_type = \"local\"");
            text.AppendLine("source = " + QuoteToml(bundledMarketplace));
            text.AppendLine();
            text.AppendLine("[marketplaces.openai-primary-runtime]");
            text.AppendLine("source_type = \"local\"");
            text.AppendLine("source = " + QuoteToml(primaryMarketplace));
            for (int i = 0; i < requiredPlugins.Length; i++)
            {
                text.AppendLine();
                text.AppendLine("[plugins." + QuoteToml(requiredPlugins[i]) + "]");
                text.AppendLine("enabled = true");
            }
            WriteConfigIfChanged(layout.ConfigFile, text.ToString());
        }

        internal static int CountConfiguredPlugins(string config, PortableArchitecture architecture)
        {
            string[] requiredPlugins = GetRequiredPlugins(architecture);
            int count = 0;
            for (int i = 0; i < requiredPlugins.Length; i++)
                if (config.IndexOf("[plugins.\"" + requiredPlugins[i] + "\"]", StringComparison.OrdinalIgnoreCase) >= 0) count++;
            return count;
        }

        internal static int RequiredPluginCount(PortableArchitecture architecture)
        {
            return GetRequiredPlugins(architecture).Length;
        }

        internal static int EnsureRequiredPluginCache(PortableLayout layout)
        {
            if (!ArchitectureInfo.HasOfficialDesktopPayload(layout.Architecture))
                throw new InvalidDataException("No official plugin cache can be repaired for architecture: " +
                    ArchitectureInfo.NameOf(layout.Architecture));
            return PluginCacheRecovery.EnsureRequiredPlugins(layout,
                GetRequiredPlugins(layout.Architecture));
        }

        internal static bool RequiredPluginCacheComplete(PortableLayout layout)
        {
            if (!ArchitectureInfo.HasOfficialDesktopPayload(layout.Architecture)) return false;
            return PluginCacheRecovery.RequiredPluginCacheComplete(layout,
                GetRequiredPlugins(layout.Architecture));
        }

        private static string EscapeToml(string value)
        {
            return value.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n");
        }

        private static string QuoteToml(string value)
        {
            return "\"" + EscapeToml(value) + "\"";
        }

        private static bool TryParseTomlString(string value, out string parsed)
        {
            parsed = null;
            if (string.IsNullOrEmpty(value) || value.Length < 2) return false;
            char quote = value[0];
            if (quote != '\"' && quote != '\'') return false;
            StringBuilder result = new StringBuilder();
            for (int i = 1; i < value.Length; i++)
            {
                char c = value[i];
                if (quote == '\"' && c == '\\')
                {
                    if (i + 1 >= value.Length) return false;
                    char escaped = value[++i];
                    switch (escaped)
                    {
                        case '\\': result.Append('\\'); break;
                        case '\"': result.Append('\"'); break;
                        case 'b': result.Append('\b'); break;
                        case 'f': result.Append('\f'); break;
                        case 'n': result.Append('\n'); break;
                        case 'r': result.Append('\r'); break;
                        case 't': result.Append('\t'); break;
                        default: return false;
                    }
                    continue;
                }
                if (c == quote)
                {
                    string suffix = value.Substring(i + 1).Trim();
                    if (suffix.Length != 0 && suffix[0] != '#') return false;
                    parsed = result.ToString();
                    return true;
                }
                if (c == '\r' || c == '\n' || c == '\0') return false;
                result.Append(c);
            }
            return false;
        }

        private static void WriteConfigIfChanged(string file, string value)
        {
            if (File.Exists(file) && string.Equals(File.ReadAllText(file, Encoding.UTF8), value, StringComparison.Ordinal)) return;
            IOUtil.AtomicWriteText(file, value);
        }
    }

    internal sealed class PortableExecutionLayout
    {
        internal string Root;
        internal string FamilyRoot;
        internal string AppRoot;
        internal string OfficialAppExe;
        internal string AppExe;
        internal string Resources;
        internal string CodexExe;
        internal string Runtime;
        internal string Tools;
    }

    internal static class HostExecutionImage
    {
        private const long MaximumExecutionBytes = 8L * 1024L * 1024L * 1024L;
        private const int MaximumExecutionFiles = 200000;
        private const long FreeSpaceReserveBytes = 1024L * 1024L * 1024L;

        internal static bool TryGetReady(PortableLayout layout,
            out PortableExecutionLayout execution)
        {
            execution = null;
            try
            {
                string family = GetFamilyRoot(layout);
                return TryGetReady(layout, family, out execution);
            }
            catch { return false; }
        }

        private static bool TryGetReady(PortableLayout layout, string family,
            out PortableExecutionLayout execution)
        {
            execution = null;
            try
            {
                string root = GetVersionRoot(layout, family);
                if (!EnsureSafeExecutionFamily(layout, family, false) ||
                    !AssertSafeCacheEntry(root, family, false) ||
                    HasPendingInvalidation(family, root)) return false;
                PortableExecutionLayout candidate = BuildLayout(root);
                if (!Validate(candidate, layout.Architecture)) return false;
                int elevationError;
                TokenElevationState elevation = WindowsTokenElevation.Query(out elevationError);
                if (elevation == TokenElevationState.Unavailable || elevationError != 0) return false;
                // The local cache is intentionally rebuilt for an elevated
                // launch. Comparing it with the mutable expanded USB tree would
                // reintroduce the very source-of-truth ambiguity this image is
                // designed to remove; the rebuild below verifies both archives
                // and their MSIX signature while holding read leases.
                if (elevation == TokenElevationState.Elevated) return false;
                execution = candidate;
                return true;
            }
            catch { return false; }
        }

        internal static PortableExecutionLayout EnsureReady(PortableLayout layout,
            bool forceRebuild, Action<FirstLaunchProgress> progress)
        {
            string family = GetFamilyRoot(layout);
            PortableExecutionLayout ready;
            if (!forceRebuild && TryGetReady(layout, family, out ready))
            {
                if (progress != null)
                {
                    progress(new FirstLaunchProgress(FirstLaunchPreparationStage.ValidatingHostExecutionImage));
                    progress(new FirstLaunchProgress(FirstLaunchPreparationStage.HostExecutionImageReady));
                }
                return ready;
            }

            Mutex mutation = PortableProcess.AcquireMutationMutex(layout, 0);
            if (mutation == null)
                throw new IOException("Another portable installation or execution-image repair is in progress.");
            Mutex local = null;
            bool localAcquired = false;
            string staging = null;
            try
            {
                local = new Mutex(false, GetPreparationMutexNameForFamily(family));
                try { localAcquired = local.WaitOne(0, false); }
                catch (AbandonedMutexException) { localAcquired = true; }
                if (!localAcquired)
                    throw new IOException("The local execution image is already being prepared.");
                if (forceRebuild) WaitForDesktopExit(layout, 10000);
                if (PortableProcess.IsDesktopRunning(layout))
                    throw new IOException("The local execution image cannot be replaced while Codex Desktop is running.");
                string destination = GetVersionRoot(layout, family);
                EnsureSafeExecutionFamily(layout, family, true);
                AssertSafeCacheEntry(destination, family, true);
                RecoverInterruptedReplacement(layout, family, destination);
                if (!forceRebuild && TryGetReady(layout, family, out ready)) return ready;

                if (progress != null)
                    progress(new FirstLaunchProgress(FirstLaunchPreparationStage.ValidatingHostExecutionImage));
                using (AppUpdater.ExecutionImagePackageLease packages =
                    AppUpdater.VerifyExecutionImagePackages(layout, progress))
                {
                    PortableBundle.ExecutionCommonArchiveInfo common =
                        PortableBundle.InspectExecutionImageArchive(packages.CommonStream);
                    PackageInfo desktop = packages.DesktopInfo;
                    long totalBytes = checked(common.ExpandedBytes + desktop.ExpandedBytes +
                        desktop.ExecutableBytes);
                    int totalFiles = checked(common.FileCount + desktop.FileCount + 1);
                    if (totalBytes <= 0 || totalBytes > MaximumExecutionBytes ||
                        totalFiles <= 0 || totalFiles > MaximumExecutionFiles)
                        throw new InvalidDataException("The local execution-image archive plan exceeds its limits.");
                    string localRoot = Path.GetPathRoot(family);
                    DriveInfo drive = new DriveInfo(localRoot);
                    if (drive.IsReady && drive.AvailableFreeSpace < totalBytes + FreeSpaceReserveBytes)
                        throw new IOException("Insufficient local free space for the Codex execution image.");

                    staging = Path.Combine(family, ".stage-" +
                        Guid.NewGuid().ToString("N").Substring(0, 10));
                    AssertSafeCacheEntry(staging, family, true);
                    Directory.CreateDirectory(staging);
                    if (progress != null)
                        progress(new FirstLaunchProgress(FirstLaunchPreparationStage.CopyingHostExecutionImage,
                            0, totalBytes, 0, totalFiles));

                    PortableBundle.ExtractExecutionImageArchive(packages.CommonStream,
                        staging, common,
                        delegate(long completedBytes, long ignoredTotalBytes,
                            int completedFiles, int ignoredTotalFiles)
                        {
                            if (progress != null) progress(new FirstLaunchProgress(
                                FirstLaunchPreparationStage.CopyingHostExecutionImage,
                                completedBytes, totalBytes, completedFiles, totalFiles));
                        });

                    string desktopStaging = Path.Combine(staging, ".desktop-package");
                    Directory.CreateDirectory(desktopStaging);
                    string payload;
                    AppUpdater.ExtractPreparedDesktopPayload(packages.DesktopPackage,
                        packages.DesktopStream, desktopStaging, layout.Architecture, desktop,
                        delegate(long completedBytes, long ignoredTotalBytes,
                            int completedFiles, int ignoredTotalFiles)
                        {
                            if (progress != null) progress(new FirstLaunchProgress(
                                FirstLaunchPreparationStage.CopyingHostExecutionImage,
                                common.ExpandedBytes + completedBytes, totalBytes,
                                common.FileCount + completedFiles, totalFiles));
                        }, null, out payload);
                    string appParent = Path.Combine(staging, "app");
                    string appDestination = Path.Combine(appParent, "current");
                    Directory.CreateDirectory(appParent);
                    Directory.Move(payload, appDestination);
                    if (Directory.Exists(desktopStaging))
                        IOUtil.DeleteDirectoryWithin(desktopStaging, staging);
                    if (Directory.Exists(Path.Combine(staging, "data")))
                        throw new InvalidDataException("The local execution image contains portable profile data.");
                    if (progress != null)
                        progress(new FirstLaunchProgress(FirstLaunchPreparationStage.CopyingHostExecutionImage,
                            totalBytes, totalBytes, totalFiles, totalFiles));
                }
                // A user might start an existing local image while a long package
                // extraction is underway. Never activate a replacement after that
                // point, even if the first check preceded the extraction.
                if (PortableProcess.IsDesktopRunning(layout))
                    throw new IOException("Codex Desktop started while the local execution image was being prepared.");
                PortableExecutionLayout staged = BuildLayout(staging);
                if (!Validate(staged, layout.Architecture))
                    throw new InvalidDataException("The staged local execution image is incomplete.");

                string backup = null;
                bool stagingActivated = false;
                try
                {
                    if (Directory.Exists(destination))
                    {
                        backup = Path.Combine(family, ".backup-" + Path.GetFileName(destination) + "-" +
                            Guid.NewGuid().ToString("N").Substring(0, 10));
                        AssertSafeCacheEntry(backup, family, true);
                        Directory.Move(destination, backup);
                    }
                    Directory.Move(staging, destination);
                    staging = null;
                    stagingActivated = true;
                    ready = BuildLayout(destination);
                    if (!Validate(ready, layout.Architecture))
                        throw new InvalidDataException("The activated local execution image is incomplete.");
                    if (!string.IsNullOrEmpty(backup) && Directory.Exists(backup))
                    {
                        try { IOUtil.DeleteDirectoryWithin(backup, family); }
                        catch (Exception cleanupError)
                        {
                            SafeLog.TryWrite(layout, "execution-image-cleanup", cleanupError);
                        }
                    }
                }
                catch
                {
                    try
                    {
                        if (stagingActivated && Directory.Exists(destination))
                            IOUtil.DeleteDirectoryWithin(destination, family);
                        if (!string.IsNullOrEmpty(backup) && Directory.Exists(backup) &&
                            !Directory.Exists(destination)) Directory.Move(backup, destination);
                    }
                    catch (Exception rollbackError)
                    {
                        SafeLog.TryWrite(layout, "execution-image-rollback", rollbackError);
                    }
                    throw;
                }
                try { CleanupObsoleteImages(family, destination); }
                catch (Exception cleanupError)
                {
                    SafeLog.TryWrite(layout, "execution-image-cleanup", cleanupError);
                }
                if (progress != null)
                    progress(new FirstLaunchProgress(FirstLaunchPreparationStage.HostExecutionImageReady));
                return ready;
            }
            finally
            {
                if (staging != null && Directory.Exists(staging))
                {
                    try
                    {
                        AssertSafeCacheEntry(staging, family, false);
                        IOUtil.DeleteDirectoryWithin(staging, family);
                    }
                    catch (Exception cleanupError) { SafeLog.TryWrite(layout, "execution-image-cleanup", cleanupError); }
                }
                if (localAcquired)
                {
                    try { local.ReleaseMutex(); } catch { }
                }
                if (local != null) local.Dispose();
                PortableProcess.ReleaseMutationMutex(mutation);
            }
        }

        private static void WaitForDesktopExit(PortableLayout layout, int timeoutMilliseconds)
        {
            Stopwatch deadline = Stopwatch.StartNew();
            while (PortableProcess.IsDesktopRunning(layout) &&
                deadline.ElapsedMilliseconds < timeoutMilliseconds)
                Thread.Sleep(50);
        }

        private static void RecoverInterruptedReplacement(PortableLayout layout,
            string family, string destination)
        {
            string destinationName = Path.GetFileName(destination);
            string[] backups = Directory.GetDirectories(family,
                ".backup-" + destinationName + "-*", SearchOption.TopDirectoryOnly);
            for (int i = 0; i < backups.Length; i++)
                AssertSafeCacheEntry(backups[i], family, false);
            string[] invalid = Directory.GetDirectories(family,
                ".invalid-" + destinationName + "-*", SearchOption.TopDirectoryOnly);
            for (int i = 0; i < invalid.Length; i++)
                AssertSafeCacheEntry(invalid[i], family, false);
            AssertSafeCacheEntry(destination, family, true);
            // An invalid sibling is a durable quarantine reservation made by the
            // detached local watcher. Remove the known-bad name immediately and
            // force a fresh verified build; never clear the reservation merely
            // because the bad tree remains structurally complete.
            if (invalid.Length != 0)
            {
                if (Directory.Exists(destination))
                {
                    string quarantine = Path.Combine(family, ".invalid-" + destinationName + "-" +
                        Guid.NewGuid().ToString("N").Substring(0, 10) + "-recovery");
                    if (!EnsureSafeExecutionFamily(layout, family, false))
                        throw new IOException("The invalid execution-image family is unavailable for recovery.");
                    AssertSafeCacheEntry(destination, family, false);
                    AssertSafeCacheEntry(quarantine, family, true);
                    Directory.Move(destination, quarantine);
                }
                return;
            }
            bool destinationValid = Directory.Exists(destination) &&
                Validate(BuildLayout(destination), layout.Architecture);
            if (!destinationValid)
            {
                string replacement = null;
                for (int i = 0; i < backups.Length; i++)
                {
                    PortableExecutionLayout candidate = BuildLayout(backups[i]);
                    if (Validate(candidate, layout.Architecture))
                    {
                        replacement = backups[i];
                        break;
                    }
                }
                if (!string.IsNullOrEmpty(replacement))
                {
                    string displaced = null;
                    if (Directory.Exists(destination))
                    {
                        displaced = Path.Combine(family, ".invalid-" + destinationName + "-" +
                            Guid.NewGuid().ToString("N").Substring(0, 10));
                        AssertSafeCacheEntry(displaced, family, true);
                        Directory.Move(destination, displaced);
                    }
                    try
                    {
                        Directory.Move(replacement, destination);
                        destinationValid = true;
                    }
                    catch
                    {
                        if (!Directory.Exists(destination) && !string.IsNullOrEmpty(displaced) &&
                            Directory.Exists(displaced)) Directory.Move(displaced, destination);
                        throw;
                    }
                    if (!string.IsNullOrEmpty(displaced) && Directory.Exists(displaced))
                    {
                        try { IOUtil.DeleteDirectoryWithin(displaced, family); }
                        catch (Exception cleanupError)
                        {
                            SafeLog.TryWrite(layout, "execution-image-cleanup", cleanupError);
                        }
                    }
                }
            }
            if (destinationValid)
                for (int i = 0; i < backups.Length; i++)
                    if (Directory.Exists(backups[i]))
                    {
                        try { IOUtil.DeleteDirectoryWithin(backups[i], family); }
                        catch (Exception cleanupError)
                        {
                            SafeLog.TryWrite(layout, "execution-image-cleanup", cleanupError);
                        }
                    }
            string[] staging = Directory.GetDirectories(family, ".stage-*",
                SearchOption.TopDirectoryOnly);
            for (int i = 0; i < staging.Length; i++)
            {
                AssertSafeCacheEntry(staging[i], family, false);
                try { IOUtil.DeleteDirectoryWithin(staging[i], family); }
                catch (Exception cleanupError)
                {
                    SafeLog.TryWrite(layout, "execution-image-cleanup", cleanupError);
                }
            }
            if (!destinationValid) return;
            for (int i = 0; i < invalid.Length; i++)
            {
                AssertSafeCacheEntry(invalid[i], family, false);
                try { IOUtil.DeleteDirectoryWithin(invalid[i], family); }
                catch (Exception cleanupError)
                {
                    SafeLog.TryWrite(layout, "execution-image-cleanup", cleanupError);
                }
            }
        }

        private static bool HasPendingInvalidation(string family, string destination)
        {
            if (!Directory.Exists(family)) return false;
            string destinationName = Path.GetFileName(destination);
            string[] invalid = Directory.GetDirectories(family,
                ".invalid-" + destinationName + "-*", SearchOption.TopDirectoryOnly);
            for (int i = 0; i < invalid.Length; i++)
                AssertSafeCacheEntry(invalid[i], family, false);
            return invalid.Length != 0;
        }

        private static void CleanupObsoleteImages(string family, string active)
        {
            string activeFull = Path.GetFullPath(active).TrimEnd('\\');
            string[] directories = Directory.GetDirectories(family, "*",
                SearchOption.TopDirectoryOnly);
            for (int i = 0; i < directories.Length; i++)
            {
                string candidate = Path.GetFullPath(directories[i]).TrimEnd('\\');
                if (string.Equals(candidate, activeFull, StringComparison.OrdinalIgnoreCase)) continue;
                AssertSafeCacheEntry(candidate, family, false);
                IOUtil.DeleteDirectoryWithin(candidate, family);
            }
        }

        internal static bool IsExecutionPathForLayout(PortableLayout layout, string executable)
        {
            try
            {
                if (layout != null && IsExecutionPathForFamily(GetFamilyRoot(layout), executable))
                    return true;
            }
            catch { }
            return IsExecutionPathUnderGlobalCache(executable);
        }

        internal static bool IsExecutionPathForFamily(string family, string executable)
        {
            if (string.IsNullOrEmpty(executable) ||
                !string.Equals(Path.GetFileName(executable), PortableBranding.DesktopExecutableName,
                    StringComparison.OrdinalIgnoreCase)) return false;
            try
            {
                string familyFull;
                string volumeToken;
                string architecture;
                if (!TryNormalizeExecutionFamily(family, out familyFull, out volumeToken,
                    out architecture)) return false;
                string full = Path.GetFullPath(executable).TrimEnd('\\');
                if (!full.StartsWith(familyFull + "\\", StringComparison.OrdinalIgnoreCase)) return false;
                string[] segments = full.Substring(familyFull.Length + 1).Split('\\');
                return segments.Length == 4 &&
                    segments[0].StartsWith("desktop-lf-", StringComparison.OrdinalIgnoreCase) &&
                    string.Equals(segments[1], "app", StringComparison.OrdinalIgnoreCase) &&
                    string.Equals(segments[2], "current", StringComparison.OrdinalIgnoreCase) &&
                    string.Equals(segments[3], PortableBranding.DesktopExecutableName,
                        StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }

        private static bool IsExecutionPathUnderGlobalCache(string executable)
        {
            if (string.IsNullOrEmpty(executable) ||
                !string.Equals(Path.GetFileName(executable), PortableBranding.DesktopExecutableName,
                    StringComparison.OrdinalIgnoreCase)) return false;
            try
            {
                string global = Path.GetFullPath(GetGlobalCacheRoot()).TrimEnd('\\');
                string full = Path.GetFullPath(executable).TrimEnd('\\');
                if (!full.StartsWith(global + "\\", StringComparison.OrdinalIgnoreCase)) return false;
                string[] segments = full.Substring(global.Length + 1).Split(new char[] { '\\' },
                    StringSplitOptions.RemoveEmptyEntries);
                if (segments.Length != 6 || !IsSimpleExecutionToken(segments[0]) ||
                    !(segments[0].StartsWith("vol-", StringComparison.OrdinalIgnoreCase) ||
                      segments[0].StartsWith("path-", StringComparison.OrdinalIgnoreCase)) ||
                    !(string.Equals(segments[1], "x86", StringComparison.OrdinalIgnoreCase) ||
                      string.Equals(segments[1], "x64", StringComparison.OrdinalIgnoreCase) ||
                      string.Equals(segments[1], "arm64", StringComparison.OrdinalIgnoreCase)) ||
                    !segments[2].StartsWith("desktop-lf-", StringComparison.OrdinalIgnoreCase) ||
                    !string.Equals(segments[3], "app", StringComparison.OrdinalIgnoreCase) ||
                    !string.Equals(segments[4], "current", StringComparison.OrdinalIgnoreCase) ||
                    !string.Equals(segments[5], PortableBranding.DesktopExecutableName,
                        StringComparison.OrdinalIgnoreCase)) return false;
                return EnsureSafeRecoveryFamily(Path.Combine(global, segments[0], segments[1]));
            }
            catch { return false; }
        }

        internal static bool SelfTestContract(PortableLayout layout)
        {
            try
            {
                PortableExecutionLayout execution = BuildLayout(GetVersionRoot(layout));
                string portableRoot = Path.GetFullPath(layout.Root).TrimEnd('\\');
                string executionRoot = Path.GetFullPath(execution.Root).TrimEnd('\\');
                if (executionRoot.StartsWith(portableRoot + "\\",
                    StringComparison.OrdinalIgnoreCase) ||
                    !IsExecutionPathForLayout(layout, execution.AppExe)) return false;
                if (Directory.Exists(execution.Root) &&
                    (Directory.Exists(Path.Combine(execution.Root, "data")) ||
                     Directory.Exists(Path.Combine(execution.Root, ".desktop-package")))) return false;

                Dictionary<string, string> env = PortableEnvironment.Build(layout, execution, null);
                try
                {
                    return EnvironmentEquals(env, "CODEX_ELECTRON_USER_DATA_PATH", layout.ElectronData) &&
                        EnvironmentEquals(env, "CODEX_HOME", layout.CodexHome) &&
                        EnvironmentEquals(env, "CODEX_SQLITE_HOME", layout.SqliteHome) &&
                        EnvironmentEquals(env, "CODEX_PORTABLE_ROOT", layout.Root) &&
                        EnvironmentEquals(env, "HOME", layout.Home) &&
                        EnvironmentEquals(env, "USERPROFILE", layout.Home) &&
                        EnvironmentEquals(env, "APPDATA", layout.AppData) &&
                        EnvironmentEquals(env, "LOCALAPPDATA", layout.LocalAppData) &&
                        EnvironmentEquals(env, "LOCALAPPDATALOW", layout.LocalAppDataLow) &&
                        EnvironmentEquals(env, "XDG_CONFIG_HOME", layout.XdgConfig) &&
                        EnvironmentEquals(env, "XDG_DATA_HOME", layout.XdgData) &&
                        EnvironmentEquals(env, "XDG_STATE_HOME", layout.XdgState) &&
                        EnvironmentEquals(env, "CODEX_CLI_PATH", execution.CodexExe) &&
                        EnvironmentEquals(env, "CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH",
                            Path.Combine(execution.Resources, "plugins"));
                }
                finally { env.Clear(); }
            }
            catch { return false; }
        }

        private static bool EnvironmentEquals(Dictionary<string, string> environment,
            string name, string expected)
        {
            string actual;
            return environment.TryGetValue(name, out actual) &&
                string.Equals(Path.GetFullPath(actual).TrimEnd('\\'),
                    Path.GetFullPath(expected).TrimEnd('\\'),
                    StringComparison.OrdinalIgnoreCase);
        }

        internal static string GetGlobalCacheRoot()
        {
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrEmpty(local) || !Path.IsPathRooted(local))
                throw new InvalidOperationException("A local application-data directory is required for the execution image.");
            local = Path.GetFullPath(local).TrimEnd('\\');
            DriveInfo drive = new DriveInfo(Path.GetPathRoot(local));
            if (!drive.IsReady || drive.DriveType != DriveType.Fixed)
                throw new InvalidOperationException("The execution image requires a ready fixed local drive.");
            return Path.Combine(local, "LFPortable", "execution");
        }

        internal static string GetPreparationMutexNameForFamily(string family)
        {
            string familyFull;
            string volumeToken;
            string architecture;
            if (!TryNormalizeExecutionFamily(family, out familyFull, out volumeToken,
                out architecture))
                throw new InvalidOperationException("The execution-image family is invalid.");
            return "Local\\LFPortable-ExecutionImage-" + volumeToken + "-" + architecture;
        }

        internal static bool TryNormalizeRecoveryTarget(string family, string executionRoot,
            out string familyFull, out string executionFull)
        {
            familyFull = null;
            executionFull = null;
            string volumeToken;
            string architecture;
            if (!TryNormalizeExecutionFamily(family, out familyFull, out volumeToken,
                out architecture) || !EnsureSafeRecoveryFamily(familyFull) ||
                string.IsNullOrEmpty(executionRoot)) return false;
            try
            {
                executionFull = Path.GetFullPath(executionRoot).TrimEnd('\\');
                if (!string.Equals(Path.GetDirectoryName(executionFull), familyFull,
                    StringComparison.OrdinalIgnoreCase)) return false;
                string name = Path.GetFileName(executionFull);
                if (string.IsNullOrEmpty(name) ||
                    !name.StartsWith("desktop-lf-", StringComparison.OrdinalIgnoreCase)) return false;
                return AssertSafeCacheEntry(executionFull, familyFull, true);
            }
            catch
            {
                familyFull = null;
                executionFull = null;
                return false;
            }
        }

        internal static bool TryNormalizeRecoveryInvalidationEntry(string family,
            string executionRoot, string invalidationEntry, out string familyFull,
            out string executionFull, out string invalidationFull)
        {
            familyFull = null;
            executionFull = null;
            invalidationFull = null;
            if (!TryNormalizeRecoveryTarget(family, executionRoot, out familyFull,
                out executionFull) || string.IsNullOrEmpty(invalidationEntry)) return false;
            try
            {
                invalidationFull = Path.GetFullPath(invalidationEntry).TrimEnd('\\');
                if (!string.Equals(Path.GetDirectoryName(invalidationFull), familyFull,
                    StringComparison.OrdinalIgnoreCase)) return false;
                string name = Path.GetFileName(invalidationFull);
                string prefix = ".invalid-" + Path.GetFileName(executionFull) + "-";
                if (string.IsNullOrEmpty(name) ||
                    !name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return false;
                return AssertSafeCacheEntry(invalidationFull, familyFull, true);
            }
            catch
            {
                familyFull = null;
                executionFull = null;
                invalidationFull = null;
                return false;
            }
        }

        // The detached watcher runs after the portable drive may be gone, so it
        // cannot consult PortableLayout or volume metadata here. It still walks
        // every fixed-disk ancestor before a delete/move operation.
        private static bool EnsureSafeRecoveryFamily(string familyFull)
        {
            try
            {
                string local = Path.GetFullPath(Environment.GetFolderPath(
                    Environment.SpecialFolder.LocalApplicationData)).TrimEnd('\\');
                string global = Path.GetFullPath(GetGlobalCacheRoot()).TrimEnd('\\');
                string normalized = Path.GetFullPath(familyFull).TrimEnd('\\');
                if (!normalized.StartsWith(global + "\\", StringComparison.OrdinalIgnoreCase))
                    return false;
                if (!EnsureSafeDirectory(local, false)) return false;
                string cursor = local;
                string[] globalSegments = new string[] { "LFPortable", "execution" };
                for (int i = 0; i < globalSegments.Length; i++)
                {
                    cursor = Path.Combine(cursor, globalSegments[i]);
                    if (!EnsureSafeDirectory(cursor, false)) return false;
                }
                string relative = normalized.Substring(global.Length).TrimStart('\\');
                string[] segments = relative.Split(new char[] { '\\' },
                    StringSplitOptions.RemoveEmptyEntries);
                for (int i = 0; i < segments.Length; i++)
                {
                    cursor = Path.Combine(cursor, segments[i]);
                    if (!EnsureSafeDirectory(cursor, false)) return false;
                }
                return string.Equals(Path.GetFullPath(cursor).TrimEnd('\\'), normalized,
                    StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }

        private static bool TryNormalizeExecutionFamily(string family, out string familyFull,
            out string volumeToken, out string architecture)
        {
            familyFull = null;
            volumeToken = null;
            architecture = null;
            if (string.IsNullOrEmpty(family)) return false;
            try
            {
                string global = Path.GetFullPath(GetGlobalCacheRoot()).TrimEnd('\\');
                familyFull = Path.GetFullPath(family).TrimEnd('\\');
                if (!familyFull.StartsWith(global + "\\", StringComparison.OrdinalIgnoreCase)) return false;
                string relative = familyFull.Substring(global.Length + 1);
                string[] segments = relative.Split(new char[] { '\\' },
                    StringSplitOptions.RemoveEmptyEntries);
                if (segments.Length != 2 || !IsSimpleExecutionToken(segments[0]) ||
                    !(segments[0].StartsWith("vol-", StringComparison.OrdinalIgnoreCase) ||
                      segments[0].StartsWith("path-", StringComparison.OrdinalIgnoreCase)) ||
                    !(string.Equals(segments[1], "x86", StringComparison.OrdinalIgnoreCase) ||
                      string.Equals(segments[1], "x64", StringComparison.OrdinalIgnoreCase) ||
                      string.Equals(segments[1], "arm64", StringComparison.OrdinalIgnoreCase))) return false;
                volumeToken = segments[0];
                architecture = segments[1].ToLowerInvariant();
                return true;
            }
            catch
            {
                familyFull = null;
                volumeToken = null;
                architecture = null;
                return false;
            }
        }

        private static bool IsSimpleExecutionToken(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length > 40) return false;
            for (int i = 0; i < value.Length; i++)
            {
                char c = value[i];
                if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                    (c >= '0' && c <= '9') || c == '-')) return false;
            }
            return true;
        }

        private static bool EnsureSafeExecutionFamily(PortableLayout layout,
            string family, bool create)
        {
            string local = Path.GetFullPath(Environment.GetFolderPath(
                Environment.SpecialFolder.LocalApplicationData)).TrimEnd('\\');
            string global = Path.GetFullPath(GetGlobalCacheRoot()).TrimEnd('\\');
            string familyFull = Path.GetFullPath(family).TrimEnd('\\');
            string portableRoot = Path.GetFullPath(layout.Root).TrimEnd('\\');
            if (!familyFull.StartsWith(global + "\\", StringComparison.OrdinalIgnoreCase) ||
                familyFull.StartsWith(portableRoot + "\\", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(familyFull, portableRoot, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The execution-image family path is unsafe.");

            DriveInfo portableDrive = new DriveInfo(Path.GetPathRoot(portableRoot));
            if (portableDrive.IsReady && (portableDrive.DriveType == DriveType.Removable ||
                string.Equals(portableDrive.VolumeLabel, "CODEX_USB", StringComparison.OrdinalIgnoreCase)) &&
                string.Equals(Path.GetPathRoot(global), Path.GetPathRoot(portableRoot),
                    StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The execution image cannot use the removable portable volume.");

            if (!EnsureSafeDirectory(local, false)) return false;
            string cursor = local;
            string[] globalSegments = new string[] { "LFPortable", "execution" };
            for (int i = 0; i < globalSegments.Length; i++)
            {
                cursor = Path.Combine(cursor, globalSegments[i]);
                if (!EnsureSafeDirectory(cursor, create)) return false;
            }
            string relative = familyFull.Substring(global.Length).TrimStart('\\');
            string[] segments = relative.Split(new char[] { '\\' },
                StringSplitOptions.RemoveEmptyEntries);
            for (int i = 0; i < segments.Length; i++)
            {
                cursor = Path.Combine(cursor, segments[i]);
                if (!EnsureSafeDirectory(cursor, create)) return false;
            }
            return string.Equals(Path.GetFullPath(cursor).TrimEnd('\\'), familyFull,
                StringComparison.OrdinalIgnoreCase);
        }

        private static bool EnsureSafeDirectory(string path, bool create)
        {
            uint rawAttributes = NativeMethods.GetFileAttributes(path);
            if (rawAttributes == NativeMethods.InvalidFileAttributes)
            {
                int error = Marshal.GetLastWin32Error();
                if (error != 2 && error != 3)
                    throw new Win32Exception(error, "Execution-image directory metadata is unavailable: " + path);
                if (!create) return false;
                Directory.CreateDirectory(path);
                rawAttributes = NativeMethods.GetFileAttributes(path);
                if (rawAttributes == NativeMethods.InvalidFileAttributes)
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Execution-image directory creation could not be verified: " + path);
            }
            FileAttributes attributes = (FileAttributes)rawAttributes;
            if ((attributes & FileAttributes.Directory) == 0 ||
                (attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Execution-image directories cannot be reparse points: " + path);
            return true;
        }

        private static bool AssertSafeCacheEntry(string path, string family,
            bool allowMissing)
        {
            string familyFull = Path.GetFullPath(family).TrimEnd('\\');
            string full = Path.GetFullPath(path).TrimEnd('\\');
            if (!full.StartsWith(familyFull + "\\", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Execution-image entry is outside its family.");
            uint rawAttributes = NativeMethods.GetFileAttributes(full);
            if (rawAttributes == NativeMethods.InvalidFileAttributes)
            {
                int error = Marshal.GetLastWin32Error();
                if (allowMissing && (error == 2 || error == 3)) return true;
                if (error == 2 || error == 3) return false;
                throw new Win32Exception(error, "Execution-image entry metadata is unavailable: " + full);
            }
            FileAttributes attributes = (FileAttributes)rawAttributes;
            if ((attributes & FileAttributes.Directory) == 0 ||
                (attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Execution-image entries cannot be files or reparse points: " + full);
            return true;
        }

        internal static string GetFamilyRoot(PortableLayout layout)
        {
            return Path.Combine(GetGlobalCacheRoot(), GetVolumeToken(layout), layout.ArchitectureName);
        }

        private static string GetVersionRoot(PortableLayout layout)
        {
            return GetVersionRoot(layout, GetFamilyRoot(layout));
        }

        private static string GetVersionRoot(PortableLayout layout, string family)
        {
            // Cache lookup must not enumerate a multi-gigabyte USB MSIX. The
            // signed packages are revalidated only when constructing/rebuilding
            // the image; the compact release descriptor names an exact pair.
            Version launcherVersion = Assembly.GetExecutingAssembly().GetName().Version;
            string packageIdentity = AppUpdater.GetExecutionImagePackageIdentity(layout);
            if (string.IsNullOrEmpty(packageIdentity))
                throw new InvalidDataException("The portable release package identity is unavailable.");
            string key = "desktop-lf-" + launcherVersion.ToString() + "-pkg-" + packageIdentity;
            return Path.Combine(family, key);
        }

        private static string GetVolumeToken(PortableLayout layout)
        {
            string root = Path.GetPathRoot(layout.Root);
            uint serial;
            uint maximumComponentLength;
            uint flags;
            if (!string.IsNullOrEmpty(root) && NativeMethods.GetVolumeInformation(root,
                null, 0, out serial, out maximumComponentLength, out flags, null, 0))
                return "vol-" + serial.ToString("X8", CultureInfo.InvariantCulture);

            string normalized = Path.GetFullPath(layout.Root).TrimEnd('\\').ToUpperInvariant();
            byte[] input = Encoding.UTF8.GetBytes(normalized);
            byte[] digest = null;
            try
            {
                using (SHA256 sha = SHA256.Create()) digest = sha.ComputeHash(input);
                StringBuilder token = new StringBuilder(16);
                for (int i = 0; i < 8; i++) token.Append(digest[i].ToString("x2", CultureInfo.InvariantCulture));
                return "path-" + token.ToString();
            }
            finally
            {
                Array.Clear(input, 0, input.Length);
                if (digest != null) Array.Clear(digest, 0, digest.Length);
            }
        }

        private static PortableExecutionLayout BuildLayout(string root)
        {
            PortableExecutionLayout execution = new PortableExecutionLayout();
            execution.Root = root;
            execution.FamilyRoot = Path.GetDirectoryName(Path.GetFullPath(root)).TrimEnd('\\');
            execution.AppRoot = Path.Combine(root, "app", "current");
            execution.OfficialAppExe = Path.Combine(execution.AppRoot, "ChatGPT.exe");
            execution.AppExe = Path.Combine(execution.AppRoot, PortableBranding.DesktopExecutableName);
            execution.Resources = Path.Combine(execution.AppRoot, "resources");
            execution.CodexExe = Path.Combine(execution.Resources, "codex.exe");
            execution.Runtime = Path.Combine(root, "runtime");
            execution.Tools = Path.Combine(root, "tools");
            return execution;
        }

        private static bool Validate(PortableExecutionLayout execution,
            PortableArchitecture architecture)
        {
            try
            {
                if (!Directory.Exists(execution.Root)) return false;
                AppUpdater.AssertExtractedTreeNoReparse(execution.Root);
                if (!PortableBranding.IsPrepared(execution.AppRoot) ||
                    !ArchitectureInfo.IsMachineCompatible(execution.AppExe, architecture) ||
                    !ArchitectureInfo.IsMachineCompatible(execution.CodexExe, architecture)) return false;
                string[] required = new string[] {
                    Path.Combine(execution.Resources, "app.asar"),
                    Path.Combine(execution.Resources, "cua_node", "bin", "node_repl.exe"),
                    Path.Combine(execution.Resources, "cua_node", "bin", "node_modules", "@oai", "sky", "bin", "windows", "codex-computer-use.exe"),
                    Path.Combine(execution.Resources, "plugins", "openai-bundled", ".agents", "plugins", "marketplace.json"),
                    Path.Combine(execution.Runtime, "dependencies", "node", "bin", "node.exe"),
                    Path.Combine(execution.Runtime, "dependencies", "python", "python.exe"),
                    Path.Combine(execution.Runtime, "dependencies", "native", "git", "cmd", "git.exe"),
                    Path.Combine(execution.Tools, "dotnet", "dotnet.exe")
                };
                for (int i = 0; i < required.Length; i++) if (!File.Exists(required[i])) return false;
                return File.Exists(Path.Combine(execution.Tools, "gh", "bin", "gh.exe")) ||
                    File.Exists(Path.Combine(execution.Tools, "gh", "gh.exe"));
            }
            catch { return false; }
        }

    }

    // Runs from a fixed local scratch directory after a successful desktop
    // handoff. It deliberately does not relaunch Codex or touch USB data. A
    // late mapped-image failure only invalidates the exact local image so the
    // next user-initiated start performs the normal verified rebuild.
    internal sealed class DesktopImageFailureWatch : IDisposable
    {
        private const string WatchArgument = "--desktop-image-failure-watch";
        private const string EventPrefix = "Local\\LFPortable-DesktopImageRecovery-";
        private const uint StatusInPageError = 0xC0000006;
        private const int ReadyTimeoutMilliseconds = 10000;
        private const int MutationTimeoutMilliseconds = 15000;
        private const int ProcessDrainTimeoutMilliseconds = 60000;
        private const int DeletionTimeoutMilliseconds = 30000;
        private const int FileSystemRetryDelayMilliseconds = 100;
        private const int CompletionTimeoutMilliseconds = MutationTimeoutMilliseconds +
            ProcessDrainTimeoutMilliseconds + (DeletionTimeoutMilliseconds * 3) +
            ReadyTimeoutMilliseconds;
        private readonly Process watcher;
        private readonly EventWaitHandle ready;
        private readonly EventWaitHandle failed;
        private readonly EventWaitHandle prepare;
        private readonly EventWaitHandle prepared;
        private readonly EventWaitHandle commit;
        private readonly EventWaitHandle armed;
        private readonly EventWaitHandle cancel;
        private readonly uint targetProcessId;
        private readonly long targetStartTicks;
        private readonly string targetExecutable;
        private bool committed;
        private bool disposed;

        private DesktopImageFailureWatch(Process process, EventWaitHandle readyEvent,
            EventWaitHandle failedEvent, EventWaitHandle prepareEvent, EventWaitHandle preparedEvent,
            EventWaitHandle commitEvent, EventWaitHandle armedEvent, EventWaitHandle cancelEvent, uint targetId,
            long targetStart, string expectedTargetExecutable)
        {
            watcher = process;
            ready = readyEvent;
            failed = failedEvent;
            prepare = prepareEvent;
            prepared = preparedEvent;
            commit = commitEvent;
            armed = armedEvent;
            cancel = cancelEvent;
            targetProcessId = targetId;
            targetStartTicks = targetStart;
            targetExecutable = expectedTargetExecutable;
        }

        internal static bool IsWatchArgument(string argument)
        {
            return string.Equals(argument, WatchArgument, StringComparison.OrdinalIgnoreCase);
        }

        internal static string PrepareHelper(PortableLayout layout)
        {
            if (layout == null) throw new ArgumentNullException("layout");
            if (!PortableScratch.IsPrepared(layout))
                throw new IOException("A fixed local scratch directory is required for desktop recovery.");
            string scratch = Path.GetFullPath(layout.HostScratchRoot).TrimEnd('\\');
            string source = Path.GetFullPath(Assembly.GetExecutingAssembly().Location);
            string helper = Path.Combine(scratch, "LFRecovery-" +
                Guid.NewGuid().ToString("N") + ".exe");
            helper = PortableScratch.ValidateRecoveryHelperPath(layout, helper, false);
            CopyHelperVerified(source, helper);
            return PortableScratch.ValidateRecoveryHelperPath(layout, helper, true);
        }

        internal static DesktopImageFailureWatch Start(PortableLayout layout,
            PortableExecutionLayout execution, uint processId, string helper)
        {
            if (layout == null || execution == null || string.IsNullOrEmpty(helper))
                throw new ArgumentException("The desktop recovery helper is missing launch state.");
            string family = execution.FamilyRoot;
            string familyFull;
            string executionFull;
            if (!HostExecutionImage.TryNormalizeRecoveryTarget(family, execution.Root,
                out familyFull, out executionFull))
                throw new InvalidOperationException("The local desktop execution image is unsafe for recovery.");
            string helperFull = PortableScratch.ValidateRecoveryHelperPath(layout, helper, true);
            string scratch = Path.GetDirectoryName(helperFull);

            Process target = OpenMatchingProcess(unchecked((int)processId), 0);
            if (target == null) return null;
            long targetStartTicks;
            try
            {
                targetStartTicks = GetStartTicks(target);
                string executable;
                if (targetStartTicks == 0 || !PortableProcess.TryGetExecutablePath(target, out executable) ||
                    !PathsEqual(executable, Path.Combine(executionFull, "app", "current",
                        PortableBranding.DesktopExecutableName))) return null;
            }
            finally { target.Dispose(); }

            Process parent = Process.GetCurrentProcess();
            long parentStartTicks;
            try { parentStartTicks = GetStartTicks(parent); }
            finally { parent.Dispose(); }
            if (parentStartTicks == 0) throw new IOException("Unable to identify the launcher process for recovery.");

            string token = Guid.NewGuid().ToString("N");
            EventWaitHandle readyEvent = null;
            EventWaitHandle failedEvent = null;
            EventWaitHandle prepareEvent = null;
            EventWaitHandle preparedEvent = null;
            EventWaitHandle commitEvent = null;
            EventWaitHandle armedEvent = null;
            EventWaitHandle cancelEvent = null;
            Process watcher = null;
            DesktopImageFailureWatch result = null;
            bool targetExitedDuringSetup = false;
            try
            {
                readyEvent = new EventWaitHandle(false, EventResetMode.ManualReset,
                    EventPrefix + token + "-ready");
                failedEvent = new EventWaitHandle(false, EventResetMode.ManualReset,
                    EventPrefix + token + "-failed");
                prepareEvent = new EventWaitHandle(false, EventResetMode.ManualReset,
                    EventPrefix + token + "-prepare");
                preparedEvent = new EventWaitHandle(false, EventResetMode.ManualReset,
                    EventPrefix + token + "-prepared");
                commitEvent = new EventWaitHandle(false, EventResetMode.ManualReset,
                    EventPrefix + token + "-commit");
                armedEvent = new EventWaitHandle(false, EventResetMode.ManualReset,
                    EventPrefix + token + "-armed");
                cancelEvent = new EventWaitHandle(false, EventResetMode.ManualReset,
                    EventPrefix + token + "-cancel");
                List<string> arguments = new List<string>();
                arguments.Add(WatchArgument);
                arguments.Add(Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture));
                arguments.Add(parentStartTicks.ToString(CultureInfo.InvariantCulture));
                arguments.Add(processId.ToString(CultureInfo.InvariantCulture));
                arguments.Add(targetStartTicks.ToString(CultureInfo.InvariantCulture));
                arguments.Add(layout.Root);
                arguments.Add(familyFull);
                arguments.Add(executionFull);
                // Pass stable names, never inheritable event handles. The helper
                // can survive the launcher closing immediately after commit.
                arguments.Add(EventPrefix + token + "-ready");
                arguments.Add(EventPrefix + token + "-failed");
                arguments.Add(EventPrefix + token + "-prepare");
                arguments.Add(EventPrefix + token + "-prepared");
                arguments.Add(EventPrefix + token + "-commit");
                arguments.Add(EventPrefix + token + "-armed");
                arguments.Add(EventPrefix + token + "-cancel");
                ProcessStartInfo startInfo = new ProcessStartInfo();
                startInfo.FileName = helperFull;
                startInfo.Arguments = JoinArguments(arguments);
                startInfo.WorkingDirectory = scratch;
                startInfo.UseShellExecute = false;
                startInfo.CreateNoWindow = true;
                watcher = Process.Start(startInfo);
                if (watcher == null) throw new IOException("Unable to start the local desktop recovery helper.");
                int signaled = WaitHandle.WaitAny(new WaitHandle[] { readyEvent, failedEvent },
                    ReadyTimeoutMilliseconds);
                if (signaled == 1)
                {
                    Process current = OpenMatchingProcess(unchecked((int)processId), targetStartTicks);
                    if (current == null)
                    {
                        targetExitedDuringSetup = true;
                        return null;
                    }
                    current.Dispose();
                }
                if (signaled != 0)
                    throw new IOException("The local desktop recovery helper did not establish a verified handoff.");
                result = new DesktopImageFailureWatch(watcher, readyEvent, failedEvent,
                    prepareEvent, preparedEvent, commitEvent, armedEvent, cancelEvent, processId,
                    targetStartTicks, Path.Combine(executionFull, "app", "current",
                        PortableBranding.DesktopExecutableName));
                watcher = null;
                readyEvent = null;
                failedEvent = null;
                prepareEvent = null;
                preparedEvent = null;
                commitEvent = null;
                armedEvent = null;
                cancelEvent = null;
                return result;
            }
            catch
            {
                if (cancelEvent != null) { try { cancelEvent.Set(); } catch { } }
                throw;
            }
            finally
            {
                if (watcher != null)
                {
                    try { if (!watcher.HasExited) watcher.WaitForExit(5000); } catch { }
                    watcher.Dispose();
                }
                if (readyEvent != null) readyEvent.Dispose();
                if (failedEvent != null) failedEvent.Dispose();
                if (prepareEvent != null) prepareEvent.Dispose();
                if (preparedEvent != null) preparedEvent.Dispose();
                if (commitEvent != null) commitEvent.Dispose();
                if (armedEvent != null) armedEvent.Dispose();
                if (cancelEvent != null) cancelEvent.Dispose();
                if (result == null && !targetExitedDuringSetup) IOUtil.TryDelete(helperFull);
            }
        }

        internal void Prepare()
        {
            ThrowIfDisposed();
            prepare.Set();
            int signaled = WaitHandle.WaitAny(new WaitHandle[] { prepared, failed },
                MutationTimeoutMilliseconds + ReadyTimeoutMilliseconds);
            if (signaled != 0)
                throw new IOException("The local desktop recovery helper could not reserve the execution image.");
        }

        internal void Commit()
        {
            ThrowIfDisposed();
            commit.Set();
            int signaled = WaitHandle.WaitAny(new WaitHandle[] { armed, failed },
                ReadyTimeoutMilliseconds);
            if (signaled != 0)
                throw new IOException("The local desktop recovery helper did not acknowledge the handoff.");
            committed = true;
        }

        internal void WaitForCompletionAfterTargetExit()
        {
            ThrowIfDisposed();
            if (!committed)
                throw new InvalidOperationException("The desktop recovery helper was not committed.");
            if (!watcher.WaitForExit(CompletionTimeoutMilliseconds))
                throw new TimeoutException("The local desktop recovery helper did not finish after Codex exited.");
        }

        // The UI must verify the same process identity immediately before it
        // releases the job. This method uses only the identity captured at
        // Start, so a transient USB volume query cannot change the handoff.
        internal bool IsTargetAlive()
        {
            ThrowIfDisposed();
            Process target = OpenMatchingProcess(unchecked((int)targetProcessId), targetStartTicks);
            if (target == null) return false;
            try
            {
                string executable;
                return PortableProcess.TryGetExecutablePath(target, out executable) &&
                    PathsEqual(executable, targetExecutable);
            }
            catch { return false; }
            finally { target.Dispose(); }
        }

        internal static int Run(string[] args)
        {
            EventWaitHandle readyEvent = null;
            EventWaitHandle failedEvent = null;
            EventWaitHandle prepareEvent = null;
            EventWaitHandle preparedEvent = null;
            EventWaitHandle commitEvent = null;
            EventWaitHandle armedEvent = null;
            EventWaitHandle cancelEvent = null;
            Process parent = null;
            Process target = null;
            Mutex mutation = null;
            bool mutationAcquired = false;
            try
            {
                int parentId;
                int targetId;
                long parentStartTicks;
                long targetStartTicks;
                string portableRoot;
                string family;
                string executionRoot;
                if (!TryParseArguments(args, out parentId, out parentStartTicks, out targetId,
                    out targetStartTicks, out portableRoot, out family, out executionRoot)) return 41;
                if (!AreEventNamesValid(args, 8, 7)) return 42;
                readyEvent = EventWaitHandle.OpenExisting(args[8]);
                failedEvent = EventWaitHandle.OpenExisting(args[9]);
                prepareEvent = EventWaitHandle.OpenExisting(args[10]);
                preparedEvent = EventWaitHandle.OpenExisting(args[11]);
                commitEvent = EventWaitHandle.OpenExisting(args[12]);
                armedEvent = EventWaitHandle.OpenExisting(args[13]);
                cancelEvent = EventWaitHandle.OpenExisting(args[14]);
                string familyFull;
                string executionFull;
                if (!HostExecutionImage.TryNormalizeRecoveryTarget(family, executionRoot,
                    out familyFull, out executionFull))
                {
                    failedEvent.Set();
                    return 43;
                }
                parent = OpenMatchingProcess(parentId, parentStartTicks);
                target = OpenMatchingProcess(targetId, targetStartTicks);
                string targetExecutable;
                if (parent == null || target == null || !PortableProcess.TryGetExecutablePath(target,
                    out targetExecutable) || !PathsEqual(targetExecutable,
                        Path.Combine(executionFull, "app", "current", PortableBranding.DesktopExecutableName)))
                {
                    failedEvent.Set();
                    return 44;
                }
                readyEvent.Set();
                if (WaitForControl(prepareEvent, cancelEvent, parent, parentStartTicks) != 0) return 0;
                mutation = PortableProcess.AcquireMutationMutex(portableRoot,
                    MutationTimeoutMilliseconds);
                if (mutation == null)
                {
                    failedEvent.Set();
                    return 45;
                }
                mutationAcquired = true;
                preparedEvent.Set();
                int commitControl = WaitForControl(commitEvent, cancelEvent, parent, parentStartTicks);
                if (commitControl == 1) return 0;
                // Once preparation has been acknowledged, parent death is an
                // implicit commit. If the job was not detached, closing the
                // parent kills the target with a non-image-fault status; if it
                // was detached, this watcher must retain the late exit code.
                armedEvent.Set();
                target.WaitForExit();
                uint exitCode = unchecked((uint)target.ExitCode);
                if (exitCode != StatusInPageError) return 0;
                return TryInvalidateExecutionImage(familyFull, executionFull) ? 0 : 46;
            }
            catch
            {
                try { if (failedEvent != null) failedEvent.Set(); } catch { }
                return 47;
            }
            finally
            {
                if (mutationAcquired) PortableProcess.ReleaseMutationMutex(mutation);
                else if (mutation != null) mutation.Dispose();
                if (parent != null) parent.Dispose();
                if (target != null) target.Dispose();
                if (readyEvent != null) readyEvent.Dispose();
                if (failedEvent != null) failedEvent.Dispose();
                if (prepareEvent != null) prepareEvent.Dispose();
                if (preparedEvent != null) preparedEvent.Dispose();
                if (commitEvent != null) commitEvent.Dispose();
                if (armedEvent != null) armedEvent.Dispose();
                if (cancelEvent != null) cancelEvent.Dispose();
            }
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            if (!committed)
            {
                try { cancel.Set(); } catch { }
                try
                {
                    if (!watcher.HasExited)
                        watcher.WaitForExit(MutationTimeoutMilliseconds + 5000);
                }
                catch { }
            }
            watcher.Dispose();
            ready.Dispose();
            failed.Dispose();
            prepare.Dispose();
            prepared.Dispose();
            commit.Dispose();
            armed.Dispose();
            cancel.Dispose();
        }

        private static bool TryParseArguments(string[] args, out int parentId,
            out long parentStartTicks, out int targetId, out long targetStartTicks,
            out string portableRoot, out string family, out string executionRoot)
        {
            parentId = 0;
            parentStartTicks = 0;
            targetId = 0;
            targetStartTicks = 0;
            portableRoot = null;
            family = null;
            executionRoot = null;
            if (args == null || args.Length != 15 || !IsWatchArgument(args[0]) ||
                !int.TryParse(args[1], NumberStyles.None, CultureInfo.InvariantCulture, out parentId) ||
                !long.TryParse(args[2], NumberStyles.None, CultureInfo.InvariantCulture, out parentStartTicks) ||
                !int.TryParse(args[3], NumberStyles.None, CultureInfo.InvariantCulture, out targetId) ||
                !long.TryParse(args[4], NumberStyles.None, CultureInfo.InvariantCulture, out targetStartTicks) ||
                parentId <= 0 || targetId <= 0 || parentStartTicks <= 0 || targetStartTicks <= 0 ||
                string.IsNullOrEmpty(args[5]) || string.IsNullOrEmpty(args[6]) ||
                string.IsNullOrEmpty(args[7])) return false;
            try
            {
                portableRoot = Path.GetFullPath(args[5]).TrimEnd('\\');
                family = Path.GetFullPath(args[6]).TrimEnd('\\');
                executionRoot = Path.GetFullPath(args[7]).TrimEnd('\\');
                return true;
            }
            catch { return false; }
        }

        private static bool AreEventNamesValid(string[] args, int start, int count)
        {
            if (args == null || start < 0 || count < 1 || args.Length < start + count) return false;
            for (int i = start; i < start + count; i++)
            {
                string value = args[i];
                if (string.IsNullOrEmpty(value) || value.Length > 160 ||
                    !value.StartsWith(EventPrefix, StringComparison.Ordinal)) return false;
            }
            return true;
        }

        private static int WaitForControl(EventWaitHandle action, EventWaitHandle cancelEvent,
            Process parent, long parentStartTicks)
        {
            WaitHandle[] controls = new WaitHandle[] { action, cancelEvent };
            while (true)
            {
                int result = WaitHandle.WaitAny(controls, 500);
                if (result == 0) return 0;
                if (result == 1) return 1;
                if (!ProcessMatches(parent, parentStartTicks)) return 2;
            }
        }

        private static Process OpenMatchingProcess(int processId, long expectedStartTicks)
        {
            Process process = null;
            try
            {
                process = Process.GetProcessById(processId);
                if (process.HasExited || (expectedStartTicks != 0 &&
                    GetStartTicks(process) != expectedStartTicks))
                {
                    process.Dispose();
                    return null;
                }
                return process;
            }
            catch
            {
                if (process != null) process.Dispose();
                return null;
            }
        }

        private static bool ProcessMatches(Process process, long expectedStartTicks)
        {
            try
            {
                return process != null && !process.HasExited &&
                    GetStartTicks(process) == expectedStartTicks;
            }
            catch { return false; }
        }

        private static long GetStartTicks(Process process)
        {
            try { return process.StartTime.ToUniversalTime().Ticks; }
            catch { return 0; }
        }

        private static bool TryInvalidateExecutionImage(string family, string executionRoot)
        {
            string familyFull;
            string executionFull;
            if (!HostExecutionImage.TryNormalizeRecoveryTarget(family, executionRoot,
                out familyFull, out executionFull)) return false;
            Mutex local = null;
            bool acquired = false;
            try
            {
                local = new Mutex(false, HostExecutionImage.GetPreparationMutexNameForFamily(familyFull));
                try { acquired = local.WaitOne(MutationTimeoutMilliseconds, false); }
                catch (AbandonedMutexException) { acquired = true; }
                if (!acquired) return false;
                string destinationName = Path.GetFileName(executionFull);
                string invalidationToken = Guid.NewGuid().ToString("N").Substring(0, 12);
                string reservation = Path.Combine(familyFull, ".invalid-" + destinationName + "-" +
                    invalidationToken + "-pending");
                string quarantine = Path.Combine(familyFull, ".invalid-" + destinationName + "-" +
                    invalidationToken + "-quarantine");

                // Reserve invalidation before waiting for mapped descendants.
                // Any surviving .invalid-* directory makes TryGetReady fail,
                // so a confirmed bad image cannot be reused after a cleanup
                // timeout, launcher crash, or transient filesystem failure.
                if (!TryCreateInvalidationReservation(familyFull, executionFull, reservation))
                    return false;
                // The root process may leave Electron utility descendants alive
                // after the injected image fault. They are bound by executable
                // path to this exact image; terminate only those descendants
                // before the path is moved out of the active cache name.
                PortableProcess.TerminateExecutablesUnderRoot(executionFull);
                Stopwatch drain = Stopwatch.StartNew();
                while (PortableProcess.IsAnyExecutableRunningUnderRoot(executionFull) &&
                    drain.ElapsedMilliseconds < ProcessDrainTimeoutMilliseconds)
                    Thread.Sleep(FileSystemRetryDelayMilliseconds);
                if (PortableProcess.IsAnyExecutableRunningUnderRoot(executionFull)) return false;
                if (!TryMoveExecutionToInvalidation(familyFull, executionFull, quarantine)) return false;

                // Moving the bad image out of its active name is the atomic
                // invalidation boundary. Deleting a multi-gigabyte quarantine
                // synchronously here can outlive the recovery confirmation
                // window and leave the helper attached indefinitely. The
                // quarantine is a durable invalidation sibling; the next
                // user-initiated verified rebuild removes it under the same
                // family mutex after the new image is ready.
                if (!IsRecoveryTargetAbsent(familyFull, executionFull)) return false;
                TryDeleteInvalidationDirectory(familyFull, executionFull, reservation);
                return IsRecoveryTargetAbsent(familyFull, executionFull);
            }
            finally
            {
                if (acquired)
                {
                    try { local.ReleaseMutex(); } catch { }
                }
                if (local != null) local.Dispose();
            }
        }

        private static bool TryCreateInvalidationReservation(string family, string executionRoot,
            string reservation)
        {
            Stopwatch timer = Stopwatch.StartNew();
            while (true)
            {
                string checkedFamily;
                string checkedExecution;
                string checkedReservation;
                if (!HostExecutionImage.TryNormalizeRecoveryInvalidationEntry(family,
                    executionRoot, reservation, out checkedFamily, out checkedExecution,
                    out checkedReservation)) return false;
                if (Directory.Exists(checkedReservation)) return true;
                try
                {
                    Directory.CreateDirectory(checkedReservation);
                    if (HostExecutionImage.TryNormalizeRecoveryInvalidationEntry(family,
                        executionRoot, reservation, out checkedFamily, out checkedExecution,
                        out checkedReservation) && Directory.Exists(checkedReservation)) return true;
                }
                catch (Exception ex)
                {
                    if (!IsRetryableFileSystemFailure(ex)) return false;
                }
                if (timer.ElapsedMilliseconds >= DeletionTimeoutMilliseconds) return false;
                Thread.Sleep(FileSystemRetryDelayMilliseconds);
            }
        }

        private static bool TryMoveExecutionToInvalidation(string family, string executionRoot,
            string quarantine)
        {
            Stopwatch timer = Stopwatch.StartNew();
            while (true)
            {
                string checkedFamily;
                string checkedExecution;
                string checkedQuarantine;
                if (!HostExecutionImage.TryNormalizeRecoveryInvalidationEntry(family,
                    executionRoot, quarantine, out checkedFamily, out checkedExecution,
                    out checkedQuarantine)) return false;
                if (!Directory.Exists(checkedExecution)) return true;
                if (PortableProcess.IsAnyExecutableRunningUnderRoot(checkedExecution)) return false;
                // Process enumeration can block briefly. Revalidate every
                // ancestor and both direct children immediately before moving.
                if (!HostExecutionImage.TryNormalizeRecoveryInvalidationEntry(family,
                    executionRoot, quarantine, out checkedFamily, out checkedExecution,
                    out checkedQuarantine)) return false;
                try { Directory.Move(checkedExecution, checkedQuarantine); }
                catch (Exception ex)
                {
                    if (!IsRetryableFileSystemFailure(ex)) return false;
                }
                if (!Directory.Exists(checkedExecution)) return true;
                if (timer.ElapsedMilliseconds >= DeletionTimeoutMilliseconds) return false;
                Thread.Sleep(FileSystemRetryDelayMilliseconds);
            }
        }

        private static bool TryDeleteInvalidationDirectory(string family, string executionRoot,
            string invalidationEntry)
        {
            Stopwatch timer = Stopwatch.StartNew();
            while (true)
            {
                string checkedFamily;
                string checkedExecution;
                string checkedInvalidation;
                if (!HostExecutionImage.TryNormalizeRecoveryInvalidationEntry(family,
                    executionRoot, invalidationEntry, out checkedFamily, out checkedExecution,
                    out checkedInvalidation)) return false;
                if (!Directory.Exists(checkedInvalidation)) return true;
                try { IOUtil.DeleteDirectoryWithin(checkedInvalidation, checkedFamily); }
                catch (Exception ex)
                {
                    // IOUtil's long-path deletion surfaces sharing/access
                    // failures as Win32Exception, so it must participate in the
                    // same bounded retry contract as the managed exceptions.
                    if (!IsRetryableFileSystemFailure(ex)) return false;
                }
                if (!Directory.Exists(checkedInvalidation)) return true;
                if (timer.ElapsedMilliseconds >= DeletionTimeoutMilliseconds) return false;
                Thread.Sleep(FileSystemRetryDelayMilliseconds);
            }
        }

        private static bool IsRecoveryTargetAbsent(string family, string executionRoot)
        {
            string familyFull;
            string executionFull;
            if (!HostExecutionImage.TryNormalizeRecoveryTarget(family, executionRoot,
                out familyFull, out executionFull)) return false;
            uint attributes = NativeMethods.GetFileAttributes(executionFull);
            if (attributes != NativeMethods.InvalidFileAttributes) return false;
            int error = Marshal.GetLastWin32Error();
            return error == 2 || error == 3;
        }

        private static bool IsRetryableFileSystemFailure(Exception exception)
        {
            return exception is IOException || exception is UnauthorizedAccessException ||
                exception is Win32Exception;
        }

        private static void CopyHelperVerified(string source, string destination)
        {
            File.Copy(source, destination, false);
            FileInfo sourceInfo = new FileInfo(source);
            FileInfo destinationInfo = new FileInfo(destination);
            if (sourceInfo.Length != destinationInfo.Length || !FilesHaveSameSha256(source, destination))
            {
                IOUtil.TryDelete(destination);
                throw new IOException("The local desktop recovery helper did not verify after copying.");
            }
        }

        private static bool FilesHaveSameSha256(string first, string second)
        {
            byte[] firstHash = null;
            byte[] secondHash = null;
            try
            {
                using (FileStream firstStream = new FileStream(first, FileMode.Open, FileAccess.Read,
                    FileShare.Read, 65536, FileOptions.SequentialScan))
                using (FileStream secondStream = new FileStream(second, FileMode.Open, FileAccess.Read,
                    FileShare.Read, 65536, FileOptions.SequentialScan))
                using (SHA256 firstSha = SHA256.Create())
                using (SHA256 secondSha = SHA256.Create())
                {
                    firstHash = firstSha.ComputeHash(firstStream);
                    secondHash = secondSha.ComputeHash(secondStream);
                }
                if (firstHash.Length != secondHash.Length) return false;
                for (int i = 0; i < firstHash.Length; i++)
                    if (firstHash[i] != secondHash[i]) return false;
                return true;
            }
            finally
            {
                if (firstHash != null) Array.Clear(firstHash, 0, firstHash.Length);
                if (secondHash != null) Array.Clear(secondHash, 0, secondHash.Length);
            }
        }

        private static string JoinArguments(List<string> arguments)
        {
            StringBuilder text = new StringBuilder();
            for (int i = 0; i < arguments.Count; i++)
            {
                if (i != 0) text.Append(' ');
                text.Append(IOUtil.QuoteArgument(arguments[i]));
            }
            return text.ToString();
        }

        private static bool PathsEqual(string first, string second)
        {
            try
            {
                return string.Equals(Path.GetFullPath(first).TrimEnd('\\'),
                    Path.GetFullPath(second).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }

        private void ThrowIfDisposed()
        {
            if (disposed) throw new ObjectDisposedException("DesktopImageFailureWatch");
        }
    }

    internal static class PortableEnvironment
    {
        internal const string DesktopBrandEnvironmentVariable = "CODEX_APP_BRAND";
        internal const string DesktopBrand = "codex";
        internal const string RemoteControlDisabledEnvironmentVariable = "CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED";
        internal const string DesktopUpdaterDisabledEnvironmentVariable = "CODEX_SPARKLE_ENABLED";

        internal static string FindMissingPrerequisite(PortableLayout p, bool verifyPluginCache)
        {
            string[] files = new string[] {
                Path.Combine(p.Runtime, "dependencies", "node", "bin", "node.exe"),
                Path.Combine(p.Runtime, "dependencies", "python", "python.exe"),
                Path.Combine(p.Runtime, "dependencies", "native", "git", "cmd", "git.exe"),
                Path.Combine(p.Tools, "dotnet", "dotnet.exe"),
                File.Exists(Path.Combine(p.Tools, "gh", "bin", "gh.exe")) ? Path.Combine(p.Tools, "gh", "bin", "gh.exe") : Path.Combine(p.Tools, "gh", "gh.exe"),
                Path.Combine(p.Resources, "cua_node", "bin", "node_repl.exe"),
                Path.Combine(p.Resources, "cua_node", "bin", "node_modules", "@oai", "sky", "bin", "windows", "codex-computer-use.exe"),
                Path.Combine(p.Resources, "plugins", "openai-bundled", ".agents", "plugins", "marketplace.json"),
                Path.Combine(p.CodexHome, "offline-marketplaces", "openai-primary-runtime", ".agents", "plugins", "marketplace.json")
            };
            for (int i = 0; i < files.Length; i++) if (!File.Exists(files[i])) return files[i];
            if (verifyPluginCache && !ProviderConfiguration.RequiredPluginCacheComplete(p))
                return Path.Combine(p.CodexHome, "plugins", "cache");
            return null;
        }

        internal static Dictionary<string, string> Build(PortableLayout p, string apiKey)
        {
            return Build(p, null, apiKey);
        }

        internal static Dictionary<string, string> Build(PortableLayout p,
            PortableExecutionLayout execution, string apiKey)
        {
            string runtime = execution == null ? p.Runtime : execution.Runtime;
            string tools = execution == null ? p.Tools : execution.Tools;
            string resources = execution == null ? p.Resources : execution.Resources;
            string codexExe = execution == null ? p.CodexExe : execution.CodexExe;
            Dictionary<string, string> env = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            IDictionary current = Environment.GetEnvironmentVariables();
            foreach (DictionaryEntry entry in current)
            {
                string key = entry.Key as string;
                string value = entry.Value as string;
                if (key != null && value != null && !ShouldDiscardHostVariable(key)) env[key] = value;
            }

            Set(env, "CODEX_ELECTRON_USER_DATA_PATH", p.ElectronData);
            Set(env, "CODEX_HOME", p.CodexHome);
            Set(env, "CODEX_SQLITE_HOME", p.SqliteHome);
            Set(env, "CODEX_PORTABLE_ROOT", p.Root);
            Set(env, "CODEX_CLI_PATH", codexExe);
            Set(env, DesktopBrandEnvironmentVariable, DesktopBrand);
            Set(env, RemoteControlDisabledEnvironmentVariable, "1");
            // The desktop updater is owned by LF Portable. Force the official
            // app's shared updater gate off even when the launcher inherits a
            // host environment that tries to enable it.
            Set(env, DesktopUpdaterDisabledEnvironmentVariable, "false");
            Set(env, "CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH", Path.Combine(resources, "plugins"));
            bool useHostScratch = PortableScratch.IsPrepared(p);
            string activeTemp = useHostScratch ? p.HostTemp : p.Temp;
            string activeXdgCache = useHostScratch ? p.HostXdgCache : p.XdgCache;
            string activeDotnetBundle = useHostScratch ? p.HostDotnetBundle : Path.Combine(p.Profile, "dotnet", "bundle");
            string activeNpmCache = useHostScratch ? p.HostNpmCache : Path.Combine(p.Profile, "npm");
            string activePipCache = useHostScratch ? p.HostPipCache : Path.Combine(p.Profile, "pip");
            string activeUvCache = useHostScratch ? p.HostUvCache : Path.Combine(p.Profile, "uv");
            Set(env, "HOME", p.Home);
            Set(env, "USERPROFILE", p.Home);
            Set(env, "HOMEDRIVE", Path.GetPathRoot(p.Home).TrimEnd('\\'));
            string root = Path.GetPathRoot(p.Home);
            string homePath = p.Home.Substring(root.Length - (root.EndsWith("\\", StringComparison.Ordinal) ? 1 : 0));
            Set(env, "HOMEPATH", homePath);
            Set(env, "APPDATA", p.AppData);
            Set(env, "LOCALAPPDATA", p.LocalAppData);
            Set(env, "LOCALAPPDATALOW", p.LocalAppDataLow);
            Set(env, "TEMP", activeTemp);
            Set(env, "TMP", activeTemp);
            Set(env, "TMPDIR", activeTemp);
            Set(env, "XDG_CONFIG_HOME", p.XdgConfig);
            Set(env, "XDG_CACHE_HOME", activeXdgCache);
            Set(env, "XDG_DATA_HOME", p.XdgData);
            Set(env, "XDG_STATE_HOME", p.XdgState);

            Set(env, "DOTNET_CLI_HOME", Path.Combine(p.Profile, "dotnet"));
            Set(env, "DOTNET_BUNDLE_EXTRACT_BASE_DIR", activeDotnetBundle);
            Set(env, "DOTNET_NOLOGO", "1");
            Set(env, "DOTNET_CLI_TELEMETRY_OPTOUT", "1");
            Set(env, "NUGET_PACKAGES", Path.Combine(p.Profile, "nuget"));
            Set(env, "GH_CONFIG_DIR", Path.Combine(p.Profile, "gh"));
            Set(env, "NPM_CONFIG_CACHE", activeNpmCache);
            Set(env, "npm_config_cache", activeNpmCache);
            Set(env, "PIP_CACHE_DIR", activePipCache);
            Set(env, "PYTHONUSERBASE", Path.Combine(p.Profile, "python-user"));
            // Plugins run the bundled interpreter directly from the portable
            // tree. Prevent it from materializing __pycache__ entries there;
            // old bytecode is tolerated by cache verification only as a narrow
            // compatibility allowance while this setting takes effect.
            Set(env, "PYTHONDONTWRITEBYTECODE", "1");
            Set(env, "UV_CACHE_DIR", activeUvCache);
            Set(env, "CARGO_HOME", Path.Combine(p.Profile, "cargo"));
            Set(env, "RUSTUP_HOME", Path.Combine(p.Profile, "rustup"));
            Set(env, "GIT_CONFIG_GLOBAL", Path.Combine(p.Profile, "gitconfig"));
            Set(env, "GIT_CONFIG_NOSYSTEM", "1");

            List<string> portablePath = new List<string>();
            AddDirectory(portablePath, Path.Combine(runtime, "dependencies", "bin", "override"));
            AddDirectory(portablePath, Path.Combine(runtime, "dependencies", "bin", "fallback"));
            AddDirectory(portablePath, Path.Combine(runtime, "dependencies", "node", "bin"));
            AddDirectory(portablePath, Path.Combine(runtime, "dependencies", "python"));
            AddDirectory(portablePath, Path.Combine(runtime, "dependencies", "python", "Scripts"));
            AddDirectory(portablePath, Path.Combine(runtime, "dependencies", "native", "git", "cmd"));
            AddDirectory(portablePath, Path.Combine(runtime, "dependencies", "native", "git", "bin"));
            AddDirectory(portablePath, Path.Combine(runtime, "dependencies", "git", "cmd"));
            AddDirectory(portablePath, Path.Combine(runtime, "dependencies", "git", "bin"));
            AddDirectory(portablePath, Path.Combine(runtime, "node"));
            AddDirectory(portablePath, Path.Combine(runtime, "python"));
            AddDirectory(portablePath, Path.Combine(runtime, "python", "Scripts"));
            AddDirectory(portablePath, Path.Combine(runtime, "git", "cmd"));
            AddDirectory(portablePath, Path.Combine(runtime, "git", "bin"));
            AddDirectory(portablePath, Path.Combine(tools, "dotnet"));
            AddDirectory(portablePath, Path.Combine(tools, "gh", "bin"));
            AddDirectory(portablePath, Path.Combine(tools, "gh"));
            AddDirectory(portablePath, resources);
            string windowsRoot = Environment.GetEnvironmentVariable("SystemRoot");
            if (!string.IsNullOrEmpty(windowsRoot))
            {
                AddDirectory(portablePath, Path.Combine(windowsRoot, "System32"));
                AddDirectory(portablePath, windowsRoot);
                AddDirectory(portablePath, Path.Combine(windowsRoot, "System32", "WindowsPowerShell", "v1.0"));
                AddDirectory(portablePath, Path.Combine(windowsRoot, "System32", "OpenSSH"));
            }

            string node = FindFile(new string[] {
                Path.Combine(runtime, "dependencies", "node", "bin", "node.exe"),
                Path.Combine(runtime, "node", "node.exe"),
                Path.Combine(resources, "cua_node", "bin", "node.exe")
            });
            if (node != null) Set(env, "CODEX_BROWSER_USE_NODE_PATH", node);
            string nodeRepl = FindFile(new string[] {
                Path.Combine(resources, "cua_node", "bin", "node_repl.exe"),
                Path.Combine(runtime, "dependencies", "node", "bin", "node_repl.exe")
            });
            if (nodeRepl != null) Set(env, "CODEX_NODE_REPL_PATH", nodeRepl);
            string git = FindFile(new string[] {
                Path.Combine(runtime, "dependencies", "native", "git", "cmd", "git.exe"),
                Path.Combine(runtime, "dependencies", "native", "git", "bin", "git.exe"),
                Path.Combine(runtime, "dependencies", "git", "cmd", "git.exe"),
                Path.Combine(runtime, "dependencies", "git", "bin", "git.exe"),
                Path.Combine(runtime, "git", "cmd", "git.exe"),
                Path.Combine(runtime, "git", "bin", "git.exe")
            });
            if (git != null) Set(env, "CODEX_PREFERRED_GIT_EXECUTABLE", git);

            string dotnet = Path.Combine(tools, "dotnet", "dotnet.exe");
            if (File.Exists(dotnet))
            {
                Set(env, "DOTNET_ROOT", Path.Combine(tools, "dotnet"));
                Set(env, "DOTNET_MULTILEVEL_LOOKUP", "0");
            }

            env["PATH"] = string.Join(";", portablePath.ToArray());
            if (!string.IsNullOrEmpty(apiKey)) env[ProviderConfiguration.ApiKeyEnvironmentVariable] = apiKey;
            else env.Remove(ProviderConfiguration.ApiKeyEnvironmentVariable);
            return env;
        }

        private static bool ShouldDiscardHostVariable(string name)
        {
            string upper = name.ToUpperInvariant();
            if (upper == "PATH" || upper == "HOME" || upper == "USERPROFILE" || upper == "HOMEDRIVE" || upper == "HOMEPATH" ||
                upper == "APPDATA" || upper == "LOCALAPPDATA" || upper == "LOCALAPPDATALOW" || upper == "TEMP" || upper == "TMP" || upper == "TMPDIR" ||
                upper == "NODE_OPTIONS" || upper == "NODE_PATH" || upper == "PYTHONHOME" || upper == "PYTHONPATH" || upper == "VIRTUAL_ENV" ||
                upper == "CONDA_PREFIX" || upper == "NPM_CONFIG_PREFIX" || upper == "DOTNET_ROOT" || upper == "ELECTRON_RUN_AS_NODE" ||
                upper == "SSH_AUTH_SOCK" || upper == "GIT_SSH" || upper == "GIT_SSH_COMMAND" || upper == "GIT_CONFIG_GLOBAL") return true;
            string[] prefixes = new string[] {
                "CODEX_", "CHATGPT_", "OPENAI_", "ANTHROPIC_", "AZURE_", "AWS_", "GOOGLE_", "GCP_",
                "GITHUB_", "GH_", "HF_", "HUGGINGFACE_", "COHERE_", "MISTRAL_", "GROQ_", "OPENROUTER_",
                "DEEPSEEK_", "ONEDRIVE", "XDG_", "CARGO_", "RUSTUP_"
            };
            for (int i = 0; i < prefixes.Length; i++) if (upper.StartsWith(prefixes[i], StringComparison.Ordinal)) return true;
            string[] suffixes = new string[] { "_API_KEY", "_TOKEN", "_SECRET", "_PASSWORD", "_CREDENTIAL", "_CREDENTIALS" };
            for (int i = 0; i < suffixes.Length; i++) if (upper.EndsWith(suffixes[i], StringComparison.Ordinal)) return true;
            return false;
        }

        private static void Set(Dictionary<string, string> env, string name, string value)
        {
            if (!string.IsNullOrEmpty(value)) env[name] = value;
        }

        private static void AddDirectory(List<string> list, string path)
        {
            if (Directory.Exists(path) && !list.Contains(path)) list.Add(path);
        }

        private static string FindFile(string[] candidates)
        {
            for (int i = 0; i < candidates.Length; i++) if (File.Exists(candidates[i])) return candidates[i];
            return null;
        }
    }

    internal sealed class PackageInfo
    {
        internal string Name;
        internal string Publisher;
        internal string Architecture;
        internal Version Version;
        internal long ExpandedBytes;
        internal int FileCount;
        internal long ExecutableBytes;
    }

    // Keep the user-facing downgrade policy separate from transport and
    // release-discovery failures.  WebException derives from
    // InvalidOperationException on .NET Framework, so catching the broader
    // type would misreport HTTP 403/404, missing releases, and similar errors
    // as a successful policy decision.
    internal sealed class DowngradeRefusedException : InvalidOperationException
    {
        internal DowngradeRefusedException(string message) : base(message) { }
    }

    internal static class AppUpdater
    {
        internal const string ExpectedName = "OpenAI.Codex";
        internal const string ExpectedPublisher = "CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B";
        internal const string UpdateChannel = "LF Portable releases";
        private const string GitHubLatestReleaseApi =
            "https://api.github.com/repos/riveryang6/lf-portable/releases/latest";
        private const string GitHubLatestReleasePage =
            "https://github.com/riveryang6/lf-portable/releases/latest";
        private const string ReleaseArchiveAssetName = "LFPortable-release.zip";
        private const string ReleaseManifestEntry = "portable-package-manifest.json";
        private const string ReleaseDescriptorPath = "CodexData/portable-release.json";
        private const string ReleaseTransactionPrefix = "release-apply-";
        private const int ReleaseTransactionNameLength = 46;
        private const int MaximumReleaseDescriptorBytes = 1024 * 1024;
        private const int MaximumReleaseManifestBytes = 32 * 1024 * 1024;
        // GitHub release assets must remain strictly smaller than 2 GiB.
        private const long MaximumReleaseArchiveBytes = 2L * 1024L * 1024L * 1024L - 1L;
        private const long MaximumReleaseMetadataBytes = 4L * 1024L * 1024L;
        private const long UpdateFreeSpaceReserveBytes = 512L * 1024L * 1024L;
        private const long MaximumDesktopExpandedBytes = 4L * 1024L * 1024L * 1024L;
        private const int MaximumDesktopPackageEntries = 100000;
        private const int ExtractionTimeoutMinutes = 45;
        private const int ProgressReportIntervalMilliseconds = 125;
        private static readonly uint[] Crc32Table = CreateCrc32Table();
        private static readonly FieldInfo ZipEntryCrc32Field = typeof(ZipArchiveEntry).GetField(
            "_crc32", BindingFlags.Instance | BindingFlags.NonPublic);

        private static readonly string[] ReleaseContentFiles = new string[] {
            "CodexPortable.exe",
            "CodexData/README.txt",
            "CodexData/THIRD_PARTY.txt",
            "CodexData/tools/launchers/CodexPortable.x86.exe",
            "CodexData/tools/launchers/CodexPortable.x64.exe",
            "CodexData/tools/launchers/CodexPortable.arm64.exe",
            "CodexData/packages/LFPortable-common.zip",
            "CodexData/packages/LFPortable-x64.msix",
            "CodexData/packages/LFPortable-arm64.msix"
        };

        private static readonly string[] ReleaseManagedFiles = new string[] {
            "CodexPortable.exe",
            "CodexData/README.txt",
            "CodexData/THIRD_PARTY.txt",
            "CodexData/tools/launchers/CodexPortable.x86.exe",
            "CodexData/tools/launchers/CodexPortable.x64.exe",
            "CodexData/tools/launchers/CodexPortable.arm64.exe",
            "CodexData/packages/LFPortable-common.zip",
            "CodexData/packages/LFPortable-x64.msix",
            "CodexData/packages/LFPortable-arm64.msix",
            ReleaseDescriptorPath
        };

        private static readonly string[] ReleaseManagedDirectories = new string[] {
            "CodexData",
            "CodexData/tools",
            "CodexData/tools/launchers",
            "CodexData/packages"
        };

        internal enum UpdateCheckStatus
        {
            NoRelease,
            UpToDate,
            NewerRelease,
            Downgrade,
            MissingAsset,
            CurrentVersionUnknown
        }

        internal enum UpdateCheckProgressStage
        {
            ContactingReleaseService,
            ValidatingReleaseMetadata,
            ReadingInstalledVersion,
            ComparingVersions,
            Complete
        }

        internal sealed class UpdateCheckProgress
        {
            internal UpdateCheckProgressStage Stage;

            internal UpdateCheckProgress(UpdateCheckProgressStage stage)
            {
                Stage = stage;
            }
        }

        internal sealed class UpdateCheckResult
        {
            internal UpdateCheckStatus Status;
            internal Version InstalledVersion;
            internal Version AvailableVersion;
            internal ReleaseAsset Asset;
        }

        internal sealed class ReleaseAsset
        {
            internal string Url;
            internal string Sha256;
            internal long Length;
            internal Version Version;
        }

        internal sealed class UpdateInstallResult
        {
            internal Version Version;
            internal bool HelperStarted;
        }

        internal enum UpdateProgressStage
        {
            VerifyingInstalledRelease,
            DownloadingRelease,
            VerifyingReleaseDownload,
            StagingRelease,
            BackingUpCurrentRelease,
            PreparingInstaller,
            InstallerReady
        }

        internal sealed class UpdateProgress
        {
            internal UpdateProgressStage Stage;
            internal long CompletedBytes;
            internal long TotalBytes;
            internal int CompletedFiles;
            internal int TotalFiles;

            internal UpdateProgress(UpdateProgressStage stage)
                : this(stage, 0, 0, 0, 0)
            {
            }

            internal UpdateProgress(UpdateProgressStage stage, long completedBytes,
                long totalBytes, int completedFiles, int totalFiles)
            {
                Stage = stage;
                CompletedBytes = completedBytes;
                TotalBytes = totalBytes;
                CompletedFiles = completedFiles;
                TotalFiles = totalFiles;
            }
        }

        private sealed class ReleaseFile
        {
            internal string Path;
            internal long Length;
            internal string Sha256;
        }

        private sealed class ReleaseDescriptor
        {
            internal Version Version;
            internal ReleaseFile[] Files;
        }

        private sealed class ReleaseArchive
        {
            internal Version Version;
            internal Dictionary<string, ReleaseFile> Files;
        }

        private sealed class ArchiveExtractionEntry
        {
            internal ZipArchiveEntry Entry;
            internal string RelativePath;
            internal string Destination;
            internal bool Directory;
        }

        // Keep the two trusted package files open for the complete execution
        // image transaction. Verification and extraction consume these exact
        // streams, while FileShare.Read prevents a USB writer from changing or
        // replacing their bytes until the transaction finishes.
        internal sealed class ExecutionImagePackageLease : IDisposable
        {
            internal readonly string CommonPackage;
            internal readonly string DesktopPackage;
            internal readonly PackageInfo DesktopInfo;
            private FileStream commonLock;
            private FileStream desktopLock;

            internal ExecutionImagePackageLease(string commonPackage, string desktopPackage,
                PackageInfo desktopInfo, FileStream commonLock, FileStream desktopLock)
            {
                CommonPackage = commonPackage;
                DesktopPackage = desktopPackage;
                DesktopInfo = desktopInfo;
                this.commonLock = commonLock;
                this.desktopLock = desktopLock;
            }

            internal FileStream CommonStream
            {
                get { return GetOpenStream(commonLock); }
            }

            internal FileStream DesktopStream
            {
                get { return GetOpenStream(desktopLock); }
            }

            private static FileStream GetOpenStream(FileStream stream)
            {
                if (stream == null || !stream.CanRead)
                    throw new ObjectDisposedException("ExecutionImagePackageLease");
                return stream;
            }

            public void Dispose()
            {
                if (desktopLock != null)
                {
                    desktopLock.Dispose();
                    desktopLock = null;
                }
                if (commonLock != null)
                {
                    commonLock.Dispose();
                    commonLock = null;
                }
            }
        }

        internal static Task<UpdateCheckResult> CheckForUpdatesAsync(PortableLayout layout)
        {
            return CheckForUpdatesAsync(layout, null);
        }

        // The startup check follows GitHub's public latest-release redirect. It
        // avoids consuming the unauthenticated REST API quota; the explicit user
        // action below still retrieves the API metadata and asset SHA-256 before
        // any download can begin.
        internal static Task<UpdateCheckResult> CheckForAutomaticUpdatesAsync(PortableLayout layout)
        {
            return Task.Run(delegate { return CheckForAutomaticUpdates(layout); });
        }

        internal static Task<UpdateCheckResult> CheckForUpdatesAsync(PortableLayout layout,
            IProgress<UpdateCheckProgress> progress)
        {
            return Task.Run(delegate { return CheckForUpdates(layout, progress); });
        }

        internal static Task<UpdateInstallResult> InstallUpdateAsync(PortableLayout layout,
            UpdateCheckResult check, IProgress<UpdateProgress> progress, int coreProcessId,
            int bootstrapperProcessId)
        {
            if (check == null) throw new ArgumentNullException("check");
            if (coreProcessId <= 0) throw new ArgumentOutOfRangeException("coreProcessId");
            if (bootstrapperProcessId < 0) throw new ArgumentOutOfRangeException("bootstrapperProcessId");
            return Task.Run(delegate {
                return DownloadAndInstall(layout, check, progress, coreProcessId, bootstrapperProcessId);
            });
        }

        private static UpdateCheckResult CheckForUpdates(PortableLayout layout,
            IProgress<UpdateCheckProgress> progress)
        {
            ReportUpdateCheckProgress(progress, UpdateCheckProgressStage.ContactingReleaseService);
            string metadata;
            try { metadata = DownloadReleaseMetadata(); }
            catch (WebException ex)
            {
                if (IsNoReleaseResponse(ex))
                {
                    ReportUpdateCheckProgress(progress, UpdateCheckProgressStage.Complete);
                    return new UpdateCheckResult { Status = UpdateCheckStatus.NoRelease };
                }
                throw;
            }

            ReportUpdateCheckProgress(progress, UpdateCheckProgressStage.ValidatingReleaseMetadata);
            Dictionary<string, object> release = ParseReleaseMetadata(metadata);
            Version available = ReadReleaseVersion(release);
            ReportUpdateCheckProgress(progress, UpdateCheckProgressStage.ReadingInstalledVersion);
            ReleaseDescriptor installedRelease = TryReadReleaseDescriptor(layout.ReleaseDescriptor);
            Version installed = installedRelease == null ? null : installedRelease.Version;
            ReportUpdateCheckProgress(progress, UpdateCheckProgressStage.ComparingVersions);
            UpdateCheckStatus status = ClassifyVersions(installed, available);
            UpdateCheckResult result = new UpdateCheckResult {
                Status = status,
                InstalledVersion = installed,
                AvailableVersion = available
            };
            if (status != UpdateCheckStatus.NewerRelease)
            {
                ReportUpdateCheckProgress(progress, UpdateCheckProgressStage.Complete);
                return result;
            }

            result.Asset = ReadReleaseAsset(release, ReleaseArchiveAssetName, available);
            if (result.Asset == null) result.Status = UpdateCheckStatus.MissingAsset;
            ReportUpdateCheckProgress(progress, UpdateCheckProgressStage.Complete);
            return result;
        }

        private static UpdateCheckResult CheckForAutomaticUpdates(PortableLayout layout)
        {
            Version available = DownloadLatestReleaseVersion();
            if (available == null) return new UpdateCheckResult { Status = UpdateCheckStatus.NoRelease };
            ReleaseDescriptor installedRelease = TryReadReleaseDescriptor(layout.ReleaseDescriptor);
            Version installed = installedRelease == null ? null : installedRelease.Version;
            return new UpdateCheckResult {
                Status = ClassifyVersions(installed, available),
                InstalledVersion = installed,
                AvailableVersion = available
            };
        }

        private static UpdateInstallResult DownloadAndInstall(PortableLayout layout,
            UpdateCheckResult check, IProgress<UpdateProgress> progress, int coreProcessId,
            int bootstrapperProcessId)
        {
            if (check.Status != UpdateCheckStatus.NewerRelease || check.Asset == null)
                throw new InvalidOperationException("A verified newer release is required before installation.");
            ReleaseAsset asset = check.Asset;
            ReleaseDescriptor installedRelease = TryReadReleaseDescriptor(layout.ReleaseDescriptor);
            if (installedRelease == null)
                throw new InvalidOperationException("The installed LF release descriptor cannot be read.");
            Version installed = installedRelease.Version;
            if (installed != null && asset.Version.CompareTo(installed) <= 0)
                throw new DowngradeRefusedException("The published version is not newer than the installed version.");

            layout.EnsureDirectories();
            string token = Guid.NewGuid().ToString("N");
            string archivePath = Path.Combine(layout.Updates, "release-download-" + token + ".zip");
            string buildTransaction = Path.Combine(layout.Updates, "release-build-" + token);
            string transaction = Path.Combine(layout.Updates, ReleaseTransactionPrefix + token);
            string helper = null;
            bool helperStarted = false;
            bool published = false;
            Mutex mutation = null;
            try
            {
                mutation = PortableProcess.AcquireMutationMutex(layout, 0);
                if (mutation == null)
                    throw new IOException("Another portable start or repair is in progress.");
                if (PortableProcess.IsDesktopRunning(layout))
                    throw new IOException("Codex Desktop must be closed before installing an update.");
                AssertNoReleaseTransaction(layout);
                installedRelease = ReadVerifiedInstalledRelease(layout, progress);
                if (asset.Version.CompareTo(installedRelease.Version) <= 0)
                    throw new DowngradeRefusedException("The published version is not newer than the installed version.");
                EnsureUpdateFreeSpace(layout, asset.Length);
                Download(archivePath, asset.Url, progress, asset.Sha256, asset.Length);
                ReleaseDescriptor currentRelease = ReadReleaseDescriptor(layout.ReleaseDescriptor,
                    "installed LF release descriptor");
                if (!ReleaseDescriptorsEqual(installedRelease, currentRelease))
                    throw new IOException("The installed LF release changed while downloading the update.");
                ReportUpdateProgress(progress, UpdateProgressStage.StagingRelease);
                Directory.CreateDirectory(buildTransaction);
                ReleaseArchive archive = StageReleaseArchive(archivePath,
                    Path.Combine(buildTransaction, "staged"), progress);
                if (!archive.Version.Equals(asset.Version))
                    throw new InvalidDataException("The LF release archive version does not match the release tag.");
                IOUtil.DeleteFileIfExists(archivePath);
                archivePath = null;
                ReportUpdateProgress(progress, UpdateProgressStage.BackingUpCurrentRelease);
                CopyInstalledRelease(layout.Root, Path.Combine(buildTransaction, "backup"), installedRelease,
                    progress);
                ReportUpdateProgress(progress, UpdateProgressStage.PreparingInstaller);
                CopyCommitDescriptor(Path.Combine(buildTransaction, "staged", "CodexData", "portable-release.json"),
                    Path.Combine(buildTransaction, "commit-descriptor.json"));
                VerifyReleaseTransaction(buildTransaction, archive.Version);
                Directory.Move(buildTransaction, transaction);
                buildTransaction = null;
                published = true;
                helper = CreateApplyHelper(layout);
                StartApplyHelper(helper, layout, Path.GetFileName(transaction), coreProcessId,
                    bootstrapperProcessId);
                helperStarted = true;
                ReportUpdateProgress(progress, UpdateProgressStage.InstallerReady);
                return new UpdateInstallResult { Version = archive.Version, HelperStarted = true };
            }
            finally
            {
                PortableProcess.ReleaseMutationMutex(mutation);
                if (!string.IsNullOrEmpty(archivePath)) IOUtil.TryDelete(archivePath);
                if (!string.IsNullOrEmpty(buildTransaction) && Directory.Exists(buildTransaction))
                {
                    try { IOUtil.DeleteDirectoryWithin(buildTransaction, layout.Updates); }
                    catch { }
                }
                if (!helperStarted) IOUtil.TryDelete(helper);
                if (!published && Directory.Exists(transaction))
                {
                    // A published-name transaction is always recovery-visible. Do not
                    // overwrite an earlier failure from this finally block; leave it
                    // for the bootstrapper's strict recovery path instead.
                    SafeLog.TryWriteEvent(layout, "release-transaction", "Unstarted release transaction retained for recovery.");
                }
            }
        }

        private static void AssertNoReleaseTransaction(PortableLayout layout)
        {
            AssertNoReparseAncestry(layout.Updates, layout.Root);
            string[] entries = Directory.GetFileSystemEntries(layout.Updates, "*",
                SearchOption.TopDirectoryOnly);
            for (int i = 0; i < entries.Length; i++)
            {
                string name = Path.GetFileName(entries[i]);
                if (IsReleaseTransactionName(name))
                    throw new IOException("An earlier LF release transaction must be recovered before updating again.");
            }
        }

        private static ReleaseDescriptor ReadVerifiedInstalledRelease(PortableLayout layout,
            IProgress<UpdateProgress> progress)
        {
            AssertNoReparseAncestry(layout.ReleaseDescriptor, layout.Root);
            ReleaseDescriptor descriptor = ReadReleaseDescriptor(layout.ReleaseDescriptor,
                "installed LF release descriptor");
            VerifyManagedFiles(layout.Root, descriptor, "installed LF release", progress,
                UpdateProgressStage.VerifyingInstalledRelease);
            return descriptor;
        }

        private static void EnsureUpdateFreeSpace(PortableLayout layout, long assetLength)
        {
            if (assetLength <= 0) return;
            long required = checked(assetLength + UpdateFreeSpaceReserveBytes);
            EnsureFreeSpace(layout.Root, required);
        }

        private static void EnsureFreeSpace(string path, long required)
        {
            DriveInfo drive = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(path)));
            if (!drive.IsReady || drive.AvailableFreeSpace < required)
                throw new IOException("Insufficient free space for the LF release update transaction.");
        }

        private static void ReportUpdateProgress(IProgress<UpdateProgress> progress,
            UpdateProgressStage stage)
        {
            ReportUpdateProgress(progress, stage, 0, 0, 0, 0);
        }

        private static void ReportUpdateProgress(IProgress<UpdateProgress> progress,
            UpdateProgressStage stage, long completedBytes, long totalBytes,
            int completedFiles, int totalFiles)
        {
            if (progress != null) progress.Report(new UpdateProgress(stage, completedBytes,
                totalBytes, completedFiles, totalFiles));
        }

        private static void ReportUpdateCheckProgress(IProgress<UpdateCheckProgress> progress,
            UpdateCheckProgressStage stage)
        {
            if (progress != null) progress.Report(new UpdateCheckProgress(stage));
        }

        private static ReleaseArchive StageReleaseArchive(string archivePath, string stagedRoot,
            IProgress<UpdateProgress> progress)
        {
            if (!File.Exists(archivePath)) throw new FileNotFoundException("LF release archive is missing.", archivePath);
            Directory.CreateDirectory(stagedRoot);
            AssertNoReparseAncestry(stagedRoot, Path.GetDirectoryName(stagedRoot));
            using (FileStream stream = new FileStream(archivePath, FileMode.Open, FileAccess.Read,
                FileShare.Read, 1024 * 1024, FileOptions.SequentialScan))
            using (ZipArchive archive = new ZipArchive(stream, ZipArchiveMode.Read, false))
            {
                if (archive.Entries.Count != ReleaseManagedFiles.Length + 1)
                    throw new InvalidDataException("LF release archive entry count is invalid.");
                Dictionary<string, ZipArchiveEntry> entries = new Dictionary<string, ZipArchiveEntry>(StringComparer.Ordinal);
                HashSet<string> caseInsensitive = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                for (int i = 0; i < archive.Entries.Count; i++)
                {
                    ZipArchiveEntry entry = archive.Entries[i];
                    string relative = ValidateReleaseArchivePath(entry.FullName);
                    AssertReleaseArchiveEntryAttributes(entry);
                    if (!caseInsensitive.Add(relative) || entries.ContainsKey(relative))
                        throw new InvalidDataException("LF release archive contains a duplicate entry.");
                    entries.Add(relative, entry);
                }

                ZipArchiveEntry manifestEntry;
                if (!entries.TryGetValue(ReleaseManifestEntry, out manifestEntry))
                    throw new InvalidDataException("LF release archive manifest is missing.");
                Dictionary<string, object> manifest = ReadZipJsonObject(manifestEntry,
                    MaximumReleaseManifestBytes, "LF release archive manifest");
                ReleaseArchive contract = ParseReleaseArchiveManifest(manifest);

                long stagedBytes = 0;
                for (int i = 0; i < ReleaseManagedFiles.Length; i++)
                {
                    ReleaseFile metadata = contract.Files[ReleaseManagedFiles[i]];
                    if (stagedBytes > long.MaxValue - metadata.Length)
                        throw new InvalidDataException("LF release archive size totals overflow.");
                    stagedBytes += metadata.Length;
                }
                EnsureFreeSpace(stagedRoot, checked(stagedBytes + UpdateFreeSpaceReserveBytes));

                long completedBytes = 0;
                int completedFiles = 0;
                Stopwatch reporter = Stopwatch.StartNew();
                ReportUpdateProgress(progress, UpdateProgressStage.StagingRelease,
                    completedBytes, stagedBytes, completedFiles, ReleaseManagedFiles.Length);
                foreach (KeyValuePair<string, ZipArchiveEntry> pair in entries)
                {
                    if (string.Equals(pair.Key, ReleaseManifestEntry, StringComparison.Ordinal)) continue;
                    ReleaseFile metadata;
                    if (!contract.Files.TryGetValue(pair.Key, out metadata))
                        throw new InvalidDataException("LF release archive contains an unexpected managed file.");
                    ExtractReleaseEntry(pair.Value, stagedRoot, metadata, delegate(long copied)
                    {
                        completedBytes += copied;
                        if (reporter.ElapsedMilliseconds >= ProgressReportIntervalMilliseconds)
                        {
                            ReportUpdateProgress(progress, UpdateProgressStage.StagingRelease,
                                completedBytes, stagedBytes, completedFiles, ReleaseManagedFiles.Length);
                            reporter.Restart();
                        }
                    });
                    completedFiles++;
                    if (reporter.ElapsedMilliseconds >= ProgressReportIntervalMilliseconds ||
                        completedFiles == ReleaseManagedFiles.Length)
                    {
                        ReportUpdateProgress(progress, UpdateProgressStage.StagingRelease,
                            completedBytes, stagedBytes, completedFiles, ReleaseManagedFiles.Length);
                        reporter.Restart();
                    }
                }
                VerifyManagedTree(stagedRoot, contract.Files, "staged LF release");
                ReleaseDescriptor descriptor = ReadReleaseDescriptor(
                    Path.Combine(stagedRoot, ToNativeRelativePath(ReleaseDescriptorPath)),
                    "staged LF release descriptor");
                if (!descriptor.Version.Equals(contract.Version))
                    throw new InvalidDataException("LF release descriptor version differs from the archive manifest.");
                VerifyDescriptorAgainstManifest(descriptor, contract.Files);
                VerifyManagedFiles(stagedRoot, descriptor, "staged LF release");
                return contract;
            }
        }

        private static ReleaseArchive ParseReleaseArchiveManifest(Dictionary<string, object> manifest)
        {
            if (ReadRequiredInt(manifest, "SchemaVersion", "LF release manifest") != 4 ||
                !string.Equals(ReadRequiredString(manifest, "Package", "LF release manifest"),
                    "Codex Portable USB", StringComparison.Ordinal) ||
                !string.Equals(ReadRequiredString(manifest, "Packaging", "LF release manifest"),
                    "CompressedFirstRun", StringComparison.Ordinal))
                throw new InvalidDataException("LF release archive manifest contract is unsupported.");
            Version launcherVersion = ParseFourPartVersion(ReadRequiredString(manifest,
                "LauncherVersion", "LF release manifest"), "LF release manifest launcher version");
            Version releaseVersion = ParseFourPartVersion(ReadRequiredString(manifest,
                "ReleaseVersion", "LF release manifest"), "LF release manifest release version");
            if (!launcherVersion.Equals(releaseVersion))
                throw new InvalidDataException("LF release manifest versions differ.");
            if (ReadRequiredInt(manifest, "FileCount", "LF release manifest") != ReleaseManagedFiles.Length)
                throw new InvalidDataException("LF release manifest file count is invalid.");
            Dictionary<string, object> managedSummary = ReadRequiredObject(manifest,
                "ManagedSummary", "LF release manifest");
            if (ReadRequiredInt(managedSummary, "FileCount", "LF release managed summary") !=
                ReleaseManagedFiles.Length)
                throw new InvalidDataException("LF release managed file count is invalid.");

            Dictionary<string, ReleaseFile> files = new Dictionary<string, ReleaseFile>(StringComparer.Ordinal);
            IEnumerable values = ReadRequiredEnumerable(manifest, "Files", "LF release manifest");
            foreach (object value in values)
            {
                Dictionary<string, object> entry = value as Dictionary<string, object>;
                AssertExactProperties(entry, new string[] { "Path", "Length", "Sha256" },
                    "LF release manifest file");
                string relative = ReadRequiredString(entry, "Path", "LF release manifest file");
                if (!IsReleaseManagedFile(relative) || files.ContainsKey(relative))
                    throw new InvalidDataException("LF release manifest contains an unexpected or duplicate file.");
                long length = ReadRequiredLong(entry, "Length", "LF release manifest file");
                if (length <= 0) throw new InvalidDataException("LF release manifest contains an invalid file length.");
                files.Add(relative, new ReleaseFile {
                    Path = relative,
                    Length = length,
                    Sha256 = NormalizeSha256(ReadRequiredString(entry, "Sha256", "LF release manifest file"))
                });
            }
            if (files.Count != ReleaseManagedFiles.Length)
                throw new InvalidDataException("LF release manifest does not declare every managed file.");
            for (int i = 0; i < ReleaseManagedFiles.Length; i++)
                if (!files.ContainsKey(ReleaseManagedFiles[i]))
                    throw new InvalidDataException("LF release manifest is missing a managed file.");

            string launcherSha = NormalizeSha256(ReadRequiredString(manifest, "LauncherSha256",
                "LF release manifest"));
            if (!string.Equals(launcherSha, files["CodexPortable.exe"].Sha256,
                StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("LF release manifest launcher hash is inconsistent.");
            Dictionary<string, object> descriptorMetadata = ReadRequiredObject(manifest,
                "PortableReleaseDescriptor", "LF release manifest");
            AssertExactProperties(descriptorMetadata, new string[] {
                "Path", "SchemaVersion", "ReleaseVersion", "LauncherVersion", "FileCount", "Length", "Sha256"
            }, "LF release descriptor metadata");
            if (!string.Equals(ReadRequiredString(descriptorMetadata, "Path", "LF release descriptor metadata"),
                    ReleaseDescriptorPath, StringComparison.Ordinal) ||
                ReadRequiredInt(descriptorMetadata, "SchemaVersion", "LF release descriptor metadata") != 1 ||
                ReadRequiredInt(descriptorMetadata, "FileCount", "LF release descriptor metadata") != ReleaseContentFiles.Length ||
                !ParseFourPartVersion(ReadRequiredString(descriptorMetadata, "ReleaseVersion",
                    "LF release descriptor metadata"), "LF release descriptor metadata").Equals(releaseVersion) ||
                !ParseFourPartVersion(ReadRequiredString(descriptorMetadata, "LauncherVersion",
                    "LF release descriptor metadata"), "LF release descriptor metadata").Equals(releaseVersion) ||
                ReadRequiredLong(descriptorMetadata, "Length", "LF release descriptor metadata") !=
                    files[ReleaseDescriptorPath].Length ||
                !string.Equals(NormalizeSha256(ReadRequiredString(descriptorMetadata, "Sha256",
                    "LF release descriptor metadata")), files[ReleaseDescriptorPath].Sha256,
                    StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("LF release descriptor metadata is inconsistent.");
            return new ReleaseArchive { Version = releaseVersion, Files = files };
        }

        private static void ExtractReleaseEntry(ZipArchiveEntry entry, string stagedRoot,
            ReleaseFile expected, Action<long> copied)
        {
            if (entry.Length != expected.Length || entry.CompressedLength < 0)
                throw new InvalidDataException("LF release archive entry length differs from its manifest: " + expected.Path);
            string destination = Path.Combine(stagedRoot, ToNativeRelativePath(expected.Path));
            string directory = Path.GetDirectoryName(destination);
            Directory.CreateDirectory(directory);
            AssertNoReparseAncestry(directory, stagedRoot);
            byte[] buffer = new byte[1024 * 1024];
            byte[] digest = null;
            long written = 0;
            try
            {
                using (SHA256 sha = SHA256.Create())
                using (Stream input = entry.Open())
                using (FileStream output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write,
                    FileShare.None, buffer.Length, FileOptions.SequentialScan | FileOptions.WriteThrough))
                {
                    int read;
                    while ((read = input.Read(buffer, 0, buffer.Length)) != 0)
                    {
                        written += read;
                        if (written > expected.Length)
                            throw new InvalidDataException("LF release archive entry expanded past its declared length.");
                        output.Write(buffer, 0, read);
                        sha.TransformBlock(buffer, 0, read, buffer, 0);
                        if (copied != null) copied(read);
                    }
                    output.Flush(true);
                    sha.TransformFinalBlock(buffer, 0, 0);
                    digest = sha.Hash;
                }
                if (written != expected.Length || !string.Equals(ToHex(digest), expected.Sha256,
                    StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("LF release archive entry hash differs from its manifest: " + expected.Path);
            }
            finally
            {
                Array.Clear(buffer, 0, buffer.Length);
                if (digest != null) Array.Clear(digest, 0, digest.Length);
            }
        }

        private static Dictionary<string, object> ReadZipJsonObject(ZipArchiveEntry entry,
            int maximumBytes, string label)
        {
            if (entry.Length <= 0 || entry.Length > maximumBytes)
                throw new InvalidDataException(label + " size is invalid.");
            byte[] bytes = new byte[(int)entry.Length];
            try
            {
                using (Stream stream = entry.Open())
                {
                    int offset = 0;
                    while (offset < bytes.Length)
                    {
                        int read = stream.Read(bytes, offset, bytes.Length - offset);
                        if (read == 0) throw new EndOfStreamException(label + " is incomplete.");
                        offset += read;
                    }
                    if (stream.ReadByte() != -1) throw new InvalidDataException(label + " is longer than declared.");
                }
                return ParseJsonObject(bytes, maximumBytes, label);
            }
            finally { Array.Clear(bytes, 0, bytes.Length); }
        }

        private static Dictionary<string, object> ParseJsonObject(byte[] bytes, int maximumBytes,
            string label)
        {
            string text;
            try { text = new UTF8Encoding(false, true).GetString(bytes); }
            catch (Exception ex) { throw new InvalidDataException(label + " is not strict UTF-8.", ex); }
            if (text.Length == 0 || text[0] == '\uFEFF')
                throw new InvalidDataException(label + " is empty or has a byte-order mark.");
            try
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                serializer.MaxJsonLength = maximumBytes;
                serializer.RecursionLimit = 64;
                Dictionary<string, object> parsed = serializer.Deserialize<Dictionary<string, object>>(text);
                if (parsed == null) throw new InvalidDataException(label + " is not a JSON object.");
                return parsed;
            }
            catch (InvalidDataException) { throw; }
            catch (Exception ex) { throw new InvalidDataException(label + " contains invalid JSON.", ex); }
        }

        private static string ValidateReleaseArchivePath(string value)
        {
            if (string.IsNullOrEmpty(value) || value.StartsWith("/", StringComparison.Ordinal) ||
                value.StartsWith("\\", StringComparison.Ordinal) || value.IndexOf(':') >= 0 ||
                value.IndexOf('\\') >= 0 || value.EndsWith("/", StringComparison.Ordinal) ||
                value.IndexOfAny(new char[] { '\0', '\r', '\n' }) >= 0)
                throw new InvalidDataException("LF release archive contains an unsafe path.");
            string[] segments = value.Split('/');
            for (int i = 0; i < segments.Length; i++)
            {
                string segment = segments[i];
                if (segment.Length == 0 || segment == "." || segment == ".." ||
                    segment.EndsWith(".", StringComparison.Ordinal) || segment.EndsWith(" ", StringComparison.Ordinal) ||
                    IsReservedWindowsName(segment))
                    throw new InvalidDataException("LF release archive contains a Windows-unsafe path.");
            }
            if (!string.Equals(value, ReleaseManifestEntry, StringComparison.Ordinal) &&
                !IsReleaseManagedFile(value))
                throw new InvalidDataException("LF release archive contains an unexpected entry.");
            return value;
        }

        private static bool IsReservedWindowsName(string value)
        {
            string stem = value;
            int dot = stem.IndexOf('.');
            if (dot >= 0) stem = stem.Substring(0, dot);
            stem = stem.ToUpperInvariant();
            if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" || stem == "CLOCK$") return true;
            if (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) ||
                stem.StartsWith("LPT", StringComparison.Ordinal)) && stem[3] >= '1' && stem[3] <= '9') return true;
            return false;
        }

        private static void AssertReleaseArchiveEntryAttributes(ZipArchiveEntry entry)
        {
            uint attributes = unchecked((uint)entry.ExternalAttributes);
            uint unixType = (attributes >> 16) & 0xF000;
            if (unixType == 0xA000 || (attributes & 0x400) != 0)
                throw new InvalidDataException("LF release archive contains a link or reparse-point entry.");
        }

        private static ReleaseDescriptor TryReadReleaseDescriptor(string path)
        {
            try { return ReadReleaseDescriptor(path, "installed LF release descriptor"); }
            catch { return null; }
        }

        private static ReleaseDescriptor ReadReleaseDescriptor(string path, string label)
        {
            if (!IsRegularFile(path)) throw new FileNotFoundException(label + " is missing.", path);
            FileInfo info = new FileInfo(path);
            if (info.Length <= 0 || info.Length > MaximumReleaseDescriptorBytes)
                throw new InvalidDataException(label + " size is invalid.");
            byte[] bytes = File.ReadAllBytes(path);
            try
            {
                Dictionary<string, object> descriptor = ParseJsonObject(bytes,
                    MaximumReleaseDescriptorBytes, label);
                AssertExactProperties(descriptor, new string[] {
                    "SchemaVersion", "ReleaseVersion", "LauncherVersion", "Files"
                }, label);
                if (ReadRequiredInt(descriptor, "SchemaVersion", label) != 1)
                    throw new InvalidDataException(label + " schema is unsupported.");
                Version releaseVersion = ParseFourPartVersion(ReadRequiredString(descriptor,
                    "ReleaseVersion", label), label + " release version");
                if (!ParseFourPartVersion(ReadRequiredString(descriptor, "LauncherVersion", label),
                    label + " launcher version").Equals(releaseVersion))
                    throw new InvalidDataException(label + " versions differ.");
                Dictionary<string, ReleaseFile> files = new Dictionary<string, ReleaseFile>(StringComparer.Ordinal);
                IEnumerable values = ReadRequiredEnumerable(descriptor, "Files", label);
                foreach (object value in values)
                {
                    Dictionary<string, object> entry = value as Dictionary<string, object>;
                    AssertExactProperties(entry, new string[] { "Path", "Length", "Sha256" },
                        label + " file");
                    string relative = ReadRequiredString(entry, "Path", label + " file");
                    if (!IsReleaseContentFile(relative) || files.ContainsKey(relative))
                        throw new InvalidDataException(label + " contains an unexpected or duplicate file.");
                    long length = ReadRequiredLong(entry, "Length", label + " file");
                    if (length <= 0) throw new InvalidDataException(label + " contains an invalid length.");
                    files.Add(relative, new ReleaseFile {
                        Path = relative,
                        Length = length,
                        Sha256 = NormalizeSha256(ReadRequiredString(entry, "Sha256", label + " file"))
                    });
                }
                if (files.Count != ReleaseContentFiles.Length)
                    throw new InvalidDataException(label + " file count is invalid.");
                ReleaseFile[] ordered = new ReleaseFile[ReleaseContentFiles.Length];
                for (int i = 0; i < ReleaseContentFiles.Length; i++)
                {
                    if (!files.TryGetValue(ReleaseContentFiles[i], out ordered[i]))
                        throw new InvalidDataException(label + " is missing a managed file.");
                }
                return new ReleaseDescriptor { Version = releaseVersion, Files = ordered };
            }
            finally { Array.Clear(bytes, 0, bytes.Length); }
        }

        private static void VerifyDescriptorAgainstManifest(ReleaseDescriptor descriptor,
            Dictionary<string, ReleaseFile> manifestFiles)
        {
            for (int i = 0; i < descriptor.Files.Length; i++)
            {
                ReleaseFile expected = manifestFiles[descriptor.Files[i].Path];
                if (descriptor.Files[i].Length != expected.Length ||
                    !string.Equals(descriptor.Files[i].Sha256, expected.Sha256,
                        StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("LF release descriptor differs from the archive manifest.");
            }
        }

        private static void VerifyManagedFiles(string root, ReleaseDescriptor descriptor, string label)
        {
            VerifyManagedFiles(root, descriptor, label, null,
                UpdateProgressStage.VerifyingInstalledRelease);
        }

        private static void VerifyManagedFiles(string root, ReleaseDescriptor descriptor, string label,
            IProgress<UpdateProgress> progress, UpdateProgressStage progressStage)
        {
            long totalBytes = 0;
            for (int i = 0; i < descriptor.Files.Length; i++)
                totalBytes = checked(totalBytes + descriptor.Files[i].Length);
            long completedBytes = 0;
            int completedFiles = 0;
            Stopwatch reporter = Stopwatch.StartNew();
            ReportUpdateProgress(progress, progressStage, completedBytes, totalBytes,
                completedFiles, descriptor.Files.Length);
            for (int i = 0; i < descriptor.Files.Length; i++)
            {
                string path = Path.Combine(root, ToNativeRelativePath(descriptor.Files[i].Path));
                AssertNoReparseAncestry(path, root);
                VerifyFile(path, descriptor.Files[i], label, delegate(long copied)
                {
                    completedBytes += copied;
                    if (reporter.ElapsedMilliseconds >= ProgressReportIntervalMilliseconds)
                    {
                        ReportUpdateProgress(progress, progressStage, completedBytes, totalBytes,
                            completedFiles, descriptor.Files.Length);
                        reporter.Restart();
                    }
                });
                completedFiles++;
                ReportUpdateProgress(progress, progressStage, completedBytes, totalBytes,
                    completedFiles, descriptor.Files.Length);
            }
        }

        private static bool ReleaseDescriptorsEqual(ReleaseDescriptor first, ReleaseDescriptor second)
        {
            if (first == null || second == null || !first.Version.Equals(second.Version) ||
                first.Files.Length != second.Files.Length) return false;
            for (int i = 0; i < first.Files.Length; i++)
            {
                if (!string.Equals(first.Files[i].Path, second.Files[i].Path, StringComparison.Ordinal) ||
                    first.Files[i].Length != second.Files[i].Length ||
                    !string.Equals(first.Files[i].Sha256, second.Files[i].Sha256,
                        StringComparison.OrdinalIgnoreCase)) return false;
            }
            return true;
        }

        private static void VerifyDescriptorManagedTree(string root, ReleaseDescriptor descriptor,
            string label)
        {
            AssertNoReparsePointsUnder(root);
            List<string> directories = new List<string>();
            string[] foundDirectories = Directory.GetDirectories(root, "*", SearchOption.AllDirectories);
            for (int i = 0; i < foundDirectories.Length; i++)
                directories.Add(GetRelativeReleasePath(root, foundDirectories[i]));
            AssertExactSet(ReleaseManagedDirectories, directories, label + " directories");
            List<string> files = new List<string>();
            string[] foundFiles = Directory.GetFiles(root, "*", SearchOption.AllDirectories);
            for (int i = 0; i < foundFiles.Length; i++)
                files.Add(GetRelativeReleasePath(root, foundFiles[i]));
            AssertExactSet(ReleaseManagedFiles, files, label + " files");
            VerifyManagedFiles(root, descriptor, label);
        }

        private static void VerifyManagedTree(string root,
            Dictionary<string, ReleaseFile> expected, string label)
        {
            AssertNoReparsePointsUnder(root);
            List<string> directories = new List<string>();
            string[] foundDirectories = Directory.GetDirectories(root, "*", SearchOption.AllDirectories);
            for (int i = 0; i < foundDirectories.Length; i++)
                directories.Add(GetRelativeReleasePath(root, foundDirectories[i]));
            AssertExactSet(ReleaseManagedDirectories, directories, label + " directories");
            List<string> files = new List<string>();
            string[] foundFiles = Directory.GetFiles(root, "*", SearchOption.AllDirectories);
            for (int i = 0; i < foundFiles.Length; i++)
                files.Add(GetRelativeReleasePath(root, foundFiles[i]));
            AssertExactSet(ReleaseManagedFiles, files, label + " files");
            for (int i = 0; i < ReleaseManagedFiles.Length; i++)
                VerifyFile(Path.Combine(root, ToNativeRelativePath(ReleaseManagedFiles[i])),
                    expected[ReleaseManagedFiles[i]], label);
        }

        private static void CopyInstalledRelease(string sourceRoot, string backupRoot,
            ReleaseDescriptor descriptor, IProgress<UpdateProgress> progress)
        {
            long descriptorLength = new FileInfo(Path.Combine(sourceRoot,
                ToNativeRelativePath(ReleaseDescriptorPath))).Length;
            long total = descriptorLength;
            for (int i = 0; i < descriptor.Files.Length; i++) total = checked(total + descriptor.Files[i].Length);
            EnsureFreeSpace(backupRoot, checked(total + UpdateFreeSpaceReserveBytes));
            Directory.CreateDirectory(backupRoot);
            long completedBytes = 0;
            int completedFiles = 0;
            int totalFiles = descriptor.Files.Length + 1;
            ReportUpdateProgress(progress, UpdateProgressStage.BackingUpCurrentRelease,
                completedBytes, total, completedFiles, totalFiles);
            for (int i = 0; i < descriptor.Files.Length; i++)
            {
                string source = Path.Combine(sourceRoot, ToNativeRelativePath(descriptor.Files[i].Path));
                string target = Path.Combine(backupRoot, ToNativeRelativePath(descriptor.Files[i].Path));
                CopyVerifiedFile(source, target, backupRoot, descriptor.Files[i]);
                completedBytes += descriptor.Files[i].Length;
                completedFiles++;
                ReportUpdateProgress(progress, UpdateProgressStage.BackingUpCurrentRelease,
                    completedBytes, total, completedFiles, totalFiles);
            }
            string descriptorSource = Path.Combine(sourceRoot, ToNativeRelativePath(ReleaseDescriptorPath));
            string descriptorTarget = Path.Combine(backupRoot, ToNativeRelativePath(ReleaseDescriptorPath));
            CopyByteIdenticalFile(descriptorSource, descriptorTarget, MaximumReleaseDescriptorBytes);
            completedBytes += descriptorLength;
            completedFiles++;
            ReportUpdateProgress(progress, UpdateProgressStage.BackingUpCurrentRelease,
                completedBytes, total, completedFiles, totalFiles);
            ReleaseDescriptor copied = ReadReleaseDescriptor(descriptorTarget, "LF release backup descriptor");
            if (!copied.Version.Equals(descriptor.Version))
                throw new InvalidDataException("LF release backup descriptor version changed.");
            VerifyManagedFiles(backupRoot, copied, "LF release backup");
        }

        private static void CopyCommitDescriptor(string source, string destination)
        {
            CopyByteIdenticalFile(source, destination, MaximumReleaseDescriptorBytes);
        }

        private static void VerifyReleaseTransaction(string transactionRoot, Version expectedVersion)
        {
            AssertNoReparsePointsUnder(transactionRoot);
            List<string> rootEntries = new List<string>();
            string[] entries = Directory.GetFileSystemEntries(transactionRoot, "*", SearchOption.TopDirectoryOnly);
            for (int i = 0; i < entries.Length; i++) rootEntries.Add(Path.GetFileName(entries[i]));
            AssertExactSet(new string[] { "backup", "staged", "commit-descriptor.json" },
                rootEntries, "LF release transaction root");
            string commitDescriptor = Path.Combine(transactionRoot, "commit-descriptor.json");
            string stagedDescriptor = Path.Combine(transactionRoot, "staged", "CodexData", "portable-release.json");
            if (!FilesEqual(commitDescriptor, stagedDescriptor, MaximumReleaseDescriptorBytes))
                throw new InvalidDataException("LF release transaction commit descriptor differs from staged release.");
            ReleaseDescriptor next = ReadReleaseDescriptor(commitDescriptor, "LF release commit descriptor");
            if (!next.Version.Equals(expectedVersion))
                throw new InvalidDataException("LF release transaction version changed.");
            VerifyDescriptorManagedTree(Path.Combine(transactionRoot, "staged"), next,
                "staged LF release");
            ReleaseDescriptor previous = ReadReleaseDescriptor(Path.Combine(transactionRoot,
                "backup", "CodexData", "portable-release.json"), "LF release backup descriptor");
            VerifyDescriptorManagedTree(Path.Combine(transactionRoot, "backup"), previous,
                "LF release backup");
        }

        private static string CreateApplyHelper(PortableLayout layout)
        {
            string source = Path.Combine(layout.Root, "CodexPortable.exe");
            if (!IsRegularFile(source)) throw new FileNotFoundException("LF bootstrapper is missing.", source);
            string directory = Path.Combine(Path.GetTempPath(), "LFPortable", "release-update");
            Directory.CreateDirectory(directory);
            string helper = Path.Combine(directory, "lf-release-apply-" + Guid.NewGuid().ToString("N") + ".exe");
            if (IsPathWithin(helper, layout.Root))
                throw new InvalidOperationException("LF release helper cannot run from the portable root.");
            File.Copy(source, helper, false);
            if (!FilesEqual(source, helper, -1))
                throw new IOException("LF release helper copy did not verify.");
            return helper;
        }

        private static void StartApplyHelper(string helper, PortableLayout layout,
            string transactionName, int coreProcessId, int bootstrapperProcessId)
        {
            if (!IsReleaseTransactionName(transactionName))
                throw new InvalidDataException("LF release transaction name is invalid.");
            ProcessStartInfo info = new ProcessStartInfo();
            info.FileName = helper;
            info.Arguments = "--apply-release " + IOUtil.QuoteArgument(layout.Root) + " " +
                IOUtil.QuoteArgument(transactionName) + " " +
                coreProcessId.ToString(CultureInfo.InvariantCulture) + " " +
                bootstrapperProcessId.ToString(CultureInfo.InvariantCulture);
            info.WorkingDirectory = layout.Root;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            using (Process process = Process.Start(info))
            {
                if (process == null) throw new InvalidOperationException("LF release helper could not start.");
            }
        }

        private static void CopyVerifiedFile(string source, string destination, string protectedRoot,
            ReleaseFile expected)
        {
            VerifyFile(source, expected, "installed LF release");
            Directory.CreateDirectory(Path.GetDirectoryName(destination));
            AssertNoReparseAncestry(Path.GetDirectoryName(destination), protectedRoot);
            File.Copy(source, destination, false);
            VerifyFile(destination, expected, "LF release backup");
        }

        private static void CopyByteIdenticalFile(string source, string destination, long maximumBytes)
        {
            if (!IsRegularFile(source)) throw new FileNotFoundException("LF release source file is missing.", source);
            FileInfo info = new FileInfo(source);
            if (info.Length <= 0 || (maximumBytes >= 0 && info.Length > maximumBytes))
                throw new InvalidDataException("LF release source file size is invalid.");
            Directory.CreateDirectory(Path.GetDirectoryName(destination));
            File.Copy(source, destination, false);
            if (!FilesEqual(source, destination, maximumBytes))
                throw new IOException("LF release byte-identical copy did not verify.");
        }

        private static void VerifyFile(string path, ReleaseFile expected, string label)
        {
            VerifyFile(path, expected, label, null);
        }

        private static void VerifyFile(string path, ReleaseFile expected, string label,
            Action<long> progress)
        {
            if (!IsRegularFile(path)) throw new FileNotFoundException(label + " file is missing.", path);
            FileInfo info = new FileInfo(path);
            if (info.Length != expected.Length ||
                !string.Equals(ComputeFileSha256(path, progress), expected.Sha256,
                    StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException(label + " file hash or length differs: " + expected.Path);
        }

        private static void VerifyFile(Stream stream, ReleaseFile expected, string label,
            Action<long> progress)
        {
            if (stream == null) throw new ArgumentNullException("stream");
            if (!stream.CanRead || !stream.CanSeek)
                throw new ArgumentException("The verified file stream must be readable and seekable.",
                    "stream");
            if (stream.Length != expected.Length)
                throw new InvalidDataException(label + " file hash or length differs: " + expected.Path);
            long completed = 0;
            string digest = ComputeFileSha256(stream, delegate(long bytes)
            {
                completed += bytes;
                if (progress != null) progress(bytes);
            });
            if (completed != expected.Length || stream.Length != expected.Length ||
                !string.Equals(digest, expected.Sha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException(label + " file hash or length differs: " + expected.Path);
        }

        private static string ComputeFileSha256(string path, Action<long> progress)
        {
            byte[] buffer = new byte[1024 * 1024];
            byte[] digest = null;
            try
            {
                using (SHA256 sha = SHA256.Create())
                using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                    FileShare.Read, buffer.Length, FileOptions.SequentialScan))
                {
                    while (true)
                    {
                        int read = stream.Read(buffer, 0, buffer.Length);
                        if (read == 0) break;
                        sha.TransformBlock(buffer, 0, read, buffer, 0);
                        if (progress != null) progress(read);
                    }
                    sha.TransformFinalBlock(buffer, 0, 0);
                    digest = sha.Hash;
                }
                return ToHex(digest);
            }
            finally
            {
                Array.Clear(buffer, 0, buffer.Length);
                if (digest != null) Array.Clear(digest, 0, digest.Length);
            }
        }

        private static string ComputeFileSha256(Stream stream, Action<long> progress)
        {
            byte[] buffer = new byte[1024 * 1024];
            byte[] digest = null;
            stream.Position = 0;
            try
            {
                using (SHA256 sha = SHA256.Create())
                {
                    while (true)
                    {
                        int read = stream.Read(buffer, 0, buffer.Length);
                        if (read == 0) break;
                        sha.TransformBlock(buffer, 0, read, buffer, 0);
                        if (progress != null) progress(read);
                    }
                    sha.TransformFinalBlock(buffer, 0, 0);
                    digest = sha.Hash;
                }
                return ToHex(digest);
            }
            finally
            {
                stream.Position = 0;
                Array.Clear(buffer, 0, buffer.Length);
                if (digest != null) Array.Clear(digest, 0, digest.Length);
            }
        }

        private static bool FilesEqual(string first, string second, long maximumBytes)
        {
            if (!IsRegularFile(first) || !IsRegularFile(second)) return false;
            FileInfo firstInfo = new FileInfo(first);
            FileInfo secondInfo = new FileInfo(second);
            if (firstInfo.Length != secondInfo.Length || firstInfo.Length < 0 ||
                (maximumBytes >= 0 && firstInfo.Length > maximumBytes)) return false;
            byte[] firstBuffer = new byte[64 * 1024];
            byte[] secondBuffer = new byte[64 * 1024];
            try
            {
                using (FileStream firstStream = File.OpenRead(first))
                using (FileStream secondStream = File.OpenRead(second))
                {
                    while (true)
                    {
                        int firstRead = firstStream.Read(firstBuffer, 0, firstBuffer.Length);
                        int secondRead = secondStream.Read(secondBuffer, 0, secondBuffer.Length);
                        if (firstRead != secondRead) return false;
                        if (firstRead == 0) return true;
                        for (int i = 0; i < firstRead; i++) if (firstBuffer[i] != secondBuffer[i]) return false;
                    }
                }
            }
            finally
            {
                Array.Clear(firstBuffer, 0, firstBuffer.Length);
                Array.Clear(secondBuffer, 0, secondBuffer.Length);
            }
        }

        private static bool IsRegularFile(string path)
        {
            try
            {
                return File.Exists(path) &&
                    (File.GetAttributes(path) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) == 0;
            }
            catch { return false; }
        }

        private static void AssertNoReparseAncestry(string path, string root)
        {
            string current = GetFullPathLongSafe(path).TrimEnd('\\');
            string boundary = GetFullPathLongSafe(root).TrimEnd('\\');
            if (!IsPathWithin(current, boundary))
                throw new InvalidDataException("LF release path is outside its protected root.");
            while (true)
            {
                uint attributes = NativeMethods.GetFileAttributes(ToExtendedPath(current));
                if (attributes != NativeMethods.InvalidFileAttributes &&
                    (attributes & (uint)FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("LF release path contains a reparse point.");
                if (string.Equals(current, boundary, StringComparison.OrdinalIgnoreCase)) return;
                string parent = GetPathParentLongSafe(current);
                if (string.IsNullOrEmpty(parent) || string.Equals(parent, current,
                    StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("LF release path hierarchy is invalid.");
                current = parent.TrimEnd('\\');
            }
        }

        private static void AssertNoReparsePointsUnder(string root)
        {
            Stack<string> pending = new Stack<string>();
            pending.Push(root);
            while (pending.Count != 0)
            {
                string current = pending.Pop();
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("LF release tree contains a reparse point.");
                string[] entries = Directory.GetFileSystemEntries(current, "*", SearchOption.TopDirectoryOnly);
                for (int i = 0; i < entries.Length; i++)
                {
                    FileAttributes attributes = File.GetAttributes(entries[i]);
                    if ((attributes & FileAttributes.ReparsePoint) != 0)
                        throw new InvalidDataException("LF release tree contains a reparse point.");
                    if ((attributes & FileAttributes.Directory) != 0) pending.Push(entries[i]);
                }
            }
        }

        private static bool IsPathWithin(string candidate, string root)
        {
            string fullCandidate = GetFullPathLongSafe(candidate).TrimEnd('\\');
            string fullRoot = GetFullPathLongSafe(root).TrimEnd('\\');
            return string.Equals(fullCandidate, fullRoot, StringComparison.OrdinalIgnoreCase) ||
                fullCandidate.StartsWith(fullRoot + "\\", StringComparison.OrdinalIgnoreCase);
        }

        private static string GetFullPathLongSafe(string path)
        {
            if (string.IsNullOrEmpty(path)) throw new ArgumentException("Path is empty.", "path");
            string normalized = path.Replace('/', '\\');
            if (normalized.StartsWith("\\\\?\\UNC\\", StringComparison.OrdinalIgnoreCase))
                normalized = "\\\\" + normalized.Substring(8);
            else if (normalized.StartsWith("\\\\?\\", StringComparison.Ordinal))
                normalized = normalized.Substring(4);

            bool driveAbsolute = normalized.Length >= 3 && normalized[1] == ':' && normalized[2] == '\\';
            bool uncAbsolute = normalized.StartsWith("\\\\", StringComparison.Ordinal);
            if (normalized.Length < 240 || (!driveAbsolute && !uncAbsolute))
                return Path.GetFullPath(normalized);

            string[] segments = normalized.Split('\\');
            for (int i = 0; i < segments.Length; i++)
                if (string.Equals(segments[i], ".", StringComparison.Ordinal) ||
                    string.Equals(segments[i], "..", StringComparison.Ordinal))
                    throw new InvalidDataException("Long package path contains a traversal segment.");
            return normalized;
        }

        private static string GetPathParentLongSafe(string path)
        {
            string normalized = GetFullPathLongSafe(path).TrimEnd('\\');
            if (normalized.Length < 240) return Path.GetDirectoryName(normalized);

            int separator = normalized.LastIndexOf('\\');
            if (separator < 0) return null;
            if (separator == 2 && normalized.Length >= 3 && normalized[1] == ':')
                return normalized.Substring(0, 3);
            if (separator == 1 && normalized.StartsWith("\\\\", StringComparison.Ordinal)) return null;
            return normalized.Substring(0, separator);
        }

        private static string GetRelativeReleasePath(string root, string path)
        {
            string fullRoot = Path.GetFullPath(root).TrimEnd('\\');
            string fullPath = Path.GetFullPath(path);
            if (!fullPath.StartsWith(fullRoot + "\\", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("LF release path is outside its tree.");
            return fullPath.Substring(fullRoot.Length + 1).Replace('\\', '/');
        }

        private static string ToNativeRelativePath(string value)
        {
            return value.Replace('/', Path.DirectorySeparatorChar);
        }

        private static bool IsReleaseManagedFile(string value)
        {
            if (value == null) return false;
            for (int i = 0; i < ReleaseManagedFiles.Length; i++)
                if (string.Equals(value, ReleaseManagedFiles[i], StringComparison.Ordinal)) return true;
            return false;
        }

        private static bool IsReleaseContentFile(string value)
        {
            if (value == null) return false;
            for (int i = 0; i < ReleaseContentFiles.Length; i++)
                if (string.Equals(value, ReleaseContentFiles[i], StringComparison.Ordinal)) return true;
            return false;
        }

        private static bool IsReleaseTransactionName(string value)
        {
            if (value == null || value.Length != ReleaseTransactionNameLength ||
                !value.StartsWith(ReleaseTransactionPrefix, StringComparison.Ordinal)) return false;
            for (int i = ReleaseTransactionPrefix.Length; i < value.Length; i++)
            {
                char c = value[i];
                if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
            }
            return true;
        }

        private static void AssertExactSet(string[] expected, List<string> actual, string label)
        {
            if (expected.Length != actual.Count)
                throw new InvalidDataException(label + " entry count is invalid.");
            HashSet<string> remaining = new HashSet<string>(expected, StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < actual.Count; i++)
                if (!remaining.Remove(actual[i]))
                    throw new InvalidDataException(label + " contains an unexpected entry.");
            if (remaining.Count != 0) throw new InvalidDataException(label + " is incomplete.");
        }

        private static void AssertExactProperties(Dictionary<string, object> value,
            string[] expected, string label)
        {
            if (value == null || value.Count != expected.Length)
                throw new InvalidDataException(label + " has an unsupported property set.");
            for (int i = 0; i < expected.Length; i++)
                if (!value.ContainsKey(expected[i]))
                    throw new InvalidDataException(label + " has an unsupported property set.");
        }

        private static Dictionary<string, object> ReadRequiredObject(Dictionary<string, object> values,
            string key, string label)
        {
            object value;
            Dictionary<string, object> result;
            if (!values.TryGetValue(key, out value) || (result = value as Dictionary<string, object>) == null)
                throw new InvalidDataException(label + " is missing object property " + key + ".");
            return result;
        }

        private static IEnumerable ReadRequiredEnumerable(Dictionary<string, object> values,
            string key, string label)
        {
            object value;
            IEnumerable result;
            if (!values.TryGetValue(key, out value) || value is string || (result = value as IEnumerable) == null)
                throw new InvalidDataException(label + " is missing array property " + key + ".");
            return result;
        }

        private static string ReadRequiredString(Dictionary<string, object> values,
            string key, string label)
        {
            object value;
            string result;
            if (!values.TryGetValue(key, out value) || (result = value as string) == null || result.Length == 0)
                throw new InvalidDataException(label + " is missing string property " + key + ".");
            return result;
        }

        private static int ReadRequiredInt(Dictionary<string, object> values, string key, string label)
        {
            object value;
            if (!values.TryGetValue(key, out value))
                throw new InvalidDataException(label + " is missing integer property " + key + ".");
            try { return Convert.ToInt32(value, CultureInfo.InvariantCulture); }
            catch (Exception ex) { throw new InvalidDataException(label + " integer property is invalid: " + key, ex); }
        }

        private static long ReadRequiredLong(Dictionary<string, object> values, string key, string label)
        {
            object value;
            if (!values.TryGetValue(key, out value))
                throw new InvalidDataException(label + " is missing integer property " + key + ".");
            try { return Convert.ToInt64(value, CultureInfo.InvariantCulture); }
            catch (Exception ex) { throw new InvalidDataException(label + " integer property is invalid: " + key, ex); }
        }

        private static Version ParseFourPartVersion(string value, string label)
        {
            string[] parts = (value ?? "").Split('.');
            if (parts.Length != 4) throw new InvalidDataException(label + " must have four parts.");
            int[] numbers = new int[4];
            for (int i = 0; i < parts.Length; i++)
            {
                ushort parsed;
                if (!ushort.TryParse(parts[i], NumberStyles.None, CultureInfo.InvariantCulture, out parsed) ||
                    parsed.ToString(CultureInfo.InvariantCulture) != parts[i])
                    throw new InvalidDataException(label + " contains an invalid part.");
                numbers[i] = parsed;
            }
            return new Version(numbers[0], numbers[1], numbers[2], numbers[3]);
        }

        private static string ToHex(byte[] bytes)
        {
            StringBuilder result = new StringBuilder(bytes.Length * 2);
            for (int i = 0; i < bytes.Length; i++)
                result.Append(bytes[i].ToString("x2", CultureInfo.InvariantCulture));
            return result.ToString();
        }

        private static Dictionary<string, object> ParseReleaseMetadata(string metadata)
        {
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = (int)MaximumReleaseMetadataBytes;
            serializer.RecursionLimit = 64;
            Dictionary<string, object> release = serializer.Deserialize<Dictionary<string, object>>(metadata);
            if (release == null) throw new InvalidDataException("LF Git release metadata is invalid.");
            object draft;
            object prerelease;
            if (release.TryGetValue("draft", out draft) && Convert.ToBoolean(draft, CultureInfo.InvariantCulture))
                throw new InvalidOperationException("The latest LF Git release is still a draft.");
            if (release.TryGetValue("prerelease", out prerelease) && Convert.ToBoolean(prerelease, CultureInfo.InvariantCulture))
                throw new InvalidOperationException("The latest LF Git release is a prerelease.");
            return release;
        }

        private static Version ReadReleaseVersion(Dictionary<string, object> release)
        {
            object tagObject;
            if (!release.TryGetValue("tag_name", out tagObject) || tagObject == null)
                throw new InvalidDataException("LF Git release tag is missing.");
            return ParseReleaseTag(Convert.ToString(tagObject, CultureInfo.InvariantCulture));
        }

        private static Version ParseReleaseTag(string tag)
        {
            string value = (tag ?? "").Trim();
            if (!value.StartsWith("v", StringComparison.Ordinal) || value.Length < 2)
                throw new InvalidDataException("LF Git release tag must be v<four-part-version>.");
            string[] parts = value.Substring(1).Split('.');
            if (parts.Length != 4) throw new InvalidDataException("LF Git release tag must contain four version parts.");
            int[] numbers = new int[4];
            for (int i = 0; i < parts.Length; i++)
            {
                ushort parsed;
                if (!ushort.TryParse(parts[i], NumberStyles.None, CultureInfo.InvariantCulture, out parsed) ||
                    parsed.ToString(CultureInfo.InvariantCulture) != parts[i])
                    throw new InvalidDataException("LF Git release tag contains an invalid version part.");
                numbers[i] = parsed;
            }
            return new Version(numbers[0], numbers[1], numbers[2], numbers[3]);
        }

        private static UpdateCheckStatus ClassifyVersions(Version installed, Version available)
        {
            if (installed == null) return UpdateCheckStatus.CurrentVersionUnknown;
            int comparison = available.CompareTo(installed);
            if (comparison == 0) return UpdateCheckStatus.UpToDate;
            return comparison > 0 ? UpdateCheckStatus.NewerRelease : UpdateCheckStatus.Downgrade;
        }

        private static ReleaseAsset ReadReleaseAsset(Dictionary<string, object> release,
            string assetName, Version available)
        {

            object assetsObject;
            if (!release.TryGetValue("assets", out assetsObject)) return null;
            IEnumerable assets = assetsObject as IEnumerable;
            if (assets == null) throw new InvalidDataException("LF Git release assets are invalid.");
            foreach (object assetObject in assets)
            {
                Dictionary<string, object> asset = assetObject as Dictionary<string, object>;
                if (asset == null) continue;
                object nameObject;
                if (!asset.TryGetValue("name", out nameObject) ||
                    !string.Equals(Convert.ToString(nameObject, CultureInfo.InvariantCulture), assetName,
                        StringComparison.Ordinal)) continue;
                object stateObject;
                if (asset.TryGetValue("state", out stateObject) &&
                    !string.Equals(Convert.ToString(stateObject, CultureInfo.InvariantCulture), "uploaded",
                        StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("LF Git release asset is not uploaded: " + assetName);
                object urlObject;
                if (!asset.TryGetValue("browser_download_url", out urlObject))
                    throw new InvalidDataException("LF Git release asset URL is missing: " + assetName);
                string url = Convert.ToString(urlObject, CultureInfo.InvariantCulture);
                ValidateGitHubReleaseUri(url, false);

                long length = -1;
                object sizeObject;
                if (asset.TryGetValue("size", out sizeObject) && sizeObject != null)
                {
                    try { length = Convert.ToInt64(sizeObject, CultureInfo.InvariantCulture); }
                    catch { throw new InvalidDataException("LF Git release asset size is invalid: " + assetName); }
                    if (length <= 0 || length > MaximumReleaseArchiveBytes)
                        throw new InvalidDataException("LF Git release asset size is invalid: " + assetName);
                }

                object digestObject;
                if (!asset.TryGetValue("digest", out digestObject) || digestObject == null)
                    throw new InvalidDataException("LF Git release asset SHA-256 digest is missing: " + assetName);
                string sha256 = NormalizeSha256(Convert.ToString(digestObject, CultureInfo.InvariantCulture));
                return new ReleaseAsset { Url = url, Sha256 = sha256, Length = length, Version = available };
            }
            return null;
        }

        private static bool IsNoReleaseResponse(WebException exception)
        {
            HttpWebResponse response = exception == null ? null : exception.Response as HttpWebResponse;
            return response != null && response.StatusCode == HttpStatusCode.NotFound;
        }

        internal static bool SelfTestUpdatePolicy()
        {
            try
            {
                Version version = ParseReleaseTag("v26.803.5235.0");
                if (!version.Equals(new Version(26, 803, 5235, 0))) return false;
                if (ClassifyVersions(null, version) != UpdateCheckStatus.CurrentVersionUnknown) return false;
                if (ClassifyVersions(version, version) != UpdateCheckStatus.UpToDate) return false;
                if (ClassifyVersions(new Version(26, 700, 0, 0), version) != UpdateCheckStatus.NewerRelease) return false;
                if (ClassifyVersions(new Version(27, 0, 0, 0), version) != UpdateCheckStatus.Downgrade) return false;
                if (!ParseLatestReleaseRedirect(new Uri(
                    "https://github.com/riveryang6/lf-portable/releases/tag/v26.803.5235.0")).Equals(version))
                    return false;
                if (ParseLatestReleaseRedirect(new Uri(
                    "https://github.com/riveryang6/lf-portable/releases")) != null)
                    return false;
                string transaction = ReleaseTransactionPrefix + "0123456789abcdef0123456789abcdef";
                if (!IsReleaseTransactionName(transaction)) return false;
                if (IsReleaseTransactionName(transaction.ToUpperInvariant()) ||
                    IsReleaseTransactionName(ReleaseTransactionPrefix + "0123456789abcdef") ||
                    IsReleaseTransactionName(ReleaseTransactionPrefix + "0123456789abcdef0123456789abcdefx")) return false;
                bool invalidAccepted = false;
                try { ParseReleaseTag("26.803.5235.0"); invalidAccepted = true; }
                catch (InvalidDataException) { }
                if (invalidAccepted) return false;

                string digest = new string('a', 64);
                Dictionary<string, object> assetMetadata = new Dictionary<string, object>();
                assetMetadata.Add("name", ReleaseArchiveAssetName);
                assetMetadata.Add("state", "uploaded");
                assetMetadata.Add("browser_download_url",
                    "https://github.com/riveryang6/lf-portable/releases/download/v26.803.5235.0/" +
                    ReleaseArchiveAssetName);
                assetMetadata.Add("size", 1024L);
                assetMetadata.Add("digest", "sha256:" + digest);
                Dictionary<string, object> release = new Dictionary<string, object>();
                release.Add("assets", new object[] { assetMetadata });
                ReleaseAsset asset = ReadReleaseAsset(release, ReleaseArchiveAssetName, version);
                if (asset == null || asset.Length != 1024L || !asset.Version.Equals(version) ||
                    !string.Equals(asset.Sha256, digest, StringComparison.Ordinal)) return false;
                assetMetadata.Remove("digest");
                bool missingDigestAccepted = false;
                try
                {
                    ReadReleaseAsset(release, ReleaseArchiveAssetName, version);
                    missingDigestAccepted = true;
                }
                catch (InvalidDataException) { }
                return !missingDigestAccepted;
            }
            catch { return false; }
        }

        private static string DownloadReleaseMetadata()
        {
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            ValidateGitHubReleaseUri(GitHubLatestReleaseApi, true);
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(GitHubLatestReleaseApi);
            request.Method = "GET";
            request.AllowAutoRedirect = true;
            request.MaximumAutomaticRedirections = 3;
            request.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
            request.UserAgent = GetReleaseUserAgent();
            request.Accept = "application/vnd.github+json";
            request.Timeout = 60000;
            request.ReadWriteTimeout = 60000;
            request.Proxy = WebRequest.DefaultWebProxy;
            if (request.Proxy != null) request.Proxy.Credentials = CredentialCache.DefaultCredentials;

            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            {
                if (response.StatusCode != HttpStatusCode.OK) throw new WebException("LF Git release metadata request failed.");
                ValidateGitHubReleaseUri(response.ResponseUri.ToString(), true);
                if (response.ContentLength > MaximumReleaseMetadataBytes)
                    throw new InvalidDataException("LF Git release metadata is too large.");
                using (Stream input = response.GetResponseStream())
                using (MemoryStream output = new MemoryStream())
                {
                    byte[] buffer = new byte[64 * 1024];
                    long received = 0;
                    while (true)
                    {
                        int count = input.Read(buffer, 0, buffer.Length);
                        if (count == 0) break;
                        received += count;
                        if (received > MaximumReleaseMetadataBytes)
                            throw new InvalidDataException("LF Git release metadata is too large.");
                        output.Write(buffer, 0, count);
                    }
                    Array.Clear(buffer, 0, buffer.Length);
                    if (received <= 0) throw new InvalidDataException("LF Git release metadata is empty.");
                    return new UTF8Encoding(false, true).GetString(output.ToArray());
                }
            }
        }

        private static Version DownloadLatestReleaseVersion()
        {
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            ValidateGitHubReleasePageUri(GitHubLatestReleasePage);
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(GitHubLatestReleasePage);
            request.Method = "HEAD";
            request.AllowAutoRedirect = false;
            request.UserAgent = GetReleaseUserAgent();
            request.Timeout = 20000;
            request.ReadWriteTimeout = 20000;
            request.Proxy = WebRequest.DefaultWebProxy;
            if (request.Proxy != null) request.Proxy.Credentials = CredentialCache.DefaultCredentials;
            try
            {
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                {
                    if ((int)response.StatusCode < 300 || (int)response.StatusCode > 399)
                        throw new WebException("LF GitHub latest release redirect is invalid.");
                    string location = response.Headers[HttpResponseHeader.Location];
                    Uri destination;
                    if (string.IsNullOrEmpty(location) || !Uri.TryCreate(response.ResponseUri, location,
                        out destination))
                        throw new WebException("LF GitHub latest release redirect is missing.");
                    return ParseLatestReleaseRedirect(destination);
                }
            }
            catch (WebException ex)
            {
                HttpWebResponse response = ex.Response as HttpWebResponse;
                if (response != null && response.StatusCode == HttpStatusCode.NotFound) return null;
                throw;
            }
        }

        private static Version ParseLatestReleaseRedirect(Uri destination)
        {
            ValidateGitHubReleasePageUri(destination == null ? null : destination.ToString());
            string repositoryPath = "/riveryang6/lf-portable/releases";
            string path = destination.AbsolutePath.TrimEnd('/');
            if (string.Equals(path, repositoryPath, StringComparison.OrdinalIgnoreCase)) return null;
            string prefix = repositoryPath + "/tag/";
            if (!path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                throw new WebException("LF GitHub latest release redirect has an unexpected destination.");
            string encodedTag = path.Substring(prefix.Length);
            if (encodedTag.Length == 0 || encodedTag.IndexOf('/') >= 0)
                throw new WebException("LF GitHub latest release redirect tag is invalid.");
            return ParseReleaseTag(Uri.UnescapeDataString(encodedTag));
        }

        private static void ValidateGitHubReleaseUri(string value, bool api)
        {
            Uri uri;
            if (!Uri.TryCreate(value, UriKind.Absolute, out uri) ||
                !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
                throw new WebException("LF Git release URL must use HTTPS.");
            string host = uri.Host.TrimEnd('.').ToLowerInvariant();
            if (api)
            {
                if (!string.Equals(host, "api.github.com", StringComparison.Ordinal))
                    throw new WebException("LF Git release metadata redirected outside api.github.com.");
            }
            else if (!string.Equals(host, "github.com", StringComparison.Ordinal) &&
                !string.Equals(host, "objects.githubusercontent.com", StringComparison.Ordinal) &&
                !string.Equals(host, "release-assets.githubusercontent.com", StringComparison.Ordinal) &&
                !host.EndsWith(".githubusercontent.com", StringComparison.Ordinal))
                throw new WebException("LF Git release asset URL is outside GitHub.");
        }

        private static void ValidateGitHubReleasePageUri(string value)
        {
            Uri uri;
            if (!Uri.TryCreate(value, UriKind.Absolute, out uri) ||
                !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(uri.Host.TrimEnd('.'), "github.com", StringComparison.OrdinalIgnoreCase))
                throw new WebException("LF GitHub release page URL is invalid.");
        }

        private static string NormalizeSha256(string value)
        {
            value = (value ?? "").Trim();
            if (value.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase)) value = value.Substring(7).Trim();
            if (value.Length != 64) throw new InvalidDataException("LF Git release SHA-256 digest is invalid.");
            for (int i = 0; i < value.Length; i++) if (!Uri.IsHexDigit(value[i]))
                throw new InvalidDataException("LF Git release SHA-256 digest is invalid.");
            return value.ToLowerInvariant();
        }

        private static void Download(string target, string releaseUrl, IProgress<UpdateProgress> progress,
            string expectedSha256, long expectedLength)
        {
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            ValidateGitHubReleaseUri(releaseUrl, false);
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(releaseUrl);
            request.Method = "GET";
            request.AllowAutoRedirect = true;
            request.MaximumAutomaticRedirections = 5;
            request.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
            request.UserAgent = GetReleaseUserAgent();
            request.Timeout = 60000;
            request.ReadWriteTimeout = 60000;
            request.Proxy = WebRequest.DefaultWebProxy;
            if (request.Proxy != null) request.Proxy.Credentials = CredentialCache.DefaultCredentials;

            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            {
                if (response.StatusCode != HttpStatusCode.OK) throw new WebException("Unexpected HTTP status.");
                if (!string.Equals(response.ResponseUri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
                    throw new WebException("LF Git release redirected to a non-HTTPS endpoint.");
                ValidateGitHubReleaseUri(response.ResponseUri.ToString(), false);
                long total = response.ContentLength;
                if (total > MaximumReleaseArchiveBytes) throw new InvalidDataException("Release archive is too large.");
                if (expectedLength > 0 && total > 0 && total != expectedLength)
                    throw new EndOfStreamException("LF Git release asset length changed before download.");
                if (total > 0)
                {
                    DriveInfo drive = new DriveInfo(Path.GetPathRoot(target));
                    if (drive.AvailableFreeSpace < total + 512L * 1024L * 1024L) throw new IOException("Insufficient free space.");
                }

                byte[] buffer = new byte[1024 * 1024];
                long received = 0;
                long progressTotal = total > 0 ? total : expectedLength;
                Stopwatch reporter = Stopwatch.StartNew();
                ReportUpdateProgress(progress, UpdateProgressStage.DownloadingRelease,
                    0, progressTotal, 0, 1);
                using (Stream input = response.GetResponseStream())
                using (FileStream output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None, buffer.Length, FileOptions.SequentialScan))
                {
                    while (true)
                    {
                        int count = input.Read(buffer, 0, buffer.Length);
                        if (count == 0) break;
                        received += count;
                        if (received > MaximumReleaseArchiveBytes) throw new InvalidDataException("Release archive is too large.");
                        output.Write(buffer, 0, count);
                        if (reporter.ElapsedMilliseconds >= ProgressReportIntervalMilliseconds)
                        {
                            ReportUpdateProgress(progress, UpdateProgressStage.DownloadingRelease,
                                received, progressTotal, 0, 1);
                            reporter.Restart();
                        }
                    }
                    output.Flush(true);
                }
                Array.Clear(buffer, 0, buffer.Length);
                if (received <= 0) throw new InvalidDataException("Downloaded release archive is empty.");
                if (total >= 0 && received != total) throw new EndOfStreamException("Download was incomplete.");
                if (expectedLength > 0 && received != expectedLength)
                    throw new EndOfStreamException("LF Git release asset download was incomplete.");
                ReportUpdateProgress(progress, UpdateProgressStage.DownloadingRelease,
                    received, progressTotal, 1, 1);
                if (!string.IsNullOrEmpty(expectedSha256))
                {
                    string actual = ComputeUpdateFileSha256(target, progress,
                        expectedLength > 0 ? expectedLength : received);
                    if (!actual.Equals(expectedSha256, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("LF Git release asset SHA-256 does not match its release metadata.");
                }
            }
        }

        private static string GetReleaseUserAgent()
        {
            Version version = Assembly.GetExecutingAssembly().GetName().Version;
            return "LFPortable/" + (version == null ? "0.0.0.0" : version.ToString()) +
                " (+https://github.com/riveryang6/lf-portable)";
        }

        private static string ComputeUpdateFileSha256(string path, IProgress<UpdateProgress> progress,
            long expectedLength)
        {
            if (!IsRegularFile(path)) throw new FileNotFoundException("LF update file is missing.", path);
            long total = new FileInfo(path).Length;
            if (total <= 0 || (expectedLength > 0 && total != expectedLength))
                throw new InvalidDataException("LF update file length changed before SHA-256 verification.");
            byte[] buffer = new byte[1024 * 1024];
            byte[] digest = null;
            try
            {
                long completed = 0;
                Stopwatch reporter = Stopwatch.StartNew();
                ReportUpdateProgress(progress, UpdateProgressStage.VerifyingReleaseDownload,
                    completed, total, 0, 1);
                using (SHA256 sha = SHA256.Create())
                using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                    FileShare.Read, buffer.Length, FileOptions.SequentialScan))
                {
                    while (true)
                    {
                        int read = stream.Read(buffer, 0, buffer.Length);
                        if (read == 0) break;
                        sha.TransformBlock(buffer, 0, read, buffer, 0);
                        completed += read;
                        if (reporter.ElapsedMilliseconds >= ProgressReportIntervalMilliseconds)
                        {
                            ReportUpdateProgress(progress, UpdateProgressStage.VerifyingReleaseDownload,
                                completed, total, 0, 1);
                            reporter.Restart();
                        }
                    }
                    sha.TransformFinalBlock(buffer, 0, 0);
                    digest = sha.Hash;
                }
                if (completed != total)
                    throw new EndOfStreamException("LF update file changed during SHA-256 verification.");
                ReportUpdateProgress(progress, UpdateProgressStage.VerifyingReleaseDownload,
                    completed, total, 1, 1);
                return ToHex(digest);
            }
            finally
            {
                Array.Clear(buffer, 0, buffer.Length);
                if (digest != null) Array.Clear(digest, 0, digest.Length);
            }
        }

        private static PackageInfo ReadAndValidateManifest(string package, PortableArchitecture expectedArchitecture)
        {
            using (FileStream stream = new FileStream(package, FileMode.Open, FileAccess.Read, FileShare.Read))
                return ReadAndValidateManifest(stream, expectedArchitecture);
        }

        private static PackageInfo ReadAndValidateManifest(Stream packageStream,
            PortableArchitecture expectedArchitecture)
        {
            if (packageStream == null) throw new ArgumentNullException("packageStream");
            if (!packageStream.CanRead || !packageStream.CanSeek)
                throw new ArgumentException("The MSIX manifest stream must be readable and seekable.",
                    "packageStream");
            packageStream.Position = 0;
            try
            {
                using (ZipArchive zip = new ZipArchive(packageStream, ZipArchiveMode.Read, true))
                {
                bool chatGpt = false;
                bool codex = false;
                ZipArchiveEntry manifest = null;
                HashSet<string> paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                long expandedBytes = 0;
                long executableBytes = 0;
                int fileCount = 0;
                int entryCount = 0;
                foreach (ZipArchiveEntry entry in zip.Entries)
                {
                    if (++entryCount > MaximumDesktopPackageEntries)
                        throw new InvalidDataException("Package has too many entries.");
                    bool directory = IsArchiveDirectory(entry);
                    AssertArchiveEntryAttributes(entry, directory);
                    string relative = NormalizePackageArchivePath(entry.FullName, directory);
                    if (relative.Length == 0)
                    {
                        if (directory) continue;
                        throw new InvalidDataException("Package contains an empty file path.");
                    }
                    if (!paths.Add(relative)) throw new InvalidDataException("Package contains duplicate paths.");
                    if (!directory)
                    {
                        if (entry.Length < 0 || entry.Length > MaximumDesktopExpandedBytes - expandedBytes)
                            throw new InvalidDataException("Package expands beyond its limit.");
                        expandedBytes += entry.Length;
                        fileCount++;
                    }
                    if (string.Equals(relative, "AppxManifest.xml", StringComparison.OrdinalIgnoreCase)) manifest = entry;
                    if (!directory && (string.Equals(relative, "ChatGPT.exe", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(relative, "app/ChatGPT.exe", StringComparison.OrdinalIgnoreCase)))
                    {
                        if (chatGpt) throw new InvalidDataException("Package contains multiple desktop executables.");
                        chatGpt = true;
                        executableBytes = entry.Length;
                    }
                    if (string.Equals(relative, "resources/codex.exe", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(relative, "app/resources/codex.exe", StringComparison.OrdinalIgnoreCase)) codex = true;
                }
                if (manifest == null || manifest.Length <= 0 || manifest.Length > 2 * 1024 * 1024) throw new InvalidDataException("Manifest is missing or invalid.");
                if (!chatGpt || executableBytes <= 0 || !codex || fileCount == 0 || expandedBytes == 0)
                    throw new InvalidDataException("Required application files are missing.");
                using (Stream manifestStream = manifest.Open())
                {
                    PackageInfo result = ParseAndValidateManifest(manifestStream, expectedArchitecture);
                    result.ExpandedBytes = expandedBytes;
                    result.FileCount = fileCount;
                    result.ExecutableBytes = executableBytes;
                    return result;
                }
            }
            }
            finally { packageStream.Position = 0; }
        }

        private static PackageInfo ParseAndValidateManifest(Stream stream, PortableArchitecture expectedArchitecture)
        {
            XmlReaderSettings settings = new XmlReaderSettings();
            settings.DtdProcessing = DtdProcessing.Prohibit;
            settings.XmlResolver = null;
            settings.MaxCharactersInDocument = 2 * 1024 * 1024;
            XmlDocument document = new XmlDocument();
            document.XmlResolver = null;
            using (XmlReader reader = XmlReader.Create(stream, settings)) document.Load(reader);
            XmlElement identity = document.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Identity']") as XmlElement;
            if (identity == null) throw new InvalidDataException("Package identity is missing.");
            PackageInfo info = new PackageInfo();
            info.Name = identity.GetAttribute("Name");
            info.Publisher = identity.GetAttribute("Publisher");
            info.Architecture = identity.GetAttribute("ProcessorArchitecture");
            Version version;
            if (!Version.TryParse(identity.GetAttribute("Version"), out version)) throw new InvalidDataException("Package version is invalid.");
            info.Version = version;
            if (!string.Equals(info.Name, ExpectedName, StringComparison.Ordinal)) throw new InvalidDataException("Unexpected package identity.");
            if (!string.Equals(info.Publisher, ExpectedPublisher, StringComparison.Ordinal)) throw new InvalidDataException("Unexpected package publisher.");
            string expectedPackageArchitecture = ArchitectureInfo.NameOf(expectedArchitecture);
            if (!string.Equals(info.Architecture, expectedPackageArchitecture, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Package architecture does not match the current Windows architecture.");
            XmlElement display = document.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Properties']/*[local-name()='PublisherDisplayName']") as XmlElement;
            if (display == null || !string.Equals(display.InnerText.Trim(), "OpenAI", StringComparison.Ordinal))
                throw new InvalidDataException("Publisher display name is invalid.");
            return info;
        }

        internal static void ExtractZipArchive(string package, string staging,
            long expectedBytes, int expectedFiles, long maximumBytes, int maximumEntries,
            Action<long, long, int, int> progress,
            Func<ZipArchiveEntry, bool, string> resolvePath)
        {
            if (!File.Exists(package)) throw new FileNotFoundException("Package is missing.", package);
            using (FileStream source = new FileStream(package, FileMode.Open, FileAccess.Read,
                FileShare.Read, 1024 * 1024, FileOptions.SequentialScan))
                ExtractZipArchive(source, staging, expectedBytes, expectedFiles, maximumBytes,
                    maximumEntries, progress, resolvePath);
        }

        internal static void ExtractZipArchive(Stream source, string staging,
            long expectedBytes, int expectedFiles, long maximumBytes, int maximumEntries,
            Action<long, long, int, int> progress,
            Func<ZipArchiveEntry, bool, string> resolvePath)
        {
            if (source == null) throw new ArgumentNullException("source");
            if (!source.CanRead || !source.CanSeek)
                throw new ArgumentException("The package stream must be readable and seekable.", "source");
            if (string.IsNullOrEmpty(staging) || !Directory.Exists(staging))
                throw new DirectoryNotFoundException("Package staging directory is missing.");
            if (maximumBytes <= 0 || maximumEntries <= 0 || resolvePath == null)
                throw new ArgumentOutOfRangeException("Package extraction limits are invalid.");
            if (Directory.GetFileSystemEntries(staging, "*", SearchOption.TopDirectoryOnly).Length != 0)
                throw new IOException("Package staging directory is not empty.");

            string root = Path.GetFullPath(staging).TrimEnd('\\');
            List<ArchiveExtractionEntry> plan = new List<ArchiveExtractionEntry>();
            HashSet<string> destinations = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            long totalBytes = 0;
            int totalFiles = 0;
            Stopwatch deadline = Stopwatch.StartNew();
            source.Position = 0;
            try
            {
                using (ZipArchive archive = new ZipArchive(source, ZipArchiveMode.Read, true))
                {
                int entryCount = 0;
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    if (++entryCount > maximumEntries)
                        throw new InvalidDataException("Package contains too many archive entries.");
                    bool directory = IsArchiveDirectory(entry);
                    AssertArchiveEntryAttributes(entry, directory);
                    string relative = resolvePath(entry, directory);
                    if (relative == null) continue;
                    if (string.IsNullOrEmpty(relative))
                    {
                        if (directory) continue;
                        throw new InvalidDataException("Package contains an empty file path.");
                    }
                    ValidateResolvedArchivePath(relative, directory);
                    string destination = ResolveArchiveDestination(root, relative);
                    if (!destinations.Add(destination))
                        throw new InvalidDataException("Package contains duplicate output paths.");
                    if (!directory)
                    {
                        if (entry.Length < 0 || entry.Length > maximumBytes - totalBytes)
                            throw new InvalidDataException("Package expands beyond its limit.");
                        totalBytes += entry.Length;
                        totalFiles++;
                    }
                    plan.Add(new ArchiveExtractionEntry {
                        Entry = entry,
                        RelativePath = relative,
                        Destination = destination,
                        Directory = directory
                    });
                }
                if (totalFiles <= 0 || totalBytes <= 0)
                    throw new InvalidDataException("Package contains no file content.");
                if (expectedBytes >= 0 && totalBytes != expectedBytes)
                    throw new InvalidDataException("Package expanded byte count changed after validation.");
                if (expectedFiles >= 0 && totalFiles != expectedFiles)
                    throw new InvalidDataException("Package file count changed after validation.");

                if (progress != null) progress(0, totalBytes, 0, totalFiles);
                byte[] buffer = new byte[1024 * 1024];
                long completedBytes = 0;
                int completedFiles = 0;
                Stopwatch reporter = Stopwatch.StartNew();
                HashSet<string> preparedDirectories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                preparedDirectories.Add(root);
                try
                {
                    for (int i = 0; i < plan.Count; i++)
                    {
                        if (deadline.Elapsed.TotalMinutes >= ExtractionTimeoutMinutes)
                            throw new TimeoutException("Package extraction timed out.");
                        ArchiveExtractionEntry item = plan[i];
                        if (item.Directory)
                        {
                            if (preparedDirectories.Add(item.Destination))
                            {
                                EnsureArchiveDirectory(item.Destination);
                                AssertNoReparseAncestry(item.Destination, root);
                            }
                            continue;
                        }

                        string directory = GetPathParentLongSafe(item.Destination);
                        if (string.IsNullOrEmpty(directory))
                            throw new InvalidDataException("Package output file has no parent directory.");
                        if (preparedDirectories.Add(directory))
                        {
                            AssertNoReparseAncestry(directory, root);
                            EnsureArchiveDirectory(directory);
                            AssertNoReparseAncestry(directory, root);
                        }
                        long written = 0;
                        uint crc = 0xFFFFFFFFU;
                        using (Stream input = item.Entry.Open())
                        using (FileStream output = OpenArchiveOutput(item.Destination, buffer.Length))
                        {
                            int read;
                            while ((read = input.Read(buffer, 0, buffer.Length)) != 0)
                            {
                                if (deadline.Elapsed.TotalMinutes >= ExtractionTimeoutMinutes)
                                    throw new TimeoutException("Package extraction timed out.");
                                written += read;
                                if (written > item.Entry.Length || completedBytes > totalBytes - read)
                                    throw new InvalidDataException("Package entry expanded beyond its declared length.");
                                output.Write(buffer, 0, read);
                                crc = UpdateCrc32(crc, buffer, 0, read);
                                completedBytes += read;
                                if (reporter.ElapsedMilliseconds >= ProgressReportIntervalMilliseconds)
                                {
                                    if (progress != null) progress(completedBytes, totalBytes,
                                        completedFiles, totalFiles);
                                    reporter.Restart();
                                }
                            }
                            output.Flush();
                            SetArchiveLastWriteTime(output.SafeFileHandle,
                                item.Entry.LastWriteTime.UtcDateTime);
                        }
                        if (written != item.Entry.Length || ~crc != ReadArchiveEntryCrc32(item.Entry))
                            throw new InvalidDataException("Package entry integrity check failed: " +
                                item.RelativePath);
                        completedFiles++;
                        if (reporter.ElapsedMilliseconds >= ProgressReportIntervalMilliseconds ||
                            completedFiles == totalFiles)
                        {
                            if (progress != null) progress(completedBytes, totalBytes,
                                completedFiles, totalFiles);
                            reporter.Restart();
                        }
                    }
                }
                finally { Array.Clear(buffer, 0, buffer.Length); }
                if (completedBytes != totalBytes || completedFiles != totalFiles)
                    throw new InvalidDataException("Package extraction was incomplete.");
                }
            }
            finally { source.Position = 0; }
        }

        private static bool IsArchiveDirectory(ZipArchiveEntry entry)
        {
            return entry.FullName.EndsWith("/", StringComparison.Ordinal) ||
                entry.FullName.EndsWith("\\", StringComparison.Ordinal) ||
                string.IsNullOrEmpty(entry.Name);
        }

        private static void AssertArchiveEntryAttributes(ZipArchiveEntry entry, bool directory)
        {
            uint attributes = unchecked((uint)entry.ExternalAttributes);
            uint unixType = (attributes >> 16) & 0xF000;
            if (unixType == 0xA000 || (attributes & 0x400) != 0)
                throw new InvalidDataException("Package contains a link or reparse-point entry.");
            if (unixType != 0 && unixType != 0x8000 && unixType != 0x4000)
                throw new InvalidDataException("Package contains an unsupported archive entry type.");
            if (directory && unixType == 0x8000)
                throw new InvalidDataException("Package directory entry has a file type.");
            if (!directory && unixType == 0x4000)
                throw new InvalidDataException("Package file entry has a directory type.");
        }

        private static string ResolveArchiveDestination(string root, string relative)
        {
            string normalizedRoot = GetFullPathLongSafe(root).TrimEnd('\\');
            string destination = normalizedRoot + "\\" +
                relative.Replace('/', Path.DirectorySeparatorChar);
            if (string.Equals(destination, root, StringComparison.OrdinalIgnoreCase) ||
                !IsPathWithin(destination, normalizedRoot))
                throw new InvalidDataException("Package output path is outside its staging directory.");
            return destination;
        }

        private static string NormalizePackageArchivePath(string path, bool directory)
        {
            string normalized = PortableBundle.NormalizeArchivePath(path);
            if (normalized.Length == 0) return normalized;
            string[] segments = normalized.Split('/');
            StringBuilder result = new StringBuilder(normalized.Length);
            for (int i = 0; i < segments.Length; i++)
            {
                string decoded = segments[i].IndexOf('%') < 0 ? segments[i] :
                    Uri.UnescapeDataString(segments[i]);
                AssertArchivePathSegment(decoded, directory || i < segments.Length - 1);
                if (i != 0) result.Append('/');
                result.Append(decoded);
            }
            return result.ToString();
        }

        private static void ValidateResolvedArchivePath(string relative, bool directory)
        {
            if (relative.StartsWith("/", StringComparison.Ordinal) ||
                relative.IndexOf('\\') >= 0 || relative.IndexOf(':') >= 0)
                throw new InvalidDataException("Package contains an unsafe output path.");
            string[] segments = relative.Split('/');
            for (int i = 0; i < segments.Length; i++)
                AssertArchivePathSegment(segments[i], directory || i < segments.Length - 1);
        }

        private static void AssertArchivePathSegment(string segment, bool directory)
        {
            if (string.IsNullOrEmpty(segment) || segment == "." || segment == ".." ||
                segment.Length > 255 || segment.EndsWith(".", StringComparison.Ordinal) ||
                segment.EndsWith(" ", StringComparison.Ordinal) ||
                segment.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
                IsReservedWindowsName(segment))
                throw new InvalidDataException("Package contains an unsafe path segment.");
            if (directory)
                for (int i = 0; i < segment.Length; i++) if (segment[i] > 127)
                    throw new InvalidDataException("Package contains a non-ASCII directory name.");
        }

        private static void EnsureArchiveDirectory(string path)
        {
            string extended = ToExtendedPath(path);
            try
            {
                Directory.CreateDirectory(extended);
                return;
            }
            catch (ArgumentException) { }
            catch (NotSupportedException) { }
            catch (IOException) { }

            if (ArchiveDirectoryExists(path)) return;
            string parent = GetPathParentLongSafe(path);
            if (!string.IsNullOrEmpty(parent) && !ArchiveDirectoryExists(parent))
                EnsureArchiveDirectory(parent);
            if (!NativeMethods.CreateDirectory(extended, IntPtr.Zero))
            {
                int error = Marshal.GetLastWin32Error();
                if (error != 183 && !ArchiveDirectoryExists(path))
                    throw new Win32Exception(error, "Long-path directory creation failed: " + path);
            }
            if (!ArchiveDirectoryExists(path))
                throw new IOException("Long-path directory creation could not be verified: " + path);
        }

        private static bool ArchiveDirectoryExists(string path)
        {
            uint attributes = NativeMethods.GetFileAttributes(ToExtendedPath(path));
            return attributes != NativeMethods.InvalidFileAttributes &&
                (attributes & (uint)FileAttributes.Directory) != 0;
        }

        private static FileStream OpenArchiveOutput(string path, int bufferSize)
        {
            IntPtr raw = NativeMethods.CreateFile(ToExtendedPath(path), NativeMethods.GenericWrite,
                0, IntPtr.Zero, NativeMethods.CreateNew,
                NativeMethods.FileAttributeNormal | NativeMethods.FileFlagSequentialScan, IntPtr.Zero);
            if (raw == NativeMethods.InvalidHandleValue)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateFileW failed: " + path);
            SafeFileHandle handle = new SafeFileHandle(raw, true);
            try { return new FileStream(handle, FileAccess.Write, bufferSize, false); }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        private static void SetArchiveLastWriteTime(SafeFileHandle handle, DateTime utc)
        {
            long value = utc.ToFileTimeUtc();
            System.Runtime.InteropServices.ComTypes.FILETIME timestamp =
                new System.Runtime.InteropServices.ComTypes.FILETIME();
            timestamp.dwLowDateTime = unchecked((int)(value & 0xFFFFFFFFL));
            timestamp.dwHighDateTime = unchecked((int)(value >> 32));
            if (!NativeMethods.SetFileTime(handle, IntPtr.Zero, IntPtr.Zero, ref timestamp))
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Package entry timestamp could not be restored.");
        }

        private static uint[] CreateCrc32Table()
        {
            uint[] table = new uint[256];
            for (int index = 0; index < table.Length; index++)
            {
                uint value = unchecked((uint)index);
                for (int bit = 0; bit < 8; bit++)
                    value = (value & 1U) != 0 ? (value >> 1) ^ 0xEDB88320U : value >> 1;
                table[index] = value;
            }
            return table;
        }

        private static uint ReadArchiveEntryCrc32(ZipArchiveEntry entry)
        {
            if (ZipEntryCrc32Field == null)
                throw new PlatformNotSupportedException("The .NET ZIP implementation does not expose entry CRC metadata.");
            object value = ZipEntryCrc32Field.GetValue(entry);
            if (!(value is uint)) throw new InvalidDataException("Package entry CRC metadata is invalid.");
            return (uint)value;
        }

        private static uint UpdateCrc32(uint crc, byte[] buffer, int offset, int count)
        {
            int end = checked(offset + count);
            for (int i = offset; i < end; i++) crc = (crc >> 8) ^
                Crc32Table[(int)((crc ^ buffer[i]) & 0xFFU)];
            return crc;
        }

        private static void ValidateExtracted(string staging, PackageInfo expected)
        {
            string exe = Path.Combine(staging, "ChatGPT.exe");
            string codex = Path.Combine(staging, "resources", "codex.exe");
            if (!File.Exists(exe) || new FileInfo(exe).Length < 100000) throw new InvalidDataException("Extracted ChatGPT.exe is invalid.");
            if (!File.Exists(codex) || new FileInfo(codex).Length < 100000) throw new InvalidDataException("Extracted codex.exe is invalid.");
            PortableArchitecture expectedArchitecture = ArchitectureInfo.ParseName(expected.Architecture);
            if (expectedArchitecture == PortableArchitecture.Unknown)
                throw new InvalidDataException("Extracted package has an unsupported architecture value.");
            if (!ArchitectureInfo.IsMachineCompatible(exe, expectedArchitecture) ||
                !ArchitectureInfo.IsMachineCompatible(codex, expectedArchitecture))
                throw new InvalidDataException("Extracted desktop payload machine architecture is inconsistent with its package manifest.");
            // The manifest stays one level above payload for the current official MSIX layout.
            string manifestPath = Path.Combine(staging, "AppxManifest.xml");
            if (!File.Exists(manifestPath)) manifestPath = Path.Combine(Path.GetDirectoryName(staging), "AppxManifest.xml");
            if (!File.Exists(manifestPath)) throw new InvalidDataException("Extracted package manifest is missing.");
            PackageInfo actual;
            using (FileStream stream = File.OpenRead(manifestPath))
                actual = ParseAndValidateManifest(stream, expectedArchitecture);
            if (!actual.Version.Equals(expected.Version)) throw new InvalidDataException("Extracted manifest version changed.");
            ValidateOfficialBundledPlugins(staging, expectedArchitecture);
        }

        private static void ValidateOfficialBundledPlugins(string payloadRoot,
            PortableArchitecture expectedArchitecture)
        {
            string pluginsRoot = Path.Combine(payloadRoot, "resources", "plugins",
                "openai-bundled", "plugins");
            if (!Directory.Exists(pluginsRoot))
                throw new DirectoryNotFoundException("Official bundled-plugin root is missing: " + pluginsRoot);

            string[] expectedNames =
                ProviderConfiguration.GetRequiredBundledPluginNames(expectedArchitecture);
            HashSet<string> expected = new HashSet<string>(StringComparer.Ordinal);
            for (int i = 0; i < expectedNames.Length; i++)
            {
                if (string.IsNullOrEmpty(expectedNames[i]) || !expected.Add(expectedNames[i]))
                    throw new InvalidDataException("Official bundled-plugin contract is invalid.");
            }

            string[] entries = Directory.GetFileSystemEntries(pluginsRoot, "*",
                SearchOption.TopDirectoryOnly);
            if (entries.Length != expected.Count)
                throw new InvalidDataException("Official bundled-plugin inventory does not match the " +
                    ArchitectureInfo.NameOf(expectedArchitecture) + " contract.");

            HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
            for (int i = 0; i < entries.Length; i++)
            {
                FileAttributes attributes = File.GetAttributes(entries[i]);
                if ((attributes & FileAttributes.ReparsePoint) != 0 ||
                    (attributes & FileAttributes.Directory) == 0)
                    throw new InvalidDataException(
                        "Official bundled-plugin root contains a non-directory or reparse entry.");
                string pluginName = Path.GetFileName(entries[i]);
                if (string.IsNullOrEmpty(pluginName) || !expected.Contains(pluginName) ||
                    !seen.Add(pluginName))
                    throw new InvalidDataException("Official bundled-plugin inventory contains an unexpected entry: " +
                        pluginName);

                string manifest = Path.Combine(entries[i], ".codex-plugin", "plugin.json");
                string manifestName;
                string version;
                PluginCacheRecovery.ReadManifestIdentity(manifest, out manifestName, out version);
                if (!string.Equals(manifestName, pluginName, StringComparison.Ordinal) ||
                    string.IsNullOrWhiteSpace(version))
                    throw new InvalidDataException("Official bundled-plugin manifest identity is invalid: " +
                        pluginName);
            }

            if (seen.Count != expected.Count)
                throw new InvalidDataException("Official bundled-plugin inventory is incomplete.");
        }

        // Shared by normal package activation and the host execution-image
        // builder.  Both paths therefore use the same signature, manifest,
        // archive-entry, extraction, payload, and LF-branding postconditions.
        internal static PackageInfo ExtractPreparedDesktopPayload(string package,
            string staging, PortableArchitecture expectedArchitecture,
            PackageInfo expected, Action<long, long, int, int> progress,
            Action verifyingAndBranding, out string payloadRoot)
        {
            if (!File.Exists(package)) throw new FileNotFoundException("MSIX not found.", package);
            using (FileStream packageStream = new FileStream(package, FileMode.Open, FileAccess.Read,
                FileShare.Read, 1024 * 1024, FileOptions.SequentialScan))
                return ExtractPreparedDesktopPayload(package, packageStream, staging,
                    expectedArchitecture, expected, progress, verifyingAndBranding, out payloadRoot);
        }

        internal static PackageInfo ExtractPreparedDesktopPayload(string package,
            FileStream packageStream, string staging, PortableArchitecture expectedArchitecture,
            PackageInfo expected, Action<long, long, int, int> progress,
            Action verifyingAndBranding, out string payloadRoot)
        {
            if (packageStream == null) throw new ArgumentNullException("packageStream");
            if (!packageStream.CanRead || !packageStream.CanSeek)
                throw new ArgumentException("The MSIX stream must be readable and seekable.",
                    "packageStream");
            if (string.IsNullOrEmpty(staging))
                throw new ArgumentException("Desktop package staging is blank.", "staging");
            Directory.CreateDirectory(staging);
            if (Directory.GetFileSystemEntries(staging, "*", SearchOption.TopDirectoryOnly).Length != 0)
                throw new IOException("Desktop package staging directory is not empty.");
            payloadRoot = null;
            if (!SignatureVerifier.Verify(package, packageStream))
                throw new InvalidDataException("The MSIX signature is not trusted.");
            PackageInfo info = ReadAndValidateManifest(packageStream, expectedArchitecture);
            if (expected != null && !PackageInfoEquals(expected, info))
                throw new InvalidDataException("The desktop package changed after verification.");
            ExtractZipArchive(packageStream, staging, info.ExpandedBytes, info.FileCount,
                MaximumDesktopExpandedBytes, MaximumDesktopPackageEntries, progress,
                delegate(ZipArchiveEntry entry, bool directory)
                {
                    return NormalizePackageArchivePath(entry.FullName, directory);
                });
            payloadRoot = GetPayloadRoot(staging);
            if (verifyingAndBranding != null) verifyingAndBranding();
            ValidateExtracted(payloadRoot, info);
            PortableBranding.PreparePayload(payloadRoot);
            if (!PortableBranding.IsPrepared(payloadRoot))
                throw new InvalidDataException("The MSIX did not produce a prepared LF payload.");
            return info;
        }

        private static bool PackageInfoEquals(PackageInfo expected, PackageInfo actual)
        {
            return expected != null && actual != null &&
                string.Equals(expected.Name, actual.Name, StringComparison.Ordinal) &&
                string.Equals(expected.Publisher, actual.Publisher, StringComparison.Ordinal) &&
                string.Equals(expected.Architecture, actual.Architecture, StringComparison.OrdinalIgnoreCase) &&
                expected.Version.Equals(actual.Version) &&
                expected.ExpandedBytes == actual.ExpandedBytes &&
                expected.FileCount == actual.FileCount &&
                expected.ExecutableBytes == actual.ExecutableBytes;
        }

        private static string GetPayloadRoot(string staging)
        {
            string nested = Path.Combine(staging, "app");
            if (File.Exists(Path.Combine(nested, "ChatGPT.exe"))) return nested;
            return staging;
        }

        internal static void AssertExtractedTreeNoReparse(string root)
        {
            List<string> files = new List<string>();
            List<string> directories = new List<string>();
            CollectPackageTree(root, files, directories);
        }

        internal static void AssertExtractedTreeNoReparse(string root, long expectedBytes,
            int expectedFiles)
        {
            List<string> files = new List<string>();
            List<string> directories = new List<string>();
            List<long> fileLengths = new List<long>();
            CollectPackageTree(root, files, directories, fileLengths);
            if (files.Count != expectedFiles)
                throw new InvalidDataException("Extracted package file count differs from its archive.");
            long totalBytes = 0;
            for (int i = 0; i < fileLengths.Count; i++)
            {
                long length = fileLengths[i];
                if (length < 0 || length > expectedBytes - totalBytes)
                    throw new InvalidDataException("Extracted package size exceeds its archive contract.");
                totalBytes += length;
            }
            if (totalBytes != expectedBytes)
                throw new InvalidDataException("Extracted package size differs from its archive.");
        }

        private static void CollectPackageTree(string current, List<string> files, List<string> directories)
        {
            CollectPackageTree(current, files, directories, null);
        }

        private static void CollectPackageTree(string current, List<string> files,
            List<string> directories, List<long> fileLengths)
        {
            string nativeCurrent = ToExtendedPath(current);
            NativeMethods.WIN32_FIND_DATA data;
            IntPtr find = NativeMethods.FindFirstFile(nativeCurrent.TrimEnd('\\') + "\\*", out data);
            if (find == NativeMethods.InvalidHandleValue)
            {
                int firstError = Marshal.GetLastWin32Error();
                if (firstError == 2 || firstError == 3) return;
                throw new Win32Exception(firstError, "Long-path package enumeration failed: " + current);
            }
            try
            {
                bool more = true;
                while (more)
                {
                    string name = data.cFileName;
                    if (name != "." && name != "..")
                    {
                        string child = nativeCurrent.TrimEnd('\\') + "\\" + name;
                        FileAttributes attributes = data.dwFileAttributes;
                        if ((attributes & FileAttributes.ReparsePoint) != 0)
                            throw new InvalidDataException("Reparse points are not allowed in an extracted package.");
                        if ((attributes & FileAttributes.Directory) != 0)
                        {
                            directories.Add(child);
                            CollectPackageTree(child, files, directories, fileLengths);
                        }
                        else
                        {
                            files.Add(child);
                            if (fileLengths != null)
                                fileLengths.Add(((long)data.nFileSizeHigh << 32) | data.nFileSizeLow);
                        }
                    }
                    more = NativeMethods.FindNextFile(find, out data);
                    if (!more)
                    {
                        int error = Marshal.GetLastWin32Error();
                        if (error != 18)
                            throw new Win32Exception(error, "Long-path package enumeration failed: " + current);
                    }
                }
            }
            finally { NativeMethods.FindClose(find); }
        }

        private static string ToExtendedPath(string path)
        {
            if (path.StartsWith("\\\\?\\", StringComparison.Ordinal)) return path;
            string full = GetFullPathLongSafe(path).Replace('/', '\\');
            if (full.StartsWith("\\\\", StringComparison.Ordinal)) return "\\\\?\\UNC\\" + full.Substring(2);
            return "\\\\?\\" + full;
        }

        internal static string ReadInstalledVersion(PortableLayout layout)
        {
            // Status rendering happens during ordinary startup. Parsing the bounded
            // descriptor is enough for display; full multi-gigabyte verification is
            // deliberately reserved for the update decision and apply transaction.
            ReleaseDescriptor descriptor = TryReadReleaseDescriptor(layout.ReleaseDescriptor);
            if (descriptor != null) return descriptor.Version.ToString();
            return File.Exists(layout.ReleaseDescriptor) || File.Exists(layout.OfficialAppExe) ?
                LauncherLocale.T("已安装（版本未知）", "Installed (version unknown)") :
                LauncherLocale.T("未安装", "Not installed");
        }

        internal static string GetExecutionImagePackageIdentity(PortableLayout layout)
        {
            ReleaseFile common = null;
            ReleaseFile desktop = null;
            GetExecutionImagePackageFiles(layout, out common, out desktop);
            return "c-" + common.Sha256.Substring(0, 16).ToLowerInvariant() +
                "-d-" + desktop.Sha256.Substring(0, 16).ToLowerInvariant();
        }

        // The cache key carries the release hashes, but the first local image
        // build must prove the USB archives actually match those hashes.
        internal static ExecutionImagePackageLease VerifyExecutionImagePackages(PortableLayout layout,
            Action<FirstLaunchProgress> progress)
        {
            ReleaseFile common = null;
            ReleaseFile desktop = null;
            GetExecutionImagePackageFiles(layout, out common, out desktop);
            FileStream commonLock = null;
            FileStream desktopLock = null;
            try
            {
                commonLock = OpenExecutionImagePackageLease(layout.CommonPackage,
                    common, "portable common execution package");
                desktopLock = OpenExecutionImagePackageLease(layout.BundledDesktopPackage,
                    desktop, "portable desktop execution package");
                long total = checked(common.Length + desktop.Length);
                long completed = 0;
                int completedFiles = 0;
                Stopwatch reporter = Stopwatch.StartNew();
                if (progress != null)
                    progress(new FirstLaunchProgress(FirstLaunchPreparationStage.ValidatingHostExecutionImage,
                        completed, total, completedFiles, 2));
                VerifyFile(commonLock, common, "portable common execution package",
                    delegate(long bytes)
                    {
                        completed += bytes;
                        if (progress != null && reporter.ElapsedMilliseconds >= ProgressReportIntervalMilliseconds)
                        {
                            progress(new FirstLaunchProgress(FirstLaunchPreparationStage.ValidatingHostExecutionImage,
                                completed, total, completedFiles, 2));
                            reporter.Restart();
                        }
                    });
                completedFiles++;
                if (progress != null)
                    progress(new FirstLaunchProgress(FirstLaunchPreparationStage.ValidatingHostExecutionImage,
                        completed, total, completedFiles, 2));
                VerifyFile(desktopLock, desktop, "portable desktop execution package",
                    delegate(long bytes)
                    {
                        completed += bytes;
                        if (progress != null && reporter.ElapsedMilliseconds >= ProgressReportIntervalMilliseconds)
                        {
                            progress(new FirstLaunchProgress(FirstLaunchPreparationStage.ValidatingHostExecutionImage,
                                completed, total, completedFiles, 2));
                            reporter.Restart();
                        }
                    });
                completedFiles++;
                if (progress != null)
                    progress(new FirstLaunchProgress(FirstLaunchPreparationStage.ValidatingHostExecutionImage,
                        completed, total, completedFiles, 2));

                if (!SignatureVerifier.Verify(layout.BundledDesktopPackage, desktopLock))
                    throw new InvalidDataException("The portable desktop package signature is not trusted.");
                PackageInfo desktopInfo = ReadAndValidateManifest(desktopLock, layout.Architecture);
                return new ExecutionImagePackageLease(layout.CommonPackage,
                    layout.BundledDesktopPackage, desktopInfo, commonLock, desktopLock);
            }
            catch
            {
                if (desktopLock != null) desktopLock.Dispose();
                if (commonLock != null) commonLock.Dispose();
                throw;
            }
        }

        private static FileStream OpenExecutionImagePackageLease(string path,
            ReleaseFile expected, string label)
        {
            if (!IsRegularFile(path)) throw new FileNotFoundException(label + " file is missing.", path);
            FileInfo info = new FileInfo(path);
            if (info.Length != expected.Length)
                throw new InvalidDataException(label + " length differs from the release descriptor.");
            return new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
                1024 * 1024, FileOptions.SequentialScan);
        }

        private static void GetExecutionImagePackageFiles(PortableLayout layout,
            out ReleaseFile common, out ReleaseFile desktop)
        {
            ReleaseDescriptor descriptor = ReadReleaseDescriptor(layout.ReleaseDescriptor,
                "portable release descriptor");
            string desktopPath = "CodexData/packages/LFPortable-" +
                layout.ArchitectureName + ".msix";
            common = null;
            desktop = null;
            for (int i = 0; i < descriptor.Files.Length; i++)
            {
                if (string.Equals(descriptor.Files[i].Path,
                    "CodexData/packages/LFPortable-common.zip", StringComparison.Ordinal))
                    common = descriptor.Files[i];
                else if (string.Equals(descriptor.Files[i].Path, desktopPath,
                    StringComparison.Ordinal)) desktop = descriptor.Files[i];
            }
            if (common == null || desktop == null || common.Sha256.Length != 64 ||
                desktop.Sha256.Length != 64)
                throw new InvalidDataException("Portable release descriptor has no complete execution-image identity.");
        }

        internal static PackageInfo SelfTestMsix(PortableLayout layout, string package,
            PortableArchitecture expectedArchitecture)
        {
            if (!File.Exists(package)) throw new FileNotFoundException("MSIX not found.", package);
            layout.EnsureDirectories();
            string[] abandoned = Directory.GetDirectories(layout.Updates, "selftest-*", SearchOption.TopDirectoryOnly);
            for (int i = 0; i < abandoned.Length; i++) IOUtil.DeleteDirectoryWithin(abandoned[i], layout.Updates);
            string staging = Path.Combine(layout.Updates, "selftest-" + Guid.NewGuid().ToString("N").Substring(0, 10));
            try
            {
                string payload;
                return ExtractPreparedDesktopPayload(package, staging, expectedArchitecture,
                    null, null, null, out payload);
            }
            finally
            {
                if (Directory.Exists(staging)) IOUtil.DeleteDirectoryWithin(staging, layout.Updates);
            }
        }

        internal static PackageInfo StageVerifiedReleasePayload(PortableLayout layout, string package,
            PortableArchitecture expectedArchitecture)
        {
            return StageVerifiedReleasePayload(layout, package, expectedArchitecture, null);
        }

        internal static PackageInfo StageVerifiedReleasePayload(PortableLayout layout, string package,
            PortableArchitecture expectedArchitecture, Action<FirstLaunchProgress> progress)
        {
            if (!File.Exists(package)) throw new FileNotFoundException("MSIX not found.", package);
            layout.EnsureDirectories();
            string staging = Path.Combine(layout.Updates, "release-" +
                Guid.NewGuid().ToString("N").Substring(0, 10));
            string destination = expectedArchitecture == PortableArchitecture.X64 ?
                Path.Combine(layout.DataRoot, "app", "current") :
                Path.Combine(layout.Tools, "desktop-payloads", "arm64", "current");
            try
            {
                if (Directory.Exists(destination) || File.Exists(destination))
                    throw new IOException("Release payload destination already exists: " + destination);
                if (progress != null) progress(new FirstLaunchProgress(FirstLaunchPreparationStage.ValidatingDesktopPackage));
                string payload;
                PackageInfo info = ExtractPreparedDesktopPayload(package, staging,
                    expectedArchitecture, null,
                    delegate(long completedBytes, long totalBytes, int completedFiles, int totalFiles)
                    {
                        if (progress != null) progress(new FirstLaunchProgress(
                            FirstLaunchPreparationStage.ExtractingDesktopPackage,
                            completedBytes, totalBytes, completedFiles, totalFiles));
                    }, delegate
                    {
                        if (progress != null) progress(new FirstLaunchProgress(
                            FirstLaunchPreparationStage.VerifyingAndBrandingDesktop));
                    }, out payload);
                string marker = info.Name + "\r\n" + info.Publisher + "\r\n" +
                    info.Version.ToString() + "\r\n" + info.Architecture + "\r\n";
                IOUtil.AtomicWriteText(Path.Combine(payload, ".portable-package.txt"), marker);
                // PreparePayload includes a complete ASAR postcondition after its
                // mutations. No branded file changes between that check and the
                // atomic directory activation below.
                string parent = Path.GetDirectoryName(destination);
                if (string.IsNullOrEmpty(parent)) throw new InvalidDataException("Release payload destination has no parent.");
                Directory.CreateDirectory(parent);
                Directory.Move(payload, destination);
                // Directory.Move is same-volume and atomic. The source was fully
                // verified immediately before activation, so re-reading both large
                // EXEs and app.asar at the destination cannot add assurance here.
                // Verify only that the activated tree contains its required anchor.
                if (!File.Exists(Path.Combine(destination, "ChatGPT.exe")) ||
                    !File.Exists(Path.Combine(destination, PortableBranding.DesktopExecutableName)))
                    throw new InvalidDataException("The installed desktop payload is incomplete.");
                if (progress != null) progress(new FirstLaunchProgress(FirstLaunchPreparationStage.DesktopPayloadReady));
                return info;
            }
            catch
            {
                if (Directory.Exists(destination)) IOUtil.DeleteDirectoryWithin(destination, layout.DataRoot);
                throw;
            }
            finally
            {
                if (Directory.Exists(staging)) IOUtil.DeleteDirectoryWithin(staging, layout.Updates);
            }
        }
    }
}

namespace CodexPortable
{
    internal sealed class KeySetupResult
    {
        internal string ApiKey;
        internal string BaseUrl;
        internal string Model;

        internal void Clear()
        {
            ApiKey = null;
            BaseUrl = null;
            Model = null;
        }
    }

    internal sealed class KeySetupDialog : Form
    {
        private readonly TextBox keyBox;
        private readonly TextBox baseUrlBox;
        private readonly TextBox modelBox;
        private KeySetupResult result;

        private KeySetupDialog(string currentBaseUrl, string currentModel, string currentApiKey)
        {
            Text = LauncherLocale.T("设置 API", "Configure API");
            Font = new Font("Microsoft YaHei UI", 9F);
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = false;
            ClientSize = new Size(560, 360);
            BackColor = Color.FromArgb(244, 246, 248);

            Panel header = new Panel();
            header.Location = new Point(0, 0);
            header.Size = new Size(ClientSize.Width, 70);
            header.BackColor = Color.FromArgb(15, 29, 48);
            Controls.Add(header);

            PictureBox brandMark = new PictureBox();
            brandMark.Location = new Point(24, 20);
            brandMark.Size = new Size(38, 38);
            brandMark.SizeMode = PictureBoxSizeMode.Zoom;
            using (Icon launcherIcon = PortableBranding.LoadLauncherIcon())
            {
                brandMark.Image = launcherIcon.ToBitmap();
            }
            header.Controls.Add(brandMark);

            Label headerTitle = new Label();
            headerTitle.Text = LauncherLocale.T("自定义 API", "Custom API");
            headerTitle.Font = new Font(Font.FontFamily, 12F, FontStyle.Bold);
            headerTitle.ForeColor = Color.White;
            headerTitle.AutoSize = true;
            headerTitle.Location = new Point(76, 17);
            header.Controls.Add(headerTitle);

            AddLabel(LauncherLocale.T("Responses API 基础 URL", "Responses API Base URL"), 26, 88, 508);
            baseUrlBox = AddTextBox(26, 120, 508, true);
            baseUrlBox.MaxLength = 2048;
            baseUrlBox.Text = currentBaseUrl ?? "";

            AddLabel(LauncherLocale.T("网关模型名", "Gateway model"), 26, 166, 508);
            modelBox = AddTextBox(26, 188, 508, true);
            modelBox.MaxLength = 200;
            modelBox.Text = currentModel ?? "";

            AddLabel(LauncherLocale.T("API Key", "API key"), 26, 234, 508);
            keyBox = AddTextBox(26, 256, 508, true);
            keyBox.MaxLength = 1024;
            keyBox.UseSystemPasswordChar = true;
            keyBox.Text = currentApiKey ?? "";

            Button save = new Button();
            save.Text = LauncherLocale.T("保存", "Save");
            save.Location = new Point(344, 306);
            save.Size = new Size(90, 34);
            save.Font = new Font(Font.FontFamily, 9F, FontStyle.Bold);
            save.BackColor = Color.FromArgb(16, 163, 127);
            save.ForeColor = Color.White;
            save.FlatStyle = FlatStyle.Flat;
            save.FlatAppearance.BorderSize = 0;
            save.Cursor = Cursors.Hand;
            save.Click += SaveClicked;
            Controls.Add(save);

            Button cancel = new Button();
            cancel.Text = LauncherLocale.T("取消", "Cancel");
            cancel.DialogResult = DialogResult.Cancel;
            cancel.Location = new Point(444, 306);
            cancel.Size = new Size(90, 34);
            cancel.ForeColor = Color.FromArgb(30, 41, 59);
            cancel.BackColor = Color.White;
            cancel.FlatStyle = FlatStyle.Flat;
            cancel.FlatAppearance.BorderColor = Color.FromArgb(203, 213, 225);
            cancel.FlatAppearance.BorderSize = 1;
            cancel.Cursor = Cursors.Hand;
            Controls.Add(cancel);
            CancelButton = cancel;
            AcceptButton = save;
        }

        private void AddLabel(string text, int x, int y, int width)
        {
            Label l = new Label();
            l.Text = text;
            l.Location = new Point(x, y);
            l.Size = new Size(width, 22);
            l.Font = new Font(Font.FontFamily, 9F, FontStyle.Bold);
            l.ForeColor = Color.FromArgb(71, 85, 105);
            l.AutoEllipsis = true;
            Controls.Add(l);
        }

        private TextBox AddTextBox(int x, int y, int width, bool singleLine)
        {
            TextBox box = new TextBox();
            box.Location = new Point(x, y);
            box.Size = new Size(width, 27);
            box.Multiline = !singleLine;
            box.Font = new Font(Font.FontFamily, 9.5F);
            box.BorderStyle = BorderStyle.FixedSingle;
            box.BackColor = Color.White;
            box.ForeColor = Color.FromArgb(15, 23, 42);
            Controls.Add(box);
            return box;
        }

        private void SaveClicked(object sender, EventArgs e)
        {
            string key = keyBox.Text.Trim();
            if (!ProviderConfiguration.IsValidApiKey(key))
            {
                MessageBox.Show(LauncherLocale.T("API Key 必须是 1–1024 个不含空格或换行的字符。", "API key must contain 1–1024 characters without spaces or line breaks."), LauncherLocale.T("设置自定义 API", "Custom API"),
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                keyBox.Focus();
                return;
            }
            string baseUrl;
            if (!ProviderConfiguration.TryNormalizeBaseUrl(baseUrlBox.Text, out baseUrl))
            {
                MessageBox.Show(LauncherLocale.T("Base URL 必须是绝对 HTTPS 地址；仅 localhost/127.0.0.1/::1 可使用 HTTP，且不能含账号、查询参数或片段。", "Base URL must be an absolute HTTPS address; HTTP is allowed only for localhost/127.0.0.1/::1, without credentials, query or fragment."), LauncherLocale.T("设置自定义 API", "Custom API"),
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                baseUrlBox.Focus();
                return;
            }
            string model = modelBox.Text.Trim();
            if (!ProviderConfiguration.IsValidModel(model))
            {
                MessageBox.Show(LauncherLocale.T("模型名必须是 1–200 个不含空格或换行的字符。", "Model name must contain 1–200 characters without spaces or line breaks."), LauncherLocale.T("设置自定义 API", "Custom API"),
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                modelBox.Focus();
                return;
            }
            result = new KeySetupResult();
            result.ApiKey = key;
            result.BaseUrl = baseUrl;
            result.Model = model;
            DialogResult = DialogResult.OK;
            Close();
        }

        internal static KeySetupResult Ask(IWin32Window owner, string currentBaseUrl, string currentModel, string currentApiKey)
        {
            using (KeySetupDialog dialog = new KeySetupDialog(currentBaseUrl, currentModel, currentApiKey))
            {
                return dialog.ShowDialog(owner) == DialogResult.OK ? dialog.result : null;
            }
        }
    }

    internal static class CryptoUtil
    {
        internal static void Zero(byte[] bytes)
        {
            if (bytes != null) Array.Clear(bytes, 0, bytes.Length);
        }
    }
}
