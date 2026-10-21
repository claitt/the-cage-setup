# Path helpers
# (moved out of Cage Setup.ps1; the build script inlines it again)

# Absolute path without the trailing separator; a drive root ("D:\") is kept.
function Get-NormalFolderPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

# Absolute paths that follow the game files folder: Set-DataRoot rewrites them
# when the user reuses an existing installation. Keys match $Config and $Paths.
function Get-DataPathMap {
    param([Parameter(Mandatory)][string]$Base)
    return @{
        ServerExe        = Join-Path $Base 'server\wizard.exe'
        MasterFile       = Join-Path $Base 'server\assets\release\20240404193219.bin.e'
        AssetsArchive    = Join-Path $Base 'downloads\resource_dump_android.7z'
        ApkStockFile     = Join-Path $Base 'apk\stock\nier-3.7.1-stock.apk'
        ApkWorkDir       = Join-Path $Base 'apk\work'
        ApkOutput        = Join-Path $Base 'apk\out\nier-patched.apk'
        Keystore         = Join-Path $Base 'apk\out\debug.keystore'
        MuMuInstaller    = Join-Path $Base 'tools\mumu\MuMu-installer.exe'
        MuMuInstallerOff = Join-Path $Base 'tools\mumu\offline\MuMuNG-offline-setup.exe'
        SevenZip         = Join-Path $Base 'tools\7zr.exe'
        ServerDir        = Join-Path $Base 'server'
        AssetsDir        = Join-Path $Base 'server\assets'
        Downloads        = Join-Path $Base 'downloads'
        JdkDir           = Join-Path $Base 'tools\jdk'
        ApktoolJar       = Join-Path $Base 'tools\apktool.jar'
        BuildToolsDir    = Join-Path $Base 'tools\build-tools'
        PythonDir        = Join-Path $Base 'tools\python'
        ScriptsDir       = Join-Path $Base 'tools\lunar-scripts'
    }
}
