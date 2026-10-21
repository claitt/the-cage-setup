# Installation actions and the grouped steps
# (moved out of Cage Setup.ps1; the build script inlines it again)

# =====================================================================
#  INSTALLATION ACTIONS
# =====================================================================
function Watch-MuMuInstall {
    param(
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
        if ($Script:CancelRequested) { return 'cancelled' }
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

    # the installer runs elevated: check who signed it before handing it UAC
    if (-not (Confirm-SignedInstaller -Path $setup -Publisher 'Netease' -Label 'MuMu Player installer')) {
        Write-Log 'Emulator: installation cancelled, the MuMu installer signature is not trusted.' 'ERROR'
        return $false
    }

    # 1st attempt: silent (hidden window). 2nd attempt: visible, if the first gets stuck.
    foreach ($attempt in 1..2) {
        $hide = ($attempt -eq 1)
        if ($hide) {
            Write-Log 'Emulator: starting the silent installation (/S). The MuMu window will be hidden.'
        } else {
            Write-Log 'Second attempt with the window VISIBLE (the first attempt was stuck).' 'WARN'
        }
        [int64]$before = Get-FolderSize $Paths.MuMuDir
        Start-Process -FilePath $setup -ArgumentList '/S', '/fchannel=gw-overseas12', '/auto_start=false' -Verb RunAs | Out-Null
        $result = Watch-MuMuInstall -InitialSize $before -Hide:$hide
        if ($result -eq 'ok') { break }
        if ($result -eq 'cancelled') {
            Write-Log 'Emulator: installation cancelled, closing the MuMu setup.' 'WARN'
            Get-Process -Name $Script:HideProcessNames -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            return $false
        }
        if ($result -eq 'stall') {
            Write-Log 'Closing the MuMu processes and retrying with the window visible.' 'WARN'
            Get-Process -Name $Script:HideProcessNames -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
        }
        if ($result -eq 'timeout') { Write-Log 'Timed out while waiting for the MuMu installation.' 'WARN' }
    }

    if (Test-MuMuInstalled) {
        Initialize-EmulatorPaths
        Write-Log 'Emulator installed' 'OK'
        Write-Log ("Emulator folder: " + $Paths.MuMuDir)
        return $true
    }
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
        for ($i = 0; $i -lt 40; $i++) {
            if ($Script:CancelRequested) { return $false }
            Start-Sleep -Seconds 3
            if (Test-EmulatorRunning) { break }
            [Windows.Forms.Application]::DoEvents()
        }
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
    Send-Download -Url $url -Destination $zip -Label 'Server binaries' -Bytes $Config.ServerBytes | Out-Null

    if ($Config.ServerSha256 -and $url -eq $Config.ServerUrl) {
        Update-Progress -Text 'Verifying the server archive...' -Indeterminate
        $hash = (Get-FileHash $zip -Algorithm SHA256).Hash
        if ($hash -ne $Config.ServerSha256.ToUpper()) {
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            Write-Log "Server archive checksum mismatch: expected $($Config.ServerSha256), got $hash. The file was removed, please retry." 'ERROR'
            return $false
        }
        Write-Log 'Server archive verified (SHA256)' 'OK'
    } elseif ($Config.ServerSha256) {
        Write-Log 'Custom server URL: the pinned checksum was not applied.' 'WARN'
    }

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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '', Justification = 'The reference patched file is identified by its SHA1, as published by the upstream project.')]
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
        if ($_.Exception -is [System.OperationCanceledException]) { throw }
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
        $partialBytes = 0
        if (Test-Path "$archive.part") { $partialBytes = (Get-Item "$archive.part").Length }
        $needGB = Get-AssetsDiskRequirementGB -TotalBytes $Config.AssetsBytes -DownloadedBytes $partialBytes
        $free = Get-FreeSpaceGB
        if ($free -lt $needGB) {
            Write-Log "Not enough disk space: about $needGB GB free in the game files folder are required (you have $free GB)." 'ERROR'
            return $false
        }
        Send-Download -Url $Config.AssetsUrl -Destination $archive -Label 'Game assets (14.9 GB)' `
                      -Bytes $Config.AssetsBytes -Sha1 $Config.AssetsSha1 | Out-Null
    }

    New-Item -ItemType Directory -Force -Path $Paths.AssetsDir | Out-Null

    # Download and extraction need the disk at the same time; check again here,
    # after the download may have filled it.
    $needExtractGB = $Script:AssetsExtractGB + 2
    if ((Get-FreeSpaceGB) -lt $needExtractGB) {
        Write-Log "Not enough disk space: extracting the assets needs about $needExtractGB GB free in the game files folder (you have $(Get-FreeSpaceGB) GB)." 'ERROR'
        return $false
    }

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
        for ($i = 0; $i -lt 40; $i++) {
            if ($Script:CancelRequested) { return $false }
            Start-Sleep -Seconds 3
            if (Test-EmulatorRunning) { break }
            [Windows.Forms.Application]::DoEvents()
        }
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
    if (Test-ServerRunning) { Write-Log 'Server already running (ports 8003/8080/3000)' 'OK'; return $true }
    if (-not (Test-ServerFiles)) { Write-Log 'Server binaries are missing: download the game first' 'ERROR'; return $false }

    $conflicts = @(Get-ServerPortConflicts)
    if ($conflicts.Count -gt 0) {
        $details = @($conflicts | ForEach-Object { "port $($_.Port) is used by $($_.Name) (PID $($_.ProcessId))" })
        foreach ($detail in $details) { Write-Log "Cannot start the server: $detail." 'ERROR' }
        Show-Notice -Icon 'Error' -Message ("The server cannot start because another program is using its ports:`r`n`r`n- " +
            ($details -join "`r`n- ") + "`r`n`r`nClose that program and press Start again.")
        return $false
    }

    Assert-NotCancelled
    Start-Process -FilePath (Join-Path $Paths.ServerDir 'wizard.exe') -ArgumentList '--prefer-saved' -WorkingDirectory $Paths.ServerDir | Out-Null
    $Script:ServerCacheTime = [datetime]::MinValue
    for ($i = 0; $i -lt 30; $i++) {
        if ($Script:CancelRequested) { return $false }
        Start-Sleep -Seconds 1
        if (Test-ServerRunning) { break }
        [Windows.Forms.Application]::DoEvents()
    }
    if (Test-ServerRunning) { Write-Log 'Server started' 'OK'; return $true }
    Write-Log 'Server not detected on ports 8003/8080/3000' 'WARN'; return $false
}

function Action-StopServer {
    Write-Log 'Server: stopping' 'STEP'
    $procs = @(Get-ServerProcesses)
    if ($procs.Count -eq 0) { Write-Log 'Server is not running' 'OK'; return $true }
    foreach ($p in $procs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    $Script:ServerCacheTime = [datetime]::MinValue
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

