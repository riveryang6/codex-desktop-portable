// Codex Portable architecture bootstrapper.
// Build target: Windows x86, .NET Framework 4.8, C# 5 compatible.

using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("LF Portable")]
[assembly: AssemblyDescription("Architecture selector for LF Portable")]
[assembly: AssemblyCompany("LF")]
[assembly: AssemblyProduct("LF Portable")]
[assembly: AssemblyCopyright("Copyright (c) 2026")]
[assembly: AssemblyVersion("1.4.20.0")]
[assembly: AssemblyFileVersion("1.4.20.0")]
[assembly: ComVisible(false)]

namespace CodexPortableBootstrap
{
    internal static class Program
    {
        private const ushort ImageFileMachineI386 = 0x014c;
        private const ushort ImageFileMachineArm = 0x01c4;
        private const ushort ImageFileMachineAmd64 = 0x8664;
        private const ushort ImageFileMachineArm64 = 0xAA64;

        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                if (args.Length >= 1 && string.Equals(args[0], "--apply-release",
                    StringComparison.OrdinalIgnoreCase))
                {
                    int coreProcessId;
                    int bootstrapperProcessId;
                    if (args.Length != 5 ||
                        !int.TryParse(args[3], NumberStyles.None, CultureInfo.InvariantCulture,
                            out coreProcessId) || coreProcessId <= 0 ||
                        !int.TryParse(args[4], NumberStyles.None, CultureInfo.InvariantCulture,
                            out bootstrapperProcessId) || bootstrapperProcessId < 0 ||
                        coreProcessId == bootstrapperProcessId)
                        return 41;
                    return ReleaseRecovery.RunApplyWorker(args[1], args[2], coreProcessId,
                        bootstrapperProcessId);
                }
                if (args.Length >= 4 && string.Equals(args[0], "--recover-release",
                    StringComparison.OrdinalIgnoreCase))
                {
                    int parentProcessId;
                    if (!int.TryParse(args[3], NumberStyles.None, CultureInfo.InvariantCulture,
                        out parentProcessId) || parentProcessId <= 0)
                        return 41;
                    List<string> resumeArguments = new List<string>();
                    for (int i = 4; i < args.Length; i++) resumeArguments.Add(args[i]);
                    return ReleaseRecovery.RunWorker(args[1], args[2], parentProcessId, resumeArguments);
                }
                for (int i = 0; i < args.Length; i++)
                {
                    if (string.Equals(args[i], "--portable-root", StringComparison.OrdinalIgnoreCase) ||
                        args[i].StartsWith("--portable-root=", StringComparison.OrdinalIgnoreCase))
                    {
                        MessageBox.Show("--portable-root is reserved for the Codex Portable bootstrapper.",
                            "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return 41;
                    }
                    if (string.Equals(args[i], "--recover-release", StringComparison.OrdinalIgnoreCase) ||
                        args[i].StartsWith("--recover-release=", StringComparison.OrdinalIgnoreCase))
                    {
                        MessageBox.Show("--recover-release is reserved for the LF Portable recovery helper.",
                            "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return 41;
                    }
                    if (string.Equals(args[i], "--apply-release", StringComparison.OrdinalIgnoreCase) ||
                        args[i].StartsWith("--apply-release=", StringComparison.OrdinalIgnoreCase))
                    {
                        MessageBox.Show("--apply-release is reserved for the LF Portable update helper.",
                            "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return 41;
                    }
                    if (string.Equals(args[i], "--bootstrapper-pid", StringComparison.OrdinalIgnoreCase) ||
                        args[i].StartsWith("--bootstrapper-pid=", StringComparison.OrdinalIgnoreCase))
                    {
                        MessageBox.Show("--bootstrapper-pid is reserved for the LF Portable bootstrapper.",
                            "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return 41;
                    }
                }
                string root = Path.GetFullPath(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location));
                int recoveryExitCode;
                if (ReleaseRecovery.DispatchIfRequired(root, args, out recoveryExitCode))
                    return recoveryExitCode;
                string architecture = DetectNativeArchitecture();
                List<string> childArguments = new List<string>();
                childArguments.Add("--portable-root");
                childArguments.Add(root);
                // The core passes this PID to the external full-release helper,
                // which must wait until this x86 bootstrapper releases the root
                // executable before atomically replacing it.
                childArguments.Add("--bootstrapper-pid");
                childArguments.Add(Process.GetCurrentProcess().Id.ToString());
                for (int i = 0; i < args.Length; i++) childArguments.Add(args[i]);
                string launchArguments = JoinArguments(childArguments);
                string variantDirectory = Path.Combine(root, "CodexData", "tools", "launchers");
                string primary = Path.Combine(variantDirectory, "CodexPortable." + architecture + ".exe");
                string fallback = Path.Combine(variantDirectory, "CodexPortable.x86.exe");
                string[] candidates = string.Equals(architecture, "x86", StringComparison.Ordinal) ?
                    new string[] { primary } : new string[] { primary, fallback };
                Exception lastStartError = null;
                for (int i = 0; i < candidates.Length; i++)
                {
                    string launcher = candidates[i];
                    if (!File.Exists(launcher)) continue;
                    try
                    {
                        ProcessStartInfo info = new ProcessStartInfo();
                        info.FileName = launcher;
                        info.Arguments = launchArguments;
                        info.WorkingDirectory = root;
                        info.UseShellExecute = false;
                        info.CreateNoWindow = true;
                        using (Process child = Process.Start(info))
                        {
                            if (child == null) throw new InvalidOperationException("Unable to create launcher process.");
                            child.WaitForExit();
                            return child.ExitCode;
                        }
                    }
                    catch (Exception ex)
                    {
                        lastStartError = ex;
                    }
                }
                MessageBox.Show("Codex Portable cannot start its " + architecture +
                    " launcher component or the x86 compatibility fallback. Rebuild or repair the portable program files." +
                    (lastStartError == null ? "" : "\r\n\r\n" + lastStartError.GetType().Name + ": " + lastStartError.Message),
                    "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 40;
            }
            catch (Exception ex)
            {
                MessageBox.Show("Codex Portable architecture bootstrap failed.\r\n\r\n" +
                    ex.GetType().Name + ": " + ex.Message, "Codex Portable",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 42;
            }
        }

        private static string DetectNativeArchitecture()
        {
            try
            {
                ushort processMachine;
                ushort nativeMachine;
                if (IsWow64Process2(GetCurrentProcess(), out processMachine, out nativeMachine))
                {
                    ushort machine = nativeMachine == 0 ? processMachine : nativeMachine;
                    string result = NameForMachine(machine);
                    if (result != null) return result;
                }
            }
            catch (EntryPointNotFoundException) { }
            catch (DllNotFoundException) { }
            catch (BadImageFormatException) { }

            SYSTEM_INFO info;
            GetNativeSystemInfo(out info);
            switch (info.wProcessorArchitecture)
            {
                case 0: return "x86";
                case 5: return "arm";
                case 9: return "x64";
                case 12: return "arm64";
                default: return Environment.Is64BitOperatingSystem ? "x64" : "x86";
            }
        }

        private static string NameForMachine(ushort machine)
        {
            if (machine == ImageFileMachineI386) return "x86";
            if (machine == ImageFileMachineAmd64) return "x64";
            if (machine == ImageFileMachineArm) return "arm";
            if (machine == ImageFileMachineArm64) return "arm64";
            return null;
        }

        private static string JoinArguments(List<string> arguments)
        {
            StringBuilder result = new StringBuilder();
            for (int i = 0; i < arguments.Count; i++)
            {
                if (i != 0) result.Append(' ');
                result.Append(QuoteArgument(arguments[i]));
            }
            return result.ToString();
        }

        private static string QuoteArgument(string argument)
        {
            if (argument.Length > 0 && argument.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0)
                return argument;
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

        [StructLayout(LayoutKind.Sequential)]
        private struct SYSTEM_INFO
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

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsWow64Process2(IntPtr process, out ushort processMachine,
            out ushort nativeMachine);

        [DllImport("kernel32.dll")]
        private static extern void GetNativeSystemInfo(out SYSTEM_INFO systemInfo);
    }

    // This runs only from a private copy outside the portable root.  A full LF
    // release can replace the bootstrapper itself, so recovery cannot run from
    // the executable being restored.
    internal static class ReleaseRecovery
    {
        private const string TransactionPrefix = "release-apply-";
        private const int TransactionNameLength = 46;
        private const int DescriptorMaximumBytes = 1024 * 1024;
        private const int WaitMilliseconds = 30000;
        private const int ParentExitWaitMilliseconds = 5 * 60 * 1000;
        private const uint ProcessQueryLimitedInformation = 0x1000;
        private const uint MoveFileReplaceExisting = 0x00000001;
        private const uint MoveFileWriteThrough = 0x00000008;
        private const uint MaximumProcessImagePath = 32768;
        private const string PortableDesktopExecutableName = "CodexDesktop.exe";

        private static readonly string[] ManagedFiles = new string[] {
            "CodexData/README.txt",
            "CodexData/THIRD_PARTY.txt",
            "CodexData/tools/launchers/CodexPortable.x86.exe",
            "CodexData/tools/launchers/CodexPortable.x64.exe",
            "CodexData/tools/launchers/CodexPortable.arm64.exe",
            "CodexData/packages/LFPortable-common.zip",
            "CodexData/packages/LFPortable-x64.msix",
            "CodexData/packages/LFPortable-arm64.msix",
            "CodexPortable.exe",
            "CodexData/portable-release.json"
        };

        private static readonly string[] BackupDirectories = new string[] {
            "CodexData",
            "CodexData/tools",
            "CodexData/tools/launchers",
            "CodexData/packages"
        };

        private static readonly string[] TransactionRootEntries = new string[] {
            "backup",
            "staged",
            "commit-descriptor.json"
        };

        private static readonly string[] TransactionDirectories = new string[] {
            "backup",
            "staged"
        };

        // Compact LF releases replace the archives, not the expanded runtime and
        // plugin trees.  These are the only expanded paths that belong to the
        // release; user data and unrecognized plugin caches deliberately remain.
        private static readonly string[] DerivedPayloadDirectories = new string[] {
            "CodexData/app/current",
            "CodexData/tools/desktop-payloads",
            "CodexData/tools/dotnet",
            "CodexData/tools/gh",
            "CodexData/data/profile/.cache/codex-runtimes",
            "CodexData/data/profile/.codex/offline-marketplaces",
            "CodexData/data/profile/.codex/plugins/cache/openai-bundled/sites",
            "CodexData/data/profile/.codex/plugins/cache/openai-bundled/browser",
            "CodexData/data/profile/.codex/plugins/cache/openai-bundled/chrome",
            "CodexData/data/profile/.codex/plugins/cache/openai-bundled/computer-use",
            "CodexData/data/profile/.codex/plugins/cache/openai-bundled/latex",
            "CodexData/data/profile/.codex/plugins/cache/openai-bundled/deep-research",
            "CodexData/data/profile/.codex/plugins/cache/openai-bundled/visualize",
            "CodexData/data/profile/.codex/plugins/cache/openai-primary-runtime/documents",
            "CodexData/data/profile/.codex/plugins/cache/openai-primary-runtime/pdf",
            "CodexData/data/profile/.codex/plugins/cache/openai-primary-runtime/presentations",
            "CodexData/data/profile/.codex/plugins/cache/openai-primary-runtime/spreadsheets",
            "CodexData/data/profile/.codex/plugins/cache/openai-primary-runtime/template-creator"
        };

        private sealed class ReleaseFile
        {
            internal string Path;
            internal long Length;
            internal string Sha256;
        }

        internal static bool DispatchIfRequired(string root, string[] resumeArguments,
            out int exitCode)
        {
            exitCode = 0;
            string transactionName = FindRecoveryTransaction(root);
            if (transactionName == null) return false;

            string helper = null;
            try
            {
                helper = CreateHelperCopy(root);
                List<string> arguments = new List<string>();
                arguments.Add("--recover-release");
                arguments.Add(root);
                arguments.Add(transactionName);
                arguments.Add(Process.GetCurrentProcess().Id.ToString());
                for (int i = 0; i < resumeArguments.Length; i++) arguments.Add(resumeArguments[i]);

                ProcessStartInfo info = new ProcessStartInfo();
                info.FileName = helper;
                info.Arguments = JoinArguments(arguments);
                info.WorkingDirectory = root;
                info.UseShellExecute = false;
                info.CreateNoWindow = true;
                using (Process worker = Process.Start(info))
                {
                    if (worker == null) throw new InvalidOperationException("Unable to start LF release recovery.");
                }
                return true;
            }
            catch
            {
                TryDelete(helper);
                throw;
            }
        }

        internal static int RunWorker(string rootArgument, string transactionName,
            int parentProcessId, List<string> resumeArguments)
        {
            string ownPath = Assembly.GetExecutingAssembly().Location;
            try
            {
                string root = NormalizePath(rootArgument);
                if (!Directory.Exists(root)) throw new DirectoryNotFoundException("Portable root is missing.");
                if (IsWithin(ownPath, root))
                    throw new InvalidOperationException("LF release recovery helper cannot run from the portable root.");
                if (!IsRecoveryTransactionName(transactionName))
                    throw new InvalidDataException("LF release recovery transaction name is invalid.");
                WaitForParentExit(parentProcessId);

                Mutex launcherMutex = null;
                Mutex mutationMutex = null;
                try
                {
                    string mutexName = GetMutexName(root);
                    launcherMutex = AcquireMutex(mutexName, "LF launcher");
                    mutationMutex = AcquireMutex(mutexName + "-mutation", "LF release recovery");
                    string discoveredTransaction = FindRecoveryTransaction(root);
                    if (!string.Equals(discoveredTransaction, transactionName, StringComparison.Ordinal))
                        throw new InvalidDataException("LF release recovery transaction changed while waiting for the launcher.");
                    if (IsPortableProcessRunning(root))
                        throw new IOException("Close LF/Codex before release recovery can continue.");

                    string transaction = GetTransactionDirectory(root, transactionName);
                    if (Directory.Exists(transaction))
                    {
                        AssertTransactionTree(root, transaction);
                        string installedDescriptor = Path.Combine(root, "CodexData", "portable-release.json");
                        string commitDescriptor = Path.Combine(transaction, "commit-descriptor.json");
                        if (FilesEqual(installedDescriptor, commitDescriptor, DescriptorMaximumBytes))
                        {
                            // The descriptor is the commit point. A matching byte-for-byte
                            // copy plus all content hashes proves that the new release was
                            // activated before a crash.
                            ReleaseFile[] committedFiles = ReadDescriptor(commitDescriptor);
                            if (InstalledTreeMatches(root, committedFiles))
                            {
                                InvalidateDerivedPayloads(root);
                                RetireTransaction(transaction, root);
                            }
                            else
                            {
                                RestoreBackup(root, transaction);
                                RetireTransaction(transaction, root);
                            }
                        }
                        else
                        {
                            RestoreBackup(root, transaction);
                            RetireTransaction(transaction, root);
                        }
                    }
                }
                finally
                {
                    ReleaseMutex(mutationMutex);
                    ReleaseMutex(launcherMutex);
                }

                StartBootstrapper(root, resumeArguments);
                return 0;
            }
            catch (Exception ex)
            {
                MessageBox.Show("LF release recovery could not complete.\r\n\r\n" +
                    ex.GetType().Name + ": " + ex.Message,
                    "LF Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 43;
            }
            finally
            {
                // Windows may keep a running image mapped until process exit. This
                // best-effort cleanup avoids accumulating helpers on systems that
                // permit deleting the image immediately; the system temp directory
                // remains the fallback cleanup boundary on older Windows versions.
                TryDelete(ownPath);
            }
        }

        internal static int RunApplyWorker(string rootArgument, string transactionName,
            int coreProcessId, int bootstrapperProcessId)
        {
            string ownPath = Assembly.GetExecutingAssembly().Location;
            try
            {
                string root = NormalizePath(rootArgument);
                if (!Directory.Exists(root)) throw new DirectoryNotFoundException("Portable root is missing.");
                if (IsWithin(ownPath, root))
                    throw new InvalidOperationException("LF release update helper cannot run from the portable root.");
                if (!IsRecoveryTransactionName(transactionName))
                    throw new InvalidDataException("LF release apply transaction name is invalid.");
                WaitForParentExit(coreProcessId);
                if (bootstrapperProcessId > 0) WaitForParentExit(bootstrapperProcessId);

                Mutex launcherMutex = null;
                Mutex mutationMutex = null;
                try
                {
                    string mutexName = GetMutexName(root);
                    launcherMutex = AcquireMutex(mutexName, "LF launcher");
                    mutationMutex = AcquireMutex(mutexName + "-mutation", "LF release update");
                    string discoveredTransaction = FindRecoveryTransaction(root);
                    if (!string.Equals(discoveredTransaction, transactionName, StringComparison.Ordinal))
                        throw new InvalidDataException("LF release update transaction changed while waiting for the launcher.");
                    if (IsPortableProcessRunning(root))
                        throw new IOException("Close LF/Codex before the release update can continue.");
                    string transaction = GetTransactionDirectory(root, transactionName);
                    if (!Directory.Exists(transaction))
                        throw new DirectoryNotFoundException("LF release update transaction is missing.");
                    AssertTransactionTree(root, transaction);
                    string installedDescriptor = Path.Combine(root, "CodexData", "portable-release.json");
                    string commitDescriptor = Path.Combine(transaction, "commit-descriptor.json");
                    if (FilesEqual(installedDescriptor, commitDescriptor, DescriptorMaximumBytes))
                    {
                        ReleaseFile[] committedFiles = ReadDescriptor(commitDescriptor);
                        if (InstalledTreeMatches(root, committedFiles))
                        {
                            InvalidateDerivedPayloads(root);
                            RetireTransaction(transaction, root);
                        }
                        else
                        {
                            RestoreBackup(root, transaction);
                            RetireTransaction(transaction, root);
                        }
                    }
                    else
                    {
                        ApplyStaged(root, transaction);
                        if (!FilesEqual(installedDescriptor, commitDescriptor, DescriptorMaximumBytes))
                            throw new IOException("LF release activation did not reach its descriptor commit point.");
                        InvalidateDerivedPayloads(root);
                        RetireTransaction(transaction, root);
                    }
                }
                finally
                {
                    ReleaseMutex(mutationMutex);
                    ReleaseMutex(launcherMutex);
                }
                return 0;
            }
            catch (Exception ex)
            {
                MessageBox.Show("LF release update could not complete. The previous release will be recovered on the next launch.\r\n\r\n" +
                    ex.GetType().Name + ": " + ex.Message,
                    "LF Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 44;
            }
            finally
            {
                TryDelete(ownPath);
            }
        }

        private static string FindRecoveryTransaction(string root)
        {
            string updates = Path.Combine(root, "CodexData", "updates");
            if (!Directory.Exists(updates)) return null;
            AssertNoReparseAncestry(updates, root);

            string transactionName = null;
            string[] entries = Directory.GetFileSystemEntries(updates, "*", SearchOption.TopDirectoryOnly);
            for (int i = 0; i < entries.Length; i++)
            {
                string name = Path.GetFileName(entries[i]);
                if (!IsRecoveryTransactionName(name)) continue;
                FileAttributes attributes = File.GetAttributes(entries[i]);
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("LF release recovery transaction cannot be a reparse point.");
                if ((attributes & FileAttributes.Directory) == 0)
                    throw new InvalidDataException("LF release recovery transaction is not a directory.");
                AssertNoReparseAncestry(entries[i], updates);
                if (transactionName != null)
                    throw new InvalidDataException("More than one LF release transaction was found.");
                transactionName = name;
            }
            return transactionName;
        }

        private static void RestoreBackup(string root, string transaction)
        {
            string backup = Path.Combine(transaction, "backup");
            ReleaseFile[] expected = ReadDescriptor(Path.Combine(backup, "CodexData", "portable-release.json"));
            AssertManagedTree(backup, "backup", expected);
            for (int i = 0; i < ManagedFiles.Length - 1; i++)
            {
                string relative = ManagedFiles[i];
                string source = Path.Combine(backup, ToNativeRelativePath(relative));
                string destination = Path.Combine(root, ToNativeRelativePath(relative));
                AtomicCopy(source, destination, root);
            }

            string descriptorSource = Path.Combine(backup, "CodexData", "portable-release.json");
            string descriptorDestination = Path.Combine(root, "CodexData", "portable-release.json");
            AtomicCopy(descriptorSource, descriptorDestination, root);

            string restoredDescriptor = Path.Combine(root, "CodexData", "portable-release.json");
            string backupDescriptor = Path.Combine(backup, "CodexData", "portable-release.json");
            if (!FilesEqual(restoredDescriptor, backupDescriptor, DescriptorMaximumBytes))
                throw new IOException("LF release descriptor restoration did not verify.");
            AssertInstalledTree(root, expected);
        }

        private static void ApplyStaged(string root, string transaction)
        {
            string staged = Path.Combine(transaction, "staged");
            string commitDescriptor = Path.Combine(transaction, "commit-descriptor.json");
            ReleaseFile[] expected = ReadDescriptor(commitDescriptor);
            AssertManagedTree(staged, "staged", expected);
            string stagedDescriptor = Path.Combine(staged, "CodexData", "portable-release.json");
            if (!FilesEqual(stagedDescriptor, commitDescriptor, DescriptorMaximumBytes))
                throw new InvalidDataException("LF release staged descriptor does not match its commit descriptor.");
            for (int i = 0; i < ManagedFiles.Length - 1; i++)
            {
                string relative = ManagedFiles[i];
                AtomicCopy(Path.Combine(staged, ToNativeRelativePath(relative)),
                    Path.Combine(root, ToNativeRelativePath(relative)), root);
            }
            AtomicCopy(stagedDescriptor, Path.Combine(root, "CodexData", "portable-release.json"), root);
            AssertInstalledTree(root, ReadDescriptor(commitDescriptor));
        }

        private static void InvalidateDerivedPayloads(string root)
        {
            for (int i = 0; i < DerivedPayloadDirectories.Length; i++)
            {
                string relative = DerivedPayloadDirectories[i];
                string directory = NormalizePath(Path.Combine(root, ToNativeRelativePath(relative)));
                if (!IsWithin(directory, root))
                    throw new InvalidDataException("LF derived payload path is outside the portable root.");
                AssertNoReparseAncestry(directory, root);

                FileAttributes attributes;
                try { attributes = File.GetAttributes(directory); }
                catch (FileNotFoundException) { continue; }
                catch (DirectoryNotFoundException) { continue; }
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("LF derived payload cannot be a reparse point: " + relative);
                if ((attributes & FileAttributes.Directory) == 0)
                    throw new IOException("LF derived payload path is not a directory: " + relative);
                AssertNoReparsePointsUnder(directory);
                Directory.Delete(directory, true);
                if (Directory.Exists(directory) || File.Exists(directory))
                    throw new IOException("LF derived payload invalidation did not complete: " + relative);
            }
        }

        private static void AssertTransactionTree(string root, string transaction)
        {
            string updates = NormalizePath(Path.Combine(root, "CodexData", "updates"));
            AssertNoReparseAncestry(transaction, updates);
            AssertNoReparsePointsUnder(transaction);

            List<string> rootEntries = new List<string>();
            string[] entries = Directory.GetFileSystemEntries(transaction, "*", SearchOption.TopDirectoryOnly);
            for (int i = 0; i < entries.Length; i++) rootEntries.Add(Path.GetFileName(entries[i]));
            AssertExactSet(TransactionRootEntries, rootEntries, "LF release transaction root");

            List<string> directories = new List<string>();
            string[] foundDirectories = Directory.GetDirectories(transaction, "*", SearchOption.TopDirectoryOnly);
            for (int i = 0; i < foundDirectories.Length; i++) directories.Add(Path.GetFileName(foundDirectories[i]));
            AssertExactSet(TransactionDirectories, directories, "LF release transaction directories");
            string commitDescriptor = Path.Combine(transaction, "commit-descriptor.json");
            if (!IsRegularFile(commitDescriptor) || new FileInfo(commitDescriptor).Length > DescriptorMaximumBytes)
                throw new InvalidDataException("LF release transaction commit descriptor is invalid.");

            ReleaseFile[] oldFiles = ReadDescriptor(Path.Combine(transaction, "backup", "CodexData", "portable-release.json"));
            AssertManagedTree(Path.Combine(transaction, "backup"), "backup", oldFiles);
            ReleaseFile[] newFiles = ReadDescriptor(commitDescriptor);
            AssertManagedTree(Path.Combine(transaction, "staged"), "staged", newFiles);
            if (!FilesEqual(Path.Combine(transaction, "staged", "CodexData", "portable-release.json"),
                commitDescriptor, DescriptorMaximumBytes))
                throw new InvalidDataException("LF release transaction staged descriptor differs from its commit descriptor.");
        }

        private static void AssertManagedTree(string tree, string label, ReleaseFile[] expected)
        {
            if (!Directory.Exists(tree))
                throw new DirectoryNotFoundException("LF release " + label + " tree is missing.");
            AssertNoReparsePointsUnder(tree);

            List<string> directories = new List<string>();
            string[] foundDirectories = Directory.GetDirectories(tree, "*", SearchOption.AllDirectories);
            for (int i = 0; i < foundDirectories.Length; i++)
                directories.Add(GetRelativePath(tree, foundDirectories[i]));
            AssertExactSet(BackupDirectories, directories, "LF release " + label + " directories");

            List<string> files = new List<string>();
            string[] foundFiles = Directory.GetFiles(tree, "*", SearchOption.AllDirectories);
            for (int i = 0; i < foundFiles.Length; i++)
            {
                string relative = GetRelativePath(tree, foundFiles[i]);
                FileInfo info = new FileInfo(foundFiles[i]);
                if (info.Length <= 0) throw new InvalidDataException("LF release " + label + " contains an empty file.");
                files.Add(relative);
            }
            AssertExactSet(ManagedFiles, files, "LF release " + label + " files");
            for (int i = 0; i < expected.Length; i++)
            {
                string source = Path.Combine(tree, ToNativeRelativePath(expected[i].Path));
                AssertFileDigest(source, expected[i], "LF release " + label);
            }
        }

        private static void AssertInstalledTree(string root, ReleaseFile[] expected)
        {
            for (int i = 0; i < expected.Length; i++)
            {
                string path = Path.Combine(root, ToNativeRelativePath(expected[i].Path));
                AssertNoReparseAncestry(path, root);
                AssertFileDigest(path, expected[i], "installed LF release");
            }
        }

        private static bool InstalledTreeMatches(string root, ReleaseFile[] expected)
        {
            try
            {
                AssertInstalledTree(root, expected);
                return true;
            }
            catch (FileNotFoundException) { return false; }
            catch (InvalidDataException) { return false; }
        }

        private static ReleaseFile[] ReadDescriptor(string path)
        {
            if (!IsRegularFile(path)) throw new FileNotFoundException("LF release descriptor is missing.", path);
            FileInfo info = new FileInfo(path);
            if (info.Length <= 0 || info.Length > DescriptorMaximumBytes)
                throw new InvalidDataException("LF release descriptor size is invalid.");
            string json;
            try { json = new UTF8Encoding(false, true).GetString(File.ReadAllBytes(path)); }
            catch (Exception ex) { throw new InvalidDataException("LF release descriptor is not strict UTF-8.", ex); }
            try
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                serializer.MaxJsonLength = DescriptorMaximumBytes;
                serializer.RecursionLimit = 32;
                Dictionary<string, object> root = serializer.Deserialize<Dictionary<string, object>>(json);
                AssertExactKeys(root, new string[] { "SchemaVersion", "ReleaseVersion", "LauncherVersion", "Files" },
                    "LF release descriptor");
                if (ReadInt(root["SchemaVersion"], "LF release descriptor schema") != 1)
                    throw new InvalidDataException("LF release descriptor schema is unsupported.");
                string releaseVersion = ReadVersion(root["ReleaseVersion"]);
                if (!string.Equals(releaseVersion, ReadVersion(root["LauncherVersion"]), StringComparison.Ordinal))
                    throw new InvalidDataException("LF release descriptor version values differ.");
                IEnumerable values = root["Files"] as IEnumerable;
                if (values == null || root["Files"] is string)
                    throw new InvalidDataException("LF release descriptor files are invalid.");
                Dictionary<string, ReleaseFile> found = new Dictionary<string, ReleaseFile>(StringComparer.Ordinal);
                foreach (object value in values)
                {
                    Dictionary<string, object> entry = value as Dictionary<string, object>;
                    AssertExactKeys(entry, new string[] { "Path", "Length", "Sha256" }, "LF release descriptor file");
                    string relative = entry["Path"] as string;
                    if (!IsContentManagedFile(relative) || found.ContainsKey(relative))
                        throw new InvalidDataException("LF release descriptor file entry is unexpected or duplicated.");
                    long length = ReadLong(entry["Length"], "LF release descriptor length");
                    string sha256 = NormalizeSha256(entry["Sha256"] as string);
                    if (length <= 0) throw new InvalidDataException("LF release descriptor length is invalid.");
                    found.Add(relative, new ReleaseFile { Path = relative, Length = length, Sha256 = sha256 });
                }
                if (found.Count != ManagedFiles.Length - 1)
                    throw new InvalidDataException("LF release descriptor file count is invalid.");
                ReleaseFile[] result = new ReleaseFile[ManagedFiles.Length - 1];
                for (int i = 0; i < result.Length; i++)
                {
                    if (!found.TryGetValue(ManagedFiles[i], out result[i]))
                        throw new InvalidDataException("LF release descriptor is missing a managed file.");
                }
                return result;
            }
            catch (InvalidDataException) { throw; }
            catch (Exception ex) { throw new InvalidDataException("LF release descriptor JSON is invalid.", ex); }
        }

        private static void AssertFileDigest(string path, ReleaseFile expected, string label)
        {
            if (!IsRegularFile(path)) throw new FileNotFoundException(label + " file is missing.", path);
            FileInfo info = new FileInfo(path);
            if (info.Length != expected.Length)
                throw new InvalidDataException(label + " file length differs: " + expected.Path);
            string actual = ComputeSha256(path);
            if (!string.Equals(actual, expected.Sha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException(label + " file hash differs: " + expected.Path);
        }

        private static string ComputeSha256(string path)
        {
            byte[] buffer = new byte[1024 * 1024];
            byte[] digest = null;
            try
            {
                using (SHA256 sha = SHA256.Create())
                using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
                    buffer.Length, FileOptions.SequentialScan))
                {
                    int read;
                    while ((read = stream.Read(buffer, 0, buffer.Length)) != 0) sha.TransformBlock(buffer, 0, read, buffer, 0);
                    sha.TransformFinalBlock(buffer, 0, 0);
                    digest = sha.Hash;
                }
                StringBuilder text = new StringBuilder(64);
                for (int i = 0; i < digest.Length; i++) text.Append(digest[i].ToString("x2", CultureInfo.InvariantCulture));
                return text.ToString();
            }
            finally
            {
                Array.Clear(buffer, 0, buffer.Length);
                if (digest != null) Array.Clear(digest, 0, digest.Length);
            }
        }

        private static bool IsContentManagedFile(string value)
        {
            if (value == null) return false;
            for (int i = 0; i < ManagedFiles.Length - 1; i++)
                if (string.Equals(value, ManagedFiles[i], StringComparison.Ordinal)) return true;
            return false;
        }

        private static void AssertExactKeys(Dictionary<string, object> value, string[] expected, string label)
        {
            if (value == null || value.Count != expected.Length)
                throw new InvalidDataException(label + " has an unsupported property set.");
            for (int i = 0; i < expected.Length; i++) if (!value.ContainsKey(expected[i]))
                throw new InvalidDataException(label + " has an unsupported property set.");
        }

        private static int ReadInt(object value, string label)
        {
            try { return Convert.ToInt32(value, CultureInfo.InvariantCulture); }
            catch (Exception ex) { throw new InvalidDataException(label + " is invalid.", ex); }
        }

        private static long ReadLong(object value, string label)
        {
            try { return Convert.ToInt64(value, CultureInfo.InvariantCulture); }
            catch (Exception ex) { throw new InvalidDataException(label + " is invalid.", ex); }
        }

        private static string ReadVersion(object value)
        {
            string text = value as string;
            if (string.IsNullOrEmpty(text)) throw new InvalidDataException("LF release descriptor version is invalid.");
            string[] parts = text.Split('.');
            if (parts.Length != 4) throw new InvalidDataException("LF release descriptor version is invalid.");
            for (int i = 0; i < parts.Length; i++)
            {
                ushort part;
                if (!ushort.TryParse(parts[i], NumberStyles.None, CultureInfo.InvariantCulture, out part) ||
                    part.ToString(CultureInfo.InvariantCulture) != parts[i])
                    throw new InvalidDataException("LF release descriptor version is invalid.");
            }
            return text;
        }

        private static string NormalizeSha256(string value)
        {
            if (value == null || value.Length != 64) throw new InvalidDataException("LF release descriptor hash is invalid.");
            StringBuilder normalized = new StringBuilder(64);
            for (int i = 0; i < value.Length; i++)
            {
                if (!Uri.IsHexDigit(value[i])) throw new InvalidDataException("LF release descriptor hash is invalid.");
                normalized.Append(char.ToLowerInvariant(value[i]));
            }
            return normalized.ToString();
        }

        private static void AtomicCopy(string source, string destination, string root)
        {
            if (!IsRegularFile(source)) throw new FileNotFoundException("LF release recovery source is missing.");
            if (Directory.Exists(destination))
                throw new IOException("LF release recovery destination is a directory.");
            string directory = Path.GetDirectoryName(destination);
            EnsureDirectoryWithin(directory, root);
            string temporary = Path.Combine(directory, ".lf-recover-" +
                Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                File.Copy(source, temporary, false);
                if (!FilesEqual(source, temporary, -1))
                    throw new IOException("LF release recovery staging copy did not verify.");
                if (!MoveFileEx(temporary, destination,
                    MoveFileReplaceExisting | MoveFileWriteThrough))
                    throw new IOException("LF release recovery activation failed. Win32=" +
                        Marshal.GetLastWin32Error().ToString());
                if (!FilesEqual(source, destination, -1))
                    throw new IOException("LF release recovery activation did not verify.");
            }
            finally
            {
                TryDelete(temporary);
            }
        }

        private static void EnsureDirectoryWithin(string directory, string root)
        {
            if (!IsWithin(directory, root))
                throw new InvalidDataException("LF release recovery destination is outside the portable root.");
            Directory.CreateDirectory(directory);
            AssertNoReparseAncestry(directory, root);
        }

        private static void RetireTransaction(string transaction, string root)
        {
            if (!Directory.Exists(transaction)) return;
            string updates = NormalizePath(Path.Combine(root, "CodexData", "updates"));
            AssertNoReparseAncestry(transaction, updates);
            AssertNoReparsePointsUnder(transaction);
            string cleanup = Path.Combine(updates, "release-cleanup-" + Guid.NewGuid().ToString("N"));
            if (Directory.Exists(cleanup) || File.Exists(cleanup))
                throw new IOException("LF release cleanup name unexpectedly exists.");
            // Rename first. If recursive deletion is interrupted, the residual
            // directory can never be mistaken for a pending release transaction.
            Directory.Move(transaction, cleanup);
            try
            {
                AssertNoReparseAncestry(cleanup, updates);
                AssertNoReparsePointsUnder(cleanup);
                Directory.Delete(cleanup, true);
            }
            catch { }
        }

        private static string GetTransactionDirectory(string root, string transactionName)
        {
            if (!IsRecoveryTransactionName(transactionName))
                throw new InvalidDataException("LF release recovery transaction name is invalid.");
            string updates = NormalizePath(Path.Combine(root, "CodexData", "updates"));
            string transaction = NormalizePath(Path.Combine(updates, transactionName));
            if (!string.Equals(Path.GetDirectoryName(transaction), updates,
                StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("LF release recovery transaction is outside updates.");
            AssertNoReparseAncestry(updates, root);
            if (Directory.Exists(transaction)) AssertNoReparseAncestry(transaction, updates);
            return transaction;
        }

        private static bool IsRecoveryTransactionName(string value)
        {
            if (value == null || value.Length != TransactionNameLength ||
                !value.StartsWith(TransactionPrefix, StringComparison.Ordinal)) return false;
            for (int i = TransactionPrefix.Length; i < value.Length; i++)
            {
                char c = value[i];
                if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
            }
            return true;
        }

        private static string CreateHelperCopy(string root)
        {
            string source = NormalizePath(Assembly.GetExecutingAssembly().Location);
            if (!IsRegularFile(source))
                throw new FileNotFoundException("LF release recovery bootstrapper is missing.", source);
            string directory = NormalizePath(Path.Combine(Path.GetTempPath(), "LFPortable", "release-recovery"));
            string helper = NormalizePath(Path.Combine(directory, "lf-release-recovery-" +
                Guid.NewGuid().ToString("N") + ".exe"));
            if (IsWithin(helper, root))
                throw new InvalidOperationException("LF release recovery helper cannot run from the portable root.");
            Directory.CreateDirectory(directory);
            File.Copy(source, helper, false);
            if (!FilesEqual(source, helper, -1))
                throw new IOException("LF release recovery helper copy did not verify.");
            return helper;
        }

        private static void WaitForParentExit(int parentProcessId)
        {
            if (parentProcessId <= 0) throw new InvalidDataException("LF release recovery parent process is invalid.");
            try
            {
                using (Process parent = Process.GetProcessById(parentProcessId))
                {
                    if (!parent.HasExited && !parent.WaitForExit(ParentExitWaitMilliseconds))
                        throw new TimeoutException("LF release recovery could not wait for its bootstrapper to exit.");
                }
            }
            catch (ArgumentException)
            {
                // The bootstrapper may have already exited before the helper started.
            }
        }

        private static void StartBootstrapper(string root, List<string> resumeArguments)
        {
            string bootstrapper = Path.Combine(root, "CodexPortable.exe");
            if (!IsRegularFile(bootstrapper))
                throw new FileNotFoundException("LF portable bootstrapper is missing after release recovery.");
            ProcessStartInfo info = new ProcessStartInfo();
            info.FileName = bootstrapper;
            info.Arguments = JoinArguments(resumeArguments);
            info.WorkingDirectory = root;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            using (Process restarted = Process.Start(info))
            {
                if (restarted == null) throw new InvalidOperationException("LF portable could not restart after release recovery.");
            }
        }

        private static Mutex AcquireMutex(string name, string label)
        {
            Mutex mutex = new Mutex(false, name);
            bool acquired = false;
            try
            {
                try { acquired = mutex.WaitOne(WaitMilliseconds, false); }
                catch (AbandonedMutexException) { acquired = true; }
                if (!acquired) throw new TimeoutException(label + " is busy.");
                return mutex;
            }
            catch
            {
                mutex.Dispose();
                throw;
            }
        }

        private static void ReleaseMutex(Mutex mutex)
        {
            if (mutex == null) return;
            try { mutex.ReleaseMutex(); }
            finally { mutex.Dispose(); }
        }

        private static string GetMutexName(string root)
        {
            string normalized = Path.GetFullPath(root).TrimEnd('\\').ToUpperInvariant();
            byte[] input = Encoding.UTF8.GetBytes(normalized);
            byte[] digest = null;
            try
            {
                using (SHA256 sha = SHA256.Create()) digest = sha.ComputeHash(input);
                StringBuilder suffix = new StringBuilder(32);
                for (int i = 0; i < 16; i++) suffix.Append(digest[i].ToString("x2"));
                return "Local\\CodexPortable-Desktop-" + suffix.ToString();
            }
            finally
            {
                Array.Clear(input, 0, input.Length);
                if (digest != null) Array.Clear(digest, 0, digest.Length);
            }
        }

        private static bool IsPortableProcessRunning(string root)
        {
            string[] managedRoots = new string[] {
                Path.Combine(root, "CodexData", "app", "current"),
                Path.Combine(root, "CodexData", "tools", "desktop-payloads"),
                Path.Combine(root, "CodexData", "tools", "dotnet"),
                Path.Combine(root, "CodexData", "tools", "gh"),
                Path.Combine(root, "CodexData", "data", "profile", ".cache", "codex-runtimes"),
                Path.Combine(root, "CodexData", "data", "profile", ".codex", "offline-marketplaces"),
                Path.Combine(root, "CodexData", "data", "profile", ".codex", "plugins", "cache")
            };
            for (int i = 0; i < managedRoots.Length; i++)
                managedRoots[i] = NormalizePath(managedRoots[i]).TrimEnd('\\') + "\\";
            // Host execution images are partitioned by the portable drive's
            // stable volume token. Only that exact LF-owned family can block
            // this root's release transaction.
            string executionFamilyRoot = TryGetExecutionFamilyRoot(root);

            int currentId = Process.GetCurrentProcess().Id;
            Process[] processes = Process.GetProcesses();
            for (int i = 0; i < processes.Length; i++)
            {
                Process process = processes[i];
                try
                {
                    if (process.Id == currentId) continue;
                    string executable;
                    if (!TryGetExecutablePath(process, out executable)) continue;
                    string full = NormalizePath(executable);
                    for (int rootIndex = 0; rootIndex < managedRoots.Length; rootIndex++)
                    {
                        if (full.StartsWith(managedRoots[rootIndex], StringComparison.OrdinalIgnoreCase))
                            return true;
                    }
                    if (IsExecutionDesktopForRoot(full, executionFamilyRoot)) return true;
                }
                catch { }
                finally { process.Dispose(); }
            }
            return false;
        }

        private static string TryGetExecutionFamilyRoot(string root)
        {
            try
            {
                string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                if (string.IsNullOrEmpty(local) || !Path.IsPathRooted(local)) return null;
                return NormalizePath(Path.Combine(local, "LFPortable", "execution",
                    GetExecutionVolumeToken(root)));
            }
            catch { return null; }
        }

        private static string GetExecutionVolumeToken(string portableRoot)
        {
            string volumeRoot = Path.GetPathRoot(portableRoot);
            uint serial;
            uint maximumComponentLength;
            uint flags;
            if (!string.IsNullOrEmpty(volumeRoot) && GetVolumeInformation(volumeRoot,
                null, 0, out serial, out maximumComponentLength, out flags, null, 0))
                return "vol-" + serial.ToString("X8", CultureInfo.InvariantCulture);

            string normalized = Path.GetFullPath(portableRoot).TrimEnd('\\').ToUpperInvariant();
            byte[] input = Encoding.UTF8.GetBytes(normalized);
            byte[] digest = null;
            try
            {
                using (SHA256 sha = SHA256.Create()) digest = sha.ComputeHash(input);
                StringBuilder token = new StringBuilder(16);
                for (int i = 0; i < 8; i++)
                    token.Append(digest[i].ToString("x2", CultureInfo.InvariantCulture));
                return "path-" + token.ToString();
            }
            finally
            {
                Array.Clear(input, 0, input.Length);
                if (digest != null) Array.Clear(digest, 0, digest.Length);
            }
        }

        private static bool IsExecutionDesktopForRoot(string executable, string executionFamilyRoot)
        {
            if (string.IsNullOrEmpty(executionFamilyRoot) ||
                !string.Equals(Path.GetFileName(executable), PortableDesktopExecutableName,
                    StringComparison.OrdinalIgnoreCase)) return false;
            try
            {
                string full = NormalizePath(executable);
                string prefix = executionFamilyRoot.TrimEnd('\\') + "\\";
                if (!full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return false;
                string[] segments = full.Substring(prefix.Length).Split(new char[] { '\\' },
                    StringSplitOptions.None);
                if (segments.Length != 5 ||
                    (!string.Equals(segments[0], "x64", StringComparison.OrdinalIgnoreCase) &&
                     !string.Equals(segments[0], "arm64", StringComparison.OrdinalIgnoreCase)) ||
                    !string.Equals(segments[2], "app", StringComparison.OrdinalIgnoreCase) ||
                    !string.Equals(segments[3], "current", StringComparison.OrdinalIgnoreCase) ||
                    !string.Equals(segments[4], PortableDesktopExecutableName,
                        StringComparison.OrdinalIgnoreCase)) return false;

                const string versionPrefix = "desktop-";
                const string launcherSeparator = "-lf-";
                const string packageIdentitySeparator = "-pkg-c-";
                const string desktopHashSeparator = "-d-";
                int separator = segments[1].LastIndexOf(launcherSeparator,
                    StringComparison.OrdinalIgnoreCase);
                if (!segments[1].StartsWith(versionPrefix, StringComparison.OrdinalIgnoreCase) ||
                    separator <= versionPrefix.Length ||
                    separator + launcherSeparator.Length >= segments[1].Length) return false;
                Version packageVersion;
                if (!Version.TryParse(segments[1].Substring(versionPrefix.Length,
                        separator - versionPrefix.Length), out packageVersion)) return false;
                string launcherAndIdentity = segments[1].Substring(separator + launcherSeparator.Length);
                Version launcherVersion;

                // Releases created before the descriptor carried no package identity.
                if (Version.TryParse(launcherAndIdentity, out launcherVersion))
                {
                    string legacyDirectory = versionPrefix + packageVersion.ToString() +
                        launcherSeparator + launcherVersion.ToString();
                    return string.Equals(segments[1], legacyDirectory,
                        StringComparison.OrdinalIgnoreCase);
                }

                int identitySeparator = launcherAndIdentity.IndexOf(packageIdentitySeparator,
                    StringComparison.OrdinalIgnoreCase);
                if (identitySeparator <= 0 || !Version.TryParse(
                        launcherAndIdentity.Substring(0, identitySeparator), out launcherVersion)) return false;
                string packageIdentity = launcherAndIdentity.Substring(identitySeparator +
                    packageIdentitySeparator.Length);
                int desktopHashSeparatorIndex = packageIdentity.IndexOf(desktopHashSeparator,
                    StringComparison.OrdinalIgnoreCase);
                if (desktopHashSeparatorIndex != 16 ||
                    packageIdentity.Length != 16 + desktopHashSeparator.Length + 16) return false;
                for (int hashIndex = 0; hashIndex < 16; hashIndex++)
                {
                    char commonHashCharacter = packageIdentity[hashIndex];
                    char desktopHashCharacter = packageIdentity[desktopHashSeparatorIndex +
                        desktopHashSeparator.Length + hashIndex];
                    if (!((commonHashCharacter >= '0' && commonHashCharacter <= '9') ||
                          (commonHashCharacter >= 'a' && commonHashCharacter <= 'f') ||
                          (commonHashCharacter >= 'A' && commonHashCharacter <= 'F')) ||
                        !((desktopHashCharacter >= '0' && desktopHashCharacter <= '9') ||
                          (desktopHashCharacter >= 'a' && desktopHashCharacter <= 'f') ||
                          (desktopHashCharacter >= 'A' && desktopHashCharacter <= 'F'))) return false;
                }
                string canonicalDirectory = versionPrefix + packageVersion.ToString() +
                    launcherSeparator + launcherVersion.ToString() + packageIdentitySeparator +
                    packageIdentity;
                return string.Equals(segments[1], canonicalDirectory,
                    StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }

        private static bool TryGetExecutablePath(Process process, out string executable)
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
                handle = OpenProcess(ProcessQueryLimitedInformation, false, unchecked((uint)process.Id));
                if (handle == IntPtr.Zero) return false;
                uint length = MaximumProcessImagePath;
                StringBuilder path = new StringBuilder((int)length);
                if (!QueryFullProcessImageName(handle, 0, path, ref length) || path.Length == 0)
                    return false;
                executable = path.ToString();
                return true;
            }
            finally
            {
                if (handle != IntPtr.Zero) CloseHandle(handle);
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
                using (FileStream firstStream = new FileStream(first, FileMode.Open, FileAccess.Read,
                    FileShare.Read, firstBuffer.Length, FileOptions.SequentialScan))
                using (FileStream secondStream = new FileStream(second, FileMode.Open, FileAccess.Read,
                    FileShare.Read, secondBuffer.Length, FileOptions.SequentialScan))
                {
                    while (true)
                    {
                        int firstCount = firstStream.Read(firstBuffer, 0, firstBuffer.Length);
                        int secondCount = secondStream.Read(secondBuffer, 0, secondBuffer.Length);
                        if (firstCount != secondCount) return false;
                        if (firstCount == 0) return true;
                        for (int i = 0; i < firstCount; i++)
                            if (firstBuffer[i] != secondBuffer[i]) return false;
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
                if (!File.Exists(path)) return false;
                FileAttributes attributes = File.GetAttributes(path);
                return (attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) == 0;
            }
            catch { return false; }
        }

        private static void AssertNoReparseAncestry(string path, string root)
        {
            string current = NormalizePath(path);
            string boundary = NormalizePath(root);
            if (!IsWithin(current, boundary))
                throw new InvalidDataException("LF release recovery path is outside its protected root.");
            while (true)
            {
                if (File.Exists(current) || Directory.Exists(current))
                {
                    if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                        throw new InvalidDataException("LF release recovery encountered a reparse point.");
                }
                if (string.Equals(current, boundary, StringComparison.OrdinalIgnoreCase)) return;
                string parent = Path.GetDirectoryName(current);
                if (string.IsNullOrEmpty(parent) || string.Equals(parent, current,
                    StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("LF release recovery path hierarchy is invalid.");
                current = NormalizePath(parent);
            }
        }

        private static void AssertNoReparsePointsUnder(string root)
        {
            Stack<string> pending = new Stack<string>();
            pending.Push(root);
            while (pending.Count != 0)
            {
                string current = pending.Pop();
                FileAttributes currentAttributes = File.GetAttributes(current);
                if ((currentAttributes & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("LF release recovery encountered a reparse point.");
                string[] entries = Directory.GetFileSystemEntries(current, "*", SearchOption.TopDirectoryOnly);
                for (int i = 0; i < entries.Length; i++)
                {
                    FileAttributes attributes = File.GetAttributes(entries[i]);
                    if ((attributes & FileAttributes.ReparsePoint) != 0)
                        throw new InvalidDataException("LF release recovery encountered a reparse point.");
                    if ((attributes & FileAttributes.Directory) != 0) pending.Push(entries[i]);
                }
            }
        }

        private static void AssertExactSet(string[] expected, List<string> actual, string label)
        {
            if (expected.Length != actual.Count)
                throw new InvalidDataException(label + " has an unexpected entry count.");
            Dictionary<string, bool> expectedSet = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < expected.Length; i++) expectedSet.Add(expected[i], true);
            for (int i = 0; i < actual.Count; i++)
            {
                if (!expectedSet.Remove(actual[i]))
                    throw new InvalidDataException(label + " contains an unexpected entry.");
            }
            if (expectedSet.Count != 0)
                throw new InvalidDataException(label + " is missing a required entry.");
        }

        private static string GetRelativePath(string root, string path)
        {
            string normalizedRoot = NormalizePath(root).TrimEnd('\\');
            string normalizedPath = NormalizePath(path);
            if (!normalizedPath.StartsWith(normalizedRoot + "\\", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("LF release recovery found a path outside its backup.");
            return normalizedPath.Substring(normalizedRoot.Length + 1).Replace('\\', '/');
        }

        private static string ToNativeRelativePath(string relative)
        {
            return relative.Replace('/', Path.DirectorySeparatorChar);
        }

        private static bool IsWithin(string candidate, string root)
        {
            string normalizedCandidate = NormalizePath(candidate);
            string normalizedRoot = NormalizePath(root);
            if (string.Equals(normalizedCandidate, normalizedRoot, StringComparison.OrdinalIgnoreCase)) return true;
            return normalizedCandidate.StartsWith(normalizedRoot.TrimEnd('\\') + "\\",
                StringComparison.OrdinalIgnoreCase);
        }

        private static string NormalizePath(string path)
        {
            string full = Path.GetFullPath(path).Replace('/', '\\');
            string volumeRoot = Path.GetPathRoot(full);
            while (full.Length > volumeRoot.Length && full.EndsWith("\\", StringComparison.Ordinal))
                full = full.Substring(0, full.Length - 1);
            return full;
        }

        private static void TryDelete(string path)
        {
            try
            {
                if (!string.IsNullOrEmpty(path) && File.Exists(path)) File.Delete(path);
            }
            catch { }
        }

        private static string JoinArguments(List<string> arguments)
        {
            StringBuilder result = new StringBuilder();
            for (int i = 0; i < arguments.Count; i++)
            {
                if (i != 0) result.Append(' ');
                result.Append(QuoteArgument(arguments[i]));
            }
            return result.ToString();
        }

        private static string QuoteArgument(string argument)
        {
            if (argument.Length > 0 && argument.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0)
                return argument;
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

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true,
            EntryPoint = "MoveFileExW", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool MoveFileEx(string existingFileName, string newFileName, uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint desiredAccess,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandle, uint processId);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryFullProcessImageName(IntPtr processHandle, uint flags,
            StringBuilder executablePath, ref uint size);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetVolumeInformation(string rootPathName,
            StringBuilder volumeNameBuffer, uint volumeNameSize, out uint volumeSerialNumber,
            out uint maximumComponentLength, out uint fileSystemFlags,
            StringBuilder fileSystemNameBuffer, uint fileSystemNameSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);
    }
}
