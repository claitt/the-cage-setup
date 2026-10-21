# Downloads with percentage and speed
# (moved out of Cage Setup.ps1; the build script inlines it again)

# =====================================================================
#  DOWNLOADS with percentage and speed
# =====================================================================
function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Update-Progress {
    param(
        [string]$Text = '',
        [int64]$Done = 0,
        [int64]$Total = 0,
        [double]$Speed = -1,
        [switch]$Indeterminate,
        [switch]$Percentage
    )
    $pct = 0
    if ($Total -gt 0) { $pct = [math]::Min(100, [math]::Round(($Done / $Total) * 100, 0)) }

    $detail = $Text
    if ($Percentage) {
        if ($Total -gt 0) { $detail += "  |  $pct%" }
    } elseif ($Total -gt 0) {
        $detail += '  |  ' + (Format-Size $Done) + ' / ' + (Format-Size $Total) + "  |  $pct%"
    }
    if ($Speed -ge 0) {
        $detail += '  |  ' + (Format-Size $Speed) + '/s'
        if ($Speed -gt 0 -and $Total -gt $Done) {
            $left = ($Total - $Done) / $Speed
            $detail += '  |  left ' + ([TimeSpan]::FromSeconds($left).ToString('mm\:ss'))
        }
    }

    if ($Script:ProgressBar) {
        if ($Indeterminate) {
            $Script:ProgressBar.Style = 'Marquee'
        } else {
            $Script:ProgressBar.Style = 'Continuous'
            $Script:ProgressBar.Value = [math]::Min(100, [math]::Max(0, $pct))
        }
    }
    if ($Script:ProgressLabel) { $Script:ProgressLabel.Text = $detail }
    [System.Windows.Forms.Application]::DoEvents()
}

function Send-Download {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '', Justification = 'archive.org publishes only SHA1 for the game assets; the server archive is verified with SHA256.')]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [string]$Label = 'Download',
        [int64]$Bytes = 0,       # known total size (enables resume)
        [string]$Sha1 = '',      # integrity check for hosts that publish SHA1
        [string]$Sha256 = '',    # integrity check for everything else
        [int]$Retries = 6
    )
    $folder = Split-Path $Destination -Parent
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }

    if ((Test-Path $Destination) -and ((-not $Bytes) -or ((Get-Item $Destination).Length -eq $Bytes))) {
        if ($Sha256) {
            # small pinned files (toolchain, patchers): verify them again, so a
            # file modified after the first download cannot be reused
            $existingHash = (Get-FileHash $Destination -Algorithm SHA256).Hash
            if ($existingHash -eq $Sha256.ToUpper()) {
                Write-Log "$Label already present: $Destination" 'OK'
                return $true
            }
            Write-Log "$Label : the existing file does not match the pinned SHA256 - downloading it again." 'WARN'
            Remove-Item $Destination -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log "$Label already present: $Destination" 'OK'
            return $true
        }
    }

    $tmp = "$Destination.part"
    Write-Log "$Label - downloading from: $Url"
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromHours(10)
    try {
        for ($attempt = 1; $attempt -le $Retries; $attempt++) {
            Assert-NotCancelled
            [int64]$existing = 0
            if (Test-Path $tmp) { $existing = (Get-Item $tmp).Length }
            if ($Bytes -gt 0 -and $existing -ge $Bytes) { break }

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)
            if ($existing -gt 0) {
                [void]$req.Headers.TryAddWithoutValidation('Range', "bytes=$existing-")
                Write-Log ("$Label : resuming from " + (Format-Size $existing))
            }
            try {
                $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                if (-not $resp.IsSuccessStatusCode) {
                    throw ('HTTP ' + [int]$resp.StatusCode + ' ' + $resp.ReasonPhrase)
                }
                $partial = ($resp.StatusCode -eq [System.Net.HttpStatusCode]::PartialContent)
                if (-not $partial) { $existing = 0 }
                [int64]$length = 0
                if ($resp.Content.Headers.ContentLength) { $length = [int64]$resp.Content.Headers.ContentLength }
                [int64]$total = 0
                if ($Bytes -gt 0) { $total = $Bytes } elseif ($length -gt 0) { $total = $existing + $length }

                $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $mode = if ($partial -and $existing -gt 0) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
                $out = [System.IO.File]::Open($tmp, $mode, [System.IO.FileAccess]::Write)
                $buffer = New-Object byte[] 1048576
                [int64]$done = $existing
                $lastMs = 0.0; [int64]$lastBytes = $done; $speed = 0.0
                try {
                    while ($true) {
                        $n = $stream.Read($buffer, 0, $buffer.Length)
                        if ($n -le 0) { break }
                        $out.Write($buffer, 0, $n)
                        $done += $n
                        $ms = $sw.Elapsed.TotalMilliseconds
                        if (($ms - $lastMs) -ge 500) {
                            $speed = ($done - $lastBytes) / (($ms - $lastMs) / 1000.0)
                            $lastMs = $ms; $lastBytes = $done
                            Update-Progress -Text $Label -Done $done -Total $total -Speed $speed
                            Assert-NotCancelled
                        }
                    }
                } finally {
                    $out.Close(); $stream.Close()
                }

                [int64]$now = 0
                if (Test-Path $tmp) { $now = (Get-Item $tmp).Length }
                if ($total -gt 0) {
                    if ($now -ge $total) { break }
                } else {
                    if ($length -le 0 -or $done -ge ($existing + $length)) { break }
                }
                Write-Log ("$Label : interrupted at " + (Format-Size $now) + ' of ' + (Format-Size $total) + ' - retrying.') 'WARN'
            } catch {
                if ($_.Exception -is [System.OperationCanceledException]) { throw }
                Write-Log ("$Label : error (" + $_.Exception.Message + ') - retrying.') 'WARN'
            }
            Start-Sleep -Seconds ([math]::Min(20, 3 * $attempt))
            [System.Windows.Forms.Application]::DoEvents()
        }

        Assert-NotCancelled
        [int64]$final = 0
        if (Test-Path $tmp) { $final = (Get-Item $tmp).Length }
        if ($Bytes -gt 0 -and $final -ne $Bytes) { throw "Incomplete download: $final of $Bytes bytes" }

        $hashAlgorithm = ''
        $expectedHash = ''
        if ($Sha256) { $hashAlgorithm = 'SHA256'; $expectedHash = $Sha256.ToUpper() }
        elseif ($Sha1) { $hashAlgorithm = 'SHA1'; $expectedHash = $Sha1.ToUpper() }
        if ($hashAlgorithm) {
            Update-Progress -Text "$Label : verifying integrity ($hashAlgorithm)..." -Indeterminate
            Write-Log "$Label : computing $hashAlgorithm (large files may take a few minutes)..."
            $hash = (Get-FileHash $tmp -Algorithm $hashAlgorithm).Hash
            if ($hash -ne $expectedHash) {
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                throw "$hashAlgorithm mismatch (expected $expectedHash, got $hash). File removed: please retry."
            }
            Write-Log "$Label : integrity verified ($hashAlgorithm ok)" 'OK'
        }

        Move-Item $tmp $Destination -Force
        Update-Progress -Text "$Label completed" -Done $final -Total $final
        Write-Log ("$Label completed: " + (Format-Size $final)) 'OK'
        return $true
    } finally {
        $client.Dispose()
    }
}

# Reads the last progress percentage from the 7zr log without loading the whole file
function Get-SevenZipPercent {
    param([string]$LogPath)
    if (-not (Test-Path $LogPath)) { return -1 }
    try {
        $fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $len = $fs.Length
            $count = [int][math]::Min(16384, $len)
            if ($count -le 0) { return -1 }
            [void]$fs.Seek($len - $count, [System.IO.SeekOrigin]::Begin)
            $buffer = New-Object byte[] $count
            [void]$fs.Read($buffer, 0, $count)
        } finally { $fs.Close() }
        $text = [System.Text.Encoding]::Default.GetString($buffer)
        $m = [regex]::Matches($text, '(\d{1,3})%')
        if ($m.Count -gt 0) { return [int]$m[$m.Count - 1].Groups[1].Value }
    } catch { return -1 }
    return -1
}

# Extracts a .7z archive with 7zr, showing 7-Zip's real percentage
function Expand-Archive7z {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Destination,
        [string]$Label = 'Extraction'
    )
    if (-not (Test-Path $Paths.SevenZip)) { throw "7zr.exe not found: $($Paths.SevenZip)" }
    if (-not (Test-Path $Archive)) { throw "Archive not found: $Archive" }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    $log = Join-Path $env:TEMP ('lunartear-extract-' + [guid]::NewGuid().ToString('N') + '.log')
    Write-Log "$Label - starting (this can take several minutes)..."

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.Arguments = '/c ""' + $Paths.SevenZip + '" x "' + $Archive + '" -o"' + $Destination +
                     '" -y -bso0 -bse1 -bsp1 > "' + $log + '" 2>&1"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    while (-not $proc.HasExited) {
        if ($Script:CancelRequested) {
            try { $proc.Kill() } catch { Write-Verbose "Cannot stop 7-Zip: $($_.Exception.Message)" }
            Remove-Item $log -Force -ErrorAction SilentlyContinue
            Assert-NotCancelled
        }
        Start-Sleep -Seconds 2
        $pct = Get-SevenZipPercent -LogPath $log
        if ($pct -ge 0) {
            Update-Progress -Text $Label -Done $pct -Total 100 -Percentage
        } else {
            Update-Progress -Text ("$Label (" + $sw.Elapsed.ToString('mm\:ss') + ')') -Indeterminate
        }
        [System.Windows.Forms.Application]::DoEvents()
    }
    $proc.WaitForExit()
    $code = $proc.ExitCode

    if ($code -ne 0) {
        $detail = ''
        if (Test-Path $log) {
            $text = [System.IO.File]::ReadAllText($log) -replace "`r", "`n"
            $detail = (@($text -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 6)) -join ' | '
            if ($detail.Length -gt 400) { $detail = $detail.Substring($detail.Length - 400) }
        }
        Remove-Item $log -Force -ErrorAction SilentlyContinue
        throw "Extraction failed (code $code). $detail"
    }
    Remove-Item $log -Force -ErrorAction SilentlyContinue
    Update-Progress -Text "$Label completed" -Done 100 -Total 100 -Percentage
    Write-Log ("$Label completed in " + $sw.Elapsed.ToString('mm\:ss')) 'OK'
    return $true
}

function Watch-FolderGrowth {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int64]$Expected = 0,
        [int]$TimeoutSeconds = 3600,
        [string]$Label = 'Download in progress'
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    [int64]$previous = 0; $previousSeconds = 0.0
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Assert-NotCancelled
        Start-Sleep -Milliseconds 2000
        [int64]$now = Get-FolderSize $Path
        $t = $sw.Elapsed.TotalSeconds
        $speed = if ($t -gt $previousSeconds) { ($now - $previous) / ($t - $previousSeconds) } else { 0 }
        $previous = $now; $previousSeconds = $t
        if ($Expected -gt 0) {
            Update-Progress -Text $Label -Done $now -Total $Expected -Speed $speed
            if ($now -ge $Expected) { break }
        } else {
            Update-Progress -Text ("$Label  (" + (Format-Size $now) + ')') -Indeterminate
        }
    }
}

