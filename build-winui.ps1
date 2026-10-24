# Builds and publishes the WinUI 3 shell of Cage Setup 2.0.
#
#   powershell -ExecutionPolicy Bypass -File .\build-winui.ps1
#
# Requires the .NET SDK (installed by this script if missing under
# %USERPROFILE%\.dotnet) and network access to nuget.org on first build.
# The output is a self-contained EXE - no runtime install needed - in
# dist\TheCageSetup\TheCageSetup.exe.
#
# After publishing, the EXE is started once with --smoke-test: it must load
# the shell and exit on its own. Pass -SkipSmokeTest for a headless machine.

param(
    [switch]$SkipSmokeTest
)

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

# Only processes running from dist are stopped: the installed copy and its
# private server must keep running. An orphan adb.exe is the one exception,
# because the app leaves it with dist as its working directory and Windows
# then refuses to delete the folder. adb is stateless: its server restarts
# on demand.
$distPrefix = $dist.TrimEnd('\') + '\'
Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        if ($_.Path -and $_.Path.StartsWith($distPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Protected processes cannot be inspected: not ours anyway.
    }
}
Get-Process -Name 'adb' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

if (Test-Path $dist\TheCageSetup) { Remove-Item $dist\TheCageSetup -Recurse -Force }
Copy-Item $published $dist\TheCageSetup -Recurse

$exe = Join-Path $dist 'TheCageSetup\TheCageSetup.exe'
$version = (Get-Item $exe).VersionInfo.ProductVersion
$size = [math]::Round((Get-Item $exe).Length / 1MB, 1)
Write-Host "Built $exe (version $version, exe $size MB)"

if (-not $SkipSmokeTest) {
    # A publish can succeed while the single-file bundle is missing a payload
    # and the window never appears. --step 1 loads a real page; --smoke-test
    # closes the window after the shell is loaded, so no interaction is needed.
    $smoke = Start-Process -FilePath $exe -ArgumentList '--step', '1', '--smoke-test' `
        -WorkingDirectory (Split-Path $exe) -PassThru

    if (-not $smoke.WaitForExit(30000)) {
        Stop-Process -Id $smoke.Id -Force -ErrorAction SilentlyContinue
        throw 'Smoke test: the app did not exit within 30 seconds.'
    }
    if ($smoke.ExitCode -ne 0) {
        throw "Smoke test: the app exited with code $($smoke.ExitCode)."
    }

    # The run writes its log next to the EXE; keep dist identical to publish.
    Remove-Item (Join-Path $dist 'TheCageSetup\cage.log') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $dist 'TheCageSetup\cage.log.old') -Force -ErrorAction SilentlyContinue
    Write-Host 'Smoke test: the shell loaded and exited cleanly.'
}
