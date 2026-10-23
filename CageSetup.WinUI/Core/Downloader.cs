using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace CageSetup.WinUI.Core
{
    /// <summary>
    /// Downloads and process helpers for the game files (step 3), ported
    /// from Send-Download / Expand-Archive7z / Invoke-Tool of the 1.x
    /// installer: resumable downloads with retry + pinned checksums, 7z
    /// extraction with the real 7-Zip percentage, and external tools with
    /// a live log tail.
    /// </summary>
    public static class Downloader
    {
        private static CultureInfo InvariantCulture => CultureInfo.InvariantCulture;

        /// <summary>Report callback: (percent, message); percent &lt; 0 = indeterminate.</summary>
        public delegate void ReportDelegate(double percent, string message);

        public static string FormatSize(double bytes)
        {
            if (bytes >= 1073741824) return (bytes / 1073741824).ToString("N2", InvariantCulture) + " GB";
            if (bytes >= 1048576) return (bytes / 1048576).ToString("N1", InvariantCulture) + " MB";
            if (bytes >= 1024) return (bytes / 1024).ToString("N0", InvariantCulture) + " KB";
            return bytes.ToString("N0", InvariantCulture) + " B";
        }

        public static string ProgressText(string label, long done, long total, double speed)
        {
            string detail = label;
            if (total > 0)
            {
                int pct = (int)Math.Min(100, Math.Round(done * 100.0 / total));
                detail += "  |  " + FormatSize(done) + " / " + FormatSize(total) + "  |  " + pct + "%";
            }
            if (speed >= 0)
            {
                detail += "  |  " + FormatSize(speed) + "/s";
                if (speed > 0 && total > done)
                {
                    double left = (total - done) / speed;
                    detail += "  |  left " + TimeSpan.FromSeconds(left).ToString(@"mm\:ss");
                }
            }
            return detail;
        }

        // ------------------------------------------------------------------
        // Send-Download
        // ------------------------------------------------------------------

        /// <summary>
        /// Resumable download with retries and optional pinned SHA256/SHA1.
        /// </summary>
        public static async Task SendDownloadAsync(
            string url, string destination, string label,
            long bytes = 0, string sha1 = "", string sha256 = "", int retries = 6,
            ReportDelegate? report = null, CancellationToken ct = default)
        {
            string folder = Path.GetDirectoryName(destination)!;
            Directory.CreateDirectory(folder);

            // Already present (and matching a pinned hash): reuse.
            if (File.Exists(destination) && (bytes == 0 || new FileInfo(destination).Length == bytes))
            {
                if (sha256.Length > 0)
                {
                    string existingHash = HashHelper.Sha256(destination);
                    if (existingHash.Equals(sha256, StringComparison.OrdinalIgnoreCase))
                    {
                        report?.Invoke(-1, label + " already present: " + destination);
                        return;
                    }
                    report?.Invoke(-1, label + ": the existing file does not match the pinned SHA256 - downloading again.");
                    File.Delete(destination);
                }
                else
                {
                    report?.Invoke(-1, label + " already present: " + destination);
                    return;
                }
            }

            string temp = destination + ".part";
            report?.Invoke(-1, label + " - downloading from: " + url);

            using HttpClient client = new();
            client.Timeout = TimeSpan.FromHours(10);

            bool segmented = false;
            if (bytes >= SegmentedDownload.ThresholdBytes)
            {
                segmented = await SegmentedDownload.TryDownloadAsync(
                    url, temp, label, bytes, report, ct);
                if (!segmented && File.Exists(temp + ".state"))
                {
                    throw new Exception(
                        "Segmented download is unavailable right now; retry later. The partial file is kept.");
                }
            }

            if (!segmented)
            {
                await DownloadSerialAsync(client, url, temp, label, bytes, retries, report, ct);
            }

            ct.ThrowIfCancellationRequested();
            long finalSize = File.Exists(temp) ? new FileInfo(temp).Length : 0;
            if (bytes > 0 && finalSize != bytes)
            {
                throw new Exception("Incomplete download: " + finalSize + " of " + bytes + " bytes");
            }

            if (sha256.Length > 0)
            {
                report?.Invoke(-1, label + ": computing SHA256 (large files may take a while)...");
                string hash = HashHelper.Sha256(temp);
                if (!hash.Equals(sha256, StringComparison.OrdinalIgnoreCase))
                {
                    TryDelete(temp);
                    TryDelete(temp + ".state");
                    throw new Exception("SHA256 mismatch (expected " + sha256 + ", got " + hash + "). File removed: please retry.");
                }
                report?.Invoke(-1, label + ": integrity verified (SHA256 ok)");
            }
            else if (sha1.Length > 0)
            {
                report?.Invoke(-1, label + ": computing SHA1...");
                string hash = HashHelper.Sha1(temp);
                if (!hash.Equals(sha1, StringComparison.OrdinalIgnoreCase))
                {
                    TryDelete(temp);
                    TryDelete(temp + ".state");
                    throw new Exception("SHA1 mismatch (expected " + sha1 + ", got " + hash + "). File removed: please retry.");
                }
                report?.Invoke(-1, label + ": integrity verified (SHA1 ok)");
            }

            File.Move(temp, destination, overwrite: true);
            TryDelete(temp + ".state");
            report?.Invoke(100, label + " completed: " + FormatSize(finalSize));
        }

        /// <summary>
        /// One connection at a time, resumable with Range, for small files
        /// and for servers that do not support segmented downloads.
        /// </summary>
        private static async Task DownloadSerialAsync(
            HttpClient client, string url, string temp, string label, long bytes,
            int retries, ReportDelegate? report, CancellationToken ct)
        {
            for (int attempt = 1; attempt <= retries; attempt++)
            {
                ct.ThrowIfCancellationRequested();
                long existing = File.Exists(temp) ? new FileInfo(temp).Length : 0;
                if (bytes > 0 && existing >= bytes) break;

                report?.Invoke(-1, existing > 0
                    ? label + ": resuming from " + FormatSize(existing)
                    : label + " - downloading from: " + url);

                try
                {
                    using HttpRequestMessage request = new(HttpMethod.Get, url);
                    if (existing > 0)
                    {
                        request.Headers.TryAddWithoutValidation("Range", "bytes=" + existing + "-");
                    }

                    using HttpResponseMessage response =
                        await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
                    response.EnsureSuccessStatusCode();
                    bool partial = response.StatusCode == System.Net.HttpStatusCode.PartialContent;
                    if (!partial) existing = 0;

                    long contentLength = response.Content.Headers.ContentLength ?? 0;
                    long total = bytes > 0 ? bytes : existing + contentLength;

                    await using Stream stream = await response.Content.ReadAsStreamAsync(ct);
                    await using FileStream output = new(
                        temp, partial && existing > 0 ? FileMode.Append : FileMode.Create, FileAccess.Write);

                    byte[] buffer = new byte[1024 * 1024];
                    long done = existing;
                    var sw = Stopwatch.StartNew();
                    double lastMs = 0;
                    long lastBytes = done;
                    double speed = 0;

                    int read;
                    while ((read = await stream.ReadAsync(buffer, ct)) > 0)
                    {
                        await output.WriteAsync(buffer, 0, read, ct);
                        done += read;
                        double ms = sw.Elapsed.TotalMilliseconds;
                        if (ms - lastMs >= 500)
                        {
                            speed = (done - lastBytes) / ((ms - lastMs) / 1000.0);
                            lastMs = ms;
                            lastBytes = done;
                            report?.Invoke(total > 0 ? done * 100.0 / total : -1,
                                ProgressText(label, done, total, speed));
                        }
                    }

                    long now = File.Exists(temp) ? new FileInfo(temp).Length : 0;
                    if (total > 0 && now >= total) break;
                    if (total == 0 && (contentLength <= 0 || done >= existing + contentLength)) break;
                    report?.Invoke(-1, label + ": interrupted at " + FormatSize(now) + " of " + FormatSize(total) + " - retrying.");
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch (Exception ex)
                {
                    report?.Invoke(-1, label + ": error (" + ex.Message + ") - retrying.");
                }

                await Task.Delay(Math.Min(20000, 3000 * attempt), ct);
            }
        }

        private static void TryDelete(string path)
        {
            try
            {
                if (File.Exists(path)) File.Delete(path);
            }
            catch
            {
                // A leftover .part or state file is harmless.
            }
        }

        // ------------------------------------------------------------------
        // Archives
        // ------------------------------------------------------------------

        /// <summary>Zip extraction (Expand-ZipFile).</summary>
        public static Task ExtractZipAsync(string archive, string destination, ReportDelegate? report = null)
        {
            report?.Invoke(-1, "Extracting " + Path.GetFileName(archive) + "...");
            return Task.Run(() =>
            {
                Directory.CreateDirectory(destination);
                using ZipArchive zip = ZipFile.OpenRead(archive);
                int total = zip.Entries.Count;
                int done = 0;
                foreach (ZipArchiveEntry entry in zip.Entries)
                {
                    string target = Path.Combine(destination, entry.FullName);
                    if (entry.FullName.EndsWith('\\') || entry.FullName.EndsWith(Path.AltDirectorySeparatorChar))
                    {
                        Directory.CreateDirectory(target);
                    }
                    else
                    {
                        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                        entry.ExtractToFile(target, overwrite: true);
                    }
                    done++;
                    if (done % 200 == 0)
                    {
                        report?.Invoke(done * 100.0 / Math.Max(1, total),
                            "Extracting " + Path.GetFileName(archive) + "... " + done + "/" + total + " files");
                    }
                }
            });
        }

        /// <summary>
        /// Ensures the x64 7-Zip engine. The bundled 7zr is x86 and decodes
        /// on a single core, which turns a 49 GB extraction into a very long
        /// wait; the x64 build in the "extra" package uses several cores.
        /// Returns false when it cannot be prepared (the caller falls back).
        /// </summary>
        public static async Task<bool> EnsureSevenZip64Async(
            ReportDelegate? report = null, CancellationToken ct = default)
        {
            if (File.Exists(GameFiles.SevenZip64)) return true;

            try
            {
                if (!File.Exists(GameFiles.SevenZip))
                {
                    report?.Invoke(-1, "Toolchain: downloading 7-Zip (7zr)...");
                    await SendDownloadAsync(GameFiles.SevenZipUrl, GameFiles.SevenZip, "7-Zip console 7zr",
                        retries: 3, report: report, ct: ct);
                }

                string archive = Path.Combine(GameFiles.Downloads, "7z-extra.7z");
                report?.Invoke(-1, "Toolchain: downloading the x64 7-Zip engine...");
                await SendDownloadAsync(GameFiles.SevenZipExtraUrl, archive, "7-Zip x64",
                    bytes: GameFiles.SevenZipExtraBytes, sha256: GameFiles.SevenZipExtraSha256,
                    retries: 3, report: report, ct: ct);

                string temp = Path.Combine(Path.GetTempPath(), "cage-7z-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(temp);
                try
                {
                    string log = Path.Combine(temp, "extract.log");
                    int code = await RunWithLogRedirectAsync(
                        GameFiles.SevenZip,
                        "x \"" + archive + "\" \"x64\\7za.exe\" -o\"" + temp + "\" -y -bso0 -bse1",
                        report, TimeSpan.FromSeconds(1), log, ct);
                    if (code != 0)
                    {
                        report?.Invoke(-1, "Toolchain: 7-Zip x64 extraction failed (code " + code + ").");
                        return false;
                    }

                    string x64 = Path.Combine(temp, "x64", "7za.exe");
                    if (!File.Exists(x64))
                    {
                        report?.Invoke(-1, "Toolchain: 7za.exe is missing from the package.");
                        return false;
                    }

                    Directory.CreateDirectory(GameFiles.ToolsDir);
                    File.Copy(x64, GameFiles.SevenZip64, overwrite: true);
                    report?.Invoke(-1, "Toolchain: 7-Zip x64 ready");
                    return true;
                }
                finally
                {
                    try { Directory.Delete(temp, recursive: true); } catch { }
                }
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                report?.Invoke(-1, "Toolchain: 7-Zip x64 unavailable (" + ex.Message + ").");
                return false;
            }
        }

        /// <summary>
        /// 7z extraction with the real percentage. Uses the x64 engine when
        /// available and falls back to 7zr otherwise.
        /// </summary>
        public static async Task Extract7zAsync(
            string archive, string destination, string label,
            ReportDelegate? report = null, CancellationToken ct = default)
        {
            string tool = GameFiles.SevenZip64;
            if (!await EnsureSevenZip64Async(report, ct))
            {
                if (!File.Exists(GameFiles.SevenZip))
                {
                    report?.Invoke(-1, "Toolchain: downloading 7-Zip (7zr)...");
                    await SendDownloadAsync(GameFiles.SevenZipUrl, GameFiles.SevenZip, "7-Zip console 7zr",
                        retries: 3, report: report, ct: ct);
                }
                tool = GameFiles.SevenZip;
                report?.Invoke(-1, "Toolchain: using 7zr, the extraction will be slower.");
            }
            if (!File.Exists(archive))
            {
                throw new Exception("Archive not found: " + archive);
            }
            Directory.CreateDirectory(destination);

            string log = Path.Combine(Path.GetTempPath(), "lunartear-extract-" + Guid.NewGuid().ToString("N") + ".log");
            report?.Invoke(-1, label + " - starting (this can take several minutes)...");

            int code = await RunWithLogRedirectAsync(
                tool,
                "x \"" + archive + "\" -o\"" + destination + "\" -y -bso0 -bse1 -bsp1",
                report, TimeSpan.FromSeconds(2), log, ct);

            if (code != 0)
            {
                string detail = string.Join(" | ", LastLogLines(log, 6));
                throw new Exception("Extraction failed (code " + code + "). " + detail);
            }
            File.Delete(log);
            report?.Invoke(100, label + " completed");
        }

        /// <summary>cmd /c "tool args > log 2>&1", polling the log tail (Invoke-Tool port).</summary>
        public static async Task<int> InvokeToolAsync(
            string file, string[] arguments, string label,
            ReportDelegate? report = null, int timeoutSeconds = 3600,
            CancellationToken ct = default)
        {
            if (!File.Exists(file))
            {
                throw new Exception("Executable not found: " + file);
            }

            string log = Path.Combine(Path.GetTempPath(), "lunartear-tool-" + Guid.NewGuid().ToString("N") + ".log");
            string call = QuoteArguments(arguments);
            report?.Invoke(-1, label + " - started");

            var sw = Stopwatch.StartNew();
            int code = await RunWithLogRedirectAsync(
                file, call, report, TimeSpan.FromMilliseconds(800), log, ct,
                prefix: label + "  ", timeoutSeconds: timeoutSeconds, elapsed: sw);

            foreach (string line in LastLogLines(log, 14))
            {
                report?.Invoke(-1, "  " + (line.Length > 300 ? line[..300] : line));
            }
            File.Delete(log);
            if (code != 0)
            {
                throw new Exception(label + " failed (exit code " + code + ")");
            }
            report?.Invoke(-1, label + " - done in " + sw.Elapsed.ToString(@"mm\:ss"));
            return code;
        }

        /// <summary>cmd-line quoting (internal: covered by unit tests).</summary>
        internal static string QuoteArguments(string[] parts) =>
            string.Join(' ', parts.Select(p =>
                (p.Contains(' ') || p.Contains('"') || p.Length == 0)
                    ? "\"" + p.Replace("\"", "\\\"") + "\""
                    : p));

        /// <summary>
        /// Shared runner: cmd /c "tool args > log 2>&1"; polls the log tail
        /// and forwards it through the report callback.
        /// </summary>
        private static async Task<int> RunWithLogRedirectAsync(
            string file, string call, ReportDelegate? report, TimeSpan pollInterval,
            string log, CancellationToken ct,
            string prefix = "", int timeoutSeconds = 0, Stopwatch? elapsed = null)
        {
            ProcessStartInfo psi = new()
            {
                FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe",
                Arguments = "/c \"\"" + file + "\" " + call + " > \"" + log + "\" 2>&1\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = GameFiles.Root,
            };

            using Process process = Process.Start(psi)!;
            try
            {
                int lastPercent = -1;
                while (!process.HasExited)
                {
                    await Task.Delay(pollInterval, ct);

                    string tail = LastLogLines(log, 1).FirstOrDefault() ?? string.Empty;
                    double percent = -1;
                    Match m = Regex.Matches(tail, @"(\d{1,3})%").Cast<Match>().LastOrDefault();
                    if (m != null) percent = int.Parse(m.Groups[1].Value);

                    string detail = tail.Length > 100 ? tail[..100].Trim() : tail.Trim();
                    string text = prefix;
                    if (timeoutSeconds > 0 && elapsed != null)
                    {
                        text += elapsed.Elapsed.ToString(@"mm\:ss");
                    }
                    if (detail.Length > 0) text += detail;

                    if (percent >= 0 && (int)percent != lastPercent)
                    {
                        lastPercent = (int)percent;
                        report?.Invoke(percent, text);
                    }
                    else
                    {
                        report?.Invoke(-1, text);
                    }

                    if (timeoutSeconds > 0 && elapsed != null && elapsed.Elapsed.TotalSeconds > timeoutSeconds)
                    {
                        KillProcessTree(process);
                        throw new Exception("Timed out after " + timeoutSeconds + " seconds");
                    }
                }

                await process.WaitForExitAsync(ct);
            }
            catch (OperationCanceledException)
            {
                // Cancel aborts the external tool too (7z, apktool, sign...).
                // The process tree matters: cmd.exe hosts the tool, and
                // killing only cmd would leave 7z running in the background.
                KillProcessTree(process);
                throw;
            }
            finally
            {
                KillProcessTree(process);
            }
            return process.ExitCode;
        }

        private static void KillProcessTree(Process process)
        {
            try
            {
                if (process.HasExited) return;
                process.Kill(entireProcessTree: true);
                process.WaitForExit(5000);
            }
            catch
            {
                // Already gone or not killable: nothing else to do.
            }
        }

        /// <summary>Log tail (internal: covered by unit tests).</summary>
        internal static string[] LastLogLines(string log, int count, int bytes = 8192)
        {
            if (!File.Exists(log)) return Array.Empty<string>();
            try
            {
                using FileStream fs = File.Open(log, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                long length = fs.Length;
                int read = (int)Math.Min(bytes, length);
                if (read <= 0) return Array.Empty<string>();
                fs.Seek(length - read, SeekOrigin.Begin);
                byte[] buffer = new byte[read];
                fs.ReadExactly(buffer, 0, read);
                string text = System.Text.Encoding.UTF8.GetString(buffer);
                return text.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None)
                           .Where(l => l.Trim().Length > 0)
                           .TakeLast(count)
                           .ToArray();
            }
            catch
            {
                return Array.Empty<string>();
            }
        }
    }
}
