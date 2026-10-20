# Pester tests for the installer logic.
#
# They load "Cage Setup.ps1" without running the GUI or the console entry
# point, then check the parts that do not need an emulator or the game files.
#
#   Install-Module Pester -Scope CurrentUser -RequiredVersion 5.7.1
#   Invoke-Pester -Path tests -Output Detailed

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $env:CAGE_SETUP_ROOT = $script:Repo

    $source = Get-Content -Raw (Join-Path $script:Repo 'Cage Setup.ps1')
    $cut = $source.IndexOf('#  CONSOLE / DIAGNOSTICS')
    if ($cut -lt 0) { throw 'Marker "#  CONSOLE / DIAGNOSTICS" not found in Cage Setup.ps1' }
    $logic = $source.Substring(0, $cut) -replace '(?m)^#Requires -Version 5\.1\s*$', ''
    . ([scriptblock]::Create($logic))
}

Describe 'Download sources' {
    It 'uses HTTPS for every download' {
        $keys = 'MuMuInstallerUrl', 'AssetsUrl', 'MasterUrl', 'ApkPageUrl',
                'JreUrl', 'ApktoolUrl', 'BuildToolsUrl', 'PythonUrl'
        foreach ($key in $keys) {
            $Config[$key] | Should -Match '^https://'
        }
    }

    It 'pins lunar-scripts to a commit' {
        $Config.ScriptsRaw | Should -Match '/raw/[0-9a-f]{40}$'
    }

    It 'pins the server archive to a release, with its size and checksum' {
        $Config.ServerUrl | Should -Match '/releases/download/v\d+\.\d+\.\d+/'
        $Config.ServerBytes | Should -BeGreaterThan 0
        $Config.ServerSha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'uses the pinned archive as the offline fallback too' {
        $Config.ServerUrlFallback | Should -Be $Config.ServerUrl
    }
}

Describe 'Working folders' {
    It 'keeps everything inside the folder of the installer' {
        $keys = 'ServerDir', 'AssetsDir', 'Downloads', 'JdkDir', 'BuildToolsDir', 'PythonDir', 'ScriptsDir'
        foreach ($key in $keys) {
            $Paths[$key] | Should -BeLike "$Root*"
        }
    }

    It 'writes installer-log.txt next to the installer' {
        $LogFile | Should -Be (Join-Path $Root 'installer-log.txt')
    }
}

Describe 'Game files folder' {
    It 'builds every path from the chosen base folder' {
        $map = Get-DataPathMap -Base 'D:\Games\Cage'
        foreach ($key in $map.Keys) {
            $map[$key] | Should -Match '^D:\\Games\\Cage\\'
        }
    }

    It 'keeps the path map in sync with the defaults' {
        $map = Get-DataPathMap -Base $Root
        foreach ($key in $map.Keys) {
            if ($Config.ContainsKey($key)) { $Config[$key] | Should -Be $map[$key] }
            if ($Paths.ContainsKey($key)) { $Paths[$key] | Should -Be $map[$key] }
        }
    }

    It 'reports the files it finds in a folder' {
        $dir = Join-Path $TestDrive 'existing'
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'server\assets\revisions\v1') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'server\bin') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'downloads') | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $dir 'server\wizard.exe') | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $dir 'server\assets\release\20240404193219.bin.e') | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $dir 'apk\out\nier-patched.apk') | Out-Null
        Set-Content -Path (Join-Path $dir 'downloads\resource_dump_android.7z') -Value 'x'

        $report = Get-FilesFolderReport -Path $dir
        $report.Found | Should -Contain 'server binaries'
        $report.Found | Should -Contain 'extracted game assets'
        $report.Found | Should -Contain 'master data'
        $report.Found | Should -Contain 'patched client'
        ($report.Found -join ' ') | Should -Match 'game assets archive'
        $report.Missing | Should -Contain 'stock APK'
        $report.Missing | Should -Contain 'build toolchain'
    }

    It 'also finds an archive saved at the root of the folder' {
        $dir = Join-Path $TestDrive 'bare'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -Path (Join-Path $dir 'resource_dump_android.7z') -Value 'x'
        ((Get-FilesFolderReport -Path $dir).Found -join ' ') | Should -Match 'game assets archive \('
    }

    It 'switches the paths to the chosen folder and back' {
        $dir = Join-Path $TestDrive 'other'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $original = $Root
        try {
            Set-DataRoot -Path $dir | Out-Null
            $Paths.ServerDir | Should -Be (Join-Path $dir 'server')
            $Config.ServerExe | Should -Be (Join-Path $dir 'server\wizard.exe')
            $Config.AssetsArchive | Should -Be (Join-Path $dir 'downloads\resource_dump_android.7z')
        } finally {
            Set-DataRoot -Path $original | Out-Null
        }
        $Paths.ServerDir | Should -Be (Join-Path $original 'server')
    }

    It 'uses an archive that sits at the root of the chosen folder' {
        $dir = Join-Path $TestDrive 'archive-at-root'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -Path (Join-Path $dir 'resource_dump_android.7z') -Value 'x'
        $original = $Root
        try {
            Set-DataRoot -Path $dir | Out-Null
            $Config.AssetsArchive | Should -Be (Join-Path $dir 'resource_dump_android.7z')
        } finally {
            Set-DataRoot -Path $original | Out-Null
        }
    }

    It 'remembers the chosen folder next to the installer' {
        $remember = Join-Path $TestDrive 'remember'
        $data = Join-Path $TestDrive 'data'
        New-Item -ItemType Directory -Force -Path $remember, $data | Out-Null
        $originalRoot = $Root
        $originalApp = $Script:AppDir
        try {
            $Script:AppDir = $remember
            Set-DataRoot -Path $data | Out-Null
            Save-DataRoot
            $file = Join-Path $remember 'data-folder.txt'
            $file | Should -Exist
            (Get-Content -LiteralPath $file -Raw).Trim() | Should -Be $data

            # pointing the game files back at the installer folder removes the file
            Set-DataRoot -Path $remember | Out-Null
            Save-DataRoot
            $file | Should -Not -Exist
        } finally {
            $Script:AppDir = $originalApp
            Set-DataRoot -Path $originalRoot | Out-Null
        }
    }

    It 'summarises what is there and what is still missing' {
        $report = [pscustomobject]@{
            Found   = [string[]]@('server binaries')
            Missing = [string[]]@('stock APK')
        }
        $text = Format-FilesFolderStatus -Report $report
        $text | Should -Match 'Found: server binaries'
        $text | Should -Match 'Still to get: stock APK'
    }
}

Describe 'Format-Size' {
    It 'formats <Bytes> bytes as "<Expected>"' -TestCases @(
        @{ Bytes = 512;  Expected = '512 B' }
        @{ Bytes = 2048; Expected = '2 KB' }
        @{ Bytes = 5MB;  Expected = '5.0 MB' }
        @{ Bytes = 2GB;  Expected = '2.00 GB' }
    ) {
        Format-Size $Bytes | Should -Be $Expected
    }
}

Describe 'ConvertTo-ArgumentString' {
    It 'leaves plain arguments untouched' {
        ConvertTo-ArgumentString @('a', 'b') | Should -Be 'a b'
    }

    It 'quotes arguments that contain spaces' {
        ConvertTo-ArgumentString @('--input', 'C:\Program Files\x y') |
            Should -Be '--input "C:\Program Files\x y"'
    }

    It 'escapes embedded quotes' {
        ConvertTo-ArgumentString @('a"b') | Should -Be '"a\"b"'
    }
}

Describe 'Signature checks' {
    It 'rejects a file that is not signed' {
        $file = Join-Path $TestDrive 'unsigned.ps1'
        Set-Content -Path $file -Value 'Write-Output 1' -Encoding ASCII
        Test-Signature -Path $file -Publisher 'Netease' | Should -BeFalse
    }

    It 'rejects a missing file' {
        Test-Signature -Path (Join-Path $TestDrive 'missing.exe') | Should -BeFalse
    }
}

Describe 'Version' {
    It 'follows major.minor.patch' {
        $Script:AppVersion | Should -Match '^\d+\.\d+\.\d+$'
    }

    It 'compares versions correctly' {
        Test-NewerVersion -Current '1.2.0' -Latest '1.3.0' | Should -BeTrue
        Test-NewerVersion -Current '1.2.0' -Latest '2.0'   | Should -BeTrue
        Test-NewerVersion -Current '1.2.0' -Latest '1.2.0' | Should -BeFalse
        Test-NewerVersion -Current '1.2.0' -Latest '1.1.9' | Should -BeFalse
        Test-NewerVersion -Current '1.2.0' -Latest 'beta'  | Should -BeFalse
    }
}

Describe 'Single instance' {
    It 'derives the same mutex name from the same folder' {
        $a = Get-InstanceMutexName -Path 'C:\Install\One'
        $b = Get-InstanceMutexName -Path 'C:\Install\One\'
        $a | Should -Be $b
        $a | Should -Match '^Local\\CageSetup-[0-9A-F]{16}$'
    }

    It 'uses a different mutex name for another folder' {
        Get-InstanceMutexName -Path 'C:\Install\One' |
            Should -Not -Be (Get-InstanceMutexName -Path 'C:\Install\Two')
    }
}

Describe 'Emulator discovery' {
    It 'picks the newest ADB inside the Android engine folders' {
        $mumu = Join-Path $TestDrive 'mumu'
        foreach ($version in '9.0', '15.0', '12.0') {
            $shell = Join-Path $mumu "nx_device\$version\shell"
            New-Item -ItemType Directory -Force $shell | Out-Null
            Set-Content -Path (Join-Path $shell 'adb.exe') -Value 'x' -Encoding ASCII
        }
        Find-AdbExe -MuMuDir $mumu | Should -BeLike '*15.0*'
    }

    It 'falls back to the bundled platform-tools when MuMu has no engine' {
        $bundled = Join-Path $Root 'tools\android-sdk\platform-tools\adb.exe'
        $found = Find-AdbExe -MuMuDir (Join-Path $TestDrive 'nothing')
        if (Test-Path $bundled) { $found | Should -Be $bundled }
        else { $found | Should -BeNullOrEmpty }
    }

    It 'only returns a folder that contains MuMuManager.exe' {
        $dir = Find-MuMuDir
        if ($dir) { Test-Path (Join-Path $dir 'nx_main\MuMuManager.exe') | Should -BeTrue }
        else { $dir | Should -BeNullOrEmpty }
    }
}

Describe 'Pinned downloads' {
    It 'pins every toolchain archive with its size and SHA256' {
        $toolchain = @(
            @{ Url = 'JreUrl';        Bytes = 'JreBytes';        Sha = 'JreSha256' }
            @{ Url = 'ApktoolUrl';    Bytes = 'ApktoolBytes';    Sha = 'ApktoolSha256' }
            @{ Url = 'BuildToolsUrl'; Bytes = 'BuildToolsBytes'; Sha = 'BuildToolsSha256' }
            @{ Url = 'PythonUrl';     Bytes = 'PythonBytes';     Sha = 'PythonSha256' }
        )
        foreach ($item in $toolchain) {
            $Config[$item.Url] | Should -Match '^https://'
            $Config[$item.Bytes] | Should -BeGreaterThan 0
            $Config[$item.Sha] | Should -Match '^[0-9a-f]{64}$'
        }
    }

    It 'pins the stock APK to its size and SHA256' {
        $Config.ApkStockBytes | Should -BeGreaterThan 0
        $Config.ApkStockSha256 | Should -Match '^[0-9a-f]{64}$'
    }
}

Describe 'Disk space planning' {
    It 'adds the extraction size to the part of the download that is left' {
        Get-AssetsDiskRequirementGB -TotalBytes (15GB) -DownloadedBytes 0 | Should -Be 66
    }

    It 'asks for less when the download is partly on disk' {
        Get-AssetsDiskRequirementGB -TotalBytes (15GB) -DownloadedBytes (10GB) | Should -Be 56
    }
}

Describe 'Cancellation' {
    AfterEach { $Script:CancelRequested = $false }

    It 'does not throw while no cancel was requested' {
        { Assert-NotCancelled } | Should -Not -Throw
    }

    It 'stops a running operation with an OperationCanceledException' {
        $Script:CancelRequested = $true
        { Assert-NotCancelled } | Should -Throw -ExceptionType ([System.OperationCanceledException])
    }
}

Describe 'Port conflicts' {
    It 'finds the process listening on a port' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
            $owner = Get-PortOwner -Port $port
            $owner | Should -Not -BeNullOrEmpty
            $owner.Port | Should -Be $port
            $owner.ProcessId | Should -Be $PID
        } finally {
            $listener.Stop()
        }
    }

    It 'treats a listener owned by another program as a conflict' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
            $conflict = @(Get-ServerPortConflicts -Ports $port)
            $conflict.Count | Should -Be 1
            $conflict[0].Port | Should -Be $port
        } finally {
            $listener.Stop()
        }
    }
}

Describe 'Diagnostics' {
    It 'returns a copyable block with the version and the environment' {
        $text = Get-DiagnosticsText
        $text | Should -Match ([regex]::Escape('Cage Setup ' + $Script:AppVersion))
        $text | Should -Match 'Root\s+:'
        $text | Should -Match 'Server\s+:'
    }
}

Describe 'Server archive' {
    It 'matches the pinned SHA256 when the archive has been downloaded' {
        $zip = Join-Path $Paths.Downloads 'lunar-tear-server.zip'
        if (-not (Test-Path $zip)) {
            Set-ItResult -Skipped -Because 'the archive has not been downloaded on this machine'
            return
        }
        (Get-FileHash $zip -Algorithm SHA256).Hash | Should -Be $Config.ServerSha256.ToUpper()
    }
}
