# Builds the installer: publishes the app, then wraps it with Inno Setup.
#
#   powershell -ExecutionPolicy Bypass -File .\build-installer.ps1
#
# Requires Inno Setup 6 (ISCC.exe). The installer ends up in
# dist\installer\TheCageSetup-<version>-setup.exe.

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot

& (Join-Path $root 'build-winui.ps1')
if ($LASTEXITCODE -ne 0) { throw "build-winui.ps1 failed with exit code $LASTEXITCODE" }

$iscc = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $iscc) {
    throw 'ISCC.exe not found. Install Inno Setup 6 (winget install JRSoftware.InnoSetup).'
}

# One source of truth for the version: the WinUI project.
$csproj = Join-Path $root 'CageSetup.WinUI\CageSetup.WinUI.csproj'
$version = ([xml](Get-Content $csproj)).Project.PropertyGroup.Version |
    Where-Object { $_ } | Select-Object -First 1
if (-not $version) { throw "No <Version> in $csproj" }

& $iscc "/DAppVersion=$version" (Join-Path $root 'installer\TheCageSetup.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }

$setup = Get-ChildItem (Join-Path $root 'dist\installer') -Filter "TheCageSetup-$version-setup.exe" |
    Select-Object -First 1
Write-Host "Installer: $($setup.FullName) ($([math]::Round($setup.Length / 1MB, 1)) MB)"
