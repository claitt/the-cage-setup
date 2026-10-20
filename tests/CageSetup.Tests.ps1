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
