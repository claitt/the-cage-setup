# =====================================================================
#  CAGE SETUP - Installer for NieR Re[in]carnation (private server)
#  ------------------------------------------------------------------
#  Guided GUI that downloads, installs and configures everything.
#  Every download shows status, percentage, speed and estimated time.
#
#  Normal use:  double-click "Cage Setup.cmd"
#  Diagnostics: powershell -ExecutionPolicy Bypass -File "Cage Setup.ps1" -Console
#
#  CREDITS
#   - Lunar Tear private server:  https://gitlab.com/walter-sparrow-group/lunar-tear
#                                 https://github.com/Walter-Sparrow/lunar-tear
#   - lunar-scripts patchers:     https://gitlab.com/walter-sparrow-group/lunar-scripts
#   - Game assets (archive.org):  https://archive.org/details/nier_reincarnation_assets
#   - Master data (archive.org):  https://archive.org/details/20240404193219.bin
#   - Stock APK:                  https://www.apkmirror.com/apk/square-enix-co-ltd/nier-reincarnation/
#   - apktool (iBotPeaches), Android build tools (Google), Temurin JRE (Adoptium),
#     Python (python.org), PyCryptodome/msgpack/lz4 (PyPI)
#   - MuMu Player:                NetEase
#
#  This package does NOT contain any game APK, game assets or master data:
#  the stock APK is downloaded from APKMirror and patched on this PC with the
#  official lunar-scripts patcher, the game data comes from archive.org and the
#  master data is patched locally with the same tooling.
# =====================================================================
#Requires -Version 5.1

param(
    [switch]$Console,      # text diagnostics, no GUI
    [switch]$InstallAll    # no GUI: run everything in the console
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

$Root = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $Root) { $Root = (Get-Location).Path }
$LogFile = Join-Path $Root 'installer-log.txt'

# ---------------------------------------------------------------------
#  SOURCES AND PATHS  (edit here when you redistribute the installer)
# ---------------------------------------------------------------------
$Config = @{
    # --- Emulator ---
    MuMuInstallerUrl = 'https://api.mumuplayer.com/api/dl/win?channel=gw-overseas12'

    # --- Server binaries (GitHub Releases; the latest version is auto-detected) ---
    ServerRepo        = 'Walter-Sparrow/lunar-tear'
    ServerAssetMatch  = 'windows-amd64'
    ServerUrl         = ''   # leave empty to use the latest GitHub release
    ServerUrlFallback = 'https://github.com/Walter-Sparrow/lunar-tear/releases/download/v1.0.2/lunar-tear-server-v1.0.2-windows-amd64.zip'

    # --- Game assets (archive.org) ~14.93 GB download, ~48.8 GB on disk ---
    AssetsUrl   = 'https://archive.org/download/nier_reincarnation_assets/resource_dump_android.7z'
    AssetsBytes = 14928186871
    AssetsSha1  = '49ad027ee838811ecf37dacfbdac1b3e7711253e'

    # --- Master data (archive.org) ~7.4 MB ---
    MasterUrl   = 'https://archive.org/download/20240404193219.bin/20240404193219.bin.e'
    MasterBytes = 7801104
    MasterSha1  = '9b7b1a077e557a5b7d3c63f0ef62a2d39fd1d899'

    # --- Game client: the STOCK apk is downloaded from APKMirror and patched ---
    #     locally, so no game binary is redistributed with this package.
    ApkPageUrl    = 'https://www.apkmirror.com/apk/square-enix-co-ltd/nier-reincarnation/nier-reincarnation-3-7-1-release/nier-reincarnation-3-7-1-2-android-apk-download/'
    ApkStockBytes = 263571029
    ApkStockFile  = Join-Path $Root 'apk\stock\nier-3.7.1-stock.apk'
    ApkWorkDir    = Join-Path $Root 'apk\work'
    ApkOutput     = Join-Path $Root 'apk\out\nier-patched.apk'
    Keystore      = Join-Path $Root 'apk\out\debug.keystore'
    GrpcAddr      = '10.0.2.2:8003'
    HttpAddr      = '10.0.2.2:8080'
    AuthAddr      = '10.0.2.2:3000'

    # --- Toolchain, downloaded on demand (never committed to the repository) ---
    #     Versions are pinned so the files can be verified by size.
    JreUrl        = 'https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20.1%2B1/OpenJDK17U-jre_x64_windows_hotspot_17.0.20.1_1.zip'
    JreBytes      = 43780109
    ApktoolUrl    = 'https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar'
    ApktoolBytes  = 15478013
    BuildToolsUrl = 'https://dl.google.com/android/repository/build-tools_r35_windows.zip'
    BuildToolsBytes = 59878107
    PythonUrl     = 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip'
    PythonBytes   = 11133606

    # --- Patcher scripts, always taken from the upstream repository ---
    ScriptsRaw    = 'https://gitlab.com/walter-sparrow-group/lunar-scripts/-/raw/main'

    # --- Local files (offline use / development) ---
    ServerExe     = Join-Path $Root 'server\wizard.exe'
    MasterFile    = Join-Path $Root 'server\assets\release\20240404193219.bin.e'
    AssetsArchive = Join-Path $Root 'downloads\resource_dump_android.7z'
}

# SHA1 of the master data after the official patcher has extended the content
# to 2030. Used to tell an already-patched file from the original one.
$Script:MasterPatchedSha1 = 'DF6F4F1AC90466F940DDB3F18E1FA9627D5B9DFA'

$Paths = @{
    MuMuDir          = 'C:\Program Files\Netease\MuMuPlayer'
    MuMuManager      = 'C:\Program Files\Netease\MuMuPlayer\nx_main\MuMuManager.exe'
    MuMuInstaller    = Join-Path $Root 'tools\mumu\MuMu-installer.exe'
    MuMuInstallerOff = Join-Path $Root 'tools\mumu\offline\MuMuNG-offline-setup.exe'
    SevenZip         = Join-Path $Root 'tools\7zr.exe'
    ServerDir        = Join-Path $Root 'server'
    AssetsDir        = Join-Path $Root 'server\assets'
    Downloads        = Join-Path $Root 'downloads'
    StartServerCmd   = Join-Path $Root 'Start Server.cmd'
    Adb              = $null   # detected at runtime
    JdkDir           = Join-Path $Root 'tools\jdk'
    ApktoolJar       = Join-Path $Root 'tools\apktool.jar'
    BuildToolsDir    = Join-Path $Root 'tools\build-tools'
    PythonDir        = Join-Path $Root 'tools\python'
    ScriptsDir       = Join-Path $Root 'tools\lunar-scripts'
}

$Script:PackageName = 'com.square_enix.android_googleplay.nierspww'
$Script:Serial      = '127.0.0.1:7555'
$Script:EngineBytes = 4200000000      # ~4 GB, used for the engine progress bar

# process names whose windows are hidden during the MuMu installation
$Script:HideProcessNames = @('nemu-downloader', 'nemu-setup', 'MuMuNG-setup', 'MuMuSetup', 'MuMuPlayer', 'MuMuPlayerUpdater', 'MuMuInstaller')

# =====================================================================
#  WINDOW CONTROL (makes the MuMu installation silent)
# =====================================================================
if (-not ('LunarTear.WinApi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace LunarTear
{
    public class WinApi
    {
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
        delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

        static HashSet<uint> Set(int[] pids)
        {
            var s = new HashSet<uint>();
            if (pids != null) foreach (var p in pids) s.Add((uint)p);
            return s;
        }

        public static int HideForPids(int[] pids, bool hide)
        {
            var set = Set(pids);
            int n = 0;
            EnumWindows((h, l) =>
            {
                uint pid; GetWindowThreadProcessId(h, out pid);
                if (set.Contains(pid)) { ShowWindow(h, hide ? 0 : 5); n++; }
                return true;
            }, IntPtr.Zero);
            return n;
        }

        public static int CountVisibleForPids(int[] pids)
        {
            var set = Set(pids);
            int n = 0;
            EnumWindows((h, l) =>
            {
                uint pid; GetWindowThreadProcessId(h, out pid);
                if (set.Contains(pid) && IsWindowVisible(h)) n++;
                return true;
            }, IntPtr.Zero);
            return n;
        }
    }
}
'@
}

function Get-ProcessIdsByName {
    param([string[]]$Names)
    @(Get-Process -Name $Names -ErrorAction SilentlyContinue | Select-Object -Expand Id)
}
function Hide-MuMuWindows {
    $p = Get-ProcessIdsByName $Script:HideProcessNames
    if ($p -and $p.Count -gt 0) { [void][LunarTear.WinApi]::HideForPids([int[]]$p, $true) }
}
# NOTE: Windows does not allow one process to re-show another process' window
# (verified: ShowWindow(SW_SHOW), ShowWindowAsync and SetWindowPos(SWP_SHOWWINDOW)
# all fail). So if the hidden installation gets stuck we kill it and retry with
# the window visible instead of trying to re-show it.
function Get-VisibleMuMuWindows {
    $p = Get-ProcessIdsByName $Script:HideProcessNames
    if ($p -and $p.Count -gt 0) { [LunarTear.WinApi]::CountVisibleForPids([int[]]$p) } else { 0 }
}

# =====================================================================
#  LOG
# =====================================================================
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERROR','STEP')][string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    if ($Script:LogBox) {
        $Script:LogBox.AppendText($line + "`r`n")
        $Script:LogBox.SelectionStart = $Script:LogBox.TextLength
        $Script:LogBox.ScrollToCaret()
    }
    if ($Console -or $InstallAll) { Write-Host $line }
}

# =====================================================================
#  UTILITIES
# =====================================================================
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FreeSpaceGB {
    try { [math]::Round((Get-PSDrive C -ErrorAction Stop).Free / 1GB, 1) } catch { 0 }
}

function Get-FolderSize {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    (Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
}

function Test-VirtualizationEnabled {
    $c = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) {
        if ($c.VirtualizationFirmwareEnabled) { return $true }
        if ($c.SecondLevelAddressTranslationExtensions) { return $true }
    }
    # fallback: the AEHD driver or MuMuNxSup present means virtualization works
    if (Get-Service aehd -ErrorAction SilentlyContinue) { return $true }
    if (Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'MuMuNxSup' }) { return $true }
    return $false
}

function Test-HyperVActive {
    try { (Get-CimInstance Win32_ComputerSystem).HypervisorPresent } catch { $false }
}

# ---- emulator -------------------------------------------------------
function Test-MuMuInstalled {
    Test-Path $Paths.MuMuManager
}

function Test-MuMuEngine {
    $base = Join-Path $Paths.MuMuDir 'nx_device'
    if (-not (Test-Path $base)) { return $false }
    [bool](Get-ChildItem $base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+\.\d+$' })
}

function Get-Adb {
    if ($Paths.Adb -and (Test-Path $Paths.Adb)) { return $Paths.Adb }
    $candidates = @()
    if (Test-Path (Join-Path $Paths.MuMuDir 'nx_device')) {
        $candidates += Get-ChildItem (Join-Path $Paths.MuMuDir 'nx_device') -Recurse -Filter 'adb.exe' -ErrorAction SilentlyContinue |
                       Select-Object -Expand FullName
    }
    $fallback = Join-Path $Root 'tools\android-sdk\platform-tools\adb.exe'
    if (Test-Path $fallback) { $candidates += $fallback }
    $Paths.Adb = $candidates | Select-Object -First 1
    $Paths.Adb
}

# Small cache: a status refresh asks this several times and every ADB call costs
# about a second, which would freeze the window while refreshing.
$Script:EmulatorCache = $false
$Script:EmulatorCacheTime = [datetime]::MinValue

function Test-EmulatorRunning {
    $now = Get-Date
    if (($now - $Script:EmulatorCacheTime).TotalSeconds -lt 3) { return $Script:EmulatorCache }

    $result = $false
    $adb = Get-Adb
    if ($adb) {
        $pattern = [regex]::Escape($Script:Serial) + '\s+device'
        $devices = (& $adb devices 2>&1) -join "`n"
        if ($devices -notmatch $pattern) {
            & $adb connect $Script:Serial 2>&1 | Out-Null
            $devices = (& $adb devices 2>&1) -join "`n"
        }
        $result = ($devices -match $pattern)
    }
    $Script:EmulatorCache = $result
    $Script:EmulatorCacheTime = $now
    return $result
}

function Test-GameInstalled {
    if (-not (Test-EmulatorRunning)) { return $false }
    $adb = Get-Adb
    ((& $adb -s $Script:Serial shell pm list packages $Script:PackageName 2>&1) -join '') -match 'nierspww'
}

function Test-DebloatApplied {
    if (-not (Test-EmulatorRunning)) { return $false }
    $adb = Get-Adb
    $r = (& $adb -s $Script:Serial shell pm list packages --user 0 com.mumu.store 2>&1) -join ''
    return (-not ($r -match 'com.mumu.store'))
}

# Removes only the NetEase/MuMu components; the game, Google services
# (GMS/GSF/Play Store) and the rest of Android are untouched.
# Everything is reversible:
#   pm install-existing <pkg>      (restore a removed package)
#   pm enable --user 0 <pkg>       (re-enable a disabled package)
function Invoke-MuMuDebloat {
    $adb = Get-Adb
    if (-not $adb) { Write-Log 'adb not found: cannot apply the debloat' 'ERROR'; return $false }

    $remove = @(
        'com.mumu.store',             # MuMu app store
        'com.mumu.shared.sdk',        # MuMu shared SDK
        'com.mumu.acc',               # MuMu account
        'com.nemu.nlp',               # NetEase NLP service
        'com.nemu.oaidmanager',       # OAID / advertising id
        'com.netease.mumu.cloner'     # app cloner
    )
    $disable = @(
        'com.sohu.inputmethod.sogou.chuizi'   # Chinese Sogou keyboard (the only system IME)
    )

    foreach ($p in $remove) {
        $r = (& $adb -s $Script:Serial shell pm uninstall --user 0 $p 2>&1) -join ' '
        Write-Log ("{0,-40} -> {1}" -f $p, $r.Trim())
        [Windows.Forms.Application]::DoEvents()
    }
    foreach ($p in $disable) {
        $r = (& $adb -s $Script:Serial shell pm disable-user --user 0 $p 2>&1) -join ' '
        Write-Log ("{0,-40} -> {1}" -f $p, $r.Trim())
        [Windows.Forms.Application]::DoEvents()
    }
    foreach ($p in ($remove + $disable)) {
        $active = (& $adb -s $Script:Serial shell pm list packages --user 0 $p 2>&1) -join ''
        $off    = (& $adb -s $Script:Serial shell pm list packages -d $p 2>&1) -join ''
        $state = if (-not $active) { 'REMOVED' } elseif ($off) { 'DISABLED' } else { 'STILL ACTIVE' }
        Write-Log ("{0,-40} {1}" -f $p, $state)
    }
    return $true
}

function Test-ArmBridge {
    if (-not (Test-EmulatorRunning)) { return $false }
    $adb = Get-Adb
    $bridge = ((& $adb -s $Script:Serial shell getprop ro.dalvik.vm.native.bridge 2>&1) -join '').Trim()
    $abis = ((& $adb -s $Script:Serial shell getprop ro.product.cpu.abilist 2>&1) -join '').Trim()
    return ([bool]$bridge -and ($abis -match 'arm64'))
}

# ---- server ---------------------------------------------------------
function Test-ServerFiles {
    (Test-Path $Config.ServerExe) -and (Test-Path (Join-Path $Paths.ServerDir 'bin'))
}

function Get-MasterDataHash {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return '' }
    $info = Get-Item $Path
    $cache = $Script:MasterHash
    if ($cache -and $cache.Path -eq $Path -and $cache.Stamp -eq $info.LastWriteTimeUtc.Ticks -and $cache.Length -eq $info.Length) {
        return $cache.Hash
    }
    $hash = (Get-FileHash $Path -Algorithm SHA1).Hash
    $Script:MasterHash = @{ Path = $Path; Stamp = $info.LastWriteTimeUtc.Ticks; Length = $info.Length; Hash = $hash }
    return $hash
}

function Test-MasterData {
    $file = $Config.MasterFile
    if (-not (Test-Path $file)) { return $false }
    $hash = Get-MasterDataHash $file
    if ($hash -eq $Script:MasterPatchedSha1) { return $true }
    # the recorded hash tells apart a file patched by us from a custom one
    $marker = "$file.patched"
    if (Test-Path $marker) {
        $recorded = (Get-Content $marker -Raw -ErrorAction SilentlyContinue)
        if ($recorded) { return ($recorded.Trim() -eq $hash) }
    }
    return $false
}

function Test-GameAssets {
    $revisions = Join-Path $Paths.AssetsDir 'revisions'
    if (-not (Test-Path $revisions)) { return $false }
    [bool](Get-ChildItem $revisions -Directory -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Test-PortOpen {
    param([int]$Port)
    $t = New-Object Net.Sockets.TcpClient
    try { $t.Connect('127.0.0.1', $Port); $true } catch { $false } finally { $t.Dispose() }
}

function Test-ServerRunning {
    (Test-PortOpen 8003) -and (Test-PortOpen 8080)
}

function Get-ServerProcesses {
    $found = @()
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        try {
            $path = $p.Path
            if ($path -and $path.StartsWith($Paths.ServerDir, [System.StringComparison]::OrdinalIgnoreCase)) {
                $found += $p
            }
        } catch { }
    }
    $found
}

# =====================================================================
#  DOWNLOADS with percentage and speed
# =====================================================================
function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Update-Progress {
    param(
        [string]$Text = '',
        [int64]$Done = 0,
        [int64]$Total = 0,
        [double]$Speed = -1,
        [switch]$Indeterminate,
        [switch]$Percentage
    )
    $pct = 0
    if ($Total -gt 0) { $pct = [math]::Min(100, [math]::Round(($Done / $Total) * 100, 0)) }

    $detail = $Text
    if ($Percentage) {
        if ($Total -gt 0) { $detail += "  |  $pct%" }
    } elseif ($Total -gt 0) {
        $detail += '  |  ' + (Format-Size $Done) + ' / ' + (Format-Size $Total) + "  |  $pct%"
    }
    if ($Speed -ge 0) {
        $detail += '  |  ' + (Format-Size $Speed) + '/s'
        if ($Speed -gt 0 -and $Total -gt $Done) {
            $left = ($Total - $Done) / $Speed
            $detail += '  |  left ' + ([TimeSpan]::FromSeconds($left).ToString('mm\:ss'))
        }
    }

    if ($Script:ProgressBar) {
        if ($Indeterminate) {
            $Script:ProgressBar.Style = 'Marquee'
        } else {
            $Script:ProgressBar.Style = 'Continuous'
            $Script:ProgressBar.Value = [math]::Min(100, [math]::Max(0, $pct))
        }
    }
    if ($Script:ProgressLabel) { $Script:ProgressLabel.Text = $detail }
    [System.Windows.Forms.Application]::DoEvents()
}

function Send-Download {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [string]$Label = 'Download',
        [int64]$Bytes = 0,       # known total size (enables resume)
        [string]$Sha1 = '',      # optional integrity check
        [int]$Retries = 6
    )
    $folder = Split-Path $Destination -Parent
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }

    if ((Test-Path $Destination) -and ((-not $Bytes) -or ((Get-Item $Destination).Length -eq $Bytes))) {
        Write-Log "$Label already present: $Destination" 'OK'
        return $true
    }

    $tmp = "$Destination.part"
    Write-Log "$Label - downloading from: $Url"
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromHours(10)
    try {
        for ($attempt = 1; $attempt -le $Retries; $attempt++) {
            [int64]$existing = 0
            if (Test-Path $tmp) { $existing = (Get-Item $tmp).Length }
            if ($Bytes -gt 0 -and $existing -ge $Bytes) { break }

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)
            if ($existing -gt 0) {
                [void]$req.Headers.TryAddWithoutValidation('Range', "bytes=$existing-")
                Write-Log ("$Label : resuming from " + (Format-Size $existing))
            }
            try {
                $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                if (-not $resp.IsSuccessStatusCode) {
                    throw ('HTTP ' + [int]$resp.StatusCode + ' ' + $resp.ReasonPhrase)
                }
                $partial = ($resp.StatusCode -eq [System.Net.HttpStatusCode]::PartialContent)
                if (-not $partial) { $existing = 0 }
                [int64]$length = 0
                if ($resp.Content.Headers.ContentLength) { $length = [int64]$resp.Content.Headers.ContentLength }
                [int64]$total = 0
                if ($Bytes -gt 0) { $total = $Bytes } elseif ($length -gt 0) { $total = $existing + $length }

                $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $mode = if ($partial -and $existing -gt 0) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
                $out = [System.IO.File]::Open($tmp, $mode, [System.IO.FileAccess]::Write)
                $buffer = New-Object byte[] 1048576
                [int64]$done = $existing
                $lastMs = 0.0; [int64]$lastBytes = $done; $speed = 0.0
                try {
                    while ($true) {
                        $n = $stream.Read($buffer, 0, $buffer.Length)
                        if ($n -le 0) { break }
                        $out.Write($buffer, 0, $n)
                        $done += $n
                        $ms = $sw.Elapsed.TotalMilliseconds
                        if (($ms - $lastMs) -ge 500) {
                            $speed = ($done - $lastBytes) / (($ms - $lastMs) / 1000.0)
                            $lastMs = $ms; $lastBytes = $done
                            Update-Progress -Text $Label -Done $done -Total $total -Speed $speed
                        }
                    }
                } finally {
                    $out.Close(); $stream.Close()
                }

                [int64]$now = 0
                if (Test-Path $tmp) { $now = (Get-Item $tmp).Length }
                if ($total -gt 0) {
                    if ($now -ge $total) { break }
                } else {
                    if ($length -le 0 -or $done -ge ($existing + $length)) { break }
                }
                Write-Log ("$Label : interrupted at " + (Format-Size $now) + ' of ' + (Format-Size $total) + ' - retrying.') 'WARN'
            } catch {
                Write-Log ("$Label : error (" + $_.Exception.Message + ') - retrying.') 'WARN'
            }
            Start-Sleep -Seconds ([math]::Min(20, 3 * $attempt))
            [System.Windows.Forms.Application]::DoEvents()
        }

        [int64]$final = 0
        if (Test-Path $tmp) { $final = (Get-Item $tmp).Length }
        if ($Bytes -gt 0 -and $final -ne $Bytes) { throw "Incomplete download: $final of $Bytes bytes" }

        if ($Sha1) {
            Update-Progress -Text "$Label : verifying integrity (SHA1)..." -Indeterminate
            Write-Log "$Label : computing SHA1 (large files may take a few minutes)..."
            $hash = (Get-FileHash $tmp -Algorithm SHA1).Hash
            if ($hash -ne $Sha1.ToUpper()) {
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                throw "SHA1 mismatch (expected $Sha1, got $hash). File removed: please retry."
            }
            Write-Log "$Label : integrity verified (SHA1 ok)" 'OK'
        }

        Move-Item $tmp $Destination -Force
        Update-Progress -Text "$Label completed" -Done $final -Total $final
        Write-Log ("$Label completed: " + (Format-Size $final)) 'OK'
        return $true
    } finally {
        $client.Dispose()
    }
}

# Reads the last progress percentage from the 7zr log without loading the whole file
function Get-SevenZipPercent {
    param([string]$LogPath)
    if (-not (Test-Path $LogPath)) { return -1 }
    try {
        $fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $len = $fs.Length
            $count = [int][math]::Min(16384, $len)
            if ($count -le 0) { return -1 }
            [void]$fs.Seek($len - $count, [System.IO.SeekOrigin]::Begin)
            $buffer = New-Object byte[] $count
            [void]$fs.Read($buffer, 0, $count)
        } finally { $fs.Close() }
        $text = [System.Text.Encoding]::Default.GetString($buffer)
        $m = [regex]::Matches($text, '(\d{1,3})%')
        if ($m.Count -gt 0) { return [int]$m[$m.Count - 1].Groups[1].Value }
    } catch { }
    return -1
}

# Extracts a .7z archive with 7zr, showing 7-Zip's real percentage
function Expand-Archive7z {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Destination,
        [string]$Label = 'Extraction'
    )
    if (-not (Test-Path $Paths.SevenZip)) { throw "7zr.exe not found: $($Paths.SevenZip)" }
    if (-not (Test-Path $Archive)) { throw "Archive not found: $Archive" }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    $log = Join-Path $env:TEMP ('lunartear-extract-' + [guid]::NewGuid().ToString('N') + '.log')
    Write-Log "$Label - starting (this can take several minutes)..."

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.Arguments = '/c ""' + $Paths.SevenZip + '" x "' + $Archive + '" -o"' + $Destination +
                     '" -y -bso0 -bse1 -bsp1 > "' + $log + '" 2>&1"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 2
        $pct = Get-SevenZipPercent -LogPath $log
        if ($pct -ge 0) {
            Update-Progress -Text $Label -Done $pct -Total 100 -Percentage
        } else {
            Update-Progress -Text ("$Label (" + $sw.Elapsed.ToString('mm\:ss') + ')') -Indeterminate
        }
        [System.Windows.Forms.Application]::DoEvents()
    }
    $proc.WaitForExit()
    $code = $proc.ExitCode

    if ($code -ne 0) {
        $detail = ''
        if (Test-Path $log) {
            $text = [System.IO.File]::ReadAllText($log) -replace "`r", "`n"
            $detail = (@($text -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 6)) -join ' | '
            if ($detail.Length -gt 400) { $detail = $detail.Substring($detail.Length - 400) }
        }
        Remove-Item $log -Force -ErrorAction SilentlyContinue
        throw "Extraction failed (code $code). $detail"
    }
    Remove-Item $log -Force -ErrorAction SilentlyContinue
    Update-Progress -Text "$Label completed" -Done 100 -Total 100 -Percentage
    Write-Log ("$Label completed in " + $sw.Elapsed.ToString('mm\:ss')) 'OK'
    return $true
}

function Watch-FolderGrowth {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int64]$Expected = 0,
        [int]$TimeoutSeconds = 3600,
        [string]$Label = 'Download in progress'
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    [int64]$previous = 0; $previousSeconds = 0.0
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Milliseconds 2000
        [int64]$now = Get-FolderSize $Path
        $t = $sw.Elapsed.TotalSeconds
        $speed = if ($t -gt $previousSeconds) { ($now - $previous) / ($t - $previousSeconds) } else { 0 }
        $previous = $now; $previousSeconds = $t
        if ($Expected -gt 0) {
            Update-Progress -Text $Label -Done $now -Total $Expected -Speed $speed
            if ($now -ge $Expected) { break }
        } else {
            Update-Progress -Text ("$Label  (" + (Format-Size $now) + ')') -Indeterminate
        }
    }
}

# =====================================================================
#  CLIENT BUILD
#  The stock APK is downloaded from APKMirror, patched with the official
#  lunar-scripts patcher (server addresses, SSL, encryption, billing) and
#  signed again, because a modified APK cannot keep its original signature.
#  Nothing of this is shipped with the installer: the toolchain (Java,
#  apktool, Android build tools, Python) is downloaded only when needed.
# =====================================================================
$Script:JavaExe      = $null
$Script:PythonExe    = $null
$Script:ZipAlignExe  = $null
$Script:ApkSignerJar = $null

function Expand-ZipFile {
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][string]$Destination)
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Destination)
}

function ConvertTo-ArgumentString {
    param([string[]]$Parts)
    ($Parts | ForEach-Object {
        if ($_ -match '[\s"]' -or $_ -eq '') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
}

function Get-LogTail {
    param([string]$Path, [int]$Lines = 6, [int]$Bytes = 8192)
    if (-not (Test-Path $Path)) { return @() }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $length = $fs.Length
            $count = [int][math]::Min($Bytes, $length)
            if ($count -le 0) { return @() }
            [void]$fs.Seek($length - $count, 'Begin')
            $buffer = New-Object byte[] $count
            [void]$fs.Read($buffer, 0, $count)
        } finally { $fs.Close() }
        $text = [System.Text.Encoding]::UTF8.GetString($buffer)
        @($text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last $Lines)
    } catch { @() }
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$Label = 'Running',
        [int]$TimeoutSeconds = 3600
    )
    if (-not (Test-Path $File)) { throw "Executable not found: $File" }

    $log = Join-Path $env:TEMP ('lunartear-tool-' + [guid]::NewGuid().ToString('N') + '.log')
    $call = (ConvertTo-ArgumentString $Arguments)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.Arguments = '/c ""' + $File + '" ' + $call + ' > "' + $log + '" 2>&1"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $Root

    Write-Log "$Label - started"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 800
            $tail = @(Get-LogTail -Path $log -Lines 1)
            $detail = if ($tail.Count -gt 0) { $tail[0].Trim() } else { '' }
            if ($detail.Length -gt 100) { $detail = $detail.Substring(0, 100) }
            $text = "$Label  (" + $sw.Elapsed.ToString('mm\:ss') + ')'
            if ($detail) { $text += '  ' + $detail }
            Update-Progress -Text $text -Indeterminate
            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                try { $proc.Kill() } catch { }
                throw "$Label timed out after $TimeoutSeconds seconds"
            }
            [System.Windows.Forms.Application]::DoEvents()
        }
        $proc.WaitForExit()
        $code = $proc.ExitCode
    } finally {
        $proc.Dispose()
    }

    foreach ($line in (Get-LogTail -Path $log -Lines 14)) {
        $short = if ($line.Length -gt 300) { $line.Substring(0, 300) } else { $line }
        Write-Log "  $short"
    }
    Remove-Item $log -Force -ErrorAction SilentlyContinue
    if ($code -ne 0) { throw "$Label failed (exit code $code)" }
    Write-Log ("$Label - done in " + $sw.Elapsed.ToString('mm\:ss')) 'OK'
    return $true
}

# ---- toolchain ---------------------------------------------------------

function Get-JavaExe {
    if ($Script:JavaExe -and (Test-Path $Script:JavaExe)) { return $Script:JavaExe }
    $found = $null
    foreach ($dir in @($Paths.JdkDir, (Join-Path $Root 'tools'))) {
        if (-not (Test-Path $dir)) { continue }
        $found = Get-ChildItem $dir -Recurse -Depth 3 -Filter 'java.exe' -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -notlike '*\android-sdk\*' } |
                 Select-Object -First 1 -ExpandProperty FullName
        if ($found) { break }
    }
    if (-not $found) {
        $cmd = Get-Command java.exe -ErrorAction SilentlyContinue
        if ($cmd) { $found = $cmd.Source }
    }
    if ($found) { $Script:JavaExe = $found }
    return $found
}

function Ensure-Jdk {
    $java = Get-JavaExe
    if ($java) { Write-Log "Java runtime: $java" 'OK'; return $true }
    Write-Log 'Toolchain: downloading the Java runtime (JRE 17, about 44 MB)'
    $zip = Join-Path $Paths.Downloads 'jre17.zip'
    Send-Download -Url $Config.JreUrl -Destination $zip -Label 'Java runtime (JRE 17)' -Bytes $Config.JreBytes | Out-Null
    Expand-ZipFile -Archive $zip -Destination $Paths.JdkDir
    if (Get-JavaExe) { Write-Log 'Java runtime ready' 'OK'; return $true }
    Write-Log 'Java runtime missing after extraction' 'ERROR'
    return $false
}

function Ensure-Apktool {
    if (Test-Path $Paths.ApktoolJar) { Write-Log "apktool: $($Paths.ApktoolJar)" 'OK'; return $true }
    Write-Log 'Toolchain: downloading apktool (about 23 MB)'
    Send-Download -Url $Config.ApktoolUrl -Destination $Paths.ApktoolJar -Label 'apktool' -Bytes $Config.ApktoolBytes | Out-Null
    if (Test-Path $Paths.ApktoolJar) { Write-Log 'apktool ready' 'OK'; return $true }
    return $false
}

function Find-BuildTool {
    param([Parameter(Mandatory)][string]$Leaf)
    foreach ($dir in @($Paths.BuildToolsDir, (Join-Path $Root 'tools\android-sdk\build-tools'))) {
        if (-not (Test-Path $dir)) { continue }
        $file = Get-ChildItem $dir -Recurse -Filter $Leaf -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending | Select-Object -First 1
        if ($file) { return $file.FullName }
    }
    return $null
}

function Ensure-BuildTools {
    $align = Find-BuildTool 'zipalign.exe'
    $signer = Find-BuildTool 'apksigner.jar'
    if ($align -and $signer) {
        $Script:ZipAlignExe = $align
        $Script:ApkSignerJar = $signer
        Write-Log "Android build tools: $align" 'OK'
        return $true
    }
    Write-Log 'Toolchain: downloading the Android build tools (about 60 MB)'
    $zip = Join-Path $Paths.Downloads 'build-tools.zip'
    Send-Download -Url $Config.BuildToolsUrl -Destination $zip -Label 'Android build tools' -Bytes $Config.BuildToolsBytes | Out-Null
    Expand-ZipFile -Archive $zip -Destination $Paths.BuildToolsDir
    $align = Find-BuildTool 'zipalign.exe'
    $signer = Find-BuildTool 'apksigner.jar'
    if ($align -and $signer) {
        $Script:ZipAlignExe = $align
        $Script:ApkSignerJar = $signer
        Write-Log 'Android build tools ready' 'OK'
        return $true
    }
    Write-Log 'Android build tools missing after extraction' 'ERROR'
    return $false
}

function Test-PythonModules {
    param([string]$Python)
    if (-not (Test-Path $Python)) { return $false }
    $out = & $Python -c "import Crypto, lz4.block, msgpack; print('modules-ok')" 2>&1
    return (($out -join ' ') -match 'modules-ok')
}

function Get-PyPiWheelUrl {
    param([Parameter(Mandatory)][string]$Package)
    $info = Invoke-RestMethod -Uri "https://pypi.org/pypi/$Package/json" -TimeoutSec 60
    $file = $info.urls |
            Where-Object { $_.filename -like '*win_amd64.whl' -and ($_.filename -match 'cp312|abi3') } |
            Sort-Object -Property upload_time -Descending |
            Select-Object -First 1
    if (-not $file) { throw "No Windows wheel available for $Package" }
    return $file.url
}

function Ensure-Python {
    if ($Script:PythonExe -and (Test-PythonModules $Script:PythonExe)) { return $Script:PythonExe }

    $python = Join-Path $Paths.PythonDir 'python.exe'
    if (-not (Test-Path $python)) {
        Write-Log 'Toolchain: downloading the Python runtime (about 11 MB)'
        $zip = Join-Path $Paths.Downloads 'python-embed.zip'
        Send-Download -Url $Config.PythonUrl -Destination $zip -Label 'Python runtime' -Bytes $Config.PythonBytes | Out-Null
        Expand-ZipFile -Archive $zip -Destination $Paths.PythonDir
    }
    if (-not (Test-Path $python)) { Write-Log 'Python runtime missing after extraction' 'ERROR'; return $null }

    # the embedded runtime ships with site-packages disabled
    $pth = Get-ChildItem $Paths.PythonDir -Filter 'python*._pth' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pth) {
        $lines = @(Get-Content $pth.FullName)
        $lines = @($lines | ForEach-Object { if ($_ -match '^\s*#\s*import site') { 'import site' } else { $_ } })
        if ($lines -notcontains 'Lib\site-packages') { $lines += 'Lib\site-packages' }
        Set-Content -Path $pth.FullName -Value $lines -Encoding ASCII
    }

    $Script:PythonExe = $python
    if (Test-PythonModules $python) { Write-Log 'Python runtime ready' 'OK'; return $python }

    $site = Join-Path $Paths.PythonDir 'Lib\site-packages'
    New-Item -ItemType Directory -Force -Path $site | Out-Null
    foreach ($package in @('pycryptodome', 'msgpack', 'lz4')) {
        $url = Get-PyPiWheelUrl $package
        $wheel = Join-Path $Paths.Downloads (Split-Path $url -Leaf)
        Send-Download -Url $url -Destination $wheel -Label "Python module: $package" | Out-Null
        Expand-ZipFile -Archive $wheel -Destination $site
    }

    if (Test-PythonModules $python) { Write-Log 'Python modules ready' 'OK'; return $python }
    Write-Log 'Python modules are not usable' 'ERROR'
    return $null
}

function Get-LunarScript {
    param([Parameter(Mandatory)][string]$Name)
    $dest = Join-Path $Paths.ScriptsDir ($Name -replace '/', '\')
    if (Test-Path $dest) { return $dest }
    New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
    $url = "$($Config.ScriptsRaw)/$Name"
    Send-Download -Url $url -Destination $dest -Label "lunar-scripts: $(Split-Path $Name -Leaf)" | Out-Null
    if (-not (Test-Path $dest)) { throw "Cannot download the script: $url" }
    return $dest
}

# ---- stock APK ---------------------------------------------------------

function Test-ApkArchive {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $false }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $names = @($zip.Entries | ForEach-Object { $_.FullName })
        } finally { $zip.Dispose() }
        return (($names -contains 'lib/arm64-v8a/libil2cpp.so') -and
                ($names -contains 'assets/bin/Data/Managed/Metadata/global-metadata.dat'))
    } catch { return $false }
}

function Get-CurlExe {
    $cmd = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $system = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $system) { return $system }
    return $null
}

function Get-ApkmirrorApk {
    param([Parameter(Mandatory)][string]$Destination)
    if (Test-ApkArchive $Destination) { Write-Log "Stock APK already downloaded: $Destination" 'OK'; return $true }

    Write-Log 'Client: looking for the stock APK on APKMirror' 'STEP'

    # APKMirror refuses the .NET HTTP stack (403): the pages are read with
    # curl.exe, which Windows ships since version 1803. The file itself is on
    # a plain CDN and is downloaded here so that progress and speed are shown.
    $curl = Get-CurlExe
    if (-not $curl) {
        Write-Log 'curl.exe not found. Windows 10 version 1803 or newer is required.' 'ERROR'
        return $false
    }

    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
    $work = Join-Path $env:TEMP ('lunartear-apk-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $jar = Join-Path $work 'cookies.txt'

    try {
        # 1) variant page -> "/.../download/?key=..."
        $page = Join-Path $work 'page1.html'
        $null = & $curl -s -L --compressed -A $ua -c $jar -b $jar -o $page $Config.ApkPageUrl 2>&1
        if (-not (Test-Path $page)) { throw 'APKMirror is not reachable' }
        $html = Get-Content -Raw $page
        $m = [regex]::Match($html, 'href="([^"]*?/download/\?key=[^"]+)"')
        if (-not $m.Success) { throw 'download link not found on the APKMirror page (the page layout may have changed)' }
        $step2 = ([Uri]::new([Uri]$Config.ApkPageUrl, $m.Groups[1].Value.Replace('&amp;', '&'))).AbsoluteUri

        # 2) download page -> "download.php?id=...&key=..."
        $page = Join-Path $work 'page2.html'
        $null = & $curl -s -L --compressed -A $ua -e $Config.ApkPageUrl -c $jar -b $jar -o $page $step2 2>&1
        $html = Get-Content -Raw $page
        $m = [regex]::Match($html, 'href="([^"]*?download\.php\?id=\d+&(?:amp;)?key=[^"]+)"')
        if (-not $m.Success) { throw 'final download link not found on the APKMirror page' }
        $step3 = ([Uri]::new([Uri]$step2, $m.Groups[1].Value.Replace('&amp;', '&'))).AbsoluteUri

        # 3) the endpoint answers with a redirect to the CDN (valid for one hour)
        $headers = Join-Path $work 'headers.txt'
        $null = & $curl -s -D $headers -o NUL --max-redirs 0 -A $ua -e $step2 -c $jar -b $jar $step3 2>&1
        $line = Get-Content $headers -ErrorAction SilentlyContinue | Where-Object { $_ -match '^location:' } | Select-Object -First 1
        if (-not $line) { throw 'the download endpoint did not return a redirect' }
        $final = ($line -replace '^location:\s*', '').Trim()
        Write-Log 'Client: direct download link obtained'

        # 4) stream the APK to disk with progress
        New-Item -ItemType Directory -Force -Path (Split-Path $Destination -Parent) | Out-Null
        $partial = "$Destination.part"
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $true
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromMinutes(60)
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $ua)
        try {
            $response = $client.GetAsync($final, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) { throw "HTTP $([int]$response.StatusCode) while downloading the APK" }

            [int64]$total = $Config.ApkStockBytes
            if ($response.Content.Headers.ContentLength) { $total = [int64]$response.Content.Headers.ContentLength }
            $input = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $output = [System.IO.File]::Open($partial, 'Create', 'Write')
            $buffer = New-Object byte[] 1048576
            [int64]$done = 0
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            [int64]$markBytes = 0
            $markMs = 0.0
            $speed = 0.0
            try {
                while ($true) {
                    $read = $input.Read($buffer, 0, $buffer.Length)
                    if ($read -le 0) { break }
                    $output.Write($buffer, 0, $read)
                    $done += $read
                    $ms = $sw.Elapsed.TotalMilliseconds
                    if (($ms - $markMs) -ge 600) {
                        $speed = ($done - $markBytes) / (($ms - $markMs) / 1000.0)
                        $markMs = $ms
                        $markBytes = $done
                        Update-Progress -Text 'Downloading the game client from APKMirror' -Done $done -Total $total -Speed $speed
                    }
                }
            } finally {
                $output.Close()
                $input.Close()
                $response.Dispose()
            }
        } finally {
            $client.Dispose()
        }

        Remove-Item $Destination -Force -ErrorAction SilentlyContinue
        Move-Item $partial $Destination -Force
    } catch {
        Write-Log $_.Exception.Message 'ERROR'
        return $false
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-ApkArchive $Destination) {
        Write-Log ("Stock APK downloaded: " + (Format-Size (Get-Item $Destination).Length)) 'OK'
        return $true
    }
    Write-Log 'The downloaded file is not a valid APK' 'ERROR'
    return $false
}

# ---- build -------------------------------------------------------------

function Get-ClientApkPath {
    param([switch]$BuildOutputOnly)
    $candidates = @($Config.ApkOutput)
    if (-not $BuildOutputOnly) {
        # APKs already built by hand on this machine are accepted as well
        $candidates += (Join-Path $Root 'apk\out\nier_aligned.apk')
        $candidates += (Join-Path $Root 'client-nier-reincarnation-patched.apk')
    }
    foreach ($path in $candidates) {
        if ($path -and (Test-Path $path)) { return $path }
    }
    return $null
}

function Test-ClientBuildCurrent {
    if (-not (Test-Path $Config.ApkOutput)) { return $false }
    $marker = Join-Path $Root 'apk\out\.build.txt'
    if (-not (Test-Path $marker)) { return $false }
    $wanted = "$($Config.GrpcAddr)|$($Config.HttpAddr)|$($Config.AuthAddr)"
    $current = (Get-Content $marker -Raw).Trim()
    return ($current -eq $wanted)
}

function Build-ClientApk {
    Write-Log 'Client: building the patched APK (a few minutes)' 'STEP'

    if (Test-ClientBuildCurrent) { Write-Log 'Patched APK already built for these addresses' 'OK'; return $true }

    $free = Get-FreeSpaceGB
    if ($free -lt 8) {
        Write-Log "At least 8 GB free on C: are required to build the APK (you have $free GB)." 'ERROR'
        return $false
    }

    # the stock APK is the most fragile step (upstream page): do it first
    if (-not (Get-ApkmirrorApk -Destination $Config.ApkStockFile)) { return $false }

    if (-not (Ensure-Jdk)) { return $false }
    if (-not (Ensure-Apktool)) { return $false }
    if (-not (Ensure-BuildTools)) { return $false }
    $python = Ensure-Python
    if (-not $python) { return $false }

    $java = Get-JavaExe

    $work = $Config.ApkWorkDir
    $unaligned = Join-Path $Root 'apk\out\nier-unaligned.apk'
    $aligned = Join-Path $Root 'apk\out\nier-aligned.apk'
    New-Item -ItemType Directory -Force -Path (Split-Path $Config.ApkOutput -Parent) | Out-Null

    # 1) decompile
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    try {
        Invoke-Tool -File $java -Label 'Decompiling the APK (apktool)' `
            -Arguments @('-Xmx2g', '-jar', $Paths.ApktoolJar, 'd', $Config.ApkStockFile, '-o', $work, '-f') | Out-Null
    } catch {
        Write-Log $_.Exception.Message 'ERROR'
        return $false
    }

    # 2) patch the decompiled tree with the official patcher
    try {
        $patcher = Get-LunarScript 'android/patch_apk.py'
        Invoke-Tool -File $python -Label 'Patching the game client' `
            -Arguments @('-X', 'utf8', $patcher, $work, '--grpc-addr', $Config.GrpcAddr, '--http-addr', $Config.HttpAddr, '--auth-host', $Config.AuthAddr) | Out-Null
    } catch {
        Write-Log $_.Exception.Message 'ERROR'
        return $false
    }

    # 3) rebuild
    try {
        Remove-Item $unaligned -Force -ErrorAction SilentlyContinue
        Invoke-Tool -File $java -Label 'Rebuilding the APK (apktool)' `
            -Arguments @('-Xmx2g', '-jar', $Paths.ApktoolJar, 'b', $work, '-o', $unaligned) | Out-Null
    } catch {
        Write-Log $_.Exception.Message 'ERROR'
        return $false
    }

    # 4) align
    try {
        Remove-Item $aligned -Force -ErrorAction SilentlyContinue
        Invoke-Tool -File $Script:ZipAlignExe -Label 'Aligning the APK (zipalign)' `
            -Arguments @('-p', '-f', '4', $unaligned, $aligned) | Out-Null
    } catch {
        Write-Log $_.Exception.Message 'ERROR'
        return $false
    }

    # 5) signing key (created once, then reused)
    if (-not (Test-Path $Config.Keystore)) {
        try {
            $keytool = Join-Path (Split-Path $java -Parent) 'keytool.exe'
            if (-not (Test-Path $keytool)) { throw 'keytool.exe not found next to the Java runtime' }
            Invoke-Tool -File $keytool -Label 'Creating the signing key' `
                -Arguments @('-genkeypair', '-keystore', $Config.Keystore, '-alias', 'androiddebugkey',
                             '-storepass', 'android', '-keypass', 'android', '-keyalg', 'RSA', '-keysize', '2048',
                             '-validity', '10000', '-dname', 'CN=Android Debug,O=Android,C=US') | Out-Null
        } catch {
            Write-Log $_.Exception.Message 'ERROR'
            return $false
        }
    }

    # 6) sign and verify
    try {
        Remove-Item $Config.ApkOutput -Force -ErrorAction SilentlyContinue
        Invoke-Tool -File $java -Label 'Signing the APK (apksigner)' `
            -Arguments @('-jar', $Script:ApkSignerJar, 'sign', '--ks', $Config.Keystore,
                         '--ks-pass', 'pass:android', '--key-pass', 'pass:android',
                         '--out', $Config.ApkOutput, $aligned) | Out-Null
        Invoke-Tool -File $java -Label 'Verifying the signature' `
            -Arguments @('-jar', $Script:ApkSignerJar, 'verify', '--print-certs', $Config.ApkOutput) | Out-Null
    } catch {
        Write-Log $_.Exception.Message 'ERROR'
        return $false
    }

    Set-Content -Path (Join-Path $Root 'apk\out\.build.txt') -Encoding ASCII `
        -Value "$($Config.GrpcAddr)|$($Config.HttpAddr)|$($Config.AuthAddr)"

    # the decompiled tree and the intermediate APKs are no longer needed
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $unaligned -Force -ErrorAction SilentlyContinue
    Remove-Item $aligned -Force -ErrorAction SilentlyContinue
    Write-Log ("Patched APK ready: " + $Config.ApkOutput + ' (' + (Format-Size (Get-Item $Config.ApkOutput).Length) + ')') 'OK'
    return $true
}

# =====================================================================
#  INSTALLATION ACTIONS
# =====================================================================
function Watch-MuMuInstall {
    param(
        $Process,
        [int64]$InitialSize = 0,
        [int]$TimeoutSeconds = 3600,
        [switch]$Hide,
        [int]$NoProgressSeconds = 240
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    [int64]$previous = $InitialSize
    [int64]$baseSize = $InitialSize
    $previousSeconds = 0.0
    $lastProgress = 0.0
    $hidden = $false
    $activitySeen = $false

    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 2

        # --- silence: hide MuMu windows as soon as they appear ---
        if ($Hide -and -not $hidden -and (Get-VisibleMuMuWindows) -gt 0) {
            Hide-MuMuWindows
            $hidden = $true
            Write-Log 'MuMu window hidden (silent installation in progress).'
        }

        # --- progress measured on the installation folder ---
        [int64]$now = Get-FolderSize $Paths.MuMuDir
        $t = $sw.Elapsed.TotalSeconds
        $pids = Get-ProcessIdsByName $Script:HideProcessNames
        $active = ($pids -and $pids.Count -gt 0)

        if ($active -or ($now -gt $baseSize)) { $activitySeen = $true }
        if ($now -gt $previous) { $lastProgress = $t }
        $speed = if ($t -gt $previousSeconds) { ($now - $previous) / ($t - $previousSeconds) } else { 0 }
        $previous = $now; $previousSeconds = $t
        Update-Progress -Text 'Installing MuMu Player and the Android engine' -Done $now -Total $Script:EngineBytes -Speed $speed

        # --- done: the setup started and no monitored process is alive anymore ---
        if ($activitySeen -and -not $active -and (($t - $lastProgress) -gt 60)) {
            if (Test-MuMuInstalled) { return 'ok' } else { return 'timeout' }
        }

        # --- stuck: no progress for N seconds; recovery (re-showing the window)
        #     is impossible across processes, so kill and retry visibly ---
        if ($Hide -and $hidden -and (($t - $lastProgress) -gt $NoProgressSeconds)) {
            Write-Log "No progress for $NoProgressSeconds seconds: the installation looks stuck." 'WARN'
            return 'stall'
        }

        [System.Windows.Forms.Application]::DoEvents()
    }
    return 'timeout'
}

function Action-InstallMuMu {
    Write-Log 'Emulator: preparing the MuMu Player installer' 'STEP'

    # prefer an OFFLINE package when available (no download during setup)
    $setup = $null
    if ($Paths.MuMuInstallerOff -and (Test-Path $Paths.MuMuInstallerOff)) {
        $setup = $Paths.MuMuInstallerOff
        Write-Log "Using the OFFLINE installer: $setup"
    } else {
        $setup = $Paths.MuMuInstaller
        if (-not (Test-Path $setup)) {
            Send-Download -Url $Config.MuMuInstallerUrl -Destination $setup -Label 'MuMu Player installer' | Out-Null
        } else {
            Write-Log "MuMu installer already present: $setup"
        }
    }

    # also monitor/hide the real installer file name
    $setupName = [System.IO.Path]::GetFileNameWithoutExtension($setup)
    if ($setupName -and ($Script:HideProcessNames -notcontains $setupName)) { $Script:HideProcessNames += $setupName }

    # 1st attempt: silent (hidden window). 2nd attempt: visible, if the first gets stuck.
    foreach ($attempt in 1..2) {
        $hide = ($attempt -eq 1)
        if ($hide) {
            Write-Log 'Emulator: starting the silent installation (/S). The MuMu window will be hidden.'
        } else {
            Write-Log 'Second attempt with the window VISIBLE (the first attempt was stuck).' 'WARN'
        }
        [int64]$before = Get-FolderSize $Paths.MuMuDir
        $proc = Start-Process -FilePath $setup -ArgumentList '/S', '/fchannel=gw-overseas12', '/auto_start=false' -Verb RunAs -PassThru
        $result = Watch-MuMuInstall -Process $proc -InitialSize $before -Hide:$hide
        if ($result -eq 'ok') { break }
        if ($result -eq 'stall') {
            Write-Log 'Closing the MuMu processes and retrying with the window visible.' 'WARN'
            Get-Process -Name $Script:HideProcessNames -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
        }
        if ($result -eq 'timeout') { Write-Log 'Timed out while waiting for the MuMu installation.' 'WARN' }
    }

    if (Test-MuMuInstalled) { Write-Log 'Emulator installed' 'OK'; return $true }
    Write-Log 'Emulator NOT installed' 'ERROR'; return $false
}

function Action-WaitEngine {
    Write-Log 'Emulator: checking the Android engine' 'STEP'
    if (Test-MuMuEngine) { Write-Log 'Android engine present' 'OK'; return $true }
    Write-Log 'Engine missing: waiting for the download to finish...'
    Watch-FolderGrowth -Path (Join-Path $Paths.MuMuDir 'nx_device') -Expected $Script:EngineBytes -TimeoutSeconds 1800 -Label 'MuMu Android engine'
    if (Test-MuMuEngine) { Write-Log 'Android engine present' 'OK'; return $true }
    Write-Log 'Android engine NOT detected' 'ERROR'; return $false
}

function Action-Debloat {
    Write-Log 'Configuration: removing NetEase/MuMu bloatware' 'STEP'
    if (-not (Test-EmulatorRunning)) {
        Write-Log 'Starting the emulator to apply the debloat...'
        & $Paths.MuMuManager control -v 0 launch 2>&1 | Out-Null
        for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Seconds 3; if (Test-EmulatorRunning) { break }; [Windows.Forms.Application]::DoEvents() }
    }
    Update-Progress -Text 'Applying the debloat...' -Indeterminate
    Invoke-MuMuDebloat | Out-Null
    if (Test-DebloatApplied) { Write-Log 'Debloat applied and verified' 'OK'; return $true }
    Write-Log 'Debloat not confirmed' 'WARN'; return $false
}

function Get-LatestServerUrl {
    $api = "https://api.github.com/repos/$($Config.ServerRepo)/releases/latest"
    try {
        $r = Invoke-RestMethod -Uri $api -Method Get -TimeoutSec 30 `
                -Headers @{ 'User-Agent' = 'cage-setup'; 'Accept' = 'application/vnd.github+json' }
        $asset = $r.assets | Where-Object { $_.name -like "*$($Config.ServerAssetMatch)*.zip" } | Select-Object -First 1
        if ($asset) {
            Write-Log ('Latest server release: {0} - {1} ({2})' -f $r.tag_name, $asset.name, (Format-Size $asset.size))
            return $asset.browser_download_url
        }
        Write-Log "Release $($r.tag_name) has no $($Config.ServerAssetMatch) archive" 'WARN'
    } catch {
        Write-Log ('GitHub unreachable (' + $_.Exception.Message + '): using the fallback link.') 'WARN'
    }
    return $Config.ServerUrlFallback
}

function Action-GetServerBinaries {
    Write-Log 'Server: downloading the binaries (GitHub Releases)' 'STEP'
    if (Test-ServerFiles) { Write-Log 'Server binaries already present' 'OK'; return $true }

    $url = $Config.ServerUrl
    if (-not $url) { $url = Get-LatestServerUrl }
    if (-not $url) { Write-Log 'No URL available for the server binaries' 'ERROR'; return $false }

    $zip = Join-Path $Paths.Downloads 'lunar-tear-server.zip'
    Send-Download -Url $url -Destination $zip -Label 'Server binaries' | Out-Null

    $tmp = Join-Path $env:TEMP ('lunartear-bin-' + [guid]::NewGuid().ToString('N'))
    Update-Progress -Text 'Extracting the server binaries...' -Indeterminate
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
        $top = Get-ChildItem $tmp -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
        $source = if ($top) { $top.FullName } else { $tmp }
        New-Item -ItemType Directory -Force -Path $Paths.ServerDir | Out-Null
        Copy-Item -Path (Join-Path $source '*') -Destination $Paths.ServerDir -Recurse -Force
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-ServerFiles) { Write-Log 'Server binaries ready' 'OK'; return $true }
    Write-Log 'Server binaries not found after extraction' 'ERROR'; return $false
}

function Invoke-MasterDataPatch {
    param(
        [Parameter(Mandatory)][string]$InputFile,
        [Parameter(Mandatory)][string]$OutputFile
    )
    $python = Ensure-Python
    if (-not $python) {
        Write-Log 'Cannot patch the master data: the Python runtime is not available' 'ERROR'
        return $false
    }

    $backup = "$InputFile.original"
    if (-not (Test-Path $backup)) { Copy-Item $InputFile $backup -Force }
    try {
        $script = Get-LunarScript 'patch_masterdata.py'
        Invoke-Tool -File $python -Label 'Patching the master data (content unlocked to 2030)' `
            -Arguments @('-X', 'utf8', $script, '--input', $InputFile, '--output', $OutputFile) | Out-Null
    } catch {
        Write-Log $_.Exception.Message 'ERROR'
        return $false
    }

    $hash = (Get-FileHash $OutputFile -Algorithm SHA1).Hash
    Set-Content -Path "$OutputFile.patched" -Value $hash -Encoding ASCII
    Write-Log ("Master data patched: " + (Format-Size (Get-Item $OutputFile).Length) + " (SHA1 $hash)") 'OK'
    if ($hash -ne $Script:MasterPatchedSha1) {
        Write-Log 'The patched file differs from the reference build (the patcher may have been updated): keeping it.' 'WARN'
    }
    return $true
}

function Action-GetMasterData {
    Write-Log 'Server: preparing the master data' 'STEP'

    $file = $Config.MasterFile
    if (Test-Path $file) {
        if (Test-MasterData) { Write-Log 'Master data already patched' 'OK'; return $true }
        $hash = Get-MasterDataHash $file
        if ($hash -eq $Config.MasterSha1.ToUpper()) {
            Write-Log 'Master data is the original file: patching it now'
            return (Invoke-MasterDataPatch -InputFile $file -OutputFile $file)
        }
        # anything else was supplied by the user: do not touch it
        Set-Content -Path "$file.patched" -Value $hash -Encoding ASCII
        Write-Log "Master data supplied by the user (SHA1 $hash): keeping it as is" 'WARN'
        return $true
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $file -Parent) | Out-Null
    Send-Download -Url $Config.MasterUrl -Destination $file -Label 'Master data' `
                  -Bytes $Config.MasterBytes -Sha1 $Config.MasterSha1 | Out-Null
    if (-not (Test-Path $file)) { return $false }
    return (Invoke-MasterDataPatch -InputFile $file -OutputFile $file)
}

function Action-GetGameAssets {
    Write-Log 'Server: downloading the game assets (long operation)' 'STEP'
    if (Test-GameAssets) { Write-Log 'Game assets already present' 'OK'; return $true }

    $archive = $Config.AssetsArchive
    $ready = ((Test-Path $archive) -and ((Get-Item $archive).Length -eq $Config.AssetsBytes))

    if ($ready) {
        Write-Log "Using the already downloaded archive: $archive" 'OK'
    } else {
        if (Test-Path $archive) {
            Write-Log 'The local archive has a different size: downloading it again.' 'WARN'
            Remove-Item $archive -Force -ErrorAction SilentlyContinue
        }
        $free = Get-FreeSpaceGB
        if ($free -lt 70) {
            Write-Log "Not enough disk space: about 70 GB free on C: are required (you have $free GB)." 'ERROR'
            return $false
        }
        Send-Download -Url $Config.AssetsUrl -Destination $archive -Label 'Game assets (14.9 GB)' `
                      -Bytes $Config.AssetsBytes -Sha1 $Config.AssetsSha1 | Out-Null
    }

    New-Item -ItemType Directory -Force -Path $Paths.AssetsDir | Out-Null

    # the master data is NOT inside the asset dump: protect it and restore it afterwards
    $backup = Join-Path $env:TEMP 'lunartear-master.bak'
    $hadMaster = $false
    if (Test-Path $Config.MasterFile) {
        Copy-Item $Config.MasterFile $backup -Force
        $hadMaster = $true
    }

    Expand-Archive7z -Archive $archive -Destination $Paths.AssetsDir -Label 'Extracting game assets (48.8 GB)'

    if ($hadMaster -and (Test-Path $backup)) {
        New-Item -ItemType Directory -Force -Path (Split-Path $Config.MasterFile -Parent) | Out-Null
        Copy-Item $backup $Config.MasterFile -Force
        Remove-Item $backup -Force -ErrorAction SilentlyContinue
        Write-Log 'Master data restored after extraction' 'OK'
    }

    if (Test-GameAssets) { Write-Log 'Game assets ready' 'OK'; return $true }
    Write-Log 'Game assets not detected after extraction' 'ERROR'; return $false
}

function Action-GetClientApk {
    Write-Log 'Client: preparing the patched APK' 'STEP'
    $existing = Get-ClientApkPath
    if ($existing) { Write-Log "Patched APK already present: $existing" 'OK'; return $true }
    return (Build-ClientApk)
}

function Action-InstallClient {
    $apk = Get-ClientApkPath
    if (-not $apk) {
        if (-not (Action-GetClientApk)) { return $false }
        $apk = Get-ClientApkPath
    }
    if (-not $apk) { Write-Log 'Patched APK not available' 'ERROR'; return $false }

    Write-Log 'Client: installing the APK on MuMu' 'STEP'
    if (-not (Test-EmulatorRunning)) {
        Write-Log 'Starting the MuMu instance...'
        & $Paths.MuMuManager control -v 0 launch 2>&1 | Out-Null
        for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Seconds 3; if (Test-EmulatorRunning) { break }; [Windows.Forms.Application]::DoEvents() }
    }
    if (-not (Test-EmulatorRunning)) { Write-Log 'MuMu instance not reachable via ADB' 'ERROR'; return $false }
    $adb = Get-Adb
    Update-Progress -Text 'Installing the APK on MuMu (this may take 1-2 minutes)' -Indeterminate
    $out = & $adb -s $Script:Serial install -r $apk 2>&1
    $out | Select-Object -Last 3 | ForEach-Object { Write-Log $_ }
    if (Test-GameInstalled) { Write-Log 'Client installed' 'OK'; return $true }
    Write-Log 'Client installation not confirmed' 'ERROR'; return $false
}

function Action-StartServer {
    Write-Log 'Server: checking the status' 'STEP'
    if (Test-ServerRunning) { Write-Log 'Server already running (ports 8003/8080)' 'OK'; return $true }
    if (-not (Test-ServerFiles)) { Write-Log 'Server binaries are missing: download the game first' 'ERROR'; return $false }
    if (Test-Path $Paths.StartServerCmd) {
        Start-Process -FilePath $Paths.StartServerCmd | Out-Null
    } else {
        Start-Process -FilePath (Join-Path $Paths.ServerDir 'wizard.exe') -ArgumentList '--prefer-saved' -WorkingDirectory $Paths.ServerDir | Out-Null
    }
    for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Seconds 1; if (Test-ServerRunning) { break }; [Windows.Forms.Application]::DoEvents() }
    if (Test-ServerRunning) { Write-Log 'Server started' 'OK'; return $true }
    Write-Log 'Server not detected on ports 8003/8080' 'WARN'; return $false
}

function Action-StopServer {
    Write-Log 'Server: stopping' 'STEP'
    $procs = @(Get-ServerProcesses)
    if ($procs.Count -eq 0) { Write-Log 'Server is not running' 'OK'; return $true }
    foreach ($p in $procs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    for ($i = 0; $i -lt 15; $i++) { Start-Sleep -Seconds 1; if (-not (Test-ServerRunning)) { break } }
    if (Test-ServerRunning) { Write-Log 'The server is still listening on its ports' 'WARN'; return $false }
    Write-Log ("Server stopped ($($procs.Count) process(es))") 'OK'
    return $true
}

function Action-RestartServer {
    Action-StopServer | Out-Null
    Start-Sleep -Seconds 2
    Action-StartServer
}

function Action-CheckArmBridge {
    Write-Log 'Check: ARM translation for arm64 apps' 'STEP'
    if (-not (Test-EmulatorRunning)) { Write-Log 'Emulator is not running' 'WARN'; return $false }
    $adb = Get-Adb
    $bridge = ((& $adb -s $Script:Serial shell getprop ro.dalvik.vm.native.bridge 2>&1) -join '').Trim()
    $abis = ((& $adb -s $Script:Serial shell getprop ro.product.cpu.abilist 2>&1) -join '').Trim()
    Write-Log "native.bridge = $bridge"
    Write-Log "abilist       = $abis"
    if ($bridge -and $abis -match 'arm64') { Write-Log 'ARM bridge active' 'OK'; return $true }
    Write-Log 'ARM bridge NOT active' 'ERROR'; return $false
}

function Action-Inventory {
    if (-not (Test-EmulatorRunning)) { Write-Log 'Emulator is not running: cannot list packages' 'WARN'; return $false }
    $adb = Get-Adb
    Update-Progress -Text 'Collecting the package inventory...' -Indeterminate
    $list = & $adb -s $Script:Serial shell pm list packages -3 2>&1
    $file = Join-Path $Root 'tools\mumu\inventory.txt'
    New-Item -ItemType Directory -Force -Path (Split-Path $file -Parent) | Out-Null
    $list | Set-Content -Path $file -Encoding UTF8
    Write-Log "Inventory saved to: $file" 'OK'
    return $true
}

# =====================================================================
#  PLAN (categories -> rows)
# =====================================================================
function New-Plan {
    @(
        [pscustomobject]@{ Group = '1. System requirements'; Id = 'R1'; Name = 'Windows 10/11 (64-bit)';       Detail = '64-bit operating system';            Size = '-';         Action = $null;             Status = 'check' }
        [pscustomobject]@{ Group = '1. System requirements'; Id = 'R2'; Name = 'Virtualization (VT-x)';        Detail = 'Enabled in the BIOS';                Size = '-';         Action = $null;             Status = 'check' }
        [pscustomobject]@{ Group = '1. System requirements'; Id = 'R3'; Name = 'Hyper-V disabled';             Detail = 'Hyper-V must not be active';         Size = '-';         Action = $null;             Status = 'check' }
        [pscustomobject]@{ Group = '1. System requirements'; Id = 'R4'; Name = 'Free disk space';              Detail = '25 GB (75 GB with game assets)';     Size = '-';         Action = $null;             Status = 'check' }
        [pscustomobject]@{ Group = '1. System requirements'; Id = 'R5'; Name = 'Administrator rights';         Detail = 'Required to install MuMu';           Size = '-';         Action = $null;             Status = 'check' }

        [pscustomobject]@{ Group = '2. Emulator';           Id = 'E1'; Name = 'MuMu Player + engine + debloat'; Detail = 'Download, install and clean up';   Size = '~5 GB';     Action = 'InstallEmulator'; Status = 'todo' }

        [pscustomobject]@{ Group = '3. Game';               Id = 'G1'; Name = 'Server, game data and client'; Detail = 'Assets, master data, APK download + build'; Size = '~15.4 GB'; Action = 'InstallGame';     Status = 'todo' }
        [pscustomobject]@{ Group = '3. Game';               Id = 'G2'; Name = 'Install client on the emulator'; Detail = 'Installed via ADB';                Size = '-';         Action = 'InstallClient';   Status = 'todo' }

        [pscustomobject]@{ Group = '4. Server';             Id = 'S1'; Name = 'Private server';               Detail = 'Use the Start / Stop / Restart buttons'; Size = '-';     Action = 'StartServer';     Status = 'todo' }

        [pscustomobject]@{ Group = '5. Verification';       Id = 'V1'; Name = 'ARM translation (arm64)';      Detail = 'Required by the game APK';           Size = '-';         Action = 'CheckArmBridge';  Status = 'todo' }
        [pscustomobject]@{ Group = '5. Verification';       Id = 'V2'; Name = 'Package inventory';            Detail = 'Summary of installed packages';      Size = '-';         Action = 'Inventory';       Status = 'todo' }
    )
}

function Refresh-Status {
    param($Plan)
    foreach ($row in $Plan) {
        switch ($row.Id) {
            'R1' { $row.Status = if ([Environment]::Is64BitOperatingSystem) { 'ok' } else { 'error' } }
            'R2' { $row.Status = if (Test-VirtualizationEnabled) { 'ok' } else { 'error' } }
            'R3' { $row.Status = if (Test-HyperVActive) { 'warn' } else { 'ok' } }
            'R4' { $row.Status = if ((Get-FreeSpaceGB) -ge 25) { 'ok' } else { 'error' } }
            'R5' { $row.Status = if (Test-Admin) { 'ok' } else { 'warn' } }
            'E1' {
                if (-not (Test-MuMuInstalled)) { $row.Status = 'todo' }
                elseif (-not (Test-MuMuEngine)) { $row.Status = 'todo' }
                elseif (-not (Test-EmulatorRunning)) { $row.Status = 'off' }
                elseif (Test-DebloatApplied) { $row.Status = 'ok' }
                else { $row.Status = 'todo' }
            }
            'G1' {
                $complete = (Test-ServerFiles) -and (Test-MasterData) -and (Test-GameAssets) -and [bool](Get-ClientApkPath)
                $row.Status = if ($complete) { 'ok' } else { 'todo' }
            }
            'G2' {
                if (Test-GameInstalled) { $row.Status = 'ok' }
                elseif (Test-EmulatorRunning) { $row.Status = 'todo' }
                else { $row.Status = 'off' }
            }
            'S1' { $row.Status = if (Test-ServerRunning) { 'ok' } else { 'todo' } }
            'V1' {
                if (-not (Test-EmulatorRunning)) { $row.Status = 'off' }
                elseif (Test-ArmBridge) { $row.Status = 'ok' }
                else { $row.Status = 'error' }
            }
            'V2' {
                if (Test-Path (Join-Path $Root 'tools\mumu\inventory.txt')) { $row.Status = 'ok' }
                elseif (Test-EmulatorRunning) { $row.Status = 'pending' } else { $row.Status = 'off' }
            }
        }
    }
}

function Get-StatusLabel {
    param([string]$Status)
    switch ($Status) {
        'ok'      { 'Ready' }
        'todo'    { 'Not installed' }
        'pending' { 'To check' }
        'running' { 'In progress...' }
        'warn'    { 'Warning' }
        'error'   { 'Problem' }
        'skipped' { 'Not applicable' }
        'off'     { 'Emulator stopped' }
        default   { $Status }
    }
}

function Get-StatusColor {
    param([string]$Status)
    switch ($Status) {
        'ok'      { [Drawing.Color]::FromArgb(0, 128, 0) }
        'todo'    { [Drawing.Color]::FromArgb(90, 90, 90) }
        'pending' { [Drawing.Color]::FromArgb(140, 100, 20) }
        'running' { [Drawing.Color]::FromArgb(0, 90, 180) }
        'warn'    { [Drawing.Color]::FromArgb(190, 120, 0) }
        'error'   { [Drawing.Color]::FromArgb(180, 0, 0) }
        'skipped' { [Drawing.Color]::Gray }
        'off'     { [Drawing.Color]::FromArgb(120, 120, 120) }
        default   { [Drawing.Color]::Black }
    }
}

# =====================================================================
#  COMPOSITE ACTIONS (the grouped options)
# =====================================================================
function Action-InstallEmulator {
    Write-Log '=== Emulator: MuMu Player, Android engine and debloat ===' 'STEP'
    $ok = $true
    if (-not (Test-MuMuInstalled)) { $ok = Action-InstallMuMu } else { Write-Log 'MuMu Player already installed, skipping' }
    if ($ok) { $ok = Action-WaitEngine }
    if ($ok) { $ok = Action-Debloat }
    return $ok
}

function Action-InstallGame {
    Write-Log '=== Game: server binaries, master data, client build and assets ===' 'STEP'

    # every step is independent: a failure in one of them must not stop the
    # others (a broken APKMirror page should not prevent the asset download)
    $ok = $true
    if (-not (Action-GetServerBinaries)) { $ok = $false }
    if (-not (Action-GetMasterData)) { $ok = $false }
    if (-not (Action-GetClientApk)) { $ok = $false }
    if (-not (Action-GetGameAssets)) { $ok = $false }

    if ($ok) { Write-Log 'All game files are ready' 'OK' }
    else { Write-Log 'Some game files could not be prepared: see the messages above' 'ERROR' }
    return $ok
}

# =====================================================================
#  EXECUTION ENGINE
# =====================================================================
function Invoke-Action {
    param([string]$Action)
    switch ($Action) {
        'InstallEmulator' { return (Action-InstallEmulator) }
        'InstallGame'     { return (Action-InstallGame) }
        'InstallClient'   { return (Action-InstallClient) }
        'StartServer'     { return (Action-StartServer) }
        'CheckArmBridge'  { return (Action-CheckArmBridge) }
        'Inventory'       { return (Action-Inventory) }
        default           { return $null }
    }
}

function Run-Plan {
    param([string[]]$OnlyIds)

    $btnAll.Enabled = $false; $btnSelected.Enabled = $false
    try {
        $everything = ($OnlyIds -eq $null)
        $pending = $Script:Plan | Where-Object {
            $_.Action -and $_.Status -ne 'ok' -and ($everything -or ($OnlyIds -contains $_.Id))
        }
        if (-not $pending) { Write-Log 'Nothing to do: everything is already in place.' 'OK' }
        foreach ($row in $pending) {
            $item = $list.Items | Where-Object { $_.Tag -eq $row.Id } | Select-Object -First 1
            if ($item) { $item.SubItems[2].Text = 'In progress...'; $item.SubItems[2].ForeColor = Get-StatusColor 'running' }
            Write-Log ('--- ' + $row.Group + ' / ' + $row.Name)
            $result = $null
            try { $result = Invoke-Action -Action $row.Action }
            catch { Write-Log ("Error on $($row.Name): " + $_.Exception.Message) 'ERROR'; $result = $false }
            if ($result -eq $true) { $row.Status = 'ok' }
            elseif ($result -eq $false) { $row.Status = 'error' }
            else { $row.Status = 'ok' }
            if ($item) { $item.SubItems[2].Text = Get-StatusLabel $row.Status; $item.SubItems[2].ForeColor = Get-StatusColor $row.Status }
        }
        Refresh-Status -Plan $Script:Plan
        Sync-List
        Update-Progress -Text 'Finished.' -Done 0 -Total 0
    } finally {
        $btnAll.Enabled = $true; $btnSelected.Enabled = $true
    }
}

# =====================================================================
#  CONSOLE / DIAGNOSTICS
# =====================================================================
if ($Console -or $InstallAll) {
    Write-Host '=== CAGE SETUP - diagnostics ===' -ForegroundColor Cyan
    Write-Host ('Windows 64-bit        : ' + [Environment]::Is64BitOperatingSystem)
    Write-Host ('Administrator         : ' + (Test-Admin))
    Write-Host ('Virtualization        : ' + (Test-VirtualizationEnabled))
    Write-Host ('Hyper-V active        : ' + (Test-HyperVActive))
    Write-Host ('Free space on C:      : ' + (Get-FreeSpaceGB) + ' GB')
    Write-Host ('MuMu installed        : ' + (Test-MuMuInstalled))
    Write-Host ('Android engine        : ' + (Test-MuMuEngine))
    Write-Host ('ADB found             : ' + (Get-Adb))
    Write-Host ('Emulator running      : ' + (Test-EmulatorRunning))
    Write-Host ('Debloat applied       : ' + (Test-DebloatApplied))
    Write-Host ('Client installed      : ' + (Test-GameInstalled))
    Write-Host ('Server binaries       : ' + (Test-ServerFiles))
    Write-Host ('Server running        : ' + (Test-ServerRunning))
    Write-Host ('Master data           : ' + (Test-MasterData))
    Write-Host ('Game assets           : ' + (Test-GameAssets))
    Write-Host ('Java runtime          : ' + (Get-JavaExe))
    Write-Host ('apktool               : ' + (Test-Path $Paths.ApktoolJar))
    Write-Host ('zipalign              : ' + (Find-BuildTool 'zipalign.exe'))
    Write-Host ('Python runtime        : ' + (Test-Path (Join-Path $Paths.PythonDir 'python.exe')))
    Write-Host ('Client APK            : ' + (Get-ClientApkPath))

    if ($InstallAll) {
        Write-Host ''
        Write-Host '=== full run (console) ===' -ForegroundColor Cyan
        Action-InstallEmulator | Out-Null
        Action-InstallGame | Out-Null
        Action-InstallClient | Out-Null
        Action-StartServer | Out-Null
        Action-CheckArmBridge | Out-Null
    }
    return
}

# =====================================================================
#  GUI
# =====================================================================
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Cage Setup - NieR Re[in]carnation private server installer'
$form.Size = New-Object Drawing.Size(1000, 850)
$form.MinimumSize = New-Object Drawing.Size(880, 760)
$form.StartPosition = 'CenterScreen'
$form.BackColor = [Drawing.Color]::FromArgb(24, 24, 28)
$form.ForeColor = [Drawing.Color]::Gainsboro
$form.Font = New-Object Drawing.Font('Segoe UI', 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'CAGE SETUP - Guided installation'
$title.Font = New-Object Drawing.Font('Segoe UI', 14, [Drawing.FontStyle]::Bold)
$title.ForeColor = [Drawing.Color]::FromArgb(222, 196, 140)
$title.Location = New-Object Drawing.Point(16, 12)
$title.Size = New-Object Drawing.Size(700, 30)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Press "Install all" (about 20 GB of downloads: MuMu, server, assets, client build) or tick the items you need.'
$subtitle.ForeColor = [Drawing.Color]::Silver
$subtitle.Location = New-Object Drawing.Point(18, 42)
$subtitle.Size = New-Object Drawing.Size(940, 20)
$form.Controls.Add($subtitle)

$list = New-Object System.Windows.Forms.ListView
$list.Location = New-Object Drawing.Point(16, 70)
$list.Size = New-Object Drawing.Size(950, 364)
$list.View = 'Details'
$list.CheckBoxes = $true
$list.FullRowSelect = $true
$list.GridLines = $false
$list.BackColor = [Drawing.Color]::FromArgb(32, 32, 38)
$list.ForeColor = [Drawing.Color]::Gainsboro
$list.Anchor = 'Top,Left,Right'
$list.Columns.Add('Component', 250) | Out-Null
$list.Columns.Add('Details', 330) | Out-Null
$list.Columns.Add('Status', 150) | Out-Null
$list.Columns.Add('Download', 120) | Out-Null
$form.Controls.Add($list)

$Script:Plan = New-Plan
$groups = @{}
foreach ($row in $Script:Plan) {
    if (-not $groups.ContainsKey($row.Group)) {
        $g = New-Object System.Windows.Forms.ListViewGroup($row.Group)
        $list.Groups.Add($g) | Out-Null
        $groups[$row.Group] = $g
    }
    $item = New-Object System.Windows.Forms.ListViewItem($row.Name)
    $item.SubItems.Add($row.Detail) | Out-Null
    $item.SubItems.Add((Get-StatusLabel $row.Status)) | Out-Null
    $item.SubItems.Add($row.Size) | Out-Null
    $item.Group = $groups[$row.Group]
    $item.Tag = $row.Id
    $item.Checked = $row.Id -notlike 'R*'
    $item.UseItemStyleForSubItems = $false
    $list.Items.Add($item) | Out-Null
}

function Sync-List {
    for ($i = 0; $i -lt $Script:Plan.Count; $i++) {
        $item = $list.Items[$i]
        if ($item) {
            $item.SubItems[2].Text = Get-StatusLabel $Script:Plan[$i].Status
            $item.SubItems[2].ForeColor = Get-StatusColor $Script:Plan[$i].Status
        }
    }
}
# NOTE: the first status refresh runs in the form's Shown event, so the window
# appears immediately instead of waiting for ADB and WMI queries.

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object Drawing.Point(16, 442)
$progressBar.Size = New-Object Drawing.Size(950, 22)
$progressBar.Anchor = 'Top,Left,Right'
$form.Controls.Add($progressBar)
$Script:ProgressBar = $progressBar

$progressLabel = New-Object System.Windows.Forms.Label
$progressLabel.Text = 'Ready.'
$progressLabel.Location = New-Object Drawing.Point(16, 468)
$progressLabel.Size = New-Object Drawing.Size(950, 20)
$progressLabel.ForeColor = [Drawing.Color]::FromArgb(160, 200, 160)
$progressLabel.Anchor = 'Top,Left,Right'
$form.Controls.Add($progressLabel)
$Script:ProgressLabel = $progressLabel

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object Drawing.Point(16, 494)
$logBox.Size = New-Object Drawing.Size(950, 178)
$logBox.Multiline = $true
$logBox.WordWrap = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly = $true
$logBox.BackColor = [Drawing.Color]::FromArgb(16, 16, 18)
$logBox.ForeColor = [Drawing.Color]::FromArgb(170, 220, 170)
$logBox.Font = New-Object Drawing.Font('Consolas', 9)
$logBox.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($logBox)
$Script:LogBox = $logBox

function New-Button {
    param([string]$Text, [int]$X, [int]$Width, [int]$Y = 672)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object Drawing.Point($X, $Y)
    $b.Size = New-Object Drawing.Size($Width, 34)
    $b.Anchor = 'Bottom,Left'
    $b.FlatStyle = 'Flat'
    $form.Controls.Add($b)
    return $b
}

$btnAll = New-Button -Text 'Install all' -X 16 -Width 150 -Y 680
$btnAll.BackColor = [Drawing.Color]::FromArgb(222, 196, 140)
$btnAll.ForeColor = [Drawing.Color]::Black

$btnSelected = New-Button -Text 'Install selected' -X 174 -Width 150 -Y 680
$btnRefresh = New-Button -Text 'Refresh status' -X 332 -Width 130 -Y 680
$btnLaunch = New-Button -Text 'Launch game' -X 470 -Width 120 -Y 680
$btnLog = New-Button -Text 'Open log' -X 598 -Width 100 -Y 680

$serverLabel = New-Object System.Windows.Forms.Label
$serverLabel.Text = 'Server:'
$serverLabel.Location = New-Object Drawing.Point(16, 726)
$serverLabel.Size = New-Object Drawing.Size(55, 20)
$serverLabel.Anchor = 'Bottom,Left'
$form.Controls.Add($serverLabel)

$btnStartServer = New-Button -Text 'Start' -X 74 -Width 90 -Y 720
$btnStopServer = New-Button -Text 'Stop' -X 172 -Width 90 -Y 720
$btnRestartServer = New-Button -Text 'Restart' -X 270 -Width 90 -Y 720

$serverState = New-Object System.Windows.Forms.Label
$serverState.Text = ''
$serverState.Location = New-Object Drawing.Point(376, 726)
$serverState.Size = New-Object Drawing.Size(300, 20)
$serverState.Anchor = 'Bottom,Left'
$form.Controls.Add($serverState)
$Script:ServerStateLabel = $serverState

$credits = New-Object System.Windows.Forms.Label
$credits.Text = 'Credits: Lunar Tear by walter-sparrow-group  |  lunar-scripts patchers  |  stock APK from APKMirror  |  assets and master data via archive.org  |  MuMu Player by NetEase'
$credits.ForeColor = [Drawing.Color]::Gray
$credits.Location = New-Object Drawing.Point(16, 766)
$credits.Size = New-Object Drawing.Size(950, 18)
$credits.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($credits)

function Update-ServerStateLabel {
    if ($Script:ServerStateLabel) {
        if (Test-ServerRunning) {
            $Script:ServerStateLabel.Text = 'running (ports 8003 / 8080)'
            $Script:ServerStateLabel.ForeColor = [Drawing.Color]::FromArgb(0, 160, 0)
        } else {
            $Script:ServerStateLabel.Text = 'stopped'
            $Script:ServerStateLabel.ForeColor = [Drawing.Color]::Gray
        }
    }
}

# ------------------------------------------------ event handlers
$btnRefresh.Add_Click({
    Update-Progress -Text 'Checking the current status...' -Indeterminate
    Refresh-Status -Plan $Script:Plan
    Sync-List
    Update-ServerStateLabel
    Update-Progress -Text 'Status updated.' -Done 0 -Total 0
})

$btnAll.Add_Click({ Run-Plan -OnlyIds $null })

$btnSelected.Add_Click({
    $ids = @()
    foreach ($item in $list.CheckedItems) { $ids += $item.Tag }
    if ($ids.Count -eq 0) { Update-Progress -Text 'No item selected.' -Done 0 -Total 0; return }
    Run-Plan -OnlyIds $ids
})

$btnStartServer.Add_Click({
    Update-Progress -Text 'Starting the server...' -Indeterminate
    Action-StartServer | Out-Null
    Update-ServerStateLabel
    Refresh-Status -Plan $Script:Plan
    Sync-List
    Update-Progress -Text 'Server: started.' -Done 0 -Total 0
})

$btnStopServer.Add_Click({
    Update-Progress -Text 'Stopping the server...' -Indeterminate
    Action-StopServer | Out-Null
    Update-ServerStateLabel
    Refresh-Status -Plan $Script:Plan
    Sync-List
    Update-Progress -Text 'Server: stopped.' -Done 0 -Total 0
})

$btnRestartServer.Add_Click({
    Update-Progress -Text 'Restarting the server...' -Indeterminate
    Action-RestartServer | Out-Null
    Update-ServerStateLabel
    Refresh-Status -Plan $Script:Plan
    Sync-List
    Update-Progress -Text 'Server: restarted.' -Done 0 -Total 0
})

$btnLaunch.Add_Click({
    if (-not (Test-ServerRunning)) { Action-StartServer | Out-Null }
    if (-not (Test-EmulatorRunning)) {
        & $Paths.MuMuManager control -v 0 launch 2>&1 | Out-Null
        for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Seconds 3; if (Test-EmulatorRunning) { break }; [Windows.Forms.Application]::DoEvents() }
    }
    if (Test-EmulatorRunning) {
        $adb = Get-Adb
        & $adb -s $Script:Serial shell monkey -p $Script:PackageName -c android.intent.category.LAUNCHER 1 2>&1 | Out-Null
        Write-Log 'Game launched.' 'OK'
    } else {
        Write-Log 'Cannot launch the game: the emulator is not running.' 'ERROR'
    }
    Update-ServerStateLabel
})

$btnLog.Add_Click({ if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile } })

$form.Add_Shown({
    Write-Log 'Cage Setup started.' 'STEP'
    if (-not (Test-Admin)) { Write-Log 'Tip: run as administrator to install MuMu Player.' 'WARN' }

    # bring the window to the front (without keeping it always on top)
    $form.Activate()
    $form.TopMost = $true
    $form.TopMost = $false

    Update-Progress -Text 'Checking the current status...' -Indeterminate
    Refresh-Status -Plan $Script:Plan
    Sync-List
    Update-ServerStateLabel
    Update-Progress -Text 'Ready.' -Done 0 -Total 0
})

[void]$form.ShowDialog()
