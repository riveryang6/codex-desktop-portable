// Codex Portable architecture bootstrapper.
// Build target: Windows x86, .NET Framework 4.8, C# 5 compatible.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("LF Portable")]
[assembly: AssemblyDescription("Architecture selector for LF Portable")]
[assembly: AssemblyCompany("LF")]
[assembly: AssemblyProduct("LF Portable")]
[assembly: AssemblyCopyright("Copyright (c) 2026")]
[assembly: AssemblyVersion("1.4.24.0")]
[assembly: AssemblyFileVersion("1.4.24.0")]
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
                for (int i = 0; i < args.Length; i++)
                {
                    if (string.Equals(args[i], "--portable-root", StringComparison.OrdinalIgnoreCase) ||
                        args[i].StartsWith("--portable-root=", StringComparison.OrdinalIgnoreCase))
                    {
                        MessageBox.Show("--portable-root is reserved for the Codex Portable bootstrapper.",
                            "Codex Portable", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return 41;
                    }
                    if (string.Equals(args[i], "--portable-root-token", StringComparison.OrdinalIgnoreCase) ||
                        args[i].StartsWith("--portable-root-token=", StringComparison.OrdinalIgnoreCase))
                    {
                        MessageBox.Show("--portable-root-token is reserved for the LF Portable bootstrapper.",
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

                string root = Path.GetFullPath(Path.GetDirectoryName(
                    Assembly.GetExecutingAssembly().Location));
                string rootToken = PortableRootIdentity.GetExecutionRootToken(root);
                string architecture = DetectNativeArchitecture();
                List<string> childArguments = new List<string>();
                childArguments.Add("--portable-root");
                childArguments.Add(root);
                childArguments.Add("--portable-root-token");
                childArguments.Add(rootToken);
                childArguments.Add("--bootstrapper-pid");
                childArguments.Add(Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture));
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
                            if (child == null)
                                throw new InvalidOperationException("Unable to create launcher process.");
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
                    (lastStartError == null ? "" : "\r\n\r\n" + lastStartError.GetType().Name + ": " +
                        lastStartError.Message),
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

    internal static class PortableRootIdentity
    {
        internal static string GetExecutionRootToken(string portableRoot)
        {
            if (string.IsNullOrEmpty(portableRoot)) throw new ArgumentException("portableRoot");
            string fullRoot = Path.GetFullPath(portableRoot).ToUpperInvariant();
            string volumeRoot = Path.GetPathRoot(fullRoot);
            uint serial;
            uint maximumComponentLength;
            uint flags;
            if (string.IsNullOrEmpty(volumeRoot) || !GetVolumeInformation(volumeRoot,
                null, 0, out serial, out maximumComponentLength, out flags, null, 0))
                throw new IOException("Portable root volume identity is unavailable.");
            string relative = fullRoot.Length > volumeRoot.Length ?
                fullRoot.Substring(volumeRoot.Length).TrimEnd('\\') : "";
            string identity = "vol:" + serial.ToString("X8", CultureInfo.InvariantCulture) +
                "|path:" + relative;
            byte[] input = Encoding.UTF8.GetBytes(identity);
            byte[] digest = null;
            try
            {
                using (SHA256 sha = SHA256.Create()) digest = sha.ComputeHash(input);
                StringBuilder token = new StringBuilder(16);
                for (int i = 0; i < 8; i++)
                    token.Append(digest[i].ToString("x2", CultureInfo.InvariantCulture));
                return "root-" + token.ToString();
            }
            finally
            {
                Array.Clear(input, 0, input.Length);
                if (digest != null) Array.Clear(digest, 0, digest.Length);
            }
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetVolumeInformation(string rootPathName,
            StringBuilder volumeNameBuffer, uint volumeNameSize, out uint volumeSerialNumber,
            out uint maximumComponentLength, out uint fileSystemFlags,
            StringBuilder fileSystemNameBuffer, uint fileSystemNameSize);
    }
}
