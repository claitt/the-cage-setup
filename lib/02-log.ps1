# Log
# (moved out of Cage Setup.ps1; the build script inlines it again)

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
