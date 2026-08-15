[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [Parameter(Mandatory = $true)]
    [string]$EvidenceRoot,

    [ValidateRange(60, 600)]
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$contract = 'LF compact first-run Sandbox'
$expectedFiles = @(
    'CodexPortable.exe',
    'CodexData/README.txt',
    'CodexData/THIRD_PARTY.txt',
    'CodexData/portable-release.json',
    'CodexData/tools/launchers/CodexPortable.x86.exe',
    'CodexData/tools/launchers/CodexPortable.x64.exe',
    'CodexData/tools/launchers/CodexPortable.arm64.exe',
    'CodexData/packages/LFPortable-common.zip',
    'CodexData/packages/LFPortable-x64.msix',
    'CodexData/packages/LFPortable-arm64.msix'
)
$expectedPlugins = [ordered]@{
    'openai-bundled' = @('sites', 'browser', 'chrome', 'computer-use', 'latex', 'deep-research', 'visualize')
    'openai-primary-runtime' = @('documents', 'pdf', 'presentations', 'spreadsheets', 'template-creator')
}

function Write-Json([string]$Path, [object]$Value) {
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = $Path + '.tmp-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 14),
            (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($temporary, $Path, $null)
        }
        else {
            [IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-NullableObjectProperty([object]$Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-RelativeFiles([string]$Root) {
    return @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction Stop |
            ForEach-Object { $_.FullName.Substring($Root.Length).TrimStart('\').Replace('\', '/') } |
            Sort-Object
    )
}

function Test-ExactStringSet([string[]]$Expected, [string[]]$Actual) {
    return @(Compare-Object -ReferenceObject @($Expected | Sort-Object) -DifferenceObject @($Actual | Sort-Object)).Count -eq 0
}

function Get-ObjectProperty([object]$Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Wait-Until([scriptblock]$Condition, [int]$Seconds, [string]$Label) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $value = & $Condition
        if ($null -ne $value -and $value -ne $false) { return $value }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Label."
}

function Get-PluginAudit([string]$ArchivePath) {
    $found = @{}
    $versions = @{}
    $unexpected = New-Object 'System.Collections.Generic.List[string]'
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            $match = [regex]::Match($entry.FullName,
                '^data/profile/\.codex/plugins/cache/([^/]+)/([^/]+)/([^/]+)/\.codex-plugin/plugin\.json$')
            if (-not $match.Success) { continue }
            if ($entry.Length -le 0 -or $entry.Length -gt 1048576) {
                throw "Plugin manifest has an unsafe size: $($entry.FullName)"
            }
            $catalog = $match.Groups[1].Value
            $plugin = $match.Groups[2].Value
            $version = $match.Groups[3].Value
            if (-not $expectedPlugins.Contains($catalog) -or $expectedPlugins[$catalog] -cnotcontains $plugin) {
                $unexpected.Add("$catalog/$plugin")
                continue
            }
            $stream = $entry.Open()
            try {
                $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false, $true)), $false)
                try { $metadata = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop }
                finally { $reader.Dispose() }
            }
            finally { $stream.Dispose() }
            if ([string]$metadata.name -cne $plugin -or [string]$metadata.version -cne $version) {
                throw "Plugin manifest does not match its versioned cache path: $($entry.FullName)"
            }
            $key = "$catalog/$plugin"
            $found[$key] = $true
            if (-not $versions.Contains($key)) { $versions[$key] = New-Object 'System.Collections.Generic.List[string]' }
            if (-not $versions[$key].Contains($version)) { $versions[$key].Add($version) }
        }
    }
    finally { $archive.Dispose() }

    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($catalog in $expectedPlugins.Keys) {
        foreach ($plugin in $expectedPlugins[$catalog]) {
            $key = "$catalog/$plugin"
            if (-not $found.Contains($key)) { $missing.Add($key) }
        }
    }
    $result = [ordered]@{
        ExpectedPluginCount = 12
        FoundPluginCount = $found.Count
        MissingPlugins = @($missing | Sort-Object)
        UnexpectedPlugins = @($unexpected | Sort-Object -Unique)
        Versions = [ordered]@{}
        Valid = $found.Count -eq 12 -and $missing.Count -eq 0 -and $unexpected.Count -eq 0
    }
    foreach ($key in @($versions.Keys | Sort-Object)) {
        $result.Versions[$key] = @($versions[$key] | Sort-Object)
    }
    return [pscustomobject]$result
}

function Copy-CompactRelease([string]$From, [string]$To) {
    if (Test-Path -LiteralPath $To) { throw "Manual-start target must not exist: $To" }
    New-Item -ItemType Directory -Path $To -Force | Out-Null
    & robocopy.exe $From $To /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /MT:16 /XJ /NFL /NDL /NP /NJH /NJS | Out-Null
    $exitCode = [int]$LASTEXITCODE
    if ($exitCode -ge 8) { throw "Manual-start compact release copy failed with robocopy exit code $exitCode." }
    $actual = Get-RelativeFiles $To
    if (-not (Test-ExactStringSet $expectedFiles $actual)) {
        throw 'Manual-start copy does not contain exactly the compact release files.'
    }
    return $exitCode
}

function Test-PathAtOrBelow([string]$Candidate, [string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $false }
    $boundary = $Root.TrimEnd('\')
    return $Candidate.Equals($boundary, [StringComparison]::OrdinalIgnoreCase) -or
        $Candidate.StartsWith($boundary + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-TargetProcesses([string]$Root) {
    $bootstrapper = Join-Path $Root 'CodexPortable.exe'
    $launcherRoot = (Join-Path $Root 'CodexData\tools\launchers').TrimEnd('\') + '\'
    $desktopRoot = (Join-Path $Root 'CodexData\app\current').TrimEnd('\') + '\'
    return @(
        Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try {
                $path = $_.Path
                -not [string]::IsNullOrWhiteSpace($path) -and
                    ($path.Equals($bootstrapper, [StringComparison]::OrdinalIgnoreCase) -or
                        $path.StartsWith($launcherRoot, [StringComparison]::OrdinalIgnoreCase) -or
                        $path.StartsWith($desktopRoot, [StringComparison]::OrdinalIgnoreCase))
            }
            catch { $false }
        }
    )
}

function Get-TargetDesktopProcesses([string]$Root) {
    $desktopRoot = (Join-Path $Root 'CodexData\app\current').TrimEnd('\') + '\'
    return @(
        Get-TargetProcesses $Root | Where-Object {
            try {
                $_.Path.StartsWith($desktopRoot, [StringComparison]::OrdinalIgnoreCase) -and
                    ($_.ProcessName -ieq 'CodexDesktop' -or $_.ProcessName -ieq 'ChatGPT')
            }
            catch { $false }
        }
    )
}

function Get-TargetAppCurrentProcesses([string]$Root) {
    $desktopRoot = (Join-Path $Root 'CodexData\app\current').TrimEnd('\') + '\'
    return @(
        Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try {
                $path = $_.Path
                -not [string]::IsNullOrWhiteSpace($path) -and
                    $path.StartsWith($desktopRoot, [StringComparison]::OrdinalIgnoreCase)
            }
            catch { $false }
        }
    )
}

function Get-ProcessSnapshot([System.Diagnostics.Process[]]$Processes) {
    $snapshot = New-Object 'System.Collections.Generic.List[object]'
    foreach ($process in @($Processes)) {
        try { $process.Refresh() } catch { }
        $id = $null
        $processName = $null
        $path = $null
        $hasExited = $null
        $exitCode = $null
        $mainWindowHandle = $null
        $mainWindowTitle = $null
        try { $id = $process.Id } catch { }
        try { $processName = $process.ProcessName } catch { }
        try { $path = $process.Path } catch { }
        try { $hasExited = $process.HasExited } catch { }
        if ($hasExited -eq $true) { try { $exitCode = $process.ExitCode } catch { } }
        try { $mainWindowHandle = $process.MainWindowHandle.ToInt64() } catch { }
        try { $mainWindowTitle = $process.MainWindowTitle } catch { }
        $snapshot.Add([ordered]@{
            Id = $id
            ProcessName = $processName
            Path = $path
            HasExited = $hasExited
            ExitCode = $exitCode
            MainWindowHandle = $mainWindowHandle
            MainWindowTitle = $mainWindowTitle
        })
    }
    return @($snapshot.ToArray())
}

function Protect-DiagnosticText([string]$Text, [string[]]$Secrets) {
    if ($null -eq $Text) { return $null }
    $protected = [string]$Text
    foreach ($secret in @($Secrets)) {
        if (-not [string]::IsNullOrWhiteSpace($secret)) {
            $protected = $protected.Replace($secret, '[REDACTED]')
        }
    }
    $protected = [regex]::Replace($protected,
        '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+', 'Bearer [REDACTED]')
    $protected = [regex]::Replace($protected,
        '(?i)\bsk-[A-Za-z0-9._-]{8,}\b', '[REDACTED]')
    $protected = [regex]::Replace($protected,
        '(?i)\bsandbox-[0-9a-f]{32}\b', '[REDACTED]')
    $assignmentPattern = '(?im)(?<prefix>["'']?(?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|token|password|secret)["'']?\s*[:=]\s*)(?<value>"[^"\r\n]*"|''[^''\r\n]*''|[^\s,;\r\n]+)'
    return [regex]::Replace($protected, $assignmentPattern, '${prefix}[REDACTED]')
}

function Get-SanitizedLauncherLogTail([string]$Root, [string[]]$Secrets) {
    $logsRoot = Join-Path $Root 'CodexData\logs'
    $log = @(
        Get-ChildItem -LiteralPath $logsRoot -Filter 'launcher-*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
    )
    if ($log.Count -eq 0) {
        return [pscustomobject][ordered]@{
            Found = $false
            FileName = $null
            LastWriteUtc = $null
            SourceLength = 0
            TailLineLimit = 100
            TailCharacterLimit = 32768
            TailWasTruncated = $false
            Text = $null
        }
    }

    $lines = @(Get-Content -LiteralPath $log[0].FullName -Tail 100 -ErrorAction Stop |
        ForEach-Object { [string]$_ })
    $text = Protect-DiagnosticText ($lines -join "`r`n") $Secrets
    $truncated = $text.Length -gt 32768
    if ($truncated) { $text = $text.Substring($text.Length - 32768) }
    return [pscustomobject][ordered]@{
        Found = $true
        FileName = $log[0].Name
        LastWriteUtc = $log[0].LastWriteTimeUtc.ToString('o')
        SourceLength = $log[0].Length
        TailLineLimit = 100
        TailCharacterLimit = 32768
        TailWasTruncated = $truncated
        Text = $text
    }
}

function Stop-TargetProcesses([string]$Root) {
    $initial = @(Get-TargetProcesses $Root)
    foreach ($process in $initial) {
        try {
            $process.Refresh()
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) { $null = $process.CloseMainWindow() }
        }
        catch { }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $remaining = @(Get-TargetProcesses $Root)
    } while ($remaining.Count -ne 0 -and [DateTime]::UtcNow -lt $deadline)
    $forced = New-Object 'System.Collections.Generic.List[int]'
    foreach ($process in $remaining) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            $forced.Add($process.Id)
        }
        catch { }
    }
    Start-Sleep -Milliseconds 500
    $final = @(Get-TargetProcesses $Root)
    return [pscustomobject][ordered]@{
        Scope = 'Only executable paths under the Sandbox target portable root'
        InitialProcessIds = @($initial | Select-Object -ExpandProperty Id)
        ForceStoppedProcessIds = @($forced)
        RemainingProcessIds = @($final | Select-Object -ExpandProperty Id)
        Succeeded = $final.Count -eq 0
    }
}

function Get-InstalledPluginAudit([string]$CacheRoot) {
    $found = @{}
    $invalid = New-Object 'System.Collections.Generic.List[string]'
    $unexpected = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path -LiteralPath $CacheRoot -PathType Container) {
        foreach ($catalogRoot in @(Get-ChildItem -LiteralPath $CacheRoot -Directory -Force)) {
            $catalog = $catalogRoot.Name
            if (-not $expectedPlugins.Contains($catalog)) { $unexpected.Add($catalog); continue }
            foreach ($pluginRoot in @(Get-ChildItem -LiteralPath $catalogRoot.FullName -Directory -Force)) {
                $plugin = $pluginRoot.Name
                if ($expectedPlugins[$catalog] -cnotcontains $plugin) { $unexpected.Add("$catalog/$plugin"); continue }
                foreach ($versionRoot in @(Get-ChildItem -LiteralPath $pluginRoot.FullName -Directory -Force)) {
                    $pluginManifest = Join-Path $versionRoot.FullName '.codex-plugin\plugin.json'
                    try {
                        $metadata = Get-Content -LiteralPath $pluginManifest -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                        if ([string]$metadata.name -cne $plugin -or [string]$metadata.version -cne $versionRoot.Name) {
                            throw 'manifest identity mismatch'
                        }
                    }
                    catch { $invalid.Add("$catalog/$plugin/$($versionRoot.Name)"); continue }
                    $found["$catalog/$plugin"] = $true
                }
            }
        }
    }
    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($catalog in $expectedPlugins.Keys) {
        foreach ($plugin in $expectedPlugins[$catalog]) {
            $key = "$catalog/$plugin"
            if (-not $found.Contains($key)) { $missing.Add($key) }
        }
    }
    return [pscustomobject][ordered]@{
        CacheRoot = $CacheRoot
        ExpectedPluginCount = 12
        FoundPluginCount = $found.Count
        MissingPlugins = @($missing | Sort-Object)
        InvalidPluginVersions = @($invalid | Sort-Object -Unique)
        UnexpectedPluginRoots = @($unexpected | Sort-Object -Unique)
        Valid = $found.Count -eq 12 -and $missing.Count -eq 0 -and $invalid.Count -eq 0 -and $unexpected.Count -eq 0
    }
}

function Initialize-SandboxStartButtonProbe {
    if ($null -eq ('LfSandboxStartButtonProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public sealed class LfSandboxProgressBarSample {
    public long Handle { get; set; }
    public string ClassName { get; set; }
    public string StyleFlagsHex { get; set; }
    public bool HasIndeterminateStyle { get; set; }
    public int Minimum { get; set; }
    public int Maximum { get; set; }
    public int Position { get; set; }
}

public sealed class LfSandboxLauncherProgressSnapshot {
    public string[] VisibleLabels { get; set; }
    public LfSandboxProgressBarSample[] ProgressBars { get; set; }
}

public sealed class LfSandboxTopLevelWindowSnapshot {
    public long Handle { get; set; }
    public long OwnerHandle { get; set; }
    public string ClassName { get; set; }
    public string Title { get; set; }
    public bool IsEnabled { get; set; }
    public bool IsDialogLike { get; set; }
    public string[] VisibleChildTexts { get; set; }
}

public static class LfSandboxStartButtonProbe {
    private const uint BM_CLICK = 0x00f5;
    private const int GWL_STYLE = -16;
    private const uint GW_OWNER = 4;
    private const uint PBS_MARQUEE = 0x0008;
    private const uint PBM_GETRANGE = 0x0407;
    private const uint PBM_GETPOS = 0x0408;
    private const uint SMTO_ABORTIFHUNG = 0x0002;
    private delegate bool EnumChildProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumChildWindows(IntPtr parent, EnumChildProc callback, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumChildProc callback, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLength(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hwnd, StringBuilder className, int count);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowEnabled(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SendMessageTimeout(IntPtr hwnd, uint message, IntPtr wParam,
        IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr hwnd, uint command);
    [DllImport("user32.dll", EntryPoint = "GetWindowLong")]
    private static extern int GetWindowLong32(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")]
    private static extern IntPtr GetWindowLongPtr64(IntPtr hwnd, int index);

    private static IntPtr GetWindowStyle(IntPtr hwnd) {
        return IntPtr.Size == 8 ? GetWindowLongPtr64(hwnd, GWL_STYLE) :
            new IntPtr(GetWindowLong32(hwnd, GWL_STYLE));
    }

    private static int GetProgressValue(IntPtr hwnd, uint message, IntPtr wParam) {
        IntPtr result;
        if (!SendMessageTimeout(hwnd, message, wParam, IntPtr.Zero,
            SMTO_ABORTIFHUNG, 1000, out result)) return -1;
        return result.ToInt32();
    }

    private static string ReadWindowText(IntPtr hwnd) {
        int length = GetWindowTextLength(hwnd);
        if (length <= 0 || length > 4096) return String.Empty;
        StringBuilder text = new StringBuilder(length + 1);
        return GetWindowText(hwnd, text, text.Capacity) == 0 ? String.Empty : text.ToString().Trim();
    }

    private static string ReadClassName(IntPtr hwnd) {
        StringBuilder className = new StringBuilder(256);
        return GetClassName(hwnd, className, className.Capacity) == 0 ? String.Empty : className.ToString();
    }

    private static string[] ReadVisibleChildTexts(IntPtr parent) {
        List<string> labels = new List<string>();
        EnumChildWindows(parent, delegate(IntPtr child, IntPtr ignored) {
            if (!IsWindowVisible(child)) return true;
            string text = ReadWindowText(child);
            if (text.Length != 0 && !labels.Contains(text) && labels.Count < 128) labels.Add(text);
            return true;
        }, IntPtr.Zero);
        return labels.ToArray();
    }

    public static string ClickStartCodexButton(IntPtr parent) {
        string clicked = null;
        EnumChildWindows(parent, delegate(IntPtr child, IntPtr ignored) {
            if (!IsWindowEnabled(child)) return true;
            StringBuilder className = new StringBuilder(128);
            if (GetClassName(child, className, className.Capacity) == 0) return true;
            string classValue = className.ToString();
            // WinForms controls are commonly exposed as Button, but themed
            // .NET Framework builds use WindowsForms10.BUTTON.*. Accept only
            // those two button-class forms; do not probe arbitrary controls.
            if (!String.Equals(classValue, "Button", StringComparison.OrdinalIgnoreCase) &&
                !classValue.StartsWith("WindowsForms10.BUTTON", StringComparison.OrdinalIgnoreCase)) return true;
            int length = GetWindowTextLength(child);
            if (length <= 0 || length > 4096) return true;
            StringBuilder text = new StringBuilder(length + 1);
            GetWindowText(child, text, text.Capacity);
            string value = text.ToString().Trim();
            if (!String.Equals(value, "Start Codex", StringComparison.Ordinal) &&
                !String.Equals(value, "\u542f\u52a8 Codex", StringComparison.Ordinal)) return true;
            IntPtr result;
            if (!SendMessageTimeout(child, BM_CLICK, IntPtr.Zero, IntPtr.Zero,
                SMTO_ABORTIFHUNG, 5000, out result)) return true;
            clicked = value;
            return false;
        }, IntPtr.Zero);
        return clicked;
    }

    public static LfSandboxLauncherProgressSnapshot CaptureProgress(IntPtr parent) {
        List<string> labels = new List<string>();
        List<LfSandboxProgressBarSample> bars = new List<LfSandboxProgressBarSample>();
        EnumChildWindows(parent, delegate(IntPtr child, IntPtr ignored) {
            if (!IsWindowVisible(child)) return true;
            StringBuilder className = new StringBuilder(256);
            if (GetClassName(child, className, className.Capacity) == 0) return true;
            string classValue = className.ToString();
            string label = ReadWindowText(child);
            if (label.Length != 0 && !labels.Contains(label) && labels.Count < 128) labels.Add(label);
            if (classValue.IndexOf("msctls_progress32", StringComparison.OrdinalIgnoreCase) < 0) return true;

            uint style = unchecked((uint)GetWindowStyle(child).ToInt64());
            bars.Add(new LfSandboxProgressBarSample {
                Handle = child.ToInt64(),
                ClassName = classValue,
                StyleFlagsHex = "0x" + style.ToString("X8"),
                HasIndeterminateStyle = (style & PBS_MARQUEE) != 0,
                Minimum = GetProgressValue(child, PBM_GETRANGE, new IntPtr(1)),
                Maximum = GetProgressValue(child, PBM_GETRANGE, IntPtr.Zero),
                Position = GetProgressValue(child, PBM_GETPOS, IntPtr.Zero)
            });
            return true;
        }, IntPtr.Zero);
        return new LfSandboxLauncherProgressSnapshot {
            VisibleLabels = labels.ToArray(),
            ProgressBars = bars.ToArray()
        };
    }

    public static LfSandboxTopLevelWindowSnapshot[] CaptureTopLevelWindows(int processId) {
        List<LfSandboxTopLevelWindowSnapshot> windows = new List<LfSandboxTopLevelWindowSnapshot>();
        EnumWindows(delegate(IntPtr window, IntPtr ignored) {
            if (!IsWindowVisible(window) || windows.Count >= 32) return true;
            uint ownerProcessId;
            GetWindowThreadProcessId(window, out ownerProcessId);
            if (ownerProcessId != unchecked((uint)processId)) return true;
            string className = ReadClassName(window);
            IntPtr owner = GetWindow(window, GW_OWNER);
            windows.Add(new LfSandboxTopLevelWindowSnapshot {
                Handle = window.ToInt64(),
                OwnerHandle = owner.ToInt64(),
                ClassName = className,
                Title = ReadWindowText(window),
                IsEnabled = IsWindowEnabled(window),
                IsDialogLike = String.Equals(className, "#32770", StringComparison.OrdinalIgnoreCase) ||
                    owner != IntPtr.Zero,
                VisibleChildTexts = ReadVisibleChildTexts(window)
            });
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }
}
'@
    }
}

function Get-LauncherWindowSnapshot([Diagnostics.Process]$Launcher, [string[]]$Secrets) {
    if ($null -eq $Launcher) { return @() }
    try { $launcherProcessId = $Launcher.Id }
    catch { return @() }
    return @(
        [LfSandboxStartButtonProbe]::CaptureTopLevelWindows($launcherProcessId) |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    Handle = $_.Handle
                    OwnerHandle = $_.OwnerHandle
                    ClassName = Protect-DiagnosticText ([string]$_.ClassName) $Secrets
                    Title = Protect-DiagnosticText ([string]$_.Title) $Secrets
                    IsEnabled = [bool]$_.IsEnabled
                    IsDialogLike = [bool]$_.IsDialogLike
                    VisibleChildTexts = @($_.VisibleChildTexts | ForEach-Object {
                        Protect-DiagnosticText ([string]$_) $Secrets
                    })
                }
            }
    )
}

function New-LauncherProgressAudit {
    return [ordered]@{
        RawSampleCount = 0
        ProgressBarObserved = $false
        IndeterminateStyleObserved = $false
        ProgressRangeObserved = $false
        InvalidProgressRangeObserved = $false
        ObservedPositions = New-Object 'System.Collections.Generic.HashSet[int]'
        HighestPositionByHandle = @{}
        PositionIncreaseObserved = $false
        AmbiguousLabels = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        GenericStatusLabels = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        ExplicitStageLabels = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        ExplicitStageKinds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        Samples = New-Object 'System.Collections.Generic.List[object]'
        LastSignature = $null
        SamplesTruncated = $false
    }
}

function Register-DeterminateProgressMeasurements([object[]]$Bars, [Collections.IDictionary]$Audit) {
    foreach ($bar in @($Bars)) {
        $minimum = [int]$bar.Minimum
        $maximum = [int]$bar.Maximum
        $position = [int]$bar.Position
        # SendMessageTimeout returns -1 when the launcher is tearing down its
        # progress control. That is an unavailable sample, not a displayed
        # invalid range. Real values remain subject to the strict range gate.
        if ($minimum -eq -1 -or $maximum -eq -1 -or $position -eq -1) {
            continue
        }
        if ($maximum -le $minimum -or $position -lt $minimum -or $position -gt $maximum) {
            $Audit.InvalidProgressRangeObserved = $true
            continue
        }

        $Audit.ProgressRangeObserved = $true
        $null = $Audit.ObservedPositions.Add($position)
        $handle = [string]$bar.Handle
        if ($Audit.HighestPositionByHandle.ContainsKey($handle)) {
            if ($position -gt [int]$Audit.HighestPositionByHandle[$handle]) {
                $Audit.PositionIncreaseObserved = $true
                $Audit.HighestPositionByHandle[$handle] = $position
            }
        }
        else {
            $Audit.HighestPositionByHandle[$handle] = $position
        }
    }
}

function Register-ExplicitStageLabels([string[]]$Labels, [Collections.IDictionary]$Audit) {
    $startButtonChinese = (-join @([char]0x542F, [char]0x52A8)) + ' Codex'
    $startButtonLabels = @('Start Codex', $startButtonChinese)
    $stageRules = @(
        [pscustomobject]@{ Kind = 'Validating'; Token = (-join @([char]0x6821, [char]0x9A8C)) }
        [pscustomobject]@{ Kind = 'Extracting'; Token = (-join @([char]0x5C55, [char]0x5F00)) }
        [pscustomobject]@{ Kind = 'Installing'; Token = (-join @([char]0x5B89, [char]0x88C5)) }
        [pscustomobject]@{ Kind = 'Verifying'; Token = (-join @([char]0x590D, [char]0x6838)) }
        [pscustomobject]@{ Kind = 'Starting'; Token = (-join @([char]0x542F, [char]0x52A8)) }
        [pscustomobject]@{ Kind = 'Validating'; Token = 'Validating' }
        [pscustomobject]@{ Kind = 'Extracting'; Token = 'Extracting' }
        [pscustomobject]@{ Kind = 'Installing'; Token = 'Installing' }
        [pscustomobject]@{ Kind = 'Verifying'; Token = 'Verifying' }
        [pscustomobject]@{ Kind = 'Starting'; Token = 'Starting' }
    )
    foreach ($label in @($Labels)) {
        if ([string]::IsNullOrWhiteSpace($label) -or $startButtonLabels -contains $label) { continue }
        foreach ($rule in $stageRules) {
            if ($label.IndexOf($rule.Token, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $null = $Audit.ExplicitStageLabels.Add($label)
                $null = $Audit.ExplicitStageKinds.Add($rule.Kind)
            }
        }
    }
}

function Register-GenericStatusLabels([string[]]$Labels, [Collections.IDictionary]$Audit) {
    $genericInitializationChinese = -join @(
        [char]0x6B63
        [char]0x5728
        [char]0x521D
        [char]0x59CB
        [char]0x5316
    )
    $genericStartPreparationChinese = -join @(
        [char]0x6B63
        [char]0x5728
        [char]0x51C6
        [char]0x5907
        [char]0x542F
        [char]0x52A8
    )
    $genericFirstLaunchPreparationChinese = -join @(
        [char]0x6B63
        [char]0x5728
        [char]0x51C6
        [char]0x5907
        [char]0x9996
        [char]0x6B21
        [char]0x542F
        [char]0x52A8
    )
    $genericPreparationEnglish = 'Pre' + 'paring'
    $genericStatuses = @(
        $genericInitializationChinese
        $genericPreparationEnglish
        $genericStartPreparationChinese
        ($genericPreparationEnglish + ' to start')
        $genericFirstLaunchPreparationChinese
        ($genericPreparationEnglish + ' first launch')
    )
    foreach ($label in @($Labels)) {
        if ([string]::IsNullOrWhiteSpace($label)) { continue }
        $normalized = $label.Trim().TrimEnd([char[]]@([char]0x2026, [char]0x002E))
        foreach ($genericStatus in $genericStatuses) {
            if ([string]::Equals($normalized, $genericStatus, [StringComparison]::OrdinalIgnoreCase)) {
                $null = $Audit.GenericStatusLabels.Add($label)
                break
            }
        }
    }
}

function Add-LauncherProgressSample([Diagnostics.Process]$Launcher, [Collections.IDictionary]$Audit) {
    try {
        $Launcher.Refresh()
        if ($Launcher.HasExited -or $Launcher.MainWindowHandle -eq [IntPtr]::Zero) { return }
        $raw = [LfSandboxStartButtonProbe]::CaptureProgress($Launcher.MainWindowHandle)
        $labels = @($raw.VisibleLabels | ForEach-Object { [string]$_ })
        $bars = @($raw.ProgressBars | ForEach-Object {
            [pscustomobject][ordered]@{
                Handle = $_.Handle
                ClassName = $_.ClassName
                StyleFlagsHex = $_.StyleFlagsHex
                HasIndeterminateStyle = [bool]$_.HasIndeterminateStyle
                Minimum = $_.Minimum
                Maximum = $_.Maximum
                Position = $_.Position
            }
        })
        $Audit.RawSampleCount = [int]$Audit.RawSampleCount + 1
        if ($bars.Count -ne 0) { $Audit.ProgressBarObserved = $true }
        if (@($bars | Where-Object { $_.HasIndeterminateStyle }).Count -ne 0) {
            $Audit.IndeterminateStyleObserved = $true
        }
        Register-DeterminateProgressMeasurements $bars $Audit
        Register-ExplicitStageLabels $labels $Audit
        Register-GenericStatusLabels $labels $Audit

        $ambiguousChineseLabel = -join @(
            [char]0x6B63
            [char]0x5728
            [char]0x5904
            [char]0x7406
        )
        $ambiguousEnglishLabel = 'Work' + 'ing'
        foreach ($label in $labels) {
            if ($label.IndexOf($ambiguousChineseLabel, [StringComparison]::Ordinal) -ge 0 -or
                $label.IndexOf($ambiguousEnglishLabel, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $null = $Audit.AmbiguousLabels.Add($label)
            }
        }

        $styleSignature = @($bars | ForEach-Object {
            $_.ClassName + ':' + $_.StyleFlagsHex + ':' + $_.Minimum + ':' + $_.Maximum + ':' + $_.Position
        }) -join '|'
        $signature = ($labels -join [char]0x1F) + [char]0x1E + $styleSignature
        if ($signature -cne $Audit.LastSignature) {
            $Audit.LastSignature = $signature
            $sample = [pscustomobject][ordered]@{
                SampledUtc = [DateTime]::UtcNow.ToString('o')
                VisibleLabels = $labels
                ProgressBars = $bars
            }
            if ($Audit.Samples.Count -lt 64) { $Audit.Samples.Add($sample) }
            else { $Audit.SamplesTruncated = $true }
        }
    }
    catch {
        # A closing launcher may invalidate its HWND between process refresh
        # and child enumeration. The aggregate gate still requires at least
        # one successful post-click progress-control observation.
    }
}

function Complete-LauncherProgressAudit([Collections.IDictionary]$Audit) {
    $ambiguousLabels = @($Audit.AmbiguousLabels | Sort-Object)
    $genericStatusLabels = @($Audit.GenericStatusLabels | Sort-Object)
    $observedPositions = @($Audit.ObservedPositions | Sort-Object)
    $explicitStageLabels = @($Audit.ExplicitStageLabels | Sort-Object)
    $explicitStageKinds = @($Audit.ExplicitStageKinds | Sort-Object)
    $progressRangeValid = [bool]$Audit.ProgressRangeObserved -and -not [bool]$Audit.InvalidProgressRangeObserved
    $progressAdvanced = $progressRangeValid -and $observedPositions.Count -ge 2 -and [bool]$Audit.PositionIncreaseObserved
    $explicitStagesObserved = $explicitStageLabels.Count -ge 3 -and $explicitStageKinds.Count -ge 3
    $passed = [bool]$Audit.ProgressBarObserved -and -not [bool]$Audit.IndeterminateStyleObserved -and
        $ambiguousLabels.Count -eq 0 -and $genericStatusLabels.Count -eq 0 -and $progressAdvanced -and
        $explicitStagesObserved
    return [pscustomobject][ordered]@{
        RawSampleCount = [int]$Audit.RawSampleCount
        ProgressBarObserved = [bool]$Audit.ProgressBarObserved
        IndeterminateStyleObserved = [bool]$Audit.IndeterminateStyleObserved
        ProgressRangeObserved = [bool]$Audit.ProgressRangeObserved
        InvalidProgressRangeObserved = [bool]$Audit.InvalidProgressRangeObserved
        ProgressRangeValid = $progressRangeValid
        ObservedPositions = $observedPositions
        DistinctPositionCount = $observedPositions.Count
        PositionIncreaseObserved = [bool]$Audit.PositionIncreaseObserved
        ProgressAdvanced = $progressAdvanced
        AmbiguousLabels = $ambiguousLabels
        GenericStatusLabels = $genericStatusLabels
        ExplicitStageLabels = $explicitStageLabels
        ExplicitStageKinds = $explicitStageKinds
        ExplicitStageLabelCount = $explicitStageLabels.Count
        ExplicitStageKindCount = $explicitStageKinds.Count
        ExplicitStagesObserved = $explicitStagesObserved
        SamplesTruncated = [bool]$Audit.SamplesTruncated
        Samples = @($Audit.Samples | ForEach-Object { $_ })
        Passed = $passed
    }
}

function Save-LauncherProgressAudit([Collections.IDictionary]$Manual,
    [Diagnostics.Process]$Launcher, [Collections.IDictionary]$Audit) {
    if ($null -eq $Audit -or $null -eq $Manual['Launcher']) { return }
    if ($null -ne $Launcher) { Add-LauncherProgressSample $Launcher $Audit }
    $Manual['Launcher']['Progress'] = Complete-LauncherProgressAudit $Audit
}

function Get-ManualStartFailureDiagnostics([string]$Root,
    [Diagnostics.Process]$Launcher, [string[]]$Secrets) {
    $collectionErrors = New-Object 'System.Collections.Generic.List[string]'
    $targetProcesses = @()
    $appCurrentProcesses = @()
    $namedDesktopProcesses = @()
    $launcherWindows = @()
    $launcherLogTail = $null

    try { $targetProcesses = Get-ProcessSnapshot @(Get-TargetProcesses $Root) }
    catch {
        $collectionErrors.Add('TargetProcesses: ' +
            (Protect-DiagnosticText $_.Exception.Message $Secrets))
    }
    try { $appCurrentProcesses = Get-ProcessSnapshot @(Get-TargetAppCurrentProcesses $Root) }
    catch {
        $collectionErrors.Add('AppCurrentProcesses: ' +
            (Protect-DiagnosticText $_.Exception.Message $Secrets))
    }
    try { $namedDesktopProcesses = Get-ProcessSnapshot @(Get-TargetDesktopProcesses $Root) }
    catch {
        $collectionErrors.Add('NamedDesktopProcesses: ' +
            (Protect-DiagnosticText $_.Exception.Message $Secrets))
    }
    try { $launcherWindows = Get-LauncherWindowSnapshot $Launcher $Secrets }
    catch {
        $collectionErrors.Add('LauncherWindows: ' +
            (Protect-DiagnosticText $_.Exception.Message $Secrets))
    }
    try { $launcherLogTail = Get-SanitizedLauncherLogTail $Root $Secrets }
    catch {
        $collectionErrors.Add('LauncherLogTail: ' +
            (Protect-DiagnosticText $_.Exception.Message $Secrets))
    }

    return [pscustomobject][ordered]@{
        CapturedUtc = [DateTime]::UtcNow.ToString('o')
        TargetProcesses = @($targetProcesses)
        AppCurrentProcesses = @($appCurrentProcesses)
        NamedDesktopProcesses = @($namedDesktopProcesses)
        LauncherWindows = @($launcherWindows)
        LauncherLogTail = $launcherLogTail
        CollectionErrors = @($collectionErrors)
    }
}

function Invoke-ManualStart([string]$Root) {
    $manual = [ordered]@{
        Executed = $true
        StartedUtc = [DateTime]::UtcNow.ToString('o')
        Passed = $false
        Error = $null
        ZeroState = $null
        EphemeralApiConfiguration = $null
        Launcher = $null
        DerivedState = $null
        FailureDiagnostics = $null
        Cleanup = $null
    }
    $progressAudit = $null
    $launcher = $null
    $ephemeralApiKey = $null
    try {
        $copyExitCode = Copy-CompactRelease $SourceRoot $Root
        $dataRoot = Join-Path $Root 'CodexData\data'
        $configRoot = Join-Path $dataRoot 'config'
        $secretsRoot = Join-Path $dataRoot 'secrets'
        $configToml = Join-Path $dataRoot 'profile\.codex\config.toml'
        $payloadRoot = Join-Path $Root 'CodexData\app\current'
        $runtimeCacheRoot = Join-Path $dataRoot 'profile\.cache\codex-runtimes'
        $pluginCacheRoot = Join-Path $dataRoot 'profile\.codex\plugins\cache'
        $zeroState = [ordered]@{
            CopyRobocopyExitCode = $copyExitCode
            ConfigTomlExists = Test-Path -LiteralPath $configToml
            ExpandedPayloadExists = Test-Path -LiteralPath $payloadRoot
            RuntimeCacheExists = Test-Path -LiteralPath $runtimeCacheRoot
            PluginCacheExists = Test-Path -LiteralPath $pluginCacheRoot
            FirstExecutableAction = 'Start CodexPortable.exe only'
        }
        # Persist the pre-start snapshot even on a failure so the exported
        # proof identifies whether a runtime or plugin cache contaminated the
        # supposedly fresh manual-start target.
        $manual.ZeroState = $zeroState
        if ($zeroState.ConfigTomlExists -or $zeroState.ExpandedPayloadExists -or
            $zeroState.RuntimeCacheExists -or $zeroState.PluginCacheExists) {
            throw 'Manual-start target was not zero-state before the first launcher action.'
        }

        # Preconfigure a disposable local endpoint so the actual Start Codex
        # click can reach the desktop startup path without any network access.
        $utf8 = New-Object Text.UTF8Encoding($false)
        New-Item -ItemType Directory -Path $configRoot, $secretsRoot -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $configRoot 'custom-api-url.txt'), "http://127.0.0.1:9`r`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $configRoot 'custom-model.txt'), "sandbox-local-probe`r`n", $utf8)
        $ephemeralApiKey = 'sandbox-' + [Guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText((Join-Path $secretsRoot 'api-key.txt'), ($ephemeralApiKey + "`r`n"), $utf8)
        $manual.EphemeralApiConfiguration = [ordered]@{
            BaseUrl = 'http://127.0.0.1:9'
            Model = 'sandbox-local-probe'
            ApiKeyWritten = $true
            KeyValueRecorded = $false
            NetworkDisabledBySandbox = $true
        }

        $bootstrapper = Join-Path $Root 'CodexPortable.exe'
        $bootstrap = Start-Process -FilePath $bootstrapper -WorkingDirectory $Root -PassThru
        $launcher = Wait-Until {
            @(Get-TargetProcesses $Root | Where-Object {
                try { $_.Path.StartsWith((Join-Path $Root 'CodexData\tools\launchers').TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -and $_.MainWindowHandle -ne [IntPtr]::Zero }
                catch { $false }
            } | Select-Object -First 1)
        } 180 'the manual-start LF launcher window'
        $launcher.Refresh()
        $clickedLabel = Wait-Until {
            [LfSandboxStartButtonProbe]::ClickStartCodexButton($launcher.MainWindowHandle)
        } 120 'the actual Start Codex button'
        $manual.Launcher = [ordered]@{
            BootstrapperProcessId = $bootstrap.Id
            CoreProcessId = $launcher.Id
            WindowTitle = $launcher.MainWindowTitle
            StartButtonLabel = $clickedLabel
            ActualButtonClicked = $true
        }
        $progressAudit = New-LauncherProgressAudit
        $manual['Launcher']['Progress'] = Complete-LauncherProgressAudit $progressAudit
        Add-LauncherProgressSample $launcher $progressAudit

        $desktopProcess = Wait-Until {
            Add-LauncherProgressSample $launcher $progressAudit
            @(Get-TargetDesktopProcesses $Root | Select-Object -First 1)
        } $TimeoutSeconds 'Codex Desktop after Start Codex'
        # Electron creates utility/zygote processes before the browser process
        # owns a window. Re-enumerate on every poll so a later main process is
        # accepted instead of pinning the check to the first child forever.
        $desktopWindow = Wait-Until {
            Add-LauncherProgressSample $launcher $progressAudit
            foreach ($candidate in @(Get-TargetDesktopProcesses $Root)) {
                try {
                    $candidate.Refresh()
                    if (-not $candidate.HasExited -and $candidate.MainWindowHandle -ne [IntPtr]::Zero) {
                        return $candidate
                    }
                }
                catch { }
            }
            return $false
        } 180 'the Codex Desktop main window'
        Add-LauncherProgressSample $launcher $progressAudit
        Save-LauncherProgressAudit $manual $launcher $progressAudit
        if (-not $manual.Launcher.Progress.Passed) {
            throw 'The post-click launcher progress UI did not satisfy the determinate, explicit-status contract.'
        }

        $payloadRequired = @('ChatGPT.exe', 'CodexDesktop.exe', 'resources\app.asar')
        $runtimeRoot = Join-Path $runtimeCacheRoot 'codex-primary-runtime'
        $runtimeRequired = @('runtime.json', 'dependencies\node\bin\node.exe', 'dependencies\python\python.exe', 'dependencies\native\git\cmd\git.exe')
        $payloadMissing = @($payloadRequired | Where-Object { -not (Test-Path -LiteralPath (Join-Path $payloadRoot $_) -PathType Leaf) })
        $runtimeMissing = @($runtimeRequired | Where-Object { -not (Test-Path -LiteralPath (Join-Path $runtimeRoot $_) -PathType Leaf) })
        if ($payloadMissing.Count -ne 0 -or $runtimeMissing.Count -ne 0) {
            throw 'Actual Start Codex did not produce every required desktop payload or runtime file.'
        }
        $pluginCache = $pluginCacheRoot
        $installedPlugins = Wait-Until {
            $audit = Get-InstalledPluginAudit $pluginCache
            if ($audit.Valid) { return $audit }
            return $false
        } $TimeoutSeconds 'all twelve versioned plugin-cache entries'
        $configText = Get-Content -LiteralPath $configToml -Raw -ErrorAction Stop
        $approval = @([regex]::Matches($configText, '(?m)^approval_policy\s*=\s*"(?<value>[^"]+)"\s*(?:#.*)?$'))
        $sandbox = @([regex]::Matches($configText, '(?m)^sandbox_mode\s*=\s*"(?<value>[^"]+)"\s*(?:#.*)?$'))
        $configValid = $approval.Count -eq 1 -and $sandbox.Count -eq 1 -and
            $approval[0].Groups['value'].Value -ceq 'never' -and $sandbox[0].Groups['value'].Value -ceq 'danger-full-access'
        if (-not $configValid) { throw 'Actual Start Codex changed the config.toml root permission contract.' }
        $manual.DerivedState = [ordered]@{
            PayloadRoot = $payloadRoot
            PayloadMissingFiles = @($payloadMissing)
            RuntimeRoot = $runtimeRoot
            RuntimeMissingFiles = @($runtimeMissing)
            PluginCache = $installedPlugins
            ConfigToml = [ordered]@{
                Path = $configToml
                ApprovalPolicy = $approval[0].Groups['value'].Value
                SandboxMode = $sandbox[0].Groups['value'].Value
                RootPermissionsStillValid = $configValid
            }
            Desktop = [ordered]@{
                ProcessId = $desktopProcess.Id
                ExecutablePath = $desktopProcess.Path
                WindowTitle = $desktopWindow.MainWindowTitle
                MainWindowObserved = $desktopWindow.MainWindowHandle -ne [IntPtr]::Zero
            }
        }
        $manual.Passed = $manual.Launcher.ActualButtonClicked -and $manual.Launcher.Progress.Passed -and
            $manual.DerivedState.Desktop.MainWindowObserved -and
            $payloadMissing.Count -eq 0 -and $runtimeMissing.Count -eq 0 -and $installedPlugins.Valid -and $configValid
    }
    catch {
        $manual.Error = Protect-DiagnosticText $_.Exception.Message @($ephemeralApiKey)
        if ($null -ne $progressAudit) {
            try { Save-LauncherProgressAudit $manual $launcher $progressAudit } catch { }
        }
        $manual.FailureDiagnostics = Get-ManualStartFailureDiagnostics $Root $launcher @($ephemeralApiKey)
        $manual.Passed = $false
    }
    finally {
        if ($null -ne $progressAudit) {
            try { Save-LauncherProgressAudit $manual $launcher $progressAudit } catch { }
        }
        if (-not $manual.Passed -and $null -eq $manual.FailureDiagnostics) {
            $manual.FailureDiagnostics = Get-ManualStartFailureDiagnostics $Root $launcher @($ephemeralApiKey)
        }
        $manual.Cleanup = Stop-TargetProcesses $Root
        if (-not $manual.Cleanup.Succeeded) {
            $manual.Passed = $false
            if ($null -eq (Get-NullableObjectProperty $manual 'Error')) {
                $manual.Error = 'Could not close all Sandbox-owned manual-start processes.'
            }
        }
        $ephemeralApiKey = $null
        $manual.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    }
    return [pscustomobject]$manual
}

$result = [ordered]@{
    Contract = $contract
    Status = 'Running'
    Passed = $false
    StartedUtc = [DateTime]::UtcNow.ToString('o')
    SourceRoot = $SourceRoot
    ManifestPath = $ManifestPath
    ExpectedManagedFileCount = 10
    ExpectedPluginCount = 12
    ManifestSha256 = $null
    ReleaseVersion = $null
    ManualStart = [ordered]@{ Executed = $false; Passed = $false }
}
$exitCode = 1

try {
    # Keep every executable initialization step inside the result-writing
    # boundary so a guest capability failure is exported to the host.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Initialize-SandboxStartButtonProbe
    foreach ($path in @($SourceRoot, $ManifestPath, $EvidenceRoot)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Required Sandbox mapping is missing: $path" }
    }
    $sourceFull = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\')
    $manifestFull = (Resolve-Path -LiteralPath $ManifestPath).Path
    $evidenceFull = (Resolve-Path -LiteralPath $EvidenceRoot).Path.TrimEnd('\')
    $manifest = Get-Content -LiteralPath $manifestFull -Raw | ConvertFrom-Json -ErrorAction Stop
    $result.SourceRoot = $sourceFull
    $result.ManifestPath = $manifestFull
    $result.ManifestSha256 = (Get-FileHash -LiteralPath $manifestFull -Algorithm SHA256).Hash.ToUpperInvariant()
    $result.ReleaseVersion = [string]$manifest.ReleaseVersion
    if ($result.ReleaseVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Release manifest has no valid four-part ReleaseVersion.' }

    $sourceFiles = Get-RelativeFiles $sourceFull
    $result.CompactRelease = [ordered]@{
        ExpectedManagedFileCount = 10
        SourceFileCount = $sourceFiles.Count
        ManifestFileCount = @($manifest.Files).Count
        SourceFileCountValid = $sourceFiles.Count -eq 10
        ManifestFileCountValid = @($manifest.Files).Count -eq 10
        SourcePathsValid = Test-ExactStringSet $expectedFiles $sourceFiles
        ManifestPathsValid = Test-ExactStringSet $expectedFiles @($manifest.Files | ForEach-Object { [string]$_.Path })
    }
    $result.Plugins = Get-PluginAudit (Join-Path $sourceFull 'CodexData\packages\LFPortable-common.zip')
    if (-not $result.CompactRelease.SourceFileCountValid -or -not $result.CompactRelease.ManifestFileCountValid -or
        -not $result.CompactRelease.SourcePathsValid -or -not $result.CompactRelease.ManifestPathsValid -or -not $result.Plugins.Valid) {
        throw 'Mapped canonical release does not satisfy the 10-file and 12-plugin compact contract.'
    }

    $validatorTarget = Join-Path $env:SystemDrive ('LFPortable-validator-' + $result.ReleaseVersion)
    $validatorResultPath = Join-Path $env:SystemDrive ('LFPortable-validator-' + $result.ReleaseVersion + '.json')
    $validatorScript = Join-Path $PSScriptRoot 'Validate-CompactFirstRun.ps1'
    & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File $validatorScript `
        -SourceRoot $sourceFull -ManifestPath $manifestFull -TargetRoot $validatorTarget -ResultPath $validatorResultPath -TimeoutSeconds $TimeoutSeconds
    $validatorExitCode = [int]$LASTEXITCODE
    $validatorResult = if (Test-Path -LiteralPath $validatorResultPath -PathType Leaf) {
        Get-Content -LiteralPath $validatorResultPath -Raw | ConvertFrom-Json -ErrorAction Stop
    }
    else { $null }
    $result.Validator = [ordered]@{
        ExitCode = $validatorExitCode
        ResultWritten = $null -ne $validatorResult
        Passed = $null -ne $validatorResult -and [bool](Get-ObjectProperty $validatorResult 'Passed')
        Status = Get-ObjectProperty $validatorResult 'Status'
        Error = Get-ObjectProperty $validatorResult 'Error'
    }
    if ($validatorExitCode -ne 0 -or -not $result.Validator.Passed -or $result.Validator.Status -cne 'Passed') {
        throw 'The isolated zero-state validator did not pass; manual Start Codex was not attempted.'
    }

    $manualTarget = Join-Path $env:SystemDrive ('LFPortable-manual-' + $result.ReleaseVersion)
    $result.ManualStart = Invoke-ManualStart $manualTarget
    $result.Passed = $result.Validator.Passed -and $result.ManualStart.Passed
    $result.Status = if ($result.Passed) { 'Passed' } else { 'Failed' }
    $exitCode = if ($result.Passed) { 0 } else { 2 }
}
catch {
    $result.Error = $_.Exception.ToString()
    $result.Passed = $false
    $result.Status = 'Failed'
}
finally {
    $result.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    try {
        Write-Json (Join-Path $EvidenceRoot 'sandbox-first-run-result.json') $result
    }
    catch {
        # The host must never mistake a missing guest result for a successful
        # validation. There is no second write attempt because the mapped
        # evidence directory itself may be unavailable.
        $result.Passed = $false
        $result.Status = 'Failed'
        if ([string]::IsNullOrWhiteSpace([string](Get-NullableObjectProperty $result 'Error'))) {
            $result.Error = 'Could not write Sandbox validation result: ' + $_.Exception.Message
        }
        $exitCode = 1
        [Console]::Error.WriteLine('Could not write Sandbox validation result: ' + $_.Exception.Message)
    }
}

exit $exitCode
