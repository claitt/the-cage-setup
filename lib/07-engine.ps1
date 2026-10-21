# Execution engine and diagnostics block
# (moved out of Cage Setup.ps1; the build script inlines it again)

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


# =====================================================================
#  SUPPORT: one copyable block for issue reports
# =====================================================================
function Get-DiagnosticsText {
    $dpi = if ($Script:Dpi) { $Script:Dpi } else { 96 }
    $scale = if ($Script:Scale) { $Script:Scale } else { 1 }
    $lines = @()
    $lines += 'Cage Setup ' + $Script:AppVersion + ' - diagnostics'
    $lines += 'Generated  : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $lines += 'Windows    : ' + [Environment]::OSVersion.Version + ' (' + [Environment]::OSVersion.VersionString + ')'
    $lines += '64-bit     : ' + [Environment]::Is64BitOperatingSystem
    $lines += 'Admin      : ' + (Test-Admin)
    $lines += 'Virtualiz. : ' + (Test-VirtualizationEnabled)
    $lines += 'Hyper-V    : ' + (Test-HyperVActive)
    $lines += 'Free space : ' + (Get-FreeSpaceGB) + ' GB on the game files drive'
    $lines += 'Display    : ' + $dpi + ' DPI (scale ' + [math]::Round($scale, 2) + ')'
    $lines += 'Root       : ' + $Root
    $lines += ''

    if ($Script:Steps) {
        $lines += 'Steps:'
        foreach ($step in $Script:Steps) {
            $lines += '  ' + $step.Number + '. ' + $step.Title + ' = ' + $step.Status
        }
        $lines += ''
    }

    $lines += 'MuMu       : ' + (Test-MuMuInstalled) + ' (' + $Paths.MuMuDir + ')'
    $lines += 'ADB        : ' + (Get-Adb)
    $lines += 'Emulator   : running=' + (Test-EmulatorRunning) + ' client=' + (Test-GameInstalled) + ' debloat=' + (Test-DebloatApplied)
    $lines += 'Server     : files=' + (Test-ServerFiles) + ' running=' + (Test-ServerRunning)
    $lines += 'Master data: ' + (Test-MasterData)
    $lines += 'Assets     : ' + (Test-GameAssets)
    $lines += 'Client APK : ' + (Get-ClientApkPath)
    $lines += 'Toolchain  : java=' + [bool](Get-JavaExe) + ' apktool=' + (Test-Path $Paths.ApktoolJar) +
              ' python=' + (Test-Path (Join-Path $Paths.PythonDir 'python.exe'))
    $lines += ''

    $tail = @(Get-LogTail -Path $LogFile -Lines 40 -Bytes 65536)
    if ($tail.Count -gt 0) {
        $lines += 'Log (last ' + $tail.Count + ' lines):'
        $lines += $tail
    } else {
        $lines += 'Log: empty'
    }
    return ($lines -join "`r`n")
}

