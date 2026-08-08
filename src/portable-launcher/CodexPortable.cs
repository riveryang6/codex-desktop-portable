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

[assembly: AssemblyTitle("Codex Portable")]
[assembly: AssemblyDescription("Portable launcher and updater for Codex Desktop")]
[assembly: AssemblyCompany("Codex Portable")]
[assembly: AssemblyProduct("Codex Portable")]
[assembly: AssemblyCopyright("Copyright (c) 2026")]
[assembly: AssemblyVersion("1.3.1.0")]
[assembly: AssemblyFileVersion("1.3.1.0")]
[assembly: ComVisible(false)]

namespace CodexPortable
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            string rootOverride = null;
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
                else forwardedArgs.Add(args[i]);
            }
            args = forwardedArgs.ToArray();
            PortableLayout layout = PortableLayout.FromExecutable(rootOverride);

            if (args.Length == 1 && string.Equals(args[0], "--self-test", StringComparison.OrdinalIgnoreCase))
            {
                return SelfTest.Run(layout);
            }
            if ((args.Length == 2 || args.Length == 3) &&
                string.Equals(args[0], "--self-test-msix", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    PortableArchitecture expectedArchitecture = args.Length == 3 ?
                        ArchitectureInfo.ParseName(args[2]) : layout.Architecture;
                    if (expectedArchitecture == PortableArchitecture.Unknown) return 30;
                    AppUpdater.SelfTestMsix(layout, Path.GetFullPath(args[1]), expectedArchitecture);
                    return 0;
                }
                catch (Exception ex)
                {
                    SafeLog.TryWriteEvent(layout, "self-test-msix", "Failure type=" + ex.GetType().Name + ", message=" + ex.Message);
                    return 30;
                }
            }
            if (args.Length == 2 && string.Equals(args[0], "--prepare-payload", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    PortableBranding.PreparePayload(Path.GetFullPath(args[1]));
                    return 0;
                }
                catch { return 31; }
            }
            if (args.Length == 1 && string.Equals(args[0], "--repair-plugin-cache", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    layout.EnsureDirectories();
                    int repaired = PluginCacheRecovery.EnsureRequiredPlugins(layout, ProviderConfiguration.RequiredPlugins);
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

            bool created;
            // A fixed, portable-only mutex prevents drive aliases or a copied launcher from
            // starting a second portable Desktop process. It does not collide with installed Codex.
            const string mutexName = "Local\\CodexPortable-Desktop-CustomApi-v1";
            using (Mutex mutex = new Mutex(true, mutexName, out created))
            {
                if (!created)
                {
                    MessageBox.Show("此 U 盘上的 Codex Portable 已经在运行。", "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return 2;
                }

                try
                {
                    PortableBranding.InitializeProcessIdentity();
                    Application.EnableVisualStyles();
                    Application.SetCompatibleTextRenderingDefault(false);
                    Application.Run(new PortableForm(layout));
                    return 0;
                }
                catch (Exception ex)
                {
                    SafeLog.TryWrite(layout, "fatal", ex);
                    MessageBox.Show("启动器发生错误。请使用“生成诊断”查看日志。\r\n\r\n错误类型：" + ex.GetType().Name,
                        "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return 1;
                }
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
            internal string CacheBaseRoot;
            internal string CacheVersionRoot;
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
            string sourceManifest = Path.Combine(sourceRoot, ".codex-plugin", "plugin.json");
            string manifestName;
            string version;
            ReadManifestIdentity(sourceManifest, out manifestName, out version);
            if (!string.Equals(manifestName, pluginName, StringComparison.Ordinal))
                throw new InvalidDataException("Offline plugin manifest name does not match its marketplace entry: " + pluginKey);
            if (!IsSafeVersionSegment(version))
                throw new InvalidDataException("Offline plugin version is not a safe cache directory name: " + pluginKey);

            string cacheBaseRoot = Path.Combine(layout.CodexHome, "plugins", "cache", marketplaceName, pluginName);
            return new PluginDefinition {
                PluginName = pluginName,
                MarketplaceName = marketplaceName,
                Version = version,
                SourceRoot = sourceRoot,
                CacheBaseRoot = cacheBaseRoot,
                CacheVersionRoot = Path.Combine(cacheBaseRoot, version)
            };
        }

        private static bool IsCachedVersionComplete(PluginDefinition definition)
        {
            if (!DirectoryExists(definition.CacheVersionRoot)) return false;
            string manifest = Path.Combine(definition.CacheVersionRoot, ".codex-plugin", "plugin.json");
            if (!FileExists(manifest)) return false;
            try
            {
                string name;
                string version;
                ReadManifestIdentity(manifest, out name, out version);
                return string.Equals(name, definition.PluginName, StringComparison.Ordinal) &&
                    string.Equals(version, definition.Version, StringComparison.Ordinal);
            }
            catch { return false; }
        }

        private static bool IsSafeVersionSegment(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length > 128 || value == "." || value == "..") return false;
            for (int i = 0; i < value.Length; i++)
            {
                char c = value[i];
                if (!(char.IsLetterOrDigit(c) || c == '-' || c == '_' || c == '.' || c == '+')) return false;
            }
            return true;
        }

        private static void ReadManifestIdentity(string path, out string name, out string version)
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
            string backupBase = Path.Combine(pluginsRoot, "repair-backups", token,
                definition.MarketplaceName, definition.PluginName);
            string failedBase = Path.Combine(pluginsRoot, "repair-backups", token,
                definition.MarketplaceName, definition.PluginName + ".failed");
            bool targetMoved = false;
            bool activated = false;

            try
            {
                EnsureDirectory(stagedVersion);
                int copiedFiles = CopyDirectoryVerified(definition.SourceRoot, stagedVersion);
                PluginDefinition stagedDefinition = new PluginDefinition {
                    PluginName = definition.PluginName,
                    MarketplaceName = definition.MarketplaceName,
                    Version = definition.Version,
                    SourceRoot = definition.SourceRoot,
                    CacheBaseRoot = stagedBase,
                    CacheVersionRoot = stagedVersion
                };
                if (!IsCachedVersionComplete(stagedDefinition))
                    throw new InvalidDataException("Staged plugin manifest did not validate: " + definition.PluginName);

                AssertTargetStillPresent(layout);
                if (DirectoryExists(definition.CacheBaseRoot))
                {
                    AssertNoReparsePoints(definition.CacheBaseRoot);
                    EnsureDirectory(Path.GetDirectoryName(backupBase));
                    Directory.Move(ToExtendedPath(definition.CacheBaseRoot), ToExtendedPath(backupBase));
                    targetMoved = true;
                }
                else if (FileExists(definition.CacheBaseRoot))
                {
                    throw new IOException("Plugin cache target is a file, not a directory: " + definition.CacheBaseRoot);
                }

                EnsureDirectory(Path.GetDirectoryName(definition.CacheBaseRoot));
                Directory.Move(ToExtendedPath(stagedBase), ToExtendedPath(definition.CacheBaseRoot));
                activated = true;

                try
                {
                    string receipt = Path.Combine(Path.GetDirectoryName(backupBase), "repair-receipt.txt");
                    IOUtil.AtomicWriteText(receipt, "plugin=" + definition.PluginName + "@" + definition.MarketplaceName +
                        "\r\nversion=" + definition.Version + "\r\nfiles=" + copiedFiles.ToString(CultureInfo.InvariantCulture) +
                        "\r\ncompletedUtc=" + DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) + "\r\n");
                }
                catch (Exception receiptError) { SafeLog.TryWrite(layout, "plugin-cache-repair-receipt", receiptError); }
            }
            catch
            {
                try
                {
                    if (activated && DirectoryExists(definition.CacheBaseRoot) && !DirectoryExists(failedBase))
                    {
                        EnsureDirectory(Path.GetDirectoryName(failedBase));
                        Directory.Move(ToExtendedPath(definition.CacheBaseRoot), ToExtendedPath(failedBase));
                    }
                    if (targetMoved && DirectoryExists(backupBase) && !DirectoryExists(definition.CacheBaseRoot))
                    {
                        Directory.Move(ToExtendedPath(backupBase), ToExtendedPath(definition.CacheBaseRoot));
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
            }
        }

        private static void AssertTargetStillPresent(PortableLayout layout)
        {
            string root = Path.GetPathRoot(layout.Root);
            if (string.IsNullOrEmpty(root) || !DirectoryExists(root)) throw new IOException("Portable drive disappeared during plugin recovery.");
            if (!DirectoryExists(layout.CodexHome)) throw new IOException("Portable Codex data disappeared during plugin recovery.");
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

        internal static string OfficialUrl(PortableArchitecture architecture)
        {
            switch (architecture)
            {
                case PortableArchitecture.X64:
                    return "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix";
                case PortableArchitecture.Arm64:
                    return "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-arm64.msix";
                default:
                    return null;
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
        internal string Rollback;
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
        internal string Downloads;
        internal string ChromiumCache;
        internal string CrashDumps;
        internal string Tools;
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
            p.Secrets = Path.Combine(p.DataRoot, "data", "secrets");
            p.Logs = Path.Combine(p.DataRoot, "logs");
            p.Updates = Path.Combine(p.DataRoot, "updates");
            p.Rollback = Path.Combine(p.AppVariantRoot, "rollback");
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
            p.Downloads = Path.Combine(p.DataRoot, "data", "downloads");
            p.ChromiumCache = Path.Combine(p.Profile, "cache", "chromium");
            p.CrashDumps = Path.Combine(p.Logs, "crash-dumps");
            p.HostScratchRoot = Path.Combine(Path.GetTempPath(), "CodexPortable",
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
                AppVariantRoot
            };
            for (int i = 0; i < dirs.Length; i++) Directory.CreateDirectory(dirs[i]);
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

    internal static class PortableOnboarding
    {
        private const int MaxGlobalStateBytes = 4 * 1024 * 1024;
        private const string PersistedAtomStateKey = "electron-persisted-atom-state";
        private const string OnboardingOverrideKey = "electron:onboarding-override";
        private const string ProjectlessCompletedKey = "electron:onboarding-projectless-completed";
        private const string WelcomePendingKey = "electron:onboarding-welcome-pending";
        private const string SeenModelUpgradeListKey = "seen-model-upgrade-list";
        private const string LatestModelSeenKey = "latest-model-seen";
        private const string CurrentModelUpgrade = "gpt-5.6-sol";
        private const string AgentModeByHostIdKey = "agent-mode-by-host-id";
        private const string LocalHostId = "local";
        private const string CustomAgentMode = "custom";
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
            changed |= SetIfDifferent(agentModes, LocalHostId, CustomAgentMode);
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
                    string.Equals(agentModeValue as string, CustomAgentMode,
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
            // published.  Startup must not reopen and rewrite the 200+ MiB ASAR
            // on a USB volume; that work belongs to --prepare-payload and the
            // update transaction.  Keep this guard limited to cheap existence
            // checks so a missing/incomplete release fails clearly.
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
                Path.Combine(resources, "icon-chatgpt.ico")
            };
            for (int i = 0; i < requiredFiles.Length; i++)
                if (!File.Exists(requiredFiles[i]))
                    throw new FileNotFoundException("Prepared portable branding file is missing.", requiredFiles[i]);
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
            AsarPortableBranding.EnsurePatched(Path.Combine(resources, "app.asar"));
        }

        internal static bool IsPrepared(PortableLayout layout)
        {
            try
            {
                if (!FilesEqual(layout.OfficialAppExe, layout.AppExe)) return false;
                string resources = layout.Resources;
                byte[] dark = ReadEmbeddedResource(DarkIconResource);
                byte[] light = ReadEmbeddedResource(LightIconResource);
                try
                {
                    return FileEqualsBytes(Path.Combine(resources, "codex-tray.ico"), dark) &&
                        FileEqualsBytes(Path.Combine(resources, "chatgpt-tray-dark.ico"), dark) &&
                        FileEqualsBytes(Path.Combine(resources, "chatgpt-tray-light.ico"), light) &&
                        FileEqualsBytes(Path.Combine(resources, "icon-chatgpt.ico"), dark) &&
                        AsarPortableBranding.IsPrepared(Path.Combine(resources, "app.asar"));
                }
                finally
                {
                    Array.Clear(dark, 0, dark.Length);
                    Array.Clear(light, 0, light.Length);
                }
            }
            catch { return false; }
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
        private const string OfficialBrandText = "\"codexAppBrand\": \"chatgpt\"";
        private const string PortableBrandText = "\"codexAppBrand\": \"codex\"  ";
        private const string OfficialAumidText = "Prod:return`com.openai.codex`";
        private const string PortableAumidText = "Prod:return`OpenAI.Codex.USB`";
        private const string OfficialCloseToTrayText =
            "canHideLastWindowToTray?.()===!0&&!t){e.preventDefault(),P.hide();return}";
        private const string LegacyPortableCloseToTrayText =
            "canHideLastWindowToTray?.()&&!!0&&!t){e.preventDefault(),P.hide();return}";
        private const string PortableCloseToTrayText =
            "canHideLastWindowToTray?.()===!0&&!t){this.isAppQuitting=!0,l.app.quit()}";
        private const string PortableCloseElectronAliasText = "l=require(\"electron\")";
        private const string OfficialWindowsLastWindowText =
            "a.app.on(`window-all-closed`,()=>{process.platform!==`win32`";
        private const string PortableWindowsLastWindowText =
            "a.app.on(`window-all-closed`,()=>{process.platform===`win32`";
        private const string WebviewAssetPrefix = "webview/assets/";
        private const string AppInitialAssetStem = "app-initial";
        private const string OnboardingPageAssetStem = "onboarding-page";
        private const string OfficialStandardOnboardingGateText =
            "shouldShowStandardOnboarding:g";
        private const string PortableStandardOnboardingGateText =
            "shouldShowStandardOnboarding:0";
        private const string OnboardingMessageIdPrefix =
            "electron.onboarding.conversationalOnboarding.";
        private const string OfficialOnboardingBrandText = "ChatGPT";
        private const string PortableOnboardingBrandText = "Codex";
        private const string OfficialOnboardingHeaderIconText =
            "(Fh,{\"aria-hidden\":`true`,className:`pointer-events-none size-6 text-token-foreground`})";
        private const string PortableOnboardingHeaderIconText =
            "(BB,{\"aria-hidden\":`true`,className:`pointer-events-none size-6 text-token-foreground`})";
        private const string OfficialOnboardingHeaderIconInitializerText =
            "rz(),ok(),tk(),Ih(),s9=J(),mFu=`h-[18px] w-[18px] rounded-[3px] border-[1px]`";
        private const string PortableOnboardingHeaderIconInitializerText =
            "rz(),ok(),tk(),VB(),s9=J(),mFu=`h-[18px] w-[18px] rounded-[3px] border-[1px]`";
        private const string OfficialWindowsSetupOnboardingStateText = "PFs=ba(Q,!1)";
        private const string PortableWindowsSetupOnboardingStateText = "PFs=ba(Q,!0)";
        private const string OfficialWindowsSetupBannerGateText =
            "gr=lr&&(ur||mr!=null||it.isEnabled&&rt)";
        private const string PortableWindowsSetupBannerGateText =
            "gr=!1" + "                                  ";
        private const string OfficialWindowsSandboxReadinessGateText =
            "n=e?.enabled??!0";
        private const string PortableWindowsSandboxReadinessGateText =
            "n=e?.enabled&&!1";
        private const string OfficialWindowsSandboxSetupPendingGateText =
            "isWindowsSandboxSetupPending:lr&&rt";
        private const string PortableWindowsSandboxSetupPendingGateText =
            "isWindowsSandboxSetupPending:!1&&rt";
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
                int brandEntries = EnsurePattern(archive, archive.FindRequiredEntry(PackagePath),
                    OfficialBrandText, PortableBrandText);
                if (brandEntries != 1) throw new InvalidDataException("Electron package brand metadata is ambiguous.");

                int aumidEntries = 0;
                int closeToTrayEntries = 0;
                int windowsLastWindowEntries = 0;
                for (int i = 0; i < archive.Entries.Count; i++)
                {
                    AsarEntry entry = archive.Entries[i];
                    if (!entry.Path.StartsWith(BuildJavaScriptPrefix, StringComparison.Ordinal) ||
                        !entry.Path.EndsWith(".js", StringComparison.OrdinalIgnoreCase)) continue;
                    aumidEntries += EnsurePattern(archive, entry, OfficialAumidText, PortableAumidText);
                    closeToTrayEntries += EnsureDirectClosePattern(archive, entry);
                    windowsLastWindowEntries += EnsurePattern(archive, entry,
                        OfficialWindowsLastWindowText, PortableWindowsLastWindowText);
                }
                if (aumidEntries == 0) throw new InvalidDataException("Electron portable AppUserModelID target is missing.");
                if (closeToTrayEntries != 1)
                    throw new InvalidDataException("Electron close-to-tray target is missing or ambiguous.");
                if (windowsLastWindowEntries != 1)
                    throw new InvalidDataException("Electron Windows last-window target is missing or ambiguous.");

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
                    byte[] officialCloseToTray = Encoding.UTF8.GetBytes(OfficialCloseToTrayText);
                    byte[] legacyPortableCloseToTray = Encoding.UTF8.GetBytes(LegacyPortableCloseToTrayText);
                    byte[] portableCloseToTray = Encoding.UTF8.GetBytes(PortableCloseToTrayText);
                    byte[] portableCloseElectronAlias = Encoding.UTF8.GetBytes(PortableCloseElectronAliasText);
                    byte[] officialWindowsLastWindow = Encoding.UTF8.GetBytes(OfficialWindowsLastWindowText);
                    byte[] portableWindowsLastWindow = Encoding.UTF8.GetBytes(PortableWindowsLastWindowText);
                    int portableAumidOccurrences = 0;
                    int portableCloseToTrayOccurrences = 0;
                    int portableWindowsLastWindowOccurrences = 0;
                    for (int i = 0; i < archive.Entries.Count; i++)
                    {
                        AsarEntry entry = archive.Entries[i];
                        if (!entry.Path.StartsWith(BuildJavaScriptPrefix, StringComparison.Ordinal) ||
                            !entry.Path.EndsWith(".js", StringComparison.OrdinalIgnoreCase)) continue;
                        byte[] bytes = archive.ReadEntry(entry);
                        int officialAumidCount = CountPattern(bytes, officialAumid);
                        int portableAumidCount = CountPattern(bytes, portableAumid);
                        int officialCloseToTrayCount = CountPattern(bytes, officialCloseToTray);
                        int legacyPortableCloseToTrayCount = CountPattern(bytes, legacyPortableCloseToTray);
                        int portableCloseToTrayCount = CountPattern(bytes, portableCloseToTray);
                        int officialWindowsLastWindowCount = CountPattern(bytes, officialWindowsLastWindow);
                        int portableWindowsLastWindowCount = CountPattern(bytes, portableWindowsLastWindow);
                        if (officialAumidCount != 0 || officialCloseToTrayCount != 0 ||
                            legacyPortableCloseToTrayCount != 0 ||
                            officialWindowsLastWindowCount != 0) return false;
                        if (portableAumidCount > 1 || portableCloseToTrayCount > 1 ||
                            portableWindowsLastWindowCount > 1) return false;
                        if (portableAumidCount == 0 && portableCloseToTrayCount == 0 &&
                            portableWindowsLastWindowCount == 0) continue;
                        if (portableCloseToTrayCount != 0 &&
                            CountPattern(bytes, portableCloseElectronAlias) != 1) return false;
                        portableAumidOccurrences += portableAumidCount;
                        portableCloseToTrayOccurrences += portableCloseToTrayCount;
                        portableWindowsLastWindowOccurrences += portableWindowsLastWindowCount;
                        if (!IntegrityMatches(entry, ComputeIntegrity(bytes, entry.BlockSize))) return false;
                    }
                    if (portableAumidOccurrences == 0 || portableCloseToTrayOccurrences != 1 ||
                        portableWindowsLastWindowOccurrences != 1) return false;

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
            {
                ReplacePattern(originalBytes, Encoding.UTF8.GetBytes(PortableOnboardingHeaderIconText),
                    Encoding.UTF8.GetBytes(OfficialOnboardingHeaderIconText));
                ReplacePattern(originalBytes,
                    Encoding.UTF8.GetBytes(PortableOnboardingHeaderIconInitializerText),
                    Encoding.UTF8.GetBytes(OfficialOnboardingHeaderIconInitializerText));
            }
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
            ReplacePattern(legacyPortableBytes,
                Encoding.UTF8.GetBytes(OfficialOnboardingHeaderIconInitializerText),
                Encoding.UTF8.GetBytes(PortableOnboardingHeaderIconInitializerText));

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
            byte[] selectedInitializer = Encoding.UTF8.GetBytes(portable ?
                PortableOnboardingHeaderIconInitializerText : OfficialOnboardingHeaderIconInitializerText);
            byte[] rejectedInitializer = Encoding.UTF8.GetBytes(portable ?
                OfficialOnboardingHeaderIconInitializerText : PortableOnboardingHeaderIconInitializerText);
            return CountPattern(bytes, selectedIcon) == 1 && CountPattern(bytes, rejectedIcon) == 0 &&
                CountPattern(bytes, selectedInitializer) == 1 && CountPattern(bytes, rejectedInitializer) == 0;
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

        private static int EnsurePattern(AsarArchive archive, AsarEntry entry, string officialText, string portableText)
        {
            byte[] official = Encoding.UTF8.GetBytes(officialText);
            byte[] portable = Encoding.UTF8.GetBytes(portableText);
            if (official.Length != portable.Length)
                throw new InvalidDataException("Portable ASAR replacements must preserve entry length.");
            byte[] bytes = archive.ReadEntry(entry);
            int officialCount = CountPattern(bytes, official);
            int portableCount = CountPattern(bytes, portable);
            if (officialCount == 0 && portableCount == 0) return 0;
            if (officialCount > 1 || portableCount > 1)
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
            return 1;
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

    internal sealed class PortableForm : Form
    {
        private readonly PortableLayout layout;
        private readonly Label status;
        private readonly Label details;
        private readonly ProgressBar progress;
        private readonly CheckBox compatibility;
        private readonly List<Button> actionButtons;
        private JobRun activeRun;
        private bool busy;
        private bool closingAfterConfirm;
        private bool formIsClosing;
        private bool portablePayloadChecked;
        private bool requiredPluginCacheChecked;

        internal PortableForm(PortableLayout p)
        {
            layout = p;
            Text = "Codex Portable";
            Icon = PortableBranding.LoadLauncherIcon();
            ShowIcon = true;
            ShowInTaskbar = true;
            Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Regular, GraphicsUnit.Point);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = true;
            ClientSize = new Size(660, 430);
            BackColor = Color.FromArgb(247, 248, 250);

            Label title = new Label();
            title.Text = "Codex Desktop 便携启动器";
            title.Font = new Font(Font.FontFamily, 16F, FontStyle.Bold);
            title.AutoSize = true;
            title.Location = new Point(28, 22);
            Controls.Add(title);

            Label subtitle = new Label();
            subtitle.Text = "账号、配置与任务保存在 U 盘；高频临时缓存退出即清理";
            subtitle.AutoSize = true;
            subtitle.ForeColor = Color.DimGray;
            subtitle.Location = new Point(31, 58);
            Controls.Add(subtitle);

            status = new Label();
            status.Text = "正在初始化…";
            status.Font = new Font(Font.FontFamily, 10F, FontStyle.Bold);
            status.Location = new Point(31, 93);
            status.Size = new Size(595, 26);
            Controls.Add(status);

            details = new Label();
            details.ForeColor = Color.DimGray;
            details.Location = new Point(31, 120);
            details.Size = new Size(595, 40);
            Controls.Add(details);

            actionButtons = new List<Button>();
            AddButton("启动 Codex", 31, 174, StartClicked, true);
            AddButton("设置自定义 API", 226, 174, SetKeyClicked, false);
            AddButton("清除 API 配置", 421, 174, ClearKeyClicked, false);
            AddButton("检查并更新", 31, 228, UpdateClicked, false);
            AddButton("回滚上一版本", 226, 228, RollbackClicked, false);
            AddButton("生成诊断", 421, 228, DiagnosticsClicked, false);
            AddButton("打开资料目录", 31, 282, OpenDataClicked, false);

            compatibility = new CheckBox();
            compatibility.Text = "兼容渲染模式（仅在黑屏、闪退时启用）";
            compatibility.AutoSize = true;
            compatibility.Location = new Point(226, 294);
            Controls.Add(compatibility);

            progress = new ProgressBar();
            progress.Location = new Point(31, 340);
            progress.Size = new Size(595, 18);
            progress.Style = ProgressBarStyle.Continuous;
            Controls.Add(progress);

            Label footer = new Label();
            footer.Text = "高性能便携模式；远程控制关闭；默认权限：danger-full-access / never。";
            footer.ForeColor = Color.Gray;
            footer.Location = new Point(31, 376);
            footer.Size = new Size(595, 36);
            Controls.Add(footer);

            FormClosing += FormIsClosing;
            Shown += FormShown;
        }

        private void AddButton(string text, int x, int y, EventHandler handler, bool primary)
        {
            Button b = new Button();
            b.Text = text;
            b.Size = new Size(176, 38);
            b.Location = new Point(x, y);
            b.UseVisualStyleBackColor = !primary;
            if (primary)
            {
                b.BackColor = Color.FromArgb(16, 124, 65);
                b.ForeColor = Color.White;
                b.FlatStyle = FlatStyle.Flat;
                b.FlatAppearance.BorderSize = 0;
            }
            b.Click += handler;
            Controls.Add(b);
            actionButtons.Add(b);
        }

        private void FormShown(object sender, EventArgs e)
        {
            try
            {
                layout.EnsureDirectories();
                ProviderConfiguration.CleanupLegacyAuthentication(layout);
                layout.EnsureConfig();
                layout.EnsureOnboardingSuppressed();
                if (!ArchitectureInfo.HasOfficialDesktopPayload(layout.Architecture))
                {
                    status.Text = "Unsupported Windows architecture";
                    details.Text = "Detected " + layout.ArchitectureName +
                        ". The official channel currently publishes x64 and arm64 desktop packages only.";
                    return;
                }
                if (!File.Exists(layout.OfficialAppExe))
                {
                    status.Text = "Codex Desktop payload is not installed";
                    details.Text = "Detected " + layout.ArchitectureName +
                        ". Use Check for updates to download the matching signed official package.";
                    return;
                }
                EnsurePortablePayloadOnce();
                int repairedPlugins = EnsureRequiredPluginCache();
                if (repairedPlugins > 0)
                    SafeLog.TryWriteEvent(layout, "plugin-cache-repair", "Restored " +
                        repairedPlugins.ToString(CultureInfo.InvariantCulture) + " required plugin(s) before startup.");
                if (ProviderConfiguration.HasCompleteApiConfiguration(layout))
                {
                    RefreshStatus("就绪");
                    // A configured portable build must open straight into Codex.  The
                    // launcher remains available behind it for lifecycle control.
                    BeginInvoke(new MethodInvoker(delegate
                    {
                        if (!formIsClosing && !busy && activeRun == null &&
                            ProviderConfiguration.HasCompleteApiConfiguration(layout))
                            StartClicked(this, EventArgs.Empty);
                    }));
                }
                else
                {
                    RefreshStatus("需要设置自定义 API");
                    BeginInvoke(new MethodInvoker(delegate
                    {
                        if (!ProviderConfiguration.HasCompleteApiConfiguration(layout)) SetKeyClicked(this, EventArgs.Empty);
                    }));
                }
            }
            catch (Exception ex)
            {
                SafeLog.TryWrite(layout, "initialization", ex);
                status.Text = "初始化失败";
                details.Text = "错误类型：" + ex.GetType().Name + "。请检查 U 盘是否只读或空间不足。";
            }
        }

        private void RefreshStatus(string prefix)
        {
            string keyMode = ProviderConfiguration.HasCompleteApiConfiguration(layout) ? "自定义 API 已配置" : "未配置（禁止启动）";
            string version = AppUpdater.ReadInstalledVersion(layout);
            status.Text = prefix;
            details.Text = "版本：" + version + "    接口：" + keyMode + "\r\n位置：" + layout.DataRoot;
        }

        private void SetBusy(bool value, string message)
        {
            busy = value;
            for (int i = 0; i < actionButtons.Count; i++) actionButtons[i].Enabled = !value;
            compatibility.Enabled = !value;
            if (message != null) status.Text = message;
            if (!value) progress.Value = 0;
        }

        private async void StartClicked(object sender, EventArgs e)
        {
            if (busy || activeRun != null) return;
            if (!ArchitectureInfo.HasOfficialDesktopPayload(layout.Architecture))
            {
                MessageBox.Show("This Windows architecture is detected as " + layout.ArchitectureName +
                    ". The official Codex Desktop channel currently provides x64 and arm64 payloads only; " +
                    "startup is blocked until an official " + layout.ArchitectureName + " package is available.",
                    "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            if (!File.Exists(layout.OfficialAppExe))
            {
                MessageBox.Show("未找到 Codex Desktop。请先点击“检查并更新”。", "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            try { EnsurePortablePayloadOnce(); }
            catch (Exception ex)
            {
                SafeLog.TryWrite(layout, "portable-branding", ex);
                MessageBox.Show("无法准备 Codex 品牌文件。请生成诊断日志。", "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            if (!File.Exists(layout.AppExe))
            {
                MessageBox.Show("未找到 CodexDesktop.exe。请执行更新。", "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            if (!ArchitectureInfo.IsMachineCompatible(layout.OfficialAppExe, layout.Architecture) ||
                !ArchitectureInfo.IsMachineCompatible(layout.AppExe, layout.Architecture))
            {
                MessageBox.Show("The installed Codex Desktop payload does not match this Windows architecture (" +
                    layout.ArchitectureName + "). Update the portable payload before starting.",
                    "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            if (!File.Exists(layout.CodexExe))
            {
                MessageBox.Show("应用文件不完整：缺少 resources\\codex.exe。请执行更新。", "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            if (!ArchitectureInfo.IsMachineCompatible(layout.CodexExe, layout.Architecture))
            {
                MessageBox.Show("The bundled Codex CLI does not match this Windows architecture (" +
                    layout.ArchitectureName + "). Update the portable payload before starting.",
                    "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            try
            {
                int repairedPlugins = EnsureRequiredPluginCache();
                if (repairedPlugins > 0)
                    SafeLog.TryWriteEvent(layout, "plugin-cache-repair", "Restored " +
                        repairedPlugins.ToString(CultureInfo.InvariantCulture) + " required plugin(s) before launch.");
            }
            catch (Exception ex)
            {
                SafeLog.TryWrite(layout, "plugin-cache-repair", ex);
                SetBusy(false, null);
                MessageBox.Show("必需插件缓存不完整，自动恢复失败。请确认 U 盘连接稳定后重试。\r\n\r\n错误类型：" +
                    ex.GetType().Name, "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            string missingPrerequisite = PortableEnvironment.FindMissingPrerequisite(layout, true);
            if (missingPrerequisite != null)
            {
                MessageBox.Show("便携运行库或插件不完整，禁止启动：\r\n" + missingPrerequisite, "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            string apiKey = null;
            string baseUrl = null;
            string model = null;
            try
            {
                if (!ProviderConfiguration.TryReadRequiredConfiguration(layout, out baseUrl, out apiKey, out model))
                {
                    MessageBox.Show("必须先设置有效的 API URL、API Key 和模型，Codex 才能启动。\r\n便携版不会提供 OpenAI/ChatGPT 登录入口。",
                        "需要自定义 API", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    SetKeyClicked(this, EventArgs.Empty);
                    return;
                }

                layout.EnsureDirectories();
                ProviderConfiguration.CleanupLegacyAuthentication(layout);
                layout.EnsureConfig();
                layout.EnsureOnboardingSuppressed();

                bool hostScratchEnabled = PortableScratch.TryPrepare(layout);
                Dictionary<string, string> env = PortableEnvironment.Build(layout, apiKey);
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
                try
                {
                    activeRun = JobRun.Start(layout.AppExe, arguments, layout.CurrentApp, env);
                }
                finally
                {
                    env.Remove(ProviderConfiguration.ApiKeyEnvironmentVariable);
                    apiKey = null;
                }
                SafeLog.TryWriteEvent(layout, "start", "Codex process tree started. Host scratch=" +
                    (hostScratchEnabled ? "enabled" : "portable fallback") + "; remote control=disabled.");
                SetBusy(false, null);
                for (int i = 0; i < actionButtons.Count; i++) actionButtons[i].Enabled = false;
                actionButtons[actionButtons.Count - 1].Enabled = true;
                status.Text = "Codex 正在运行";
                details.Text = "自定义 API：" + baseUrl + "    模型：" + model;

                JobRun run = activeRun;
                await Task.Run(delegate { run.WaitForTreeExitAndStopWhenWindowCloses(); });
                run.Dispose();
                if (object.ReferenceEquals(activeRun, run)) activeRun = null;
                CleanupLegacyAuthenticationAfterRun();
                SafeLog.TryWriteEvent(layout, "stop", run.StoppedAfterWindowClosed ?
                    "Codex window closed; process tree terminated." : "Codex process tree exited.");
                if (formIsClosing || IsDisposed || Disposing) return;
                for (int i = 0; i < actionButtons.Count; i++) actionButtons[i].Enabled = true;
                RefreshStatus("Codex 已退出");
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
                MessageBox.Show("启动失败。错误类型：" + ex.GetType().Name + "。请生成诊断日志。", "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                RefreshStatus("启动失败");
            }
            finally
            {
                if (apiKey != null) apiKey = null;
                PortableScratch.Cleanup(layout);
            }
        }

        private int EnsureRequiredPluginCache()
        {
            if (requiredPluginCacheChecked) return 0;
            if (ProviderConfiguration.RequiredPluginCacheComplete(layout))
            {
                requiredPluginCacheChecked = true;
                return 0;
            }
            status.Text = "正在恢复插件缓存";
            details.Text = "正在从 U 盘内置的离线插件源校验并恢复必需文件……";
            Application.DoEvents();
            int repaired = PluginCacheRecovery.EnsureRequiredPlugins(layout, ProviderConfiguration.RequiredPlugins);
            if (!ProviderConfiguration.RequiredPluginCacheComplete(layout))
                throw new InvalidDataException("Required plugin cache is still incomplete after recovery.");
            requiredPluginCacheChecked = true;
            return repaired;
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
            requiredPluginCacheChecked = false;
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
                SetBusy(true, "正在保存自定义 API…");
                layout.EnsureDirectories();
                ProviderConfiguration.Save(layout, result.BaseUrl, result.Model, result.ApiKey);
                SafeLog.TryWriteEvent(layout, "custom-api-set", "Custom API URL, key and model saved in portable data.");
                MessageBox.Show("自定义 API 已保存。Codex 将只使用此接口。", "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                SafeLog.TryWrite(layout, "key-set", ex);
                MessageBox.Show("无法保存自定义 API。错误类型：" + ex.GetType().Name, "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                result.Clear();
                SetBusy(false, null);
                RefreshStatus("就绪");
            }
        }

        private void ClearKeyClicked(object sender, EventArgs e)
        {
            if (busy) return;
            if (MessageBox.Show("将清除 API URL、API Key 和模型；清除后 Codex 禁止启动。是否继续？", "清除 API 配置",
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
                RefreshStatus("自定义 API 已清除");
            }
            catch (Exception ex)
            {
                SafeLog.TryWrite(layout, "key-clear", ex);
                MessageBox.Show("清除失败。错误类型：" + ex.GetType().Name, "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private async void UpdateClicked(object sender, EventArgs e)
        {
            if (busy || activeRun != null) return;
            try
            {
                SetBusy(true, "正在下载官方更新…");
                Progress<int> reporter = new Progress<int>(delegate(int value)
                {
                    progress.Style = value < 0 ? ProgressBarStyle.Marquee : ProgressBarStyle.Continuous;
                    if (value >= 0) progress.Value = Math.Max(0, Math.Min(100, value));
                });
                PackageInfo info = await AppUpdater.UpdateAsync(layout, reporter);
                InvalidatePayloadPreflight();
                SafeLog.TryWriteEvent(layout, "update", "Official package installed, version " + info.Version.ToString() + ".");
                MessageBox.Show("更新完成：" + info.Version.ToString() + "\r\n旧版本已保留，可使用回滚按钮。", "Codex Portable",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                RefreshStatus("更新完成");
            }
            catch (InvalidOperationException ex)
            {
                SafeLog.TryWrite(layout, "update-policy", ex);
                MessageBox.Show("官方稳定通道中的版本低于当前已安装版本，启动器已拒绝降级。当前版本保持不变。",
                    "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Information);
                RefreshStatus("无需更新");
            }
            catch (Exception ex)
            {
                SafeLog.TryWrite(layout, "update", ex);
                MessageBox.Show("更新失败，当前版本未被破坏。\r\n错误类型：" + ex.GetType().Name + "\r\n请生成诊断日志。",
                    "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                RefreshStatus("更新失败");
            }
            finally
            {
                progress.Style = ProgressBarStyle.Continuous;
                SetBusy(false, null);
            }
        }

        private void RollbackClicked(object sender, EventArgs e)
        {
            if (busy || activeRun != null) return;
            if (!File.Exists(Path.Combine(layout.Rollback, "ChatGPT.exe")))
            {
                MessageBox.Show("没有可回滚的版本。", "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            if (MessageBox.Show("将当前版本与上一版本交换。是否继续？", "回滚版本", MessageBoxButtons.YesNo,
                    MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
            try
            {
                SetBusy(true, "正在回滚…");
                AppUpdater.Rollback(layout);
                InvalidatePayloadPreflight();
                SafeLog.TryWriteEvent(layout, "rollback", "Current and rollback app directories exchanged.");
                RefreshStatus("回滚完成");
            }
            catch (Exception ex)
            {
                SafeLog.TryWrite(layout, "rollback", ex);
                MessageBox.Show("回滚失败；启动器已尽力恢复当前版本。错误类型：" + ex.GetType().Name,
                    "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally { SetBusy(false, null); }
        }

        private void DiagnosticsClicked(object sender, EventArgs e)
        {
            try
            {
                string path = Diagnostics.Create(layout);
                MessageBox.Show("诊断已保存（不包含密钥值）：\r\n" + path, "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show("无法生成诊断。错误类型：" + ex.GetType().Name, "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
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
                MessageBox.Show("无法打开资料目录。", "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void FormIsClosing(object sender, FormClosingEventArgs e)
        {
            if (closingAfterConfirm) return;
            if (activeRun == null)
            {
                formIsClosing = true;
                try { ProviderConfiguration.CleanupLegacyAuthentication(layout); } catch { }
                PortableScratch.Cleanup(layout);
                return;
            }
            DialogResult answer = MessageBox.Show("关闭启动器会同时结束由它启动的 Codex 进程。是否继续？",
                "Codex 正在运行", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
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
                int analyticsSection = config.IndexOf("[analytics]", StringComparison.OrdinalIgnoreCase);
                if (config.IndexOf("model_provider = \"portable_custom\"", StringComparison.OrdinalIgnoreCase) < 0 ||
                    config.IndexOf(ProviderConfiguration.DeveloperInstructionsConfigLine, StringComparison.OrdinalIgnoreCase) < 0 ||
                    config.IndexOf("chatgpt_base_url = \"http://127.0.0.1:9\"", StringComparison.OrdinalIgnoreCase) < 0 ||
                    config.IndexOf(ProviderConfiguration.ReasoningEffortConfigLine, StringComparison.OrdinalIgnoreCase) < 0 ||
                    config.IndexOf(ProviderConfiguration.ApprovalPolicyConfigLine, StringComparison.OrdinalIgnoreCase) < 0 ||
                    config.IndexOf(ProviderConfiguration.SandboxModeConfigLine, StringComparison.OrdinalIgnoreCase) < 0 ||
                    config.IndexOf("cli_auth_credentials_store = \"file\"", StringComparison.OrdinalIgnoreCase) < 0 ||
                    config.IndexOf("env_key = \"CODEX_PORTABLE_API_KEY\"", StringComparison.OrdinalIgnoreCase) < 0 ||
                    config.IndexOf("wire_api = \"responses\"", StringComparison.OrdinalIgnoreCase) < 0 ||
                    config.IndexOf("requires_openai_auth = false", StringComparison.OrdinalIgnoreCase) < 0 ||
                    config.IndexOf("shell_environment_policy", StringComparison.OrdinalIgnoreCase) < 0 ||
                    config.IndexOf("exclude", StringComparison.OrdinalIgnoreCase) < 0 ||
                    analyticsSection < 0 ||
                    config.IndexOf("enabled = false", analyticsSection, StringComparison.OrdinalIgnoreCase) < 0 ||
                    ProviderConfiguration.CountConfiguredPlugins(config) != ProviderConfiguration.RequiredPluginCount) return 14;
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
                brandEnvironment.Clear();
                if (!brandConfigured) return 26;
                if (!remoteControlSuppressed) return 28;
                string marker = Path.Combine(layout.CurrentApp, ".portable-package.txt");
                if (!File.Exists(marker)) return 21;
                string[] markerLines = File.ReadAllLines(marker, Encoding.UTF8);
                Version markerVersion;
                if (markerLines.Length < 4 || !string.Equals(markerLines[0].Trim(), AppUpdater.ExpectedName, StringComparison.Ordinal) ||
                    !string.Equals(markerLines[1].Trim(), AppUpdater.ExpectedPublisher, StringComparison.Ordinal) ||
                    !Version.TryParse(markerLines[2].Trim(), out markerVersion) ||
                    !string.Equals(markerLines[3].Trim(), ArchitectureInfo.NameOf(layout.Architecture), StringComparison.OrdinalIgnoreCase)) return 21;
                return 0;
            }
            catch (Exception ex)
            {
                SafeLog.TryWrite(layout, "self-test", ex);
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
            pending.Push(root);
            while (pending.Count > 0)
            {
                string current = pending.Pop();
                string[] dirs = Directory.GetDirectories(current);
                for (int i = 0; i < dirs.Length; i++)
                {
                    string name = Path.GetFileName(dirs[i]);
                    for (int c = 0; c < name.Length; c++) if (name[c] > 127) return false;
                    FileAttributes attributes = File.GetAttributes(dirs[i]);
                    if ((attributes & FileAttributes.ReparsePoint) == 0) pending.Push(dirs[i]);
                }
            }
            return true;
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
                text.AppendLine("ConfigDangerFullAccess=" + config.Contains(ProviderConfiguration.SandboxModeConfigLine).ToString(CultureInfo.InvariantCulture));
                text.AppendLine("ConfigApprovalNever=" + config.Contains(ProviderConfiguration.ApprovalPolicyConfigLine).ToString(CultureInfo.InvariantCulture));
                int analyticsSection = config.IndexOf("[analytics]", StringComparison.OrdinalIgnoreCase);
                text.AppendLine("ConfigAnalyticsDisabled=" + (analyticsSection >= 0 &&
                    config.IndexOf("enabled = false", analyticsSection, StringComparison.OrdinalIgnoreCase) >= 0).ToString(CultureInfo.InvariantCulture));
                text.AppendLine("ConfiguredPluginCount=" + ProviderConfiguration.CountConfiguredPlugins(config).ToString(CultureInfo.InvariantCulture));
            }
            text.AppendLine("DefaultApprovalPolicy=" + ProviderConfiguration.DefaultApprovalPolicy);
            text.AppendLine("DefaultSandboxMode=" + ProviderConfiguration.DefaultSandboxMode);
            text.AppendLine("DefaultReasoningEffort=" + ProviderConfiguration.DefaultReasoningEffort);
            text.AppendLine("DesktopOnboardingSuppressed=" + PortableOnboarding.IsSuppressed(layout).ToString(CultureInfo.InvariantCulture));
            text.AppendLine("DesktopAppBrand=" + PortableEnvironment.DesktopBrand);
            text.AppendLine("DesktopAppUserModelId=" + PortableBranding.AppUserModelId);
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
            text.AppendLine("RedirectedVariableNames=CODEX_APP_BRAND,CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED,CODEX_ELECTRON_USER_DATA_PATH,CODEX_HOME,CODEX_SQLITE_HOME,CODEX_PORTABLE_API_KEY,HOME,USERPROFILE,APPDATA,LOCALAPPDATA,LOCALAPPDATALOW,TEMP,TMP,TMPDIR,XDG_CONFIG_HOME,XDG_CACHE_HOME,XDG_DATA_HOME,XDG_STATE_HOME,DOTNET_CLI_HOME,DOTNET_BUNDLE_EXTRACT_BASE_DIR,DOTNET_ROOT,GH_CONFIG_DIR,NPM_CONFIG_CACHE,PIP_CACHE_DIR,UV_CACHE_DIR");
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
        internal static bool TryPrepare(PortableLayout layout)
        {
            try
            {
                string baseRoot = GetValidatedBaseRoot(layout);
                Directory.CreateDirectory(baseRoot);
                string current = Path.GetFullPath(layout.HostScratchRoot).TrimEnd('\\');
                string[] stale = Directory.GetDirectories(baseRoot, "session-*");
                DateTime cutoff = DateTime.UtcNow.AddDays(-2);
                for (int i = 0; i < stale.Length; i++)
                {
                    string candidate = Path.GetFullPath(stale[i]).TrimEnd('\\');
                    if (string.Equals(candidate, current, StringComparison.OrdinalIgnoreCase)) continue;
                    try
                    {
                        if (Directory.GetLastWriteTimeUtc(candidate) < cutoff)
                            IOUtil.DeleteDirectoryWithin(candidate, baseRoot);
                    }
                    catch { }
                }

                string[] directories = new string[] {
                    layout.HostScratchRoot, layout.HostTemp, layout.HostXdgCache,
                    layout.HostChromiumCache, layout.HostDotnetBundle,
                    layout.HostNpmCache, layout.HostPipCache, layout.HostUvCache
                };
                for (int i = 0; i < directories.Length; i++) Directory.CreateDirectory(directories[i]);
                return true;
            }
            catch (Exception ex)
            {
                SafeLog.TryWrite(layout, "performance-cache", ex);
                Cleanup(layout);
                return false;
            }
        }

        internal static bool IsPrepared(PortableLayout layout)
        {
            try
            {
                GetValidatedBaseRoot(layout);
                return Directory.Exists(layout.HostScratchRoot) &&
                    Directory.Exists(layout.HostTemp) &&
                    Directory.Exists(layout.HostChromiumCache);
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
                string baseRoot = GetValidatedBaseRoot(layout);
                if (Directory.Exists(layout.HostScratchRoot))
                    IOUtil.DeleteDirectoryWithin(layout.HostScratchRoot, baseRoot);
            }
            catch { }
        }

        private static string GetValidatedBaseRoot(PortableLayout layout)
        {
            string expectedBase = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "CodexPortable")).TrimEnd('\\');
            string configuredBase = Path.GetFullPath(Path.GetDirectoryName(layout.HostScratchRoot)).TrimEnd('\\');
            string scratch = Path.GetFullPath(layout.HostScratchRoot).TrimEnd('\\');
            string portableRoot = Path.GetFullPath(layout.Root).TrimEnd('\\');
            if (!string.Equals(expectedBase, configuredBase, StringComparison.OrdinalIgnoreCase) ||
                scratch.Length <= configuredBase.Length ||
                !scratch.StartsWith(configuredBase + "\\", StringComparison.OrdinalIgnoreCase) ||
                scratch.StartsWith(portableRoot + "\\", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Invalid host scratch path.");
            return configuredBase;
        }
    }

    internal static class IOUtil
    {
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
            finally { TryDelete(temporary); }
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
            NativeMethods.WINTRUST_FILE_INFO fileInfo = new NativeMethods.WINTRUST_FILE_INFO();
            fileInfo.cbStruct = (uint)Marshal.SizeOf(typeof(NativeMethods.WINTRUST_FILE_INFO));
            fileInfo.pcwszFilePath = path;
            fileInfo.hFile = IntPtr.Zero;
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
        private readonly object sync = new object();
        private IntPtr jobHandle;
        private IntPtr processHandle;
        private bool stoppedAfterWindowClosed;
        internal readonly uint ProcessId;

        internal bool StoppedAfterWindowClosed
        {
            get { lock (sync) return stoppedAfterWindowClosed; }
        }

        private JobRun(IntPtr job, IntPtr process, uint processId)
        {
            jobHandle = job;
            processHandle = process;
            ProcessId = processId;
        }

        internal static JobRun Start(string executable, string arguments, string workingDirectory, Dictionary<string, string> environment)
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
                uint flags = 0x00000004 | 0x00000400; // CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT
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

        internal void WaitForTreeExitAndStopWhenWindowCloses()
        {
            bool visibleWindowSeen = false;
            DateTime noVisibleWindowSince = DateTime.MinValue;
            while (true)
            {
                NativeMethods.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting = new NativeMethods.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION();
                int size = Marshal.SizeOf(typeof(NativeMethods.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
                IntPtr pointer = Marshal.AllocHGlobal(size);
                try
                {
                    Marshal.StructureToPtr(accounting, pointer, false);
                    lock (sync)
                    {
                        if (jobHandle == IntPtr.Zero) return;
                        if (!NativeMethods.QueryInformationJobObject(jobHandle, 1, pointer, (uint)size, IntPtr.Zero))
                            throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to monitor Codex process tree.");
                    }
                    accounting = (NativeMethods.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)Marshal.PtrToStructure(pointer,
                        typeof(NativeMethods.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
                    if (accounting.ActiveProcesses == 0) return;
                }
                finally { Marshal.FreeHGlobal(pointer); }

                bool visible = HasVisibleDesktopWindow(ProcessId);
                if (visible)
                {
                    visibleWindowSeen = true;
                    noVisibleWindowSince = DateTime.MinValue;
                }
                else if (visibleWindowSeen)
                {
                    if (noVisibleWindowSince == DateTime.MinValue) noVisibleWindowSince = DateTime.UtcNow;
                    else if ((DateTime.UtcNow - noVisibleWindowSince).TotalMilliseconds >= 3000)
                    {
                        lock (sync) stoppedAfterWindowClosed = true;
                        StopProcessTree();
                        return;
                    }
                }
                Thread.Sleep(250);
            }
        }

        private static bool HasVisibleDesktopWindow(uint processId)
        {
            bool found = false;
            NativeMethods.EnumWindowsProc callback = delegate(IntPtr window, IntPtr parameter)
            {
                uint ownerProcess;
                NativeMethods.GetWindowThreadProcessId(window, out ownerProcess);
                if (ownerProcess != processId || !NativeMethods.IsWindowVisible(window)) return true;
                NativeMethods.RECT bounds;
                if (!NativeMethods.GetWindowRect(window, out bounds)) return true;
                if (bounds.Right - bounds.Left < 100 || bounds.Bottom - bounds.Top < 100) return true;
                found = true;
                return false;
            };
            NativeMethods.EnumWindows(callback, IntPtr.Zero);
            GC.KeepAlive(callback);
            return found;
        }

        internal void StopProcessTree()
        {
            lock (sync)
            {
                if (jobHandle != IntPtr.Zero) NativeMethods.TerminateJobObject(jobHandle, 0);
            }
        }

        public void Dispose()
        {
            lock (sync)
            {
                if (jobHandle != IntPtr.Zero)
                {
                    NativeMethods.TerminateJobObject(jobHandle, 0);
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
        internal struct RECT
        {
            internal int Left;
            internal int Top;
            internal int Right;
            internal int Bottom;
        }

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

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
            internal long TotalUserTime;
            internal long TotalKernelTime;
            internal long ThisPeriodTotalUserTime;
            internal long ThisPeriodTotalKernelTime;
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

        [DllImport("wintrust.dll", ExactSpelling = true, SetLastError = true, CharSet = CharSet.Unicode)]
        internal static extern int WinVerifyTrust(IntPtr hwnd, [In] ref Guid actionId, [In] ref WINTRUST_DATA data);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern IntPtr CreateJobObject(IntPtr securityAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetInformationJobObject(IntPtr job, int informationClass, IntPtr information, uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool QueryInformationJobObject(IntPtr job, int informationClass, IntPtr information, uint informationLength, IntPtr returnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool TerminateJobObject(IntPtr job, uint exitCode);

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
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CloseHandle(IntPtr handle);

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

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool IsWindowVisible(IntPtr window);

        [DllImport("user32.dll", SetLastError = true)]
        internal static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetWindowRect(IntPtr window, out RECT bounds);

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
        internal static extern IntPtr CreateFile(string fileName, uint desiredAccess, uint shareMode,
            IntPtr securityAttributes, uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CopyFile(string existingFileName, string newFileName,
            [MarshalAs(UnmanagedType.Bool)] bool failIfExists);

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
        private const string UnconfiguredModel = "portable-api-not-configured";
        private const string SecretExcludes = "[\"OPENAI_API_KEY\", \"CODEX_API_KEY\", \"CODEX_PORTABLE_API_KEY\", \"OPENAI_BASE_URL\", \"CODEX_APP_SERVER_OPENAI_BASE_URL\", \"ANTHROPIC_API_KEY\", \"AZURE_OPENAI_API_KEY\", \"AWS_ACCESS_KEY_ID\", \"AWS_SECRET_ACCESS_KEY\", \"AWS_SESSION_TOKEN\", \"GITHUB_TOKEN\", \"GH_TOKEN\"]";
        internal static readonly string[] RequiredPlugins = new string[] {
            "browser@openai-bundled", "chrome@openai-bundled", "computer-use@openai-bundled",
            "latex@openai-bundled", "visualize@openai-bundled",
            "documents@openai-primary-runtime", "pdf@openai-primary-runtime",
            "presentations@openai-primary-runtime", "spreadsheets@openai-primary-runtime",
            "template-creator@openai-primary-runtime"
        };

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
                if (!File.Exists(layout.ModelFile)) return null;
                string value = File.ReadAllText(layout.ModelFile, Encoding.UTF8).Trim();
                return IsValidModel(value) ? value : null;
            }
            catch { return null; }
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
            string model = ReadEffectiveModel(layout) ?? UnconfiguredModel;
            string bundledMarketplace = Path.Combine(layout.Resources, "plugins", "openai-bundled");
            string primaryMarketplace = Path.Combine(layout.CodexHome, "offline-marketplaces", "openai-primary-runtime");
            StringBuilder text = new StringBuilder();
            text.AppendLine("# Generated by Codex Portable. Manual edits are replaced on launch.");
            text.AppendLine("model = " + QuoteToml(model));
            text.AppendLine("model_provider = " + QuoteToml(ProviderId));
            text.AppendLine(DeveloperInstructionsConfigLine);
            text.AppendLine(ReasoningEffortConfigLine);
            text.AppendLine("chatgpt_base_url = \"http://127.0.0.1:9\"");
            text.AppendLine(ApprovalPolicyConfigLine);
            text.AppendLine(SandboxModeConfigLine);
            text.AppendLine("cli_auth_credentials_store = \"file\"");
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
            for (int i = 0; i < RequiredPlugins.Length; i++)
            {
                text.AppendLine();
                text.AppendLine("[plugins." + QuoteToml(RequiredPlugins[i]) + "]");
                text.AppendLine("enabled = true");
            }
            WriteConfigIfChanged(layout.ConfigFile, text.ToString());
        }

        internal static int CountConfiguredPlugins(string config)
        {
            int count = 0;
            for (int i = 0; i < RequiredPlugins.Length; i++)
                if (config.IndexOf("[plugins.\"" + RequiredPlugins[i] + "\"]", StringComparison.OrdinalIgnoreCase) >= 0) count++;
            return count;
        }

        internal static int RequiredPluginCount { get { return RequiredPlugins.Length; } }

        internal static bool RequiredPluginCacheComplete(PortableLayout layout)
        {
            return PluginCacheRecovery.RequiredPluginCacheComplete(layout, RequiredPlugins);
        }

        private static string EscapeToml(string value)
        {
            return value.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n");
        }

        private static string QuoteToml(string value)
        {
            return "\"" + EscapeToml(value) + "\"";
        }

        private static void WriteConfigIfChanged(string file, string value)
        {
            if (File.Exists(file) && string.Equals(File.ReadAllText(file, Encoding.UTF8), value, StringComparison.Ordinal)) return;
            IOUtil.AtomicWriteText(file, value);
        }
    }

    internal static class PortableEnvironment
    {
        internal const string DesktopBrandEnvironmentVariable = "CODEX_APP_BRAND";
        internal const string DesktopBrand = "codex";
        internal const string RemoteControlDisabledEnvironmentVariable = "CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED";

        internal static string FindMissingPrerequisite(PortableLayout p, bool pluginCacheAlreadyVerified)
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
            if (!pluginCacheAlreadyVerified && !ProviderConfiguration.RequiredPluginCacheComplete(p))
                return Path.Combine(p.CodexHome, "plugins", "cache");
            return null;
        }

        internal static Dictionary<string, string> Build(PortableLayout p, string apiKey)
        {
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
            Set(env, "CODEX_CLI_PATH", p.CodexExe);
            Set(env, DesktopBrandEnvironmentVariable, DesktopBrand);
            Set(env, RemoteControlDisabledEnvironmentVariable, "1");
            Set(env, "CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH", Path.Combine(p.Resources, "plugins"));
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
            Set(env, "UV_CACHE_DIR", activeUvCache);
            Set(env, "CARGO_HOME", Path.Combine(p.Profile, "cargo"));
            Set(env, "RUSTUP_HOME", Path.Combine(p.Profile, "rustup"));
            Set(env, "GIT_CONFIG_GLOBAL", Path.Combine(p.Profile, "gitconfig"));
            Set(env, "GIT_CONFIG_NOSYSTEM", "1");

            List<string> portablePath = new List<string>();
            AddDirectory(portablePath, Path.Combine(p.Runtime, "dependencies", "bin", "override"));
            AddDirectory(portablePath, Path.Combine(p.Runtime, "dependencies", "bin", "fallback"));
            AddDirectory(portablePath, Path.Combine(p.Runtime, "dependencies", "node", "bin"));
            AddDirectory(portablePath, Path.Combine(p.Runtime, "dependencies", "python"));
            AddDirectory(portablePath, Path.Combine(p.Runtime, "dependencies", "python", "Scripts"));
            AddDirectory(portablePath, Path.Combine(p.Runtime, "dependencies", "native", "git", "cmd"));
            AddDirectory(portablePath, Path.Combine(p.Runtime, "dependencies", "native", "git", "bin"));
            AddDirectory(portablePath, Path.Combine(p.Runtime, "dependencies", "git", "cmd"));
            AddDirectory(portablePath, Path.Combine(p.Runtime, "dependencies", "git", "bin"));
            AddDirectory(portablePath, Path.Combine(p.Runtime, "node"));
            AddDirectory(portablePath, Path.Combine(p.Runtime, "python"));
            AddDirectory(portablePath, Path.Combine(p.Runtime, "python", "Scripts"));
            AddDirectory(portablePath, Path.Combine(p.Runtime, "git", "cmd"));
            AddDirectory(portablePath, Path.Combine(p.Runtime, "git", "bin"));
            AddDirectory(portablePath, Path.Combine(p.Tools, "dotnet"));
            AddDirectory(portablePath, Path.Combine(p.Tools, "gh", "bin"));
            AddDirectory(portablePath, Path.Combine(p.Tools, "gh"));
            AddDirectory(portablePath, p.Resources);
            string windowsRoot = Environment.GetEnvironmentVariable("SystemRoot");
            if (!string.IsNullOrEmpty(windowsRoot))
            {
                AddDirectory(portablePath, Path.Combine(windowsRoot, "System32"));
                AddDirectory(portablePath, windowsRoot);
                AddDirectory(portablePath, Path.Combine(windowsRoot, "System32", "WindowsPowerShell", "v1.0"));
                AddDirectory(portablePath, Path.Combine(windowsRoot, "System32", "OpenSSH"));
            }

            string node = FindFile(new string[] {
                Path.Combine(p.Runtime, "dependencies", "node", "bin", "node.exe"),
                Path.Combine(p.Runtime, "node", "node.exe"),
                Path.Combine(p.Resources, "cua_node", "bin", "node.exe")
            });
            if (node != null) Set(env, "CODEX_BROWSER_USE_NODE_PATH", node);
            string nodeRepl = FindFile(new string[] {
                Path.Combine(p.Resources, "cua_node", "bin", "node_repl.exe"),
                Path.Combine(p.Runtime, "dependencies", "node", "bin", "node_repl.exe")
            });
            if (nodeRepl != null) Set(env, "CODEX_NODE_REPL_PATH", nodeRepl);
            string git = FindFile(new string[] {
                Path.Combine(p.Runtime, "dependencies", "native", "git", "cmd", "git.exe"),
                Path.Combine(p.Runtime, "dependencies", "native", "git", "bin", "git.exe"),
                Path.Combine(p.Runtime, "dependencies", "git", "cmd", "git.exe"),
                Path.Combine(p.Runtime, "dependencies", "git", "bin", "git.exe"),
                Path.Combine(p.Runtime, "git", "cmd", "git.exe"),
                Path.Combine(p.Runtime, "git", "bin", "git.exe")
            });
            if (git != null) Set(env, "CODEX_PREFERRED_GIT_EXECUTABLE", git);

            string dotnet = Path.Combine(p.Tools, "dotnet", "dotnet.exe");
            if (File.Exists(dotnet))
            {
                Set(env, "DOTNET_ROOT", Path.Combine(p.Tools, "dotnet"));
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
    }

    internal static class AppUpdater
    {
        internal const string ExpectedName = "OpenAI.Codex";
        internal const string ExpectedPublisher = "CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B";
        private const long MaximumPackageBytes = 3L * 1024L * 1024L * 1024L;

        internal static Task<PackageInfo> UpdateAsync(PortableLayout layout, IProgress<int> progress)
        {
            return Task.Run(delegate { return DownloadAndInstall(layout, progress); });
        }

        private static PackageInfo DownloadAndInstall(PortableLayout layout, IProgress<int> progress)
        {
            string officialUrl = ArchitectureInfo.OfficialUrl(layout.Architecture);
            if (string.IsNullOrEmpty(officialUrl))
                throw new InvalidOperationException("No official Codex Desktop package is published for Windows architecture " + layout.ArchitectureName + ".");
            layout.EnsureDirectories();
            string token = Guid.NewGuid().ToString("N").Substring(0, 12);
            string package = Path.Combine(layout.Updates, "d-" + token + ".msix");
            string staging = Path.Combine(layout.Updates, "s-" + token);
            try
            {
                Download(package, officialUrl, progress);
                if (!SignatureVerifier.Verify(package)) throw new InvalidDataException("The MSIX signature is not trusted.");
                PackageInfo info = ReadAndValidateManifest(package, layout.Architecture);
                Version installed = ReadCurrentPackageVersion(layout);
                if (installed != null && info.Version.CompareTo(installed) < 0)
                    throw new InvalidOperationException("The official channel package is older than the installed version; downgrade refused.");
                if (progress != null) progress.Report(-1);
                Directory.CreateDirectory(staging);
                ExtractWithTar(package, staging);
                DecodeUriEscapedNames(staging);
                string payload = GetPayloadRoot(staging);
                ValidateExtracted(payload, info);
                string digest = IOUtil.Sha256File(package);
                string marker = info.Name + "\r\n" + info.Publisher + "\r\n" + info.Version.ToString() + "\r\n" + info.Architecture + "\r\nsha256=" + digest + "\r\n";
                IOUtil.AtomicWriteText(Path.Combine(payload, ".portable-package.txt"), marker);
                PortableBranding.PreparePayload(payload);
                InstallStaging(layout, payload);
                if (progress != null) progress.Report(100);
                return info;
            }
            finally
            {
                IOUtil.TryDelete(package);
                if (Directory.Exists(staging)) IOUtil.DeleteDirectoryWithin(staging, layout.Updates);
            }
        }

        private static void Download(string target, string officialUrl, IProgress<int> progress)
        {
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(officialUrl);
            request.Method = "GET";
            request.AllowAutoRedirect = true;
            request.MaximumAutomaticRedirections = 5;
            request.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
            request.UserAgent = "CodexPortable/1.0";
            request.Timeout = 60000;
            request.ReadWriteTimeout = 60000;
            request.Proxy = WebRequest.DefaultWebProxy;
            if (request.Proxy != null) request.Proxy.Credentials = CredentialCache.DefaultCredentials;

            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            {
                if (response.StatusCode != HttpStatusCode.OK) throw new WebException("Unexpected HTTP status.");
                if (!string.Equals(response.ResponseUri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
                    throw new WebException("Update redirected to a non-HTTPS endpoint.");
                long total = response.ContentLength;
                if (total > MaximumPackageBytes) throw new InvalidDataException("Package is too large.");
                if (total > 0)
                {
                    DriveInfo drive = new DriveInfo(Path.GetPathRoot(target));
                    if (drive.AvailableFreeSpace < total + 512L * 1024L * 1024L) throw new IOException("Insufficient free space.");
                }

                byte[] buffer = new byte[1024 * 1024];
                long received = 0;
                using (Stream input = response.GetResponseStream())
                using (FileStream output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None, buffer.Length, FileOptions.SequentialScan))
                {
                    while (true)
                    {
                        int count = input.Read(buffer, 0, buffer.Length);
                        if (count == 0) break;
                        received += count;
                        if (received > MaximumPackageBytes) throw new InvalidDataException("Package is too large.");
                        output.Write(buffer, 0, count);
                        if (progress != null && total > 0) progress.Report((int)Math.Min(95L, received * 95L / total));
                    }
                    output.Flush(true);
                }
                Array.Clear(buffer, 0, buffer.Length);
                if (received < 1024 * 1024) throw new InvalidDataException("Downloaded package is unexpectedly small.");
                if (total >= 0 && received != total) throw new EndOfStreamException("Download was incomplete.");
            }
        }

        private static PackageInfo ReadAndValidateManifest(string package, PortableArchitecture expectedArchitecture)
        {
            using (FileStream stream = new FileStream(package, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (ZipArchive zip = new ZipArchive(stream, ZipArchiveMode.Read, false))
            {
                bool chatGpt = false;
                bool codex = false;
                ZipArchiveEntry manifest = null;
                string fakeRoot = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "codex-package-root")) + Path.DirectorySeparatorChar;
                foreach (ZipArchiveEntry entry in zip.Entries)
                {
                    string name = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
                    string resolved = Path.GetFullPath(Path.Combine(fakeRoot, name));
                    if (!resolved.StartsWith(fakeRoot, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Package path traversal detected.");
                    if (string.Equals(entry.FullName, "AppxManifest.xml", StringComparison.OrdinalIgnoreCase)) manifest = entry;
                    if (string.Equals(entry.FullName, "ChatGPT.exe", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(entry.FullName, "app/ChatGPT.exe", StringComparison.OrdinalIgnoreCase)) chatGpt = true;
                    if (string.Equals(entry.FullName, "resources/codex.exe", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(entry.FullName, "app/resources/codex.exe", StringComparison.OrdinalIgnoreCase)) codex = true;
                }
                if (manifest == null || manifest.Length <= 0 || manifest.Length > 2 * 1024 * 1024) throw new InvalidDataException("Manifest is missing or invalid.");
                if (!chatGpt || !codex) throw new InvalidDataException("Required application files are missing.");
                using (Stream manifestStream = manifest.Open()) return ParseAndValidateManifest(manifestStream, expectedArchitecture);
            }
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

        private static void ExtractWithTar(string package, string staging)
        {
            string tar = Path.Combine(Environment.SystemDirectory, "tar.exe");
            if (!File.Exists(tar)) throw new FileNotFoundException("Windows tar.exe is unavailable.", tar);
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = tar;
            psi.Arguments = "-xf " + IOUtil.QuoteArgument(package) + " -C " + IOUtil.QuoteArgument(staging);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            using (Process process = Process.Start(psi))
            {
                Task<string> stdout = process.StandardOutput.ReadToEndAsync();
                Task<string> stderr = process.StandardError.ReadToEndAsync();
                if (!process.WaitForExit(45 * 60 * 1000))
                {
                    try { process.Kill(); } catch { }
                    throw new TimeoutException("Package extraction timed out.");
                }
                Task.WaitAll(new Task[] { stdout, stderr }, 5000);
                if (process.ExitCode != 0) throw new InvalidDataException("Package extraction failed.");
            }
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
        }

        private static string GetPayloadRoot(string staging)
        {
            string nested = Path.Combine(staging, "app");
            if (File.Exists(Path.Combine(nested, "ChatGPT.exe"))) return nested;
            return staging;
        }

        private static void DecodeUriEscapedNames(string staging)
        {
            // MSIX ZIP names use URI escaping. bsdtar deliberately preserves the literal
            // archive names, so decode each segment before the unpacked app is used.
            string[] files = Directory.GetFiles(staging, "*", SearchOption.AllDirectories);
            Array.Sort(files, delegate(string a, string b) { return b.Length.CompareTo(a.Length); });
            for (int i = 0; i < files.Length; i++) RenameDecodedLeaf(files[i], false);

            string[] directories = Directory.GetDirectories(staging, "*", SearchOption.AllDirectories);
            Array.Sort(directories, delegate(string a, string b)
            {
                int depth = PathDepth(b).CompareTo(PathDepth(a));
                return depth != 0 ? depth : b.Length.CompareTo(a.Length);
            });
            for (int i = 0; i < directories.Length; i++) RenameDecodedLeaf(directories[i], true);
        }

        private static int PathDepth(string path)
        {
            int depth = 0;
            for (int i = 0; i < path.Length; i++) if (path[i] == Path.DirectorySeparatorChar || path[i] == Path.AltDirectorySeparatorChar) depth++;
            return depth;
        }

        private static void RenameDecodedLeaf(string path, bool directory)
        {
            string leaf = Path.GetFileName(path);
            if (leaf.IndexOf('%') < 0) return;
            string decoded = Uri.UnescapeDataString(leaf);
            if (string.Equals(leaf, decoded, StringComparison.Ordinal)) return;
            if (decoded.Length == 0 || decoded == "." || decoded == ".." || decoded.EndsWith(".", StringComparison.Ordinal) ||
                decoded.EndsWith(" ", StringComparison.Ordinal) || decoded.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
                throw new InvalidDataException("Unsafe URI-escaped package path.");
            if (directory)
            {
                for (int i = 0; i < decoded.Length; i++) if (decoded[i] > 127) throw new InvalidDataException("Non-ASCII package directory name refused.");
            }
            string target = Path.Combine(Path.GetDirectoryName(path), decoded);
            if (File.Exists(target) || Directory.Exists(target)) throw new InvalidDataException("Decoded package path collision.");
            if (directory) Directory.Move(path, target);
            else File.Move(path, target);
        }

        private static void InstallStaging(PortableLayout layout, string staging)
        {
            string current = layout.CurrentApp;
            string rollback = layout.Rollback;
            if (Directory.Exists(rollback)) IOUtil.DeleteDirectoryWithin(rollback, layout.DataRoot);
            bool currentMoved = false;
            try
            {
                if (Directory.Exists(current))
                {
                    Directory.Move(current, rollback);
                    currentMoved = true;
                }
                Directory.Move(staging, current);
            }
            catch
            {
                if (!Directory.Exists(current) && currentMoved && Directory.Exists(rollback))
                {
                    try { Directory.Move(rollback, current); } catch { }
                }
                throw;
            }
        }

        internal static void Rollback(PortableLayout layout)
        {
            if (!Directory.Exists(layout.Rollback)) throw new DirectoryNotFoundException("Rollback version is missing.");
            string swap = Path.Combine(layout.DataRoot, "app", "swap-" + Guid.NewGuid().ToString("N"));
            Directory.Move(layout.CurrentApp, swap);
            try
            {
                Directory.Move(layout.Rollback, layout.CurrentApp);
                try { Directory.Move(swap, layout.Rollback); }
                catch
                {
                    // The selected rollback is already usable. Preserve the former current version under its safe swap name.
                    throw;
                }
            }
            catch
            {
                if (!Directory.Exists(layout.CurrentApp) && Directory.Exists(swap))
                {
                    try { Directory.Move(swap, layout.CurrentApp); } catch { }
                }
                throw;
            }
            PortableBranding.EnsurePortablePayload(layout);
        }

        internal static string ReadInstalledVersion(PortableLayout layout)
        {
            try
            {
                string marker = Path.Combine(layout.CurrentApp, ".portable-package.txt");
                if (File.Exists(marker))
                {
                    string[] lines = File.ReadAllLines(marker, Encoding.UTF8);
                    if (lines.Length >= 3) return lines[2];
                }
                string versionExecutable = File.Exists(layout.AppExe) ? layout.AppExe : layout.OfficialAppExe;
                if (File.Exists(versionExecutable))
                {
                    string version = FileVersionInfo.GetVersionInfo(versionExecutable).FileVersion;
                    return string.IsNullOrEmpty(version) ? "已安装（版本未知）" : version;
                }
            }
            catch { }
            return "未安装";
        }

        private static Version ReadCurrentPackageVersion(PortableLayout layout)
        {
            try
            {
                string marker = Path.Combine(layout.CurrentApp, ".portable-package.txt");
                if (!File.Exists(marker)) return null;
                string[] lines = File.ReadAllLines(marker, Encoding.UTF8);
                Version parsed;
                return lines.Length >= 3 && Version.TryParse(lines[2].Trim(), out parsed) ? parsed : null;
            }
            catch { return null; }
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
                if (!SignatureVerifier.Verify(package)) throw new InvalidDataException("The MSIX signature is not trusted.");
                PackageInfo info = ReadAndValidateManifest(package, expectedArchitecture);
                Directory.CreateDirectory(staging);
                ExtractWithTar(package, staging);
                DecodeUriEscapedNames(staging);
                ValidateExtracted(GetPayloadRoot(staging), info);
                return info;
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
            Text = "设置自定义 API";
            Font = new Font("Microsoft YaHei UI", 9F);
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = false;
            ClientSize = new Size(520, 340);

            AddLabel("Responses API Base URL（HTTPS；本机测试可用 HTTP loopback）", 24, 18, 470);
            baseUrlBox = AddTextBox(24, 45, 470, true);
            baseUrlBox.MaxLength = 2048;
            baseUrlBox.Text = currentBaseUrl ?? "";

            AddLabel("网关模型名", 24, 88, 470);
            modelBox = AddTextBox(24, 115, 470, true);
            modelBox.MaxLength = 200;
            modelBox.Text = currentModel ?? "";

            AddLabel("API Key", 24, 158, 470);
            keyBox = AddTextBox(24, 185, 470, true);
            keyBox.MaxLength = 1024;
            keyBox.UseSystemPasswordChar = true;
            keyBox.Text = currentApiKey ?? "";

            CheckBox showKey = new CheckBox();
            showKey.Text = "显示 Key";
            showKey.AutoSize = true;
            showKey.Location = new Point(24, 221);
            showKey.CheckedChanged += delegate
            {
                keyBox.UseSystemPasswordChar = !showKey.Checked;
            };
            Controls.Add(showKey);

            Label note = new Label();
            note.Text = "Key 仅以明文保存在 CodexData\\data\\secrets 中；不会生成 auth.json，也不会提供 OpenAI/ChatGPT 登录。";
            note.ForeColor = Color.DimGray;
            note.Location = new Point(24, 248);
            note.Size = new Size(470, 42);
            Controls.Add(note);

            Button save = new Button();
            save.Text = "保存";
            save.Location = new Point(306, 294);
            save.Size = new Size(88, 32);
            save.Click += SaveClicked;
            Controls.Add(save);

            Button cancel = new Button();
            cancel.Text = "取消";
            cancel.DialogResult = DialogResult.Cancel;
            cancel.Location = new Point(406, 294);
            cancel.Size = new Size(88, 32);
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
            Controls.Add(l);
        }

        private TextBox AddTextBox(int x, int y, int width, bool singleLine)
        {
            TextBox box = new TextBox();
            box.Location = new Point(x, y);
            box.Size = new Size(width, 27);
            box.Multiline = !singleLine;
            Controls.Add(box);
            return box;
        }

        private void SaveClicked(object sender, EventArgs e)
        {
            string key = keyBox.Text.Trim();
            if (!ProviderConfiguration.IsValidApiKey(key))
            {
                MessageBox.Show("API Key 必须是 1–1024 个不含空格或换行的字符。", "设置自定义 API",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                keyBox.Focus();
                return;
            }
            string baseUrl;
            if (!ProviderConfiguration.TryNormalizeBaseUrl(baseUrlBox.Text, out baseUrl))
            {
                MessageBox.Show("Base URL 必须是绝对 HTTPS 地址；仅 localhost/127.0.0.1/::1 可使用 HTTP，且不能含账号、查询参数或片段。", "设置自定义 API",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                baseUrlBox.Focus();
                return;
            }
            string model = modelBox.Text.Trim();
            if (!ProviderConfiguration.IsValidModel(model))
            {
                MessageBox.Show("模型名必须是 1–200 个不含空格或换行的字符。", "设置自定义 API",
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
