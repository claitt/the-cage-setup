# Builds the single-file script and, with -Pack, the executable.
#
# TODO: ps2exe embeds a build timestamp, so the same source produces a different
# SHA256 on every machine. If ps2exe ever exposes a deterministic switch, use it
# here; until then the README says that local hashes differ from the CI one.
#
# The sources are "Cage Setup.ps1" plus lib\*.ps1. The installer is meant to be
# a single file, so this script inlines the modules back into
# dist\CageSetup.bundled.ps1 before ps2exe sees it. Nothing here changes the
# code: the bundle is byte-for-byte the sources, only reassembled.
#
#   powershell -ExecutionPolicy Bypass -File build.ps1          # bundle only
#   powershell -ExecutionPolicy Bypass -File build.ps1 -Pack    # bundle + exe
#
# The workflow runs the second form on every tag.

[CmdletBinding()]
param(
    [switch]$Pack
)

$ErrorActionPreference = 'Stop'

$repo       = $PSScriptRoot
$mainPath   = Join-Path $repo 'Cage Setup.ps1'
$libDir     = Join-Path $repo 'lib'
$dist       = Join-Path $repo 'dist'
$bundlePath = Join-Path $dist 'CageSetup.bundled.ps1'

$main = Get-Content -Raw -LiteralPath $mainPath
$startMarker = '# @@LIBS-START'
$endMarker   = '# @@LIBS-END'
$start = $main.IndexOf($startMarker)
$end   = $main.IndexOf($endMarker)
if ($start -lt 0 -or $end -lt 0) {
    throw "The module markers ($startMarker / $endMarker) are missing from Cage Setup.ps1"
}

$header = $main.Substring(0, $start)
$body   = $main.Substring($end + $endMarker.Length)

$parts = foreach ($lib in (Get-ChildItem $libDir -Filter '*.ps1' | Sort-Object Name)) {
    $text = Get-Content -Raw -LiteralPath $lib.FullName
    "# =====================================================================`r`n" +
    "#  lib\$($lib.Name)`r`n" +
    "# =====================================================================`r`n" +
    $text.TrimEnd() + "`r`n`r`n"
}

$bundle = $header + ($parts -join '') + $body
New-Item -ItemType Directory -Force -Path $dist | Out-Null
[System.IO.File]::WriteAllText($bundlePath, $bundle, (New-Object System.Text.UTF8Encoding($true)))
Write-Host "Bundled script: $bundlePath ($((Get-Item $bundlePath).Length) bytes)"

$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($bundlePath, [ref]$null, [ref]$parseErrors) | Out-Null
if ($parseErrors) {
    $parseErrors | ForEach-Object { Write-Host "ERROR line $($_.Extent.StartLineNumber): $($_.Message)" }
    throw 'The bundled script does not parse. Captured above.'
}

if (-not $Pack) { return }

if (-not (Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue)) {
    throw 'ps2exe is not installed. Run: Install-Module ps2exe -Scope CurrentUser'
}

$version = [regex]::Match($main, '(?m)^\$Script:AppVersion\s*=\s*''([^'']+)''').Groups[1].Value
if (-not $version) { throw '$Script:AppVersion not found in Cage Setup.ps1' }

$exe = Join-Path $dist 'CageSetup.exe'
Invoke-PS2EXE -InputFile $bundlePath -OutputFile $exe -noConsole -requireAdmin -STA `
    -iconFile (Join-Path $repo 'assets\cage.ico') `
    -title 'Cage Setup' -product 'Cage Setup' `
    -description 'Guided installer for the NieR Re[in]carnation private server' `
    -company 'Cage Setup contributors' `
    -version "$version.0"

$file = Get-Item $exe
Write-Host ("EXE: {0} bytes, version {1}, SHA256 {2}" -f `
    $file.Length, $file.VersionInfo.FileVersion, (Get-FileHash $exe -Algorithm SHA256).Hash)
