# =====================================================================
#  CAGE SETUP - Installer for NieR Re[in]carnation (private server)
#  ------------------------------------------------------------------
#  Guided GUI that downloads, installs and configures everything.
#  Every download shows status, percentage, speed and estimated time.
#
#  Normal use:  CageSetup.exe (packed from this file by GitHub Actions)
#  From source: powershell -ExecutionPolicy Bypass -File "Cage Setup.ps1"
#  Diagnostics: powershell -ExecutionPolicy Bypass -File "Cage Setup.ps1" -Console
#
#  CREDITS
#   - Lunar Tear private server:  https://gitlab.com/walter-sparrow-group/lunar-tear
#                                 https://github.com/Walter-Sparrow/lunar-tear
#   - lunar-scripts patchers:     https://gitlab.com/walter-sparrow-group/lunar-scripts
#
#  Without their work this installer would not exist: the server, the client
#  patch and the master data patch are all built on the Lunar Tear project and
#  on the lunar-scripts tooling. Cage Setup only automates the steps around
#  them. Every other file is downloaded from its official source at runtime.
#
#  This package does NOT contain any game APK, game assets or master data:
#  the stock APK is downloaded from APKMirror and patched on this PC with the
#  official lunar-scripts patcher, the game data comes from archive.org and the
#  master data is patched locally with the same tooling.
# =====================================================================
#  INDEX
#  ------------------------------------------------------------------
#   SOURCES AND PATHS ....... URLs, checksums, folders (the only part to edit)
#   lib\00-paths.ps1 ........ path helpers and the game files folder
#   lib\01-window.ps1 ....... hides the MuMu installer windows
#   lib\02-log.ps1 .......... logging
#   lib\03-utilities.ps1 .... signatures, disk space, ports, data folder
#   lib\04-downloads.ps1 .... downloads with percentage and speed
#   lib\05-client-build.ps1 . toolchain and APK patching
#   lib\06-actions.ps1 ...... the individual installation steps
#   lib\07-engine.ps1 ....... runs the steps and the diagnostics block
#   CONSOLE / DIAGNOSTICS ... -Console output
#   GUI ..................... the window, the six steps, update check
# =====================================================================
#Requires -Version 5.1

param(
    [switch]$Console,      # text diagnostics, no GUI
    [switch]$InstallAll    # no GUI: run everything in the console
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

# DPI awareness: without it Windows bitmap-stretches the window on a scaled
# display (blurry text). The layout is then scaled by hand in the GUI section,
# so a 150% display gets the same proportions instead of a tiny window.
if (-not ('CageSetup.Dpi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CageSetup {
    public static class Dpi {
        [DllImport("shcore.dll")]
        private static extern int GetProcessDpiAwareness(IntPtr process, out int awareness);

        [DllImport("shcore.dll")]
        private static extern int SetProcessDpiAwareness(int awareness);

        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [DllImport("user32.dll")]
        private static extern IntPtr GetDC(IntPtr window);

        [DllImport("user32.dll")]
        private static extern int ReleaseDC(IntPtr window, IntPtr dc);

        [DllImport("gdi32.dll")]
        private static extern int GetDeviceCaps(IntPtr dc, int index);

        // Returns true when the process is DPI aware, making it aware if needed.
        public static bool EnsureAware() {
            int awareness;
            try {
                if (GetProcessDpiAwareness(IntPtr.Zero, out awareness) == 0 && awareness != 0) {
                    return true;
                }
            } catch { }
            try { if (SetProcessDpiAwareness(2) == 0) { return true; } } catch { }
            try { return SetProcessDPIAware(); } catch { }
            return false;
        }

        // LOGPIXELSX of the desktop: 96 = 100%, 120 = 125%, 144 = 150%.
        public static int CurrentDpi() {
            IntPtr dc = GetDC(IntPtr.Zero);
            try { return GetDeviceCaps(dc, 88); } finally { ReleaseDC(IntPtr.Zero, dc); }
        }
    }
}
'@
}

# The installer logic lives in lib\*.ps1. build.ps1 inlines these files into
# a single script before packing it, so the executable stays self-contained.
# @@LIBS-START
. (Join-Path $PSScriptRoot 'lib\00-paths.ps1')
. (Join-Path $PSScriptRoot 'lib\01-window.ps1')
. (Join-Path $PSScriptRoot 'lib\02-log.ps1')
. (Join-Path $PSScriptRoot 'lib\03-utilities.ps1')
. (Join-Path $PSScriptRoot 'lib\04-downloads.ps1')
. (Join-Path $PSScriptRoot 'lib\05-client-build.ps1')
. (Join-Path $PSScriptRoot 'lib\06-actions.ps1')
. (Join-Path $PSScriptRoot 'lib\07-engine.ps1')
# @@LIBS-END
# Running packed as CageSetup.exe? Then the script has no path of its own, so
# the folder of the executable is both the place for the log and the default
# place for the game files.
# CAGE_SETUP_ROOT overrides both, which the test harness uses.
$HostExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
if ($env:CAGE_SETUP_ROOT) {
    $AppDir = $env:CAGE_SETUP_ROOT
    $Root = $AppDir
} else {
    if ($HostExe -and (Split-Path -Leaf $HostExe) -notmatch '^(powershell|pwsh)(_ise)?\.exe$') {
        $AppDir = Split-Path -Parent $HostExe
    } else {
        $AppDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
        if (-not $AppDir) { $AppDir = (Get-Location).Path }
    }
    # The game files can live in another folder, chosen in the window with
    # "Use game files..." and remembered in this file next to the installer.
    $Root = $AppDir
    $savedRoot = Join-Path $AppDir 'data-folder.txt'
    if (Test-Path -LiteralPath $savedRoot) {
        $candidate = Get-Content -LiteralPath $savedRoot -Raw -ErrorAction SilentlyContinue
        if ($candidate) {
            $candidate = $candidate.Trim()
            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) {
                $Root = Get-NormalFolderPath -Path $candidate
            }
        }
    }
}
$LogFile = Join-Path $AppDir 'installer-log.txt'
$Script:AppDir = $AppDir

# Version of the installer: this is the single source of truth. The build
# workflow reads this line and refuses to build a tag that does not match it.
$Script:AppVersion = '1.4.1'

# ---------------------------------------------------------------------
#  SOURCES AND PATHS  (edit here when you redistribute the installer)
# ---------------------------------------------------------------------
$Config = @{
    # --- Emulator ---
    MuMuInstallerUrl = 'https://api.mumuplayer.com/api/dl/win?channel=gw-overseas12'

    # --- Server binaries (GitHub Releases, pinned to a known version) ---
    # The installer downloads and runs this software: version and SHA256 are
    # fixed on purpose. Set ServerUrl to '' to follow the latest release
    # instead, and clear ServerSha256 (a different archive would not match).
    ServerRepo        = 'Walter-Sparrow/lunar-tear'
    ServerAssetMatch  = 'windows-amd64'
    ServerUrl         = 'https://github.com/Walter-Sparrow/lunar-tear/releases/download/v1.0.2/lunar-tear-server-v1.0.2-windows-amd64.zip'
    ServerBytes       = 33872763
    ServerSha256      = 'd8f6330a8f3a8788a89ba8ecfc01a5ff40ab566a9c46d9ff6fd0929503dd5f0a'
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
    ApkStockSha256 = '9ded0797ee607b6892b531ba3a02f4c4510774f5fe098ccada78ccff881c9209'
    ApkStockFile  = Join-Path $Root 'apk\stock\nier-3.7.1-stock.apk'
    ApkWorkDir    = Join-Path $Root 'apk\work'
    ApkOutput     = Join-Path $Root 'apk\out\nier-patched.apk'
    Keystore      = Join-Path $Root 'apk\out\debug.keystore'
    GrpcAddr      = '10.0.2.2:8003'
    HttpAddr      = '10.0.2.2:8080'
    AuthAddr      = '10.0.2.2:3000'

    # --- Toolchain, downloaded on demand (never committed to the repository) ---
    #     Each file is pinned by version, size and SHA256: a substituted or
    #     truncated archive is rejected before it is unpacked or executed.
    JreUrl        = 'https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20.1%2B1/OpenJDK17U-jre_x64_windows_hotspot_17.0.20.1_1.zip'
    JreBytes      = 43780109
    JreSha256     = 'bc21a93923103cdaac93ee337b0ae4365e739fde36df823dd456bc67c8a9d352'
    ApktoolUrl    = 'https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar'
    ApktoolBytes  = 15478013
    ApktoolSha256 = 'dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423'
    BuildToolsUrl = 'https://dl.google.com/android/repository/build-tools_r35_windows.zip'
    BuildToolsBytes = 59878107
    BuildToolsSha256 = '5753c679a1b90bcf6fbc9945a2ce39dfb9e74f1df0831a1e1866ae5b594326f0'
    PythonUrl     = 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip'
    PythonBytes   = 11133606
    PythonSha256  = '4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3'

    # --- Patcher scripts, pinned to a commit of the upstream repository ---
    # Pinned on purpose: an upstream change must not silently alter what this
    # installer downloads and runs. See the README to update the pin.
    ScriptsRaw    = 'https://gitlab.com/walter-sparrow-group/lunar-scripts/-/raw/942dced617ea836a0e3abcfc0e0befec42baab11'

    # --- Local files (offline use / development) ---
    ServerExe     = Join-Path $Root 'server\wizard.exe'
    MasterFile    = Join-Path $Root 'server\assets\release\20240404193219.bin.e'
    AssetsArchive = Join-Path $Root 'downloads\resource_dump_android.7z'

    # --- Update check (one request to the public GitHub API at startup) ---
    ReleasesUrl      = 'https://github.com/claitt/cage-setup/releases/latest'
    LatestReleaseApi = 'https://api.github.com/repos/claitt/cage-setup/releases/latest'
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
$Script:AssetsExtractGB = 49          # extracted size of the game assets archive
$Script:ServerPorts = @(8003, 8080, 3000)

# process names whose windows are hidden during the MuMu installation
$Script:HideProcessNames = @('nemu-downloader', 'nemu-setup', 'MuMuNG-setup', 'MuMuSetup', 'MuMuPlayer', 'MuMuPlayerUpdater', 'MuMuInstaller')

# Runtime state. It used to sit next to the functions, but the modules are
# loaded before $Paths exists, so the state is created here instead.
$Script:CancelRequested = $false
$Script:EmulatorCache = $false
$Script:EmulatorCacheTime = [datetime]::MinValue
$Script:ServerCache = $false
$Script:ServerCacheTime = [datetime]::MinValue
$Script:JavaExe = $null
$Script:PythonExe = $null
$Script:ZipAlignExe = $null
$Script:ApkSignerJar = $null
Initialize-EmulatorPaths

# =====================================================================
#  CONSOLE / DIAGNOSTICS
# =====================================================================
if ($Console -or $InstallAll) {
    Write-Host '=== CAGE SETUP - diagnostics ===' -ForegroundColor Cyan
    Write-Host ('Version               : ' + $Script:AppVersion)
    Write-Host ('Root folder           : ' + $Root)
    Write-Host ('Windows 64-bit        : ' + [Environment]::Is64BitOperatingSystem)
    Write-Host ('Administrator         : ' + (Test-Admin))
    Write-Host ('Virtualization        : ' + (Test-VirtualizationEnabled))
    Write-Host ('Hyper-V active        : ' + (Test-HyperVActive))
    Write-Host ('Free space            : ' + (Get-FreeSpaceGB) + ' GB (game files drive)')
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

# DPI: the window is scaled by hand further down, because WinForms automatic
# scaling does not run for windows built in a script.
$Script:DpiAware = [CageSetup.Dpi]::EnsureAware()
$Script:Dpi = [CageSetup.Dpi]::CurrentDpi()
$Script:Scale = if ($Script:DpiAware -and $Script:Dpi -gt 0) { $Script:Dpi / 96.0 } else { 1.0 }
$Script:Running = $false

# One instance per installer folder: two windows would fight over the same
# downloads and ports, and could start the server twice. The game files folder
# can change while the window is open, so the lock follows the executable.
$Script:InstanceMutex = $null
$Script:HasInstanceMutex = $false
try {
    $Script:InstanceMutex = New-Object System.Threading.Mutex($false, (Get-InstanceMutexName -Path $AppDir))
    if ($Script:InstanceMutex.WaitOne(0)) { $Script:HasInstanceMutex = $true }
} catch [System.Threading.AbandonedMutexException] {
    $Script:HasInstanceMutex = $true
} catch {
    Write-Verbose "Single-instance check skipped: $($_.Exception.Message)"
}
if ($Script:InstanceMutex -and -not $Script:HasInstanceMutex) {
    [System.Windows.Forms.MessageBox]::Show(
        "Cage Setup is already running from this folder:`r`n`r`n$AppDir",
        'Cage Setup', 'OK', 'Information') | Out-Null
    return
}

$Script:Gold      = [Drawing.Color]::FromArgb(222, 196, 140)
$Script:Back      = [Drawing.Color]::FromArgb(24, 24, 28)
$Script:Button    = [Drawing.Color]::FromArgb(36, 36, 42)
$Script:ButtonHot = [Drawing.Color]::FromArgb(48, 48, 56)
$Script:Border    = [Drawing.Color]::FromArgb(58, 58, 66)
$Script:TextMain  = [Drawing.Color]::Gainsboro
$Script:TextDim   = [Drawing.Color]::FromArgb(140, 140, 148)
$Script:Green     = [Drawing.Color]::FromArgb(120, 190, 120)
$Script:Amber     = [Drawing.Color]::FromArgb(220, 170, 80)
$Script:Red       = [Drawing.Color]::FromArgb(210, 90, 90)
$Script:Blue      = [Drawing.Color]::FromArgb(110, 160, 220)

$form = New-Object System.Windows.Forms.Form
$form.AutoScaleMode = 'None'   # the layout is scaled by hand, see "DPI scaling"
$form.Text = 'Cage Setup ' + $Script:AppVersion + ' - NieR Re[in]carnation private server installer'
$form.Size = New-Object Drawing.Size(800, 700)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.BackColor = $Script:Back
$form.ForeColor = $Script:TextMain
$form.Font = New-Object Drawing.Font('Segoe UI', 9)

# Packed as an executable: use the icon embedded in CageSetup.exe.
if ($HostExe -and (Split-Path -Leaf $HostExe) -notmatch '^(powershell|pwsh)(_ise)?\.exe$') {
    try { $form.Icon = [Drawing.Icon]::ExtractAssociatedIcon($HostExe) } catch { Write-Verbose "Cannot load the icon: $($_.Exception.Message)" }
}

$title = New-Object System.Windows.Forms.Label
$title.Text = 'CAGE SETUP'
$title.Font = New-Object Drawing.Font('Segoe UI', 16, [Drawing.FontStyle]::Bold)
$title.ForeColor = $Script:Gold
$title.Location = New-Object Drawing.Point(20, 12)
$title.Size = New-Object Drawing.Size(400, 32)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'NieR Re[in]carnation private server - guided installation'
$subtitle.ForeColor = $Script:TextDim
$subtitle.Location = New-Object Drawing.Point(22, 44)
$subtitle.Size = New-Object Drawing.Size(600, 20)
$form.Controls.Add($subtitle)

# Version, and a link to the releases page. When a newer release exists the
# text becomes "Update: vX.Y.Z" (see Start-UpdateCheck).
$versionLink = New-Object System.Windows.Forms.LinkLabel
$versionLink.Text = 'v' + $Script:AppVersion
$versionLink.Location = New-Object Drawing.Point(624, 44)
$versionLink.Size = New-Object Drawing.Size(140, 20)
$versionLink.TextAlign = 'MiddleRight'
$versionLink.LinkColor = $Script:TextDim
$versionLink.ActiveLinkColor = $Script:Gold
$versionLink.LinkBehavior = 'NeverUnderline'
$versionLink.TabIndex = 8
$versionLink.Add_LinkClicked({ Start-Process $Config.ReleasesUrl })
$form.Controls.Add($versionLink)

$rule = New-Object System.Windows.Forms.Panel
$rule.Location = New-Object Drawing.Point(20, 72)
$rule.Size = New-Object Drawing.Size(744, 1)
$rule.BackColor = [Drawing.Color]::FromArgb(70, 60, 40)
$form.Controls.Add($rule)

# ---- the six steps ------------------------------------------------
$Script:Steps = @(
    [pscustomobject]@{ Key = 'pc';       Number = 1; Title = 'Check your PC';        Detail = 'Windows 64-bit, virtualization, Hyper-V, free space'; Status = 'pending' }
    [pscustomobject]@{ Key = 'emulator'; Number = 2; Title = 'Install the emulator'; Detail = 'MuMu Player, Android engine, cleanup  -  ~5 GB';       Status = 'pending' }
    [pscustomobject]@{ Key = 'files';    Number = 3; Title = 'Get the game files';   Detail = 'Server, master data, client build, assets  -  ~15.4 GB'; Status = 'pending' }
    [pscustomobject]@{ Key = 'client';   Number = 4; Title = 'Install the game';     Detail = 'Client on the emulator, via ADB';                      Status = 'pending' }
    [pscustomobject]@{ Key = 'server';   Number = 5; Title = 'Start the server';     Detail = 'gRPC 8003 / CDN 8080';                                 Status = 'pending' }
    [pscustomobject]@{ Key = 'play';     Number = 6; Title = 'Launch the game';      Detail = 'Opens the game on the emulator';                       Status = 'pending' }
)

$stepsPanel = New-Object System.Windows.Forms.Panel
$stepsPanel.Location = New-Object Drawing.Point(20, 84)
$stepsPanel.Size = New-Object Drawing.Size(744, 324)
$stepsPanel.BackColor = $Script:Back
$form.Controls.Add($stepsPanel)

$Script:StepRows = @{}
$y = 0
foreach ($s in $Script:Steps) {
    $row = New-Object System.Windows.Forms.Panel
    $row.Location = New-Object Drawing.Point(0, $y)
    $row.Size = New-Object Drawing.Size(744, 54)
    $row.BackColor = $Script:Back
    $stepsPanel.Controls.Add($row)

    $marker = New-Object System.Windows.Forms.Label
    $marker.Location = New-Object Drawing.Point(2, 10)
    $marker.Size = New-Object Drawing.Size(28, 28)
    $marker.Font = New-Object Drawing.Font('Segoe UI', 14, [Drawing.FontStyle]::Bold)
    $marker.TextAlign = 'MiddleCenter'
    $marker.Text = 'o'
    $marker.ForeColor = $Script:TextDim
    $row.Controls.Add($marker)

    $t = New-Object System.Windows.Forms.Label
    $t.Location = New-Object Drawing.Point(38, 5)
    $t.Size = New-Object Drawing.Size(520, 22)
    $t.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
    $t.Text = "$($s.Number). $($s.Title)"
    $row.Controls.Add($t)

    $d = New-Object System.Windows.Forms.Label
    $d.Location = New-Object Drawing.Point(38, 26)
    $d.Size = New-Object Drawing.Size(580, 18)
    $d.ForeColor = $Script:TextDim
    $d.Text = $s.Detail
    $row.Controls.Add($d)

    $st = New-Object System.Windows.Forms.Label
    $st.Location = New-Object Drawing.Point(620, 8)
    $st.Size = New-Object Drawing.Size(120, 20)
    $st.TextAlign = 'MiddleRight'
    $st.ForeColor = $Script:TextDim
    $row.Controls.Add($st)

    $sep = New-Object System.Windows.Forms.Panel
    $sep.Location = New-Object Drawing.Point(0, 52)
    $sep.Size = New-Object Drawing.Size(744, 1)
    $sep.BackColor = [Drawing.Color]::FromArgb(42, 42, 50)
    $row.Controls.Add($sep)

    $Script:StepRows[$s.Key] = @{ Marker = $marker; Detail = $d; Status = $st }
    $y += 54
}

function Set-StepVisual {
    param([string]$Key)
    $step = $Script:Steps | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
    $ui = $Script:StepRows[$Key]
    if (-not $step -or -not $ui) { return }
    switch ($step.Status) {
        'ok'      { $ui.Marker.Text = [char]0x2713; $ui.Marker.ForeColor = $Script:Green; $ui.Status.Text = 'Ready';    $ui.Status.ForeColor = $Script:Green }
        'warn'    { $ui.Marker.Text = '!';           $ui.Marker.ForeColor = $Script:Amber; $ui.Status.Text = 'Check';    $ui.Status.ForeColor = $Script:Amber }
        'error'   { $ui.Marker.Text = [char]0x00D7;  $ui.Marker.ForeColor = $Script:Red;   $ui.Status.Text = 'Problem';  $ui.Status.ForeColor = $Script:Red }
        'running' { $ui.Marker.Text = [char]0x25CF;  $ui.Marker.ForeColor = $Script:Blue;  $ui.Status.Text = 'Working';  $ui.Status.ForeColor = $Script:Blue }
        default   { $ui.Marker.Text = [char]0x25CB;  $ui.Marker.ForeColor = $Script:TextDim; $ui.Status.Text = 'Waiting'; $ui.Status.ForeColor = $Script:TextDim }
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-Steps {
    foreach ($s in $Script:Steps) {
        $s.Status = Get-StepStatus -Key $s.Key
        Set-StepVisual -Key $s.Key
    }
    $pc = $Script:Steps | Where-Object { $_.Key -eq 'pc' } | Select-Object -First 1
    $pcUi = $Script:StepRows['pc']
    if ($pc -and $pcUi) {
        if ($pc.Status -eq 'ok') {
            $pcUi.Detail.Text = 'Windows 64-bit, virtualization, Hyper-V, free space'
        } else {
            $issues = @(Get-PcIssues)
            if ($issues.Count -gt 0) { $pcUi.Detail.Text = ($issues -join '  -  ') }
        }
    }
    $play = $Script:Steps | Where-Object { $_.Key -eq 'play' } | Select-Object -First 1
    if ($play -and $play.Status -eq 'ok') { $btnMain.Text = 'Launch game' } else { $btnMain.Text = 'Start setup' }
    [System.Windows.Forms.Application]::DoEvents()
}

# The primary button doubles as the Cancel button while the steps run: pressing
# it asks the running operation to stop and keeps the partial downloads.
function Update-MainButton {
    if ($form) { $form.AcceptButton = if ($Script:Running) { $null } else { $btnMain } }
    if ($Script:Running) {
        $btnMain.BackColor = $Script:Button
        $btnMain.ForeColor = $Script:TextMain
        $btnMain.FlatAppearance.MouseOverBackColor = $Script:ButtonHot
        if ($Script:CancelRequested) {
            $btnMain.Text = 'Cancelling...'
            $btnMain.Enabled = $false
        } else {
            $btnMain.Text = 'Cancel setup'
            $btnMain.Enabled = $true
        }
        return
    }
    $btnMain.Enabled = $true
    $btnMain.BackColor = $Script:Gold
    $btnMain.ForeColor = [Drawing.Color]::Black
    $btnMain.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(240, 214, 158)
    $play = $Script:Steps | Where-Object { $_.Key -eq 'play' } | Select-Object -First 1
    if ($play -and $play.Status -eq 'ok') { $btnMain.Text = 'Launch game' } else { $btnMain.Text = 'Start setup' }
}

function Request-Cancel {
    if (-not $Script:Running -or $Script:CancelRequested) { return }
    $Script:CancelRequested = $true
    Write-Log 'Cancel requested: stopping the current operation (partial downloads are kept).' 'WARN'
    Update-Progress -Text 'Cancelling... partial downloads are kept.' -Indeterminate
    Update-MainButton
}

# ---- progress -----------------------------------------------------
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object Drawing.Point(20, 420)
$progressBar.Size = New-Object Drawing.Size(744, 14)
$form.Controls.Add($progressBar)
$Script:ProgressBar = $progressBar

$progressLabel = New-Object System.Windows.Forms.Label
$progressLabel.Text = 'Ready.'
$progressLabel.Location = New-Object Drawing.Point(20, 440)
$progressLabel.Size = New-Object Drawing.Size(744, 20)
$progressLabel.ForeColor = $Script:TextDim
$form.Controls.Add($progressLabel)
$Script:ProgressLabel = $progressLabel

# ---- buttons ------------------------------------------------------
function New-FlatButton {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 36, [switch]$Primary)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object Drawing.Point($X, $Y)
    $b.Size = New-Object Drawing.Size($Width, $Height)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = $Script:Border
    if ($Primary) {
        $b.BackColor = $Script:Gold
        $b.ForeColor = [Drawing.Color]::Black
        $b.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(240, 214, 158)
        $b.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
    } else {
        $b.BackColor = $Script:Button
        $b.ForeColor = $Script:TextMain
        $b.FlatAppearance.MouseOverBackColor = $Script:ButtonHot
    }
    $form.Controls.Add($b)
    return $b
}

$btnMain = New-FlatButton -Text 'Start setup' -X 20 -Y 472 -Width 190 -Height 40 -Primary
$btnLog = New-FlatButton -Text 'Open log' -X 222 -Y 472 -Width 120 -Height 40
$btnDiagnostics = New-FlatButton -Text 'Copy diagnostics' -X 354 -Y 472 -Width 138 -Height 40

$btnMain.TabIndex = 0
$btnLog.TabIndex = 1
$btnDiagnostics.TabIndex = 2

$lnkUseFiles = New-Object System.Windows.Forms.LinkLabel
$lnkUseFiles.Text = 'Use game files...'
$lnkUseFiles.Location = New-Object Drawing.Point(492, 484)
$lnkUseFiles.Size = New-Object Drawing.Size(100, 18)
$lnkUseFiles.TextAlign = 'MiddleRight'
$lnkUseFiles.LinkColor = $Script:TextDim
$lnkUseFiles.ActiveLinkColor = $Script:Gold
$lnkUseFiles.LinkBehavior = 'NeverUnderline'
$lnkUseFiles.TabIndex = 3
$form.Controls.Add($lnkUseFiles)

$lnkRefresh = New-Object System.Windows.Forms.LinkLabel
$lnkRefresh.Text = 'Refresh'
$lnkRefresh.Location = New-Object Drawing.Point(600, 484)
$lnkRefresh.Size = New-Object Drawing.Size(56, 18)
$lnkRefresh.TextAlign = 'MiddleRight'
$lnkRefresh.LinkColor = $Script:TextDim
$lnkRefresh.ActiveLinkColor = $Script:Gold
$lnkRefresh.LinkBehavior = 'NeverUnderline'
$lnkRefresh.TabIndex = 4
$form.Controls.Add($lnkRefresh)

$lnkAdvanced = New-Object System.Windows.Forms.LinkLabel
$lnkAdvanced.Text = 'Advanced...'
$lnkAdvanced.Location = New-Object Drawing.Point(664, 484)
$lnkAdvanced.Size = New-Object Drawing.Size(100, 18)
$lnkAdvanced.TextAlign = 'MiddleRight'
$lnkAdvanced.LinkColor = $Script:TextDim
$lnkAdvanced.ActiveLinkColor = $Script:Gold
$lnkAdvanced.LinkBehavior = 'NeverUnderline'
$lnkAdvanced.TabIndex = 5
$form.Controls.Add($lnkAdvanced)

# ---- server row ---------------------------------------------------
$serverLabel = New-Object System.Windows.Forms.Label
$serverLabel.Text = 'Server'
$serverLabel.Location = New-Object Drawing.Point(22, 532)
$serverLabel.Size = New-Object Drawing.Size(56, 20)
$serverLabel.ForeColor = $Script:TextDim
$form.Controls.Add($serverLabel)

$serverState = New-Object System.Windows.Forms.Label
$serverState.Text = ''
$serverState.Location = New-Object Drawing.Point(84, 532)
$serverState.Size = New-Object Drawing.Size(240, 20)
$form.Controls.Add($serverState)
$Script:ServerStateLabel = $serverState

$btnStartServer = New-FlatButton -Text 'Start' -X 340 -Y 526 -Width 80 -Height 30
$btnStopServer = New-FlatButton -Text 'Stop' -X 430 -Y 526 -Width 80 -Height 30
$btnRestartServer = New-FlatButton -Text 'Restart' -X 520 -Y 526 -Width 90 -Height 30
$btnStartServer.TabIndex = 6
$btnStopServer.TabIndex = 7
$btnRestartServer.TabIndex = 8

function Update-ServerStateLabel {
    if (-not $Script:ServerStateLabel) { return }
    if (Test-ServerRunning) {
        $Script:ServerStateLabel.Text = [string][char]0x25CF + ' running (ports 8003 / 8080)'
        $Script:ServerStateLabel.ForeColor = $Script:Green
    } else {
        $Script:ServerStateLabel.Text = [string][char]0x25CB + ' stopped'
        $Script:ServerStateLabel.ForeColor = $Script:TextDim
    }
    [System.Windows.Forms.Application]::DoEvents()
}

# ---- credits ------------------------------------------------------
$credits = New-Object System.Windows.Forms.Label
$credits.Text = "Credits: Lunar Tear private server - walter-sparrow-group on GitLab / Walter-Sparrow on GitHub`r`n" +
                "lunar-scripts patchers (patch_apk.py, patch_masterdata.py) - walter-sparrow-group`r`n" +
                "Without their work this installer would not exist."
$credits.ForeColor = [Drawing.Color]::FromArgb(110, 110, 118)
$credits.Location = New-Object Drawing.Point(20, 590)
$credits.Size = New-Object Drawing.Size(744, 50)
$credits.Font = New-Object Drawing.Font('Segoe UI', 8)
$form.Controls.Add($credits)

# ---- actions ------------------------------------------------------
function Start-Game {
    Update-Progress -Text 'Launching the game...' -Indeterminate
    if (-not (Test-ServerRunning)) { Action-StartServer | Out-Null }
    if (-not (Test-EmulatorRunning)) {
        & $Paths.MuMuManager control -v 0 launch 2>&1 | Out-Null
        for ($i = 0; $i -lt 40; $i++) {
            if ($Script:CancelRequested) { return $false }
            Start-Sleep -Seconds 3
            if (Test-EmulatorRunning) { break }
            [Windows.Forms.Application]::DoEvents()
        }
    }
    if (Test-EmulatorRunning) {
        $adb = Get-Adb
        & $adb -s $Script:Serial shell monkey -p $Script:PackageName -c android.intent.category.LAUNCHER 1 2>&1 | Out-Null
        Write-Log 'Game launched.' 'OK'
        Update-Progress -Text 'Game launched. Have fun.' -Done 0 -Total 0
    } else {
        Write-Log 'Cannot launch the game: the emulator is not running.' 'ERROR'
        Update-Progress -Text 'The emulator is not running.' -Done 0 -Total 0
    }
    Update-Steps
    Update-ServerStateLabel
}

function Invoke-StepAction {
    param([string]$Key)
    switch ($Key) {
        'emulator' { return (Invoke-Action -Action 'InstallEmulator') }
        'files'    { return (Invoke-Action -Action 'InstallGame') }
        'client'   { return (Invoke-Action -Action 'InstallClient') }
        'server'   { return (Invoke-Action -Action 'StartServer') }
        default    { return $true }
    }
}

function Run-Steps {
    param([string[]]$Keys)
    $Script:Running = $true
    $Script:CancelRequested = $false
    $lnkRefresh.Enabled = $false
    $lnkAdvanced.Enabled = $false
    $lnkUseFiles.Enabled = $false
    $btnStartServer.Enabled = $false
    $btnStopServer.Enabled = $false
    $btnRestartServer.Enabled = $false
    Update-MainButton
    try {
        Update-Steps
        foreach ($key in @('emulator', 'files', 'client', 'server')) {
            if ($Script:CancelRequested) { break }
            if ($Keys -and ($Keys -notcontains $key)) { continue }
            $step = $Script:Steps | Where-Object { $_.Key -eq $key } | Select-Object -First 1
            if (-not $step) { continue }
            if ($step.Status -eq 'ok') { Write-Log ("Skipping " + $step.Title + ": already done."); continue }

            $step.Status = 'running'
            Set-StepVisual -Key $key
            $result = $null
            try { $result = Invoke-StepAction -Key $key }
            catch [System.OperationCanceledException] { $result = $false }
            catch { Write-Log ("Error on " + $step.Title + ": " + $_.Exception.Message) 'ERROR'; $result = $false }
            Update-Steps

            # a cancelled operation is not a failure: no error dialog
            if ($Script:CancelRequested) { break }

            if ($result -eq $false) {
                Update-Progress -Text ("Stopped at step " + $step.Number + ": " + $step.Title + ". See the log.") -Done 0 -Total 0
                Show-Notice -Icon 'Error' -Message "Step $($step.Number) ($($step.Title)) failed.`r`n`r`nOpen the log for the details."
                return
            }
        }
        if ($Script:CancelRequested) {
            Write-Log 'Setup cancelled. Partial downloads are kept and resume next time.' 'WARN'
            Update-Progress -Text 'Cancelled. Press Start setup to continue later.' -Done 0 -Total 0
        } else {
            Update-Progress -Text 'Done.' -Done 0 -Total 0
        }
    } finally {
        $Script:Running = $false
        $Script:CancelRequested = $false
        $lnkRefresh.Enabled = $true
        $lnkAdvanced.Enabled = $true
        $lnkUseFiles.Enabled = $true
        $btnStartServer.Enabled = $true
        $btnStopServer.Enabled = $true
        $btnRestartServer.Enabled = $true
        Update-Steps
        Update-ServerStateLabel
    }
}

function Start-Setup {
    $pc = $Script:Steps | Where-Object { $_.Key -eq 'pc' } | Select-Object -First 1
    if ($pc -and $pc.Status -eq 'error') {
        [System.Windows.Forms.MessageBox]::Show(
            ("This PC cannot run the installer:`r`n`r`n- " + ((@(Get-PcIssues)) -join "`r`n- ")),
            'Cage Setup', 'OK', 'Warning') | Out-Null
        return
    }
    Run-Steps -Keys $null
}

function Show-Advanced {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Advanced'
    $dlg.Size = New-Object Drawing.Size(470, 336)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $Script:Back
    $dlg.ForeColor = $Script:TextMain
    $dlg.Font = New-Object Drawing.Font('Segoe UI', 9)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Run only the selected components:'
    $lbl.Location = New-Object Drawing.Point(16, 14)
    $lbl.Size = New-Object Drawing.Size(420, 20)
    $dlg.Controls.Add($lbl)

    $items = @(
        @{ Key = 'emulator';  Text = 'Emulator (MuMu Player, engine, cleanup)' }
        @{ Key = 'files';     Text = 'Game files (server, data, client build)' }
        @{ Key = 'client';    Text = 'Install the client on the emulator' }
        @{ Key = 'server';    Text = 'Start the server' }
        @{ Key = 'arm';       Text = 'Check the ARM translation' }
        @{ Key = 'inventory'; Text = 'Save the package inventory' }
    )
    $boxes = @{}
    $y = 44
    foreach ($it in $items) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $it.Text
        $cb.Location = New-Object Drawing.Point(18, $y)
        $cb.Size = New-Object Drawing.Size(420, 24)
        $step = $Script:Steps | Where-Object { $_.Key -eq $it.Key } | Select-Object -First 1
        $cb.Checked = (-not $step) -or ($step.Status -ne 'ok')
        $dlg.Controls.Add($cb)
        $boxes[$it.Key] = $cb
        $y += 30
    }

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Run selected'
    $ok.Location = New-Object Drawing.Point(232, 246)
    $ok.Size = New-Object Drawing.Size(130, 32)
    $ok.FlatStyle = 'Flat'
    $ok.BackColor = $Script:Gold
    $ok.ForeColor = [Drawing.Color]::Black
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Location = New-Object Drawing.Point(368, 246)
    $cancel.Size = New-Object Drawing.Size(80, 32)
    $cancel.FlatStyle = 'Flat'
    $cancel.BackColor = $Script:Button
    $cancel.ForeColor = $Script:TextMain
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($cancel)

    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel

    if ($dlg.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $chosen = @()
    foreach ($k in $boxes.Keys) { if ($boxes[$k].Checked) { $chosen += $k } }
    if ($chosen.Count -eq 0) { return }

    Run-Steps -Keys $chosen
    if ($chosen -contains 'arm') { Action-CheckArmBridge | Out-Null }
    if ($chosen -contains 'inventory') { Action-Inventory | Out-Null }
    Update-Steps
}

# ---- game files folder ----------------------------------------------
# Switches the whole installation to another folder after showing what is
# already inside, so an earlier install or a pre-downloaded archive is reused
# instead of downloaded again.
function Use-FilesFolder {
    param([Parameter(Mandatory)][string]$Path)

    if (Test-ServerRunning) {
        [System.Windows.Forms.MessageBox]::Show(
            'Stop the server before changing the game files folder.',
            'Game files folder', 'OK', 'Information') | Out-Null
        return $false
    }

    $report = Get-FilesFolderReport -Path $Path
    if ($report.Path -eq $script:Root) { return $true }

    $message = "Use this folder for the game files?`r`n`r`n" + $report.Path + "`r`n`r`n"
    if ($report.Found.Count -gt 0) {
        $message += "Found:`r`n- " + ($report.Found -join "`r`n- ") + "`r`n`r`n"
    } else {
        $message += "This folder has no Cage Setup files yet: everything will be downloaded there.`r`n`r`n"
    }
    if ($report.Missing.Count -gt 0) {
        $message += "Still to do:`r`n- " + ($report.Missing -join "`r`n- ")
    } else {
        $message += 'Everything is already there.'
    }
    $message += "`r`n`r`nThe installer uses this folder from now on."

    $answer = [System.Windows.Forms.MessageBox]::Show(
        $message, 'Game files folder', 'YesNo', 'Question')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }

    Set-DataRoot -Path $report.Path | Out-Null
    Save-DataRoot
    Write-Log ("Game files folder: " + $script:Root) 'INFO'
    Update-Steps
    Update-ServerStateLabel
    Update-Progress -Text ("Game files folder: " + $script:Root) -Done 0 -Total 0
    return $true
}

function Show-FilesFolder {
    if ($Script:Running) { return }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Game files folder'
    $dlg.Size = New-Object Drawing.Size(560, 300)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $Script:Back
    $dlg.ForeColor = $Script:TextMain
    $dlg.Font = New-Object Drawing.Font('Segoe UI', 9)

    $info = New-Object System.Windows.Forms.Label
    $info.Text = "Everything is downloaded, patched and unpacked in this folder.`r`n" +
                 "If you already have the files (an earlier installation, or the`r`n" +
                 "archive saved somewhere else), pick that folder to reuse them."
    $info.Location = New-Object Drawing.Point(16, 12)
    $info.Size = New-Object Drawing.Size(512, 52)
    $info.ForeColor = $Script:TextDim
    $dlg.Controls.Add($info)

    $caption = New-Object System.Windows.Forms.Label
    $caption.Text = 'Current folder'
    $caption.Location = New-Object Drawing.Point(16, 70)
    $caption.Size = New-Object Drawing.Size(512, 18)
    $dlg.Controls.Add($caption)

    $pathBox = New-Object System.Windows.Forms.TextBox
    $pathBox.Text = $script:Root
    $pathBox.ReadOnly = $true
    $pathBox.Location = New-Object Drawing.Point(16, 90)
    $pathBox.Size = New-Object Drawing.Size(512, 24)
    $pathBox.BackColor = $Script:Button
    $pathBox.ForeColor = $Script:TextMain
    $pathBox.BorderStyle = 'FixedSingle'
    $dlg.Controls.Add($pathBox)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object Drawing.Point(16, 122)
    $status.Size = New-Object Drawing.Size(512, 74)
    $status.ForeColor = $Script:TextDim
    $status.Text = Format-FilesFolderStatus (Get-FilesFolderReport -Path $script:Root)
    $dlg.Controls.Add($status)

    $change = New-Object System.Windows.Forms.Button
    $change.Text = 'Change...'
    $change.Location = New-Object Drawing.Point(16, 208)
    $change.Size = New-Object Drawing.Size(110, 32)
    $change.FlatStyle = 'Flat'
    $change.BackColor = $Script:Gold
    $change.ForeColor = [Drawing.Color]::Black
    $dlg.Controls.Add($change)

    $default = New-Object System.Windows.Forms.Button
    $default.Text = 'Use installer folder'
    $default.Location = New-Object Drawing.Point(134, 208)
    $default.Size = New-Object Drawing.Size(150, 32)
    $default.FlatStyle = 'Flat'
    $default.BackColor = $Script:Button
    $default.ForeColor = $Script:TextMain
    $dlg.Controls.Add($default)

    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'Close'
    $close.Location = New-Object Drawing.Point(448, 208)
    $close.Size = New-Object Drawing.Size(80, 32)
    $close.FlatStyle = 'Flat'
    $close.BackColor = $Script:Button
    $close.ForeColor = $Script:TextMain
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($close)

    $refresh = {
        $pathBox.Text = $script:Root
        $status.Text = Format-FilesFolderStatus (Get-FilesFolderReport -Path $script:Root)
    }

    $change.Add_Click({
        $browse = New-Object System.Windows.Forms.FolderBrowserDialog
        $browse.Description = 'Pick the folder that contains the game files'
        $browse.SelectedPath = $script:Root
        $browse.ShowNewFolderButton = $false
        if ($browse.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        if (Use-FilesFolder -Path $browse.SelectedPath) { & $refresh }
        # the status refresh can activate the main window: keep this one in front
        $dlg.Activate()
    })

    $default.Add_Click({
        if (Use-FilesFolder -Path $Script:AppDir) { & $refresh }
        $dlg.Activate()
    })

    $dlg.AcceptButton = $change
    $dlg.CancelButton = $close
    $dlg.ShowDialog($form) | Out-Null
}

# ---- DPI scaling --------------------------------------------------
# Applied once, after the layout is complete: every control, including the
# five nested panels, is scaled. Fonts stay in points, so GDI+ renders them at
# the size the display expects. On a 100% display this does nothing.
if ($Script:Scale -ne 1.0) {
    $form.Scale((New-Object Drawing.SizeF([single]$Script:Scale, [single]$Script:Scale)))
    Write-Verbose ("Window scaled by $($Script:Scale) for $($Script:Dpi) DPI")
}

# ---- update check -------------------------------------------------
# One request to the public GitHub API when the window opens. Nothing about
# the PC is sent; only a newer version changes the label.
function Start-UpdateCheck {
    try {
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(6)
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', 'CageSetup/' + $Script:AppVersion)
        $Script:UpdateTask = $client.GetStringAsync($Config.LatestReleaseApi)
        $Script:UpdateClient = $client
        $Script:UpdateTimer = New-Object System.Windows.Forms.Timer
        $Script:UpdateTimer.Interval = 500
        $Script:UpdateTimer.Add_Tick({
            if (-not $Script:UpdateTask.IsCompleted) { return }
            $Script:UpdateTimer.Stop()
            $Script:UpdateTimer.Dispose()
            try {
                if ($Script:UpdateTask.Status -eq 'RanToCompletion') {
                    $release = $Script:UpdateTask.Result | ConvertFrom-Json
                    $latest = ([string]$release.tag_name) -replace '^v', ''
                    if (Test-NewerVersion -Current $Script:AppVersion -Latest $latest) {
                        $versionLink.Text = 'Update: v' + $latest
                        $versionLink.LinkColor = $Script:Gold
                        Write-Log ("Update available: v$latest (this is $($Script:AppVersion))")
                    }
                }
            } catch {
                Write-Verbose "Update check failed: $($_.Exception.Message)"
            } finally {
                if ($Script:UpdateClient) { $Script:UpdateClient.Dispose() }
            }
        })
        $Script:UpdateTimer.Start()
    } catch {
        Write-Verbose "Update check not started: $($_.Exception.Message)"
    }
}

# ---- event handlers -----------------------------------------------
$btnMain.Add_Click({
    if ($Script:Running) { Request-Cancel; return }
    if ($btnMain.Text -eq 'Launch game') { Start-Game } else { Start-Setup }
})

$btnLog.Add_Click({ if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile } })

$btnDiagnostics.Add_Click({
    Update-Progress -Text 'Collecting diagnostics...' -Indeterminate
    $copied = $false
    for ($attempt = 1; $attempt -le 5 -and -not $copied; $attempt++) {
        try { [System.Windows.Forms.Clipboard]::SetText((Get-DiagnosticsText)); $copied = $true }
        catch { Start-Sleep -Milliseconds 150 }
    }
    if ($copied) {
        Write-Log 'Diagnostics copied to the clipboard.' 'OK'
        Update-Progress -Text 'Diagnostics copied. Paste them into the issue.' -Done 0 -Total 0
    } else {
        Write-Log 'Cannot copy to the clipboard: another program is holding it.' 'ERROR'
        Update-Progress -Text 'The clipboard is busy: close the program using it and try again.' -Done 0 -Total 0
    }
})

$lnkRefresh.Add_LinkClicked({
    Update-Progress -Text 'Checking the current status...' -Indeterminate
    Update-Steps
    Update-ServerStateLabel
    Update-Progress -Text 'Ready.' -Done 0 -Total 0
})

$lnkAdvanced.Add_LinkClicked({ Show-Advanced })
$lnkUseFiles.Add_LinkClicked({ Show-FilesFolder })

$btnStartServer.Add_Click({
    Update-Progress -Text 'Starting the server...' -Indeterminate
    Action-StartServer | Out-Null
    Update-ServerStateLabel
    Update-Steps
    Update-Progress -Text 'Server: started.' -Done 0 -Total 0
})

$btnStopServer.Add_Click({
    Update-Progress -Text 'Stopping the server...' -Indeterminate
    Action-StopServer | Out-Null
    Update-ServerStateLabel
    Update-Steps
    Update-Progress -Text 'Server: stopped.' -Done 0 -Total 0
})

$btnRestartServer.Add_Click({
    Update-Progress -Text 'Restarting the server...' -Indeterminate
    Action-RestartServer | Out-Null
    Update-ServerStateLabel
    Update-Steps
    Update-Progress -Text 'Server: restarted.' -Done 0 -Total 0
})

# ---- keyboard -----------------------------------------------------
# Enter activates the primary button through AcceptButton (disabled while a
# setup runs, so a second key press cannot cancel by accident). Escape cancels
# a running setup, or closes the window when nothing is running.
$form.KeyPreview = $true
$form.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
        if ($Script:Running) {
            Request-Cancel
        } else {
            $form.Close()
        }
        $_.SuppressKeyPress = $true
    }
})

# Closing the window while a setup runs would leave a download half-written in
# a disposed window: ask the operation to stop, then close when it has stopped.
$form.Add_FormClosing({
    if ($Script:Running) {
        $_.Cancel = $true
        Request-Cancel
    }
})

$form.Add_Shown({
    Write-Log ("Cage Setup " + $Script:AppVersion + " started.") 'STEP'
    if (-not (Test-Admin)) { Write-Log 'Tip: run as administrator to install MuMu Player.' 'WARN' }
    if ($Script:DpiAware) {
        Write-Log ("Display: $($Script:Dpi) DPI, window scale $([math]::Round($Script:Scale, 2))")
    } else {
        Write-Log 'Display: DPI awareness not available, Windows may scale the window.' 'WARN'
    }

    # A scaled window may not fit on a small screen: keep it reachable.
    $area = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $frameW = $form.Width - $form.ClientSize.Width
    $frameH = $form.Height - $form.ClientSize.Height
    $maxW = $area.Width - $frameW - 8
    $maxH = $area.Height - $frameH - 8
    if (($form.ClientSize.Width -gt $maxW) -or ($form.ClientSize.Height -gt $maxH)) {
        $form.AutoScroll = $true
        $form.ClientSize = New-Object Drawing.Size(
            [Math]::Min($form.ClientSize.Width, $maxW),
            [Math]::Min($form.ClientSize.Height, $maxH))
        Write-Log ("Window reduced to $($form.ClientSize.Width)x$($form.ClientSize.Height) to fit the screen.")
    }

    $form.Activate()
    $form.TopMost = $true
    $form.TopMost = $false

    Update-Progress -Text 'Checking the current status...' -Indeterminate
    Update-Steps
    Update-ServerStateLabel
    Update-Progress -Text 'Ready.' -Done 0 -Total 0
    Start-UpdateCheck
})

try {
    [void]$form.ShowDialog()
} finally {
    if ($Script:HasInstanceMutex -and $Script:InstanceMutex) {
        try { $Script:InstanceMutex.ReleaseMutex() } catch { Write-Verbose "Mutex release failed: $($_.Exception.Message)" }
    }
    if ($Script:InstanceMutex) { $Script:InstanceMutex.Dispose() }
}
