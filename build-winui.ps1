# Builds and publishes the WinUI 3 shell of Cage Setup 2.0.
#
#   powershell -ExecutionPolicy Bypass -File .\build-winui.ps1
#
# Requires the .NET SDK (installed by this script if missing under
# %USERPROFILE%\.dotnet) and network access to nuget.org on first build.
# The output is a self-contained EXE - no runtime install needed - in
# dist\winui\CageSetup2.exe.

$ErrorActionPreference = 'Stop'

$dotnet = Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
if (-not (Test-Path $dotnet)) {
    $tmp = Join-Path $env:TEMP 'dotnet-install.ps1'
    Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -UseBasicParsing -OutFile $tmp
    & $tmp -Channel 9.0 -InstallDir "$env:USERPROFILE\.dotnet"
    if (-not (Test-Path $dotnet)) { throw 'dotnet.exe was not installed.' }
}

$root = $PSScriptRoot
$project = Join-Path $root 'CageSetup.WinUI\CageSetup.WinUI.csproj'

$env:DOTNET_ROOT = Split-Path $dotnet
$env:PATH = "$env:DOTNET_ROOT;$env:PATH"

& $dotnet publish $project -c Release -p:Platform=x64
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE" }

$published = Join-Path $root 'CageSetup.WinUI\bin\x64\Release\net9.0-windows10.0.19041.0\win-x64\publish'
if (-not (Test-Path $published)) {
    $candidates = Get-ChildItem (Join-Path $root 'CageSetup.WinUI\bin') -Recurse -Directory -Filter 'publish'
    if ($candidates.Count -eq 0) { throw 'publish output folder not found.' }
    $published = $candidates[0].FullName
}

$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

# Kill leftovers whose working directory lives inside dist: an orphan
# adb.exe child (started by a killed app) keeps dist un-deletable even
# when its own executable lives outside the folder.
foreach ($name in @('CageSetup2', 'adb', 'wizard', 'auth-server', 'octo-cdn', 'lunar-tear')) {
    Get-Process -Name $name -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 500

if (Test-Path $dist\CageSetup2) { Remove-Item $dist\CageSetup2 -Recurse -Force }
Copy-Item $published $dist\CageSetup2 -Recurse

$exe = Join-Path $dist 'CageSetup2\CageSetup2.exe'
$size = [math]::Round((Get-Item $exe).Length / 1MB, 1)
$total = [math]::Round((Get-ChildItem $dist\CageSetup2 -Recurse | Measure-Object Length -Sum).Sum / 1MB, 1)
Write-Host "Built $exe (exe $size MB, folder $total MB)"
