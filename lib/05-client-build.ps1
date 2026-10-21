# Client build: toolchain, apktool, Python, APK patching
# (moved out of Cage Setup.ps1; the build script inlines it again)

# =====================================================================
#  CLIENT BUILD
#  The stock APK is downloaded from APKMirror, patched with the official
#  lunar-scripts patcher (server addresses, SSL, encryption, billing) and
#  signed again, because a modified APK cannot keep its original signature.
#  Nothing of this is shipped with the installer: the toolchain (Java,
#  apktool, Android build tools, Python) is downloaded only when needed.
# =====================================================================

function Expand-ZipFile {
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][string]$Destination)
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Destination)
}

function ConvertTo-ArgumentString {
    param([string[]]$Parts)
    ($Parts | ForEach-Object {
        if ($_ -match '[\s"]' -or $_ -eq '') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
}

function Get-LogTail {
    param([string]$Path, [int]$Lines = 6, [int]$Bytes = 8192)
    if (-not (Test-Path $Path)) { return @() }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $length = $fs.Length
            $count = [int][math]::Min($Bytes, $length)
            if ($count -le 0) { return @() }
            [void]$fs.Seek($length - $count, 'Begin')
            $buffer = New-Object byte[] $count
            [void]$fs.Read($buffer, 0, $count)
        } finally { $fs.Close() }
        $text = [System.Text.Encoding]::UTF8.GetString($buffer)
        @($text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last $Lines)
    } catch { @() }
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$Label = 'Running',
        [int]$TimeoutSeconds = 3600
    )
    if (-not (Test-Path $File)) { throw "Executable not found: $File" }

    $log = Join-Path $env:TEMP ('lunartear-tool-' + [guid]::NewGuid().ToString('N') + '.log')
    $call = (ConvertTo-ArgumentString $Arguments)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.Arguments = '/c ""' + $File + '" ' + $call + ' > "' + $log + '" 2>&1"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $Root

    Write-Log "$Label - started"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        while (-not $proc.HasExited) {
            if ($Script:CancelRequested) {
                try { $proc.Kill() } catch { Write-Verbose "Cannot stop ${Label}: $($_.Exception.Message)" }
                Remove-Item $log -Force -ErrorAction SilentlyContinue
                Assert-NotCancelled
            }
            Start-Sleep -Milliseconds 800
            $tail = @(Get-LogTail -Path $log -Lines 1)
            $detail = if ($tail.Count -gt 0) { $tail[0].Trim() } else { '' }
            if ($detail.Length -gt 100) { $detail = $detail.Substring(0, 100) }
            $text = "$Label  (" + $sw.Elapsed.ToString('mm\:ss') + ')'
            if ($detail) { $text += '  ' + $detail }
            Update-Progress -Text $text -Indeterminate
            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                try { $proc.Kill() } catch { Write-Verbose "Cannot stop the process: $($_.Exception.Message)" }
                throw "$Label timed out after $TimeoutSeconds seconds"
            }
            [System.Windows.Forms.Application]::DoEvents()
        }
        $proc.WaitForExit()
        $code = $proc.ExitCode
    } finally {
        $proc.Dispose()
    }

    foreach ($line in (Get-LogTail -Path $log -Lines 14)) {
        $short = if ($line.Length -gt 300) { $line.Substring(0, 300) } else { $line }
        Write-Log "  $short"
    }
    Remove-Item $log -Force -ErrorAction SilentlyContinue
    if ($code -ne 0) { throw "$Label failed (exit code $code)" }
    Write-Log ("$Label - done in " + $sw.Elapsed.ToString('mm\:ss')) 'OK'
    return $true
}

# ---- toolchain ---------------------------------------------------------

function Get-JavaExe {
    if ($Script:JavaExe -and (Test-Path $Script:JavaExe)) { return $Script:JavaExe }
    $found = $null
    foreach ($dir in @($Paths.JdkDir, (Join-Path $Root 'tools'))) {
        if (-not (Test-Path $dir)) { continue }
        $found = Get-ChildItem $dir -Recurse -Depth 3 -Filter 'java.exe' -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -notlike '*\android-sdk\*' } |
                 Select-Object -First 1 -ExpandProperty FullName
        if ($found) { break }
    }
    if (-not $found) {
        $cmd = Get-Command java.exe -ErrorAction SilentlyContinue
        if ($cmd) { $found = $cmd.Source }
    }
    if ($found) { $Script:JavaExe = $found }
    return $found
}

function Ensure-Jdk {
    $java = Get-JavaExe
    if ($java) { Write-Log "Java runtime: $java" 'OK'; return $true }
    Write-Log 'Toolchain: downloading the Java runtime (JRE 17, about 44 MB)'
    $zip = Join-Path $Paths.Downloads 'jre17.zip'
    Send-Download -Url $Config.JreUrl -Destination $zip -Label 'Java runtime (JRE 17)' -Bytes $Config.JreBytes -Sha256 $Config.JreSha256 | Out-Null
    Expand-ZipFile -Archive $zip -Destination $Paths.JdkDir
    if (Get-JavaExe) { Write-Log 'Java runtime ready' 'OK'; return $true }
    Write-Log 'Java runtime missing after extraction' 'ERROR'
    return $false
}

function Ensure-Apktool {
    if (Test-Path $Paths.ApktoolJar) { Write-Log "apktool: $($Paths.ApktoolJar)" 'OK'; return $true }
    Write-Log 'Toolchain: downloading apktool (about 15 MB)'
    Send-Download -Url $Config.ApktoolUrl -Destination $Paths.ApktoolJar -Label 'apktool' -Bytes $Config.ApktoolBytes -Sha256 $Config.ApktoolSha256 | Out-Null
    if (Test-Path $Paths.ApktoolJar) { Write-Log 'apktool ready' 'OK'; return $true }
    return $false
}

function Find-BuildTool {
    param([Parameter(Mandatory)][string]$Leaf)
    foreach ($dir in @($Paths.BuildToolsDir, (Join-Path $Root 'tools\android-sdk\build-tools'))) {
        if (-not (Test-Path $dir)) { continue }
        $file = Get-ChildItem $dir -Recurse -Filter $Leaf -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending | Select-Object -First 1
        if ($file) { return $file.FullName }
    }
    return $null
}

function Ensure-BuildTools {
    $align = Find-BuildTool 'zipalign.exe'
    $signer = Find-BuildTool 'apksigner.jar'
    if ($align -and $signer) {
        $Script:ZipAlignExe = $align
        $Script:ApkSignerJar = $signer
        Write-Log "Android build tools: $align" 'OK'
        return $true
    }
    Write-Log 'Toolchain: downloading the Android build tools (about 60 MB)'
    $zip = Join-Path $Paths.Downloads 'build-tools.zip'
    Send-Download -Url $Config.BuildToolsUrl -Destination $zip -Label 'Android build tools' -Bytes $Config.BuildToolsBytes -Sha256 $Config.BuildToolsSha256 | Out-Null
    Expand-ZipFile -Archive $zip -Destination $Paths.BuildToolsDir
    $align = Find-BuildTool 'zipalign.exe'
    $signer = Find-BuildTool 'apksigner.jar'
    if ($align -and $signer) {
        $Script:ZipAlignExe = $align
        $Script:ApkSignerJar = $signer
        Write-Log 'Android build tools ready' 'OK'
        return $true
    }
    Write-Log 'Android build tools missing after extraction' 'ERROR'
    return $false
}

function Test-PythonModules {
    param([string]$Python)
    if (-not (Test-Path $Python)) { return $false }
    $out = & $Python -c "import Crypto, lz4.block, msgpack; print('modules-ok')" 2>&1
    return (($out -join ' ') -match 'modules-ok')
}

function Get-PyPiWheelUrl {
    param([Parameter(Mandatory)][string]$Package)
    $info = Invoke-RestMethod -Uri "https://pypi.org/pypi/$Package/json" -TimeoutSec 60
    $file = $info.urls |
            Where-Object { $_.filename -like '*win_amd64.whl' -and ($_.filename -match 'cp312|abi3') } |
            Sort-Object -Property upload_time -Descending |
            Select-Object -First 1
    if (-not $file) { throw "No Windows wheel available for $Package" }
    return $file.url
}

function Ensure-Python {
    if ($Script:PythonExe -and (Test-PythonModules $Script:PythonExe)) { return $Script:PythonExe }

    $python = Join-Path $Paths.PythonDir 'python.exe'
    if (-not (Test-Path $python)) {
        Write-Log 'Toolchain: downloading the Python runtime (about 11 MB)'
        $zip = Join-Path $Paths.Downloads 'python-embed.zip'
        Send-Download -Url $Config.PythonUrl -Destination $zip -Label 'Python runtime' -Bytes $Config.PythonBytes -Sha256 $Config.PythonSha256 | Out-Null
        Expand-ZipFile -Archive $zip -Destination $Paths.PythonDir
    }
    if (-not (Test-Path $python)) { Write-Log 'Python runtime missing after extraction' 'ERROR'; return $null }

    # the embedded runtime ships with site-packages disabled
    $pth = Get-ChildItem $Paths.PythonDir -Filter 'python*._pth' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pth) {
        $lines = @(Get-Content $pth.FullName)
        $lines = @($lines | ForEach-Object { if ($_ -match '^\s*#\s*import site') { 'import site' } else { $_ } })
        if ($lines -notcontains 'Lib\site-packages') { $lines += 'Lib\site-packages' }
        Set-Content -Path $pth.FullName -Value $lines -Encoding ASCII
    }

    $Script:PythonExe = $python
    if (Test-PythonModules $python) { Write-Log 'Python runtime ready' 'OK'; return $python }

    $site = Join-Path $Paths.PythonDir 'Lib\site-packages'
    New-Item -ItemType Directory -Force -Path $site | Out-Null
    foreach ($package in @('pycryptodome', 'msgpack', 'lz4')) {
        $url = Get-PyPiWheelUrl $package
        $wheel = Join-Path $Paths.Downloads (Split-Path $url -Leaf)
        Send-Download -Url $url -Destination $wheel -Label "Python module: $package" | Out-Null
        Expand-ZipFile -Archive $wheel -Destination $site
    }

    if (Test-PythonModules $python) { Write-Log 'Python modules ready' 'OK'; return $python }
    Write-Log 'Python modules are not usable' 'ERROR'
    return $null
}

function Get-LunarScript {
    param([Parameter(Mandatory)][string]$Name)
    $dest = Join-Path $Paths.ScriptsDir ($Name -replace '/', '\')
    if (Test-Path $dest) { return $dest }
    New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
    $url = "$($Config.ScriptsRaw)/$Name"
    Send-Download -Url $url -Destination $dest -Label "lunar-scripts: $(Split-Path $Name -Leaf)" | Out-Null
    if (-not (Test-Path $dest)) { throw "Cannot download the script: $url" }
    return $dest
}

# ---- stock APK ---------------------------------------------------------

function Test-ApkArchive {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $false }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $names = @($zip.Entries | ForEach-Object { $_.FullName })
        } finally { $zip.Dispose() }
        return (($names -contains 'lib/arm64-v8a/libil2cpp.so') -and
                ($names -contains 'assets/bin/Data/Managed/Metadata/global-metadata.dat'))
    } catch { return $false }
}

function Get-CurlExe {
    $cmd = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $system = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $system) { return $system }
    return $null
}

function Get-ApkmirrorApk {
    param([Parameter(Mandatory)][string]$Destination)
    if (Test-ApkArchive $Destination) { Write-Log "Stock APK already downloaded: $Destination" 'OK'; return $true }

    Write-Log 'Client: looking for the stock APK on APKMirror' 'STEP'

    # APKMirror refuses the .NET HTTP stack (403): the pages are read with
    # curl.exe, which Windows ships since version 1803. The file itself is on
    # a plain CDN and is downloaded here so that progress and speed are shown.
    $curl = Get-CurlExe
    if (-not $curl) {
        Write-Log 'curl.exe not found. Windows 10 version 1803 or newer is required.' 'ERROR'
        return $false
    }

    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
    $work = Join-Path $env:TEMP ('lunartear-apk-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $jar = Join-Path $work 'cookies.txt'
    $downloaded = $false

    try {
        Assert-NotCancelled
        # 1) variant page -> "/.../download/?key=..."
        # FIXME: this scrapes the APKMirror HTML with a regex. The layout has
        # changed before and will change again; the manual download in the README
        # is the fallback when the match stops working.
        $page = Join-Path $work 'page1.html'
        $null = & $curl -s -L --compressed -A $ua -c $jar -b $jar -o $page $Config.ApkPageUrl 2>&1
        if (-not (Test-Path $page)) { throw 'APKMirror is not reachable' }
        $html = Get-Content -Raw $page
        $m = [regex]::Match($html, 'href="([^"]*?/download/\?key=[^"]+)"')
        if (-not $m.Success) { throw 'download link not found on the APKMirror page (the page layout may have changed)' }
        $step2 = ([Uri]::new([Uri]$Config.ApkPageUrl, $m.Groups[1].Value.Replace('&amp;', '&'))).AbsoluteUri

        # 2) download page -> "download.php?id=...&key=..."
        $page = Join-Path $work 'page2.html'
        $null = & $curl -s -L --compressed -A $ua -e $Config.ApkPageUrl -c $jar -b $jar -o $page $step2 2>&1
        $html = Get-Content -Raw $page
        $m = [regex]::Match($html, 'href="([^"]*?download\.php\?id=\d+&(?:amp;)?key=[^"]+)"')
        if (-not $m.Success) { throw 'final download link not found on the APKMirror page' }
        $step3 = ([Uri]::new([Uri]$step2, $m.Groups[1].Value.Replace('&amp;', '&'))).AbsoluteUri

        # 3) the endpoint answers with a redirect to the CDN (valid for one hour)
        $headers = Join-Path $work 'headers.txt'
        $null = & $curl -s -D $headers -o NUL --max-redirs 0 -A $ua -e $step2 -c $jar -b $jar $step3 2>&1
        $line = Get-Content $headers -ErrorAction SilentlyContinue | Where-Object { $_ -match '^location:' } | Select-Object -First 1
        if (-not $line) { throw 'the download endpoint did not return a redirect' }
        $final = ($line -replace '^location:\s*', '').Trim()
        Write-Log 'Client: direct download link obtained'

        # 4) stream the APK to disk with progress
        New-Item -ItemType Directory -Force -Path (Split-Path $Destination -Parent) | Out-Null
        $partial = "$Destination.part"
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $true
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromMinutes(60)
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $ua)
        try {
            $response = $client.GetAsync($final, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) { throw "HTTP $([int]$response.StatusCode) while downloading the APK" }

            [int64]$total = $Config.ApkStockBytes
            if ($response.Content.Headers.ContentLength) { $total = [int64]$response.Content.Headers.ContentLength }
            $streamIn = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $output = [System.IO.File]::Open($partial, 'Create', 'Write')
            $buffer = New-Object byte[] 1048576
            [int64]$done = 0
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            [int64]$markBytes = 0
            $markMs = 0.0
            $speed = 0.0
            try {
                while ($true) {
                    $read = $streamIn.Read($buffer, 0, $buffer.Length)
                    if ($read -le 0) { break }
                    $output.Write($buffer, 0, $read)
                    $done += $read
                    $ms = $sw.Elapsed.TotalMilliseconds
                    if (($ms - $markMs) -ge 600) {
                        $speed = ($done - $markBytes) / (($ms - $markMs) / 1000.0)
                        $markMs = $ms
                        $markBytes = $done
                        Update-Progress -Text 'Downloading the game client from APKMirror' -Done $done -Total $total -Speed $speed
                        Assert-NotCancelled
                    }
                }
            } finally {
                $output.Close()
                $streamIn.Close()
                $response.Dispose()
            }
        } finally {
            $client.Dispose()
        }

        Remove-Item $Destination -Force -ErrorAction SilentlyContinue
        Move-Item $partial $Destination -Force
        $downloaded = $true
    } catch {
        if ($_.Exception -is [System.OperationCanceledException]) { throw }
        Write-Log $_.Exception.Message 'ERROR'
        return $false
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-ApkArchive $Destination) {
        if ($Config.ApkStockSha256) {
            Update-Progress -Text 'Verifying the stock APK (SHA256)...' -Indeterminate
            $hash = (Get-FileHash $Destination -Algorithm SHA256).Hash
            if ($hash -ne $Config.ApkStockSha256.ToUpper()) {
                if ($downloaded) {
                    Remove-Item $Destination -Force -ErrorAction SilentlyContinue
                    Write-Log "Stock APK checksum mismatch: expected $($Config.ApkStockSha256), got $hash. The file was removed, please retry." 'ERROR'
                    return $false
                }
                Write-Log "The stock APK was supplied locally and differs from the pinned file (SHA256 $hash): using it anyway." 'WARN'
            } else {
                Write-Log 'Stock APK verified (SHA256)' 'OK'
            }
        }
        Write-Log ("Stock APK downloaded: " + (Format-Size (Get-Item $Destination).Length)) 'OK'
        return $true
    }
    Write-Log 'The downloaded file is not a valid APK' 'ERROR'
    return $false
}

# ---- build -------------------------------------------------------------

function Get-ClientApkPath {
    param([switch]$BuildOutputOnly)
    $candidates = @($Config.ApkOutput)
    if (-not $BuildOutputOnly) {
        # APKs already built by hand on this machine are accepted as well
        $candidates += (Join-Path $Root 'apk\out\nier_aligned.apk')
        $candidates += (Join-Path $Root 'client-nier-reincarnation-patched.apk')
    }
    foreach ($path in $candidates) {
        if ($path -and (Test-Path $path)) { return $path }
    }
    return $null
}

function Test-ClientBuildCurrent {
    if (-not (Test-Path $Config.ApkOutput)) { return $false }
    $marker = Join-Path $Root 'apk\out\.build.txt'
    if (-not (Test-Path $marker)) { return $false }
    $wanted = "$($Config.GrpcAddr)|$($Config.HttpAddr)|$($Config.AuthAddr)"
    $current = (Get-Content $marker -Raw).Trim()
    return ($current -eq $wanted)
}

function Build-ClientApk {
    Write-Log 'Client: building the patched APK (a few minutes)' 'STEP'

    if (Test-ClientBuildCurrent) { Write-Log 'Patched APK already built for these addresses' 'OK'; return $true }

    $free = Get-FreeSpaceGB
    if ($free -lt 8) {
        Write-Log "At least 8 GB free in the game files folder are required to build the APK (you have $free GB)." 'ERROR'
        return $false
    }

    # the stock APK is the most fragile step (upstream page): do it first
    if (-not (Get-ApkmirrorApk -Destination $Config.ApkStockFile)) { return $false }

    if (-not (Ensure-Jdk)) { return $false }
    if (-not (Ensure-Apktool)) { return $false }
    if (-not (Ensure-BuildTools)) { return $false }
    $python = Ensure-Python
    if (-not $python) { return $false }

    $java = Get-JavaExe

    $work = $Config.ApkWorkDir
    $unaligned = Join-Path $Root 'apk\out\nier-unaligned.apk'
    $aligned = Join-Path $Root 'apk\out\nier-aligned.apk'
    New-Item -ItemType Directory -Force -Path (Split-Path $Config.ApkOutput -Parent) | Out-Null

    # 1) decompile
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    try {
        Invoke-Tool -File $java -Label 'Decompiling the APK (apktool)' `
            -Arguments @('-Xmx2g', '-jar', $Paths.ApktoolJar, 'd', $Config.ApkStockFile, '-o', $work, '-f') | Out-Null
    } catch {
        if ($_.Exception -is [System.OperationCanceledException]) { throw }
        Write-Log $_.Exception.Message 'ERROR'
        return $false
    }

    # 2) patch the decompiled tree with the official patcher
    try {
        $patcher = Get-LunarScript 'android/patch_apk.py'
        Invoke-Tool -File $python -Label 'Patching the game client' `
            -Arguments @('-X', 'utf8', $patcher, $work, '--grpc-addr', $Config.GrpcAddr, '--http-addr', $Config.HttpAddr, '--auth-host', $Config.AuthAddr) | Out-Null
    } catch {
        if ($_.Exception -is [System.OperationCanceledException]) { throw }
        Write-Log $_.Exception.Message 'ERROR'
        return $false
    }

    # 3) rebuild
    try {
        Remove-Item $unaligned -Force -ErrorAction SilentlyContinue
        Invoke-Tool -File $java -Label 'Rebuilding the APK (apktool)' `
            -Arguments @('-Xmx2g', '-jar', $Paths.ApktoolJar, 'b', $work, '-o', $unaligned) | Out-Null
    } catch {
        if ($_.Exception -is [System.OperationCanceledException]) { throw }
        Write-Log $_.Exception.Message 'ERROR'
        return $false
    }

    # 4) align
    try {
        Remove-Item $aligned -Force -ErrorAction SilentlyContinue
        Invoke-Tool -File $Script:ZipAlignExe -Label 'Aligning the APK (zipalign)' `
            -Arguments @('-p', '-f', '4', $unaligned, $aligned) | Out-Null
    } catch {
        if ($_.Exception -is [System.OperationCanceledException]) { throw }
        Write-Log $_.Exception.Message 'ERROR'
        return $false
    }

    # 5) signing key (created once, then reused)
    if (-not (Test-Path $Config.Keystore)) {
        try {
            $keytool = Join-Path (Split-Path $java -Parent) 'keytool.exe'
            if (-not (Test-Path $keytool)) { throw 'keytool.exe not found next to the Java runtime' }
            Invoke-Tool -File $keytool -Label 'Creating the signing key' `
                -Arguments @('-genkeypair', '-keystore', $Config.Keystore, '-alias', 'androiddebugkey',
                             '-storepass', 'android', '-keypass', 'android', '-keyalg', 'RSA', '-keysize', '2048',
                             '-validity', '10000', '-dname', 'CN=Android Debug,O=Android,C=US') | Out-Null
        } catch {
            Write-Log $_.Exception.Message 'ERROR'
            return $false
        }
    }

    # 6) sign and verify
    try {
        Remove-Item $Config.ApkOutput -Force -ErrorAction SilentlyContinue
        Invoke-Tool -File $java -Label 'Signing the APK (apksigner)' `
            -Arguments @('-jar', $Script:ApkSignerJar, 'sign', '--ks', $Config.Keystore,
                         '--ks-pass', 'pass:android', '--key-pass', 'pass:android',
                         '--out', $Config.ApkOutput, $aligned) | Out-Null
        Invoke-Tool -File $java -Label 'Verifying the signature' `
            -Arguments @('-jar', $Script:ApkSignerJar, 'verify', '--print-certs', $Config.ApkOutput) | Out-Null
    } catch {
        if ($_.Exception -is [System.OperationCanceledException]) { throw }
        Write-Log $_.Exception.Message 'ERROR'
        return $false
    }

    Set-Content -Path (Join-Path $Root 'apk\out\.build.txt') -Encoding ASCII `
        -Value "$($Config.GrpcAddr)|$($Config.HttpAddr)|$($Config.AuthAddr)"

    # the decompiled tree and the intermediate APKs are no longer needed
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $unaligned -Force -ErrorAction SilentlyContinue
    Remove-Item $aligned -Force -ErrorAction SilentlyContinue
    Write-Log ("Patched APK ready: " + $Config.ApkOutput + ' (' + (Format-Size (Get-Item $Config.ApkOutput).Length) + ')') 'OK'
    return $true
}

