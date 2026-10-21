# Utilities: signatures, disk space, ports, data folder
# (moved out of Cage Setup.ps1; the build script inlines it again)

# =====================================================================
#  UTILITIES
# =====================================================================
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---- cancellation ---------------------------------------------------
# The primary button turns into "Cancel setup" while the steps run and sets
# this flag. Long operations call Assert-NotCancelled so they stop promptly;
# downloaded .part files are kept, so pressing Start setup later resumes.

function Assert-NotCancelled {
    if ($Script:CancelRequested) { throw [System.OperationCanceledException]::new('Cancelled by the user.') }
}

# Shows a message box only when a user is looking at the window.
function Show-Notice {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Information','Warning','Error')][string]$Icon = 'Warning'
    )
    if ($Console -or $InstallAll) { return }
    [System.Windows.Forms.MessageBox]::Show($Message, 'Cage Setup', 'OK', $Icon) | Out-Null
}

# GB that must be free before the assets archive is downloaded and extracted.
# Download and extraction need the disk at the same time, so both count.
function Get-AssetsDiskRequirementGB {
    param(
        [int64]$TotalBytes = 0,
        [int64]$DownloadedBytes = 0
    )
    $remaining = [math]::Max([int64]0, [int64]($TotalBytes - $DownloadedBytes))
    return [int]($Script:AssetsExtractGB + [math]::Ceiling($remaining / 1GB) + 2)
}


# One installer per folder, so two windows cannot fight over the same
# downloads and ports. The name is derived from the folder: installs in
# different folders stay allowed.
function Get-InstanceMutexName {
    param([Parameter(Mandatory)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path.TrimEnd('\').ToLowerInvariant())
        $hash = [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
    return 'Local\CageSetup-' + $hash.Substring(0, 16)
}

# True when $Latest is a valid version and is newer than $Current.
function Test-NewerVersion {
    param([string]$Current, [string]$Latest)
    $a = $null
    $b = $null
    if (-not [version]::TryParse($Current, [ref]$a)) { return $false }
    if (-not [version]::TryParse($Latest, [ref]$b)) { return $false }
    return ($b -gt $a)
}

# Checks the Authenticode signature of a downloaded installer. Returns $true
# only for a valid signature from one of the expected publishers.
function Test-Signature {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Publisher = @()
    )
    if (-not (Test-Path $Path)) { return $false }
    try {
        $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
    } catch {
        Write-Log "Signature check failed for $Path ($($_.Exception.Message))" 'WARN'
        return $false
    }
    if ($sig.Status -ne 'Valid' -or -not $sig.SignerCertificate) {
        Write-Log "Signature check: $(Split-Path $Path -Leaf) is not validly signed ($($sig.Status))." 'WARN'
        return $false
    }
    $subject = $sig.SignerCertificate.Subject
    if ($Publisher.Count -gt 0) {
        $match = $false
        foreach ($name in $Publisher) { if ($subject -like "*$name*") { $match = $true } }
        if (-not $match) {
            Write-Log "Signature check: unexpected publisher for $(Split-Path $Path -Leaf) ($subject)." 'WARN'
            return $false
        }
    }
    Write-Log "Signature verified: $(Split-Path $Path -Leaf) ($subject)" 'OK'
    return $true
}

# Runs the signature check and, when it fails, asks before running an untrusted
# installer. In console mode a failed check always aborts.
function Confirm-SignedInstaller {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Publisher,
        [string]$Label = 'installer'
    )
    if (Test-Signature -Path $Path -Publisher @($Publisher)) { return $true }
    if ($Console -or $InstallAll) {
        Write-Log "Refusing to run the ${Label}: the signature check failed (non-interactive mode)." 'ERROR'
        return $false
    }
    $message = "The $Label is not signed by $Publisher, or its signature is not valid." + "`r`n`r`n" +
               "File: $Path" + "`r`n`r`n" +
               'Continue anyway? Only do this if you downloaded it from the official source.'
    $answer = [System.Windows.Forms.MessageBox]::Show($message, 'Cage Setup', 'YesNo', 'Warning')
    return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
}

# Free space on the drive that holds the game files (not necessarily C:).
function Get-FreeSpaceGB {
    param([string]$Path = $Root)
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $drive = New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($full))
        return [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    } catch {
        try { [math]::Round((Get-PSDrive C -ErrorAction Stop).Free / 1GB, 1) } catch { 0 }
    }
}

function Get-FolderSize {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    (Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
}

# ---- game files folder ----------------------------------------------
# The window can point the whole installation at another folder: an earlier
# install, a disk with more space, or a folder where the files were downloaded.
# Every path below is derived from $Root, so switching is a matter of rewriting
# the map and the status checks follow.
function Set-DataRoot {
    param([Parameter(Mandatory)][string]$Path)
    $full = Get-NormalFolderPath -Path $Path
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "Folder not found: $full"
    }
    $script:Root = $full
    $map = Get-DataPathMap -Base $full
    foreach ($key in $map.Keys) {
        if ($Config.ContainsKey($key)) { $Config[$key] = $map[$key] }
        if ($Paths.ContainsKey($key)) { $Paths[$key] = $map[$key] }
    }
    # an archive saved straight into the chosen folder is used as well
    $standard = $Config.AssetsArchive
    $bare = Join-Path $full 'resource_dump_android.7z'
    if (-not (Test-Path -LiteralPath $standard) -and (Test-Path -LiteralPath $bare)) {
        $Config.AssetsArchive = $bare
    }
    $Script:MasterHash = $null
    $Script:EmulatorCacheTime = [datetime]::MinValue
    $Script:ServerCacheTime = [datetime]::MinValue
    return $full
}

function Save-DataRoot {
    $file = Join-Path $Script:AppDir 'data-folder.txt'
    try {
        if ($script:Root -eq $Script:AppDir) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        } else {
            Set-Content -LiteralPath $file -Value $script:Root -Encoding UTF8
        }
    } catch {
        Write-Log ("The game files folder cannot be remembered next to the installer: " + $_.Exception.Message) 'WARN'
    }
}

# What a folder already contains, shown before switching to it. The "missing"
# part is the actual plan, not a checklist: the stock APK and the build toolchain
# are only listed when the patched client has to be built, and the archive is
# not requested when the assets are already extracted.
function Get-FilesFolderReport {
    param([Parameter(Mandatory)][string]$Path)

    $server = (Test-Path -LiteralPath (Join-Path $Path 'server\wizard.exe')) -and
        (Test-Path -LiteralPath (Join-Path $Path 'server\bin'))
    $revisions = Join-Path $Path 'server\assets\revisions'
    $assets = (Test-Path -LiteralPath $revisions) -and
        [bool](Get-ChildItem -LiteralPath $revisions -Directory -ErrorAction SilentlyContinue | Select-Object -First 1)
    $master = Test-Path -LiteralPath (Join-Path $Path 'server\assets\release\20240404193219.bin.e')
    $archive = @(
        (Join-Path $Path 'downloads\resource_dump_android.7z'),
        (Join-Path $Path 'resource_dump_android.7z')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $stock = Test-Path -LiteralPath (Join-Path $Path 'apk\stock\nier-3.7.1-stock.apk')
    $client = @(
        (Join-Path $Path 'apk\out\nier-patched.apk'),
        (Join-Path $Path 'apk\out\nier_aligned.apk'),
        (Join-Path $Path 'client-nier-reincarnation-patched.apk')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $toolchain = (Test-Path -LiteralPath (Join-Path $Path 'tools\jdk')) -or
        (Test-Path -LiteralPath (Join-Path $Path 'tools\apktool.jar'))

    $found = @()
    if ($server) { $found += 'server binaries' }
    if ($assets) { $found += 'extracted game assets' }
    if ($master) { $found += 'master data' }
    if ($archive) {
        $size = (Get-Item -LiteralPath $archive).Length
        $label = 'game assets archive (' + (Format-Size $size) + ')'
        if ($Config.AssetsBytes -and $size -ne $Config.AssetsBytes) {
            $label = 'game assets archive (' + (Format-Size $size) + ', expected ' + (Format-Size $Config.AssetsBytes) + ')'
        }
        $found += $label
    }
    if ($stock) { $found += 'stock APK' }
    if ($client) { $found += 'patched client' }
    if ($toolchain) { $found += 'build toolchain' }

    $missing = @()
    if (-not $server) { $missing += 'server binaries' }
    if (-not $master) { $missing += 'master data' }
    if (-not $assets) {
        if ($archive) { $missing += 'extract the game assets' }
        else { $missing += 'game assets archive (14.9 GB)' }
    }
    if (-not $client) {
        if (-not $stock) { $missing += 'stock APK' }
        $missing += 'patched client (built from the stock APK)'
        $missing += 'build toolchain (Java, apktool, Android build tools, Python)'
    }

    return [pscustomobject]@{
        Path    = Get-NormalFolderPath -Path $Path
        Found   = [string[]]$found
        Missing = [string[]]$missing
    }
}

function Format-FilesFolderStatus {
    param([Parameter(Mandatory)]$Report)
    if ($Report.Found.Count -gt 0) {
        $text = 'Found: ' + ($Report.Found -join ', ')
    } else {
        $text = 'No Cage Setup files here yet.'
    }
    if ($Report.Missing.Count -gt 0) {
        $text += "`r`nStill to do: " + ($Report.Missing -join ', ')
    } else {
        $text += "`r`nEverything is already there."
    }
    return $text
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
# MuMu lets you choose the installation folder and the folder name changes
# between versions, so it is discovered instead of hardcoded: uninstall
# entries first, then the usual folders.
function Find-MuMuDir {
    $candidates = @()
    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $info = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
            if ($info -and $info.DisplayName -match 'MuMu' -and $info.InstallLocation) {
                $candidates += [string]$info.InstallLocation
            }
        }
    }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $base) { continue }
        $candidates += Join-Path $base 'Netease\MuMuPlayer'
        $candidates += @(Get-ChildItem (Join-Path $base 'Netease') -Directory -Filter 'MuMuPlayer*' -ErrorAction SilentlyContinue |
                         Select-Object -Expand FullName)
    }
    foreach ($dir in $candidates) {
        if (-not $dir) { continue }
        $dir = ([string]$dir).Trim().Trim('"').TrimEnd('\')
        if (Test-Path (Join-Path $dir 'nx_main\MuMuManager.exe')) { return $dir }
    }
    return $null
}

# The ADB binary ships inside the Android engine folder, one per engine
# version: use the newest one instead of whatever the recursion finds first.
function Find-AdbExe {
    param([string]$MuMuDir)
    $candidates = @()
    if ($MuMuDir) {
        $device = Join-Path $MuMuDir 'nx_device'
        if (Test-Path $device) {
            $dirs = @(Get-ChildItem $device -Directory -ErrorAction SilentlyContinue)
            $sorted = $dirs | Sort-Object -Property @{ Expression = {
                $v = $null
                if ([version]::TryParse($_.Name, [ref]$v)) { $v } else { [version]'0.0' }
            } } -Descending
            foreach ($dir in $sorted) { $candidates += Join-Path $dir.FullName 'shell\adb.exe' }
        }
    }
    $candidates += Join-Path $Root 'tools\android-sdk\platform-tools\adb.exe'
    foreach ($file in $candidates) {
        if ($file -and (Test-Path $file)) { return $file }
    }
    return $null
}

# Refreshes $Paths after an installation; also called once at startup.
function Initialize-EmulatorPaths {
    $mumu = Find-MuMuDir
    if ($mumu) {
        $Paths.MuMuDir = $mumu
        $Paths.MuMuManager = Join-Path $mumu 'nx_main\MuMuManager.exe'
    }
    $Paths.Adb = Find-AdbExe $Paths.MuMuDir
}

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
    $Paths.Adb = Find-AdbExe $Paths.MuMuDir
    $Paths.Adb
}

# Small cache: a status refresh asks this several times and every ADB call costs
# about a second, which would freeze the window while refreshing.

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

function Get-PcIssues {
    $why = @()
    if (-not [Environment]::Is64BitOperatingSystem) { $why += 'Windows must be 64-bit' }
    if (-not (Test-VirtualizationEnabled)) { $why += 'virtualization (VT-x / AMD-V) must be enabled in the BIOS' }
    if ((Get-FreeSpaceGB) -lt 25) { $why += 'at least 25 GB of free space in the game files folder are required' }
    if (Test-HyperVActive) { $why += 'Hyper-V must be disabled' }
    if (-not (Test-Admin)) { $why += 'run the installer as administrator' }
    return $why
}

# TODO: the first status refresh takes about 7 seconds because every ADB probe
# costs roughly a second and the closed server ports add more. The cache in
# Test-EmulatorRunning / Test-ServerRunning helps within one refresh, but the
# first pass still blocks. Run the independent probes in parallel (or with a
# single ADB call) so the window updates immediately.
function Get-StepStatus {
    param([string]$Key)
    switch ($Key) {
        'pc' {
            if (-not [Environment]::Is64BitOperatingSystem) { return 'error' }
            if (-not (Test-VirtualizationEnabled)) { return 'error' }
            if ((Get-FreeSpaceGB) -lt 25) { return 'error' }
            if (Test-HyperVActive) { return 'warn' }
            if (-not (Test-Admin)) { return 'warn' }
            return 'ok'
        }
        'emulator' {
            if ((Test-MuMuInstalled) -and (Test-MuMuEngine) -and (Test-EmulatorRunning) -and (Test-DebloatApplied)) { return 'ok' }
            return 'pending'
        }
        'files' {
            if ((Test-ServerFiles) -and (Test-MasterData) -and (Test-GameAssets) -and [bool](Get-ClientApkPath)) { return 'ok' }
            return 'pending'
        }
        'client' {
            if (Test-GameInstalled) { return 'ok' }
            return 'pending'
        }
        'server' {
            if (Test-ServerRunning) { return 'ok' }
            return 'pending'
        }
        'play' {
            if ((Test-GameInstalled) -and (Test-ServerRunning)) { return 'ok' }
            return 'pending'
        }
        default { return 'pending' }
    }
}


# ---- server ---------------------------------------------------------
function Test-ServerFiles {
    (Test-Path $Config.ServerExe) -and (Test-Path (Join-Path $Paths.ServerDir 'bin'))
}

function Get-MasterDataHash {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '', Justification = 'SHA1 is the identifier published with the master data; it is not a security boundary.')]
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
    # same idea as the emulator cache: a single status refresh asks this three
    # times, and probing two closed ports is slow on some machines
    $now = Get-Date
    if (($now - $Script:ServerCacheTime).TotalSeconds -lt 3) { return $Script:ServerCache }
    $result = (Test-PortOpen 8003) -and (Test-PortOpen 8080)
    $Script:ServerCache = $result
    $Script:ServerCacheTime = $now
    return $result
}

function Get-ServerProcesses {
    $found = @()
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        try {
            $path = $p.Path
            if ($path -and $path.StartsWith($Paths.ServerDir, [System.StringComparison]::OrdinalIgnoreCase)) {
                $found += $p
            }
        } catch {
            Write-Verbose "Cannot read the path of process $($p.Id): $($_.Exception.Message)"
        }
    }
    $found
}

# ---- ports ---------------------------------------------------------
# Returns the process listening on a TCP port, or $null. Get-NetTCPConnection
# exists since Windows 8; netstat is the fallback for unusual systems.
# FIXME: the fallback only runs when Get-NetTCPConnection throws. On a machine
# where the cmdlet succeeds but returns nothing (some loopback sockets), netstat
# would have found the listener and the conflict is missed. Fall back on an empty
# result too, not only on an exception.
function Get-PortOwner {
    param([Parameter(Mandatory)][int]$Port)
    $ownerId = 0
    try {
        # Listening sockets have no remote port. The State property is not used:
        # some network stacks report it as empty for loopback sockets.
        $conn = Get-NetTCPConnection -LocalPort $Port -ErrorAction Stop |
                Where-Object { $_.RemotePort -eq 0 } | Select-Object -First 1
        if ($conn) { $ownerId = [int]$conn.OwningProcess }
    } catch {
        # Fallback for systems without Get-NetTCPConnection: read netstat, without
        # matching the (localized) state word.
        foreach ($line in @(netstat -ano -p tcp 2>$null)) {
            if ($line -match "^\s*TCP\s+\S+:$Port\s+\S+:0\s+\S+\s+(\d+)\s*$") { $ownerId = [int]$Matches[1]; break }
        }
    }
    if ($ownerId -le 0) { return $null }

    $name = 'unknown'
    $path = ''
    try {
        $proc = Get-Process -Id $ownerId -ErrorAction Stop
        $name = $proc.ProcessName
        $path = $proc.Path
    } catch {
        Write-Verbose "Cannot read the process listening on port $Port (PID $ownerId)."
    }
    [pscustomobject]@{ Port = $Port; ProcessId = $ownerId; Name = $name; Path = $path }
}

# Ports held by something other than this installation's server. Starting the
# server in that case fails deep inside wizard.exe, so the installer says it
# up front and names the process.
function Get-ServerPortConflicts {
    param([int[]]$Ports = $Script:ServerPorts)
    $prefix = $Paths.ServerDir.TrimEnd('\') + '\'
    $conflicts = @()
    foreach ($port in $Ports) {
        $owner = Get-PortOwner -Port $port
        if (-not $owner) { continue }
        if ($owner.Path -and $owner.Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $conflicts += $owner
    }
    return $conflicts
}

