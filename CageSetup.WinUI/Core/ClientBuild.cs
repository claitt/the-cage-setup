using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace CageSetup.WinUI.Core
{
    /// <summary>
    /// Client build, ported from 05-client-build.ps1: the stock APK comes
    /// from APKMirror (read with curl.exe, which .NET cannot scrape), gets
    /// decompiled with apktool, patched with the official lunar-scripts
    /// patcher, rebuilt, aligned, signed and verified. The toolchain is
    /// downloaded on demand.
    /// </summary>
    public static class ClientBuild
    {
        // ------------------------------------------------------------------
        // APK archive self-check (Test-ApkArchive)
        // ------------------------------------------------------------------

        private static bool IsApkArchive(string path)
        {
            if (string.IsNullOrEmpty(path) || !File.Exists(path)) return false;
            try
            {
                using ZipArchive zip = ZipFile.OpenRead(path);
                string[] names = zip.Entries.Select(e => e.FullName).ToArray();
                return names.Contains("lib/arm64-v8a/libil2cpp.so") &&
                       names.Contains("assets/bin/Data/Managed/Metadata/global-metadata.dat");
            }
            catch
            {
                return false;
            }
        }

        public static bool LooksLikeApk(string path) => IsApkArchive(path);

        private static string? CurlExe()
        {
            string path = Environment.GetEnvironmentVariable("PATH") ?? "";
            foreach (string dir in path.Split(';', StringSplitOptions.RemoveEmptyEntries))
            {
                try
                {
                    string candidate = Path.Combine(dir.Trim(), "curl.exe");
                    if (File.Exists(candidate)) return candidate;
                }
                catch
                {
                    // Skip malformed PATH entries.
                }
            }
            string system = Path.Combine(Environment.SystemDirectory, "curl.exe");
            return File.Exists(system) ? system : null;
        }

        private static string UserAgent() =>
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

        // ------------------------------------------------------------------
        // Stock APK from APKMirror
        // ------------------------------------------------------------------

        /// <summary>Get-ApkmirrorApk. Returns false on any failure.</summary>
        public static async Task<bool> GetApkmirrorApk(
            string destination, Downloader.ReportDelegate report, CancellationToken ct)
        {
            if (IsApkArchive(destination))
            {
                report(-1, "Stock APK already downloaded: " + destination);
                return true;
            }

            string? curl = CurlExe();
            if (curl == null)
            {
                report(-1, "curl.exe not found. Windows 10 version 1803 or newer is required.");
                return false;
            }

            report(-1, "Client: looking for the stock APK on APKMirror");
            string ua = UserAgent();
            string work = Path.Combine(Path.GetTempPath(), "lunartear-apk-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(work);
            string jar = Path.Combine(work, "cookies.txt");

            try
            {
                // 1) variant page -> "/.../download/?key=..."
                string page1 = Path.Combine(work, "page1.html");
                await RunCurlAsync(curl, ua, $"-s -L --compressed -A {ua} -c {jar} -b {jar} -o {page1}",
                    GameFiles.ApkPageUrl, ct);
                if (!File.Exists(page1))
                {
                    report(-1, "APKMirror is not reachable");
                    return false;
                }
                string html = await File.ReadAllTextAsync(page1, ct);
                Match m = Regex.Match(html, "href=\"([^\"]*?/download/\\?key=[^\"]+)\"");
                if (!m.Success)
                {
                    report(-1, "download link not found on the APKMirror page (the page layout may have changed)");
                    return false;
                }
                string step2Url = new Uri(new Uri(GameFiles.ApkPageUrl), m.Groups[1].Value.Replace("&amp;", "&")).AbsoluteUri;
                report(-1, "Client: variant download page found");

                // 2) download page -> "download.php?id=...&key=..."
                string page2 = Path.Combine(work, "page2.html");
                await RunCurlAsync(curl, ua, $"-s -L --compressed -A {ua} -e {GameFiles.ApkPageUrl} -c {jar} -b {jar} -o {page2}",
                    step2Url, ct);
                html = await File.ReadAllTextAsync(page2, ct);
                m = Regex.Match(html, "href=\"([^\"]*?download\\.php\\?id=\\d+&(?:amp;)?key=[^\"]+)\"");
                if (!m.Success)
                {
                    report(-1, "final download link not found on the APKMirror page");
                    return false;
                }
                string step3Url = new Uri(new Uri(step2Url), m.Groups[1].Value.Replace("&amp;", "&")).AbsoluteUri;

                // 3) the endpoint answers with a redirect to the CDN (1h validity)
                string headers = Path.Combine(work, "headers.txt");
                await RunCurlAsync(curl, ua, $"-s -D {headers} -o NUL --max-redirs 0 -A {ua} -e {step2Url} -c {jar} -b {jar}",
                    step3Url, ct);
                string? location = (await File.ReadAllLinesAsync(headers, ct))
                    .FirstOrDefault(l => l.StartsWith("location:", StringComparison.OrdinalIgnoreCase));
                if (location == null)
                {
                    report(-1, "the download endpoint did not return a redirect");
                    return false;
                }
                string finalUrl = Regex.Replace(location, @"^location:\s*", "").Trim();
                report(-1, "Client: direct download link obtained");

                // 4) stream the APK to disk with progress
                Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                string partial = destination + ".part";

                using HttpClientHandler handler = new() { AllowAutoRedirect = true };
                using HttpClient client = new(handler) { Timeout = TimeSpan.FromMinutes(60) };
                using HttpRequestMessage request = new(HttpMethod.Get, finalUrl);
                request.Headers.TryAddWithoutValidation("User-Agent", ua);
                using HttpResponseMessage response =
                    await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
                response.EnsureSuccessStatusCode();

                long total = GameFiles.ApkStockBytes;
                if (response.Content.Headers.ContentLength is long length && length > 0) total = length;

                await using Stream stream = await response.Content.ReadAsStreamAsync(ct);
                await using FileStream output = File.Create(partial);
                byte[] buffer = new byte[1024 * 1024];
                long done = 0;
                var sw = Stopwatch.StartNew();
                double lastMs = 0;
                long lastBytes = 0;

                int read;
                while ((read = await stream.ReadAsync(buffer, ct)) > 0)
                {
                    await output.WriteAsync(buffer, 0, read, ct);
                    done += read;
                    double ms = sw.Elapsed.TotalMilliseconds;
                    if (ms - lastMs >= 600)
                    {
                        double speed = (done - lastBytes) / ((ms - lastMs) / 1000.0);
                        lastMs = ms;
                        lastBytes = done;
                        report?.Invoke(total > 0 ? done * 100.0 / total : -1,
                            Downloader.ProgressText("Downloading the game client from APKMirror", done, total, speed));
                    }
                }

                if (File.Exists(destination)) File.Delete(destination);
                File.Move(partial, destination);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                report(-1, ex.Message);
                return false;
            }
            finally
            {
                try { Directory.Delete(work, recursive: true); } catch { }
            }

            if (!IsApkArchive(destination))
            {
                report(-1, "The downloaded file is not a valid APK");
                return false;
            }

            string hash = HashHelper.Sha256(destination);
            if (!hash.Equals(GameFiles.ApkStockSha256, StringComparison.OrdinalIgnoreCase))
            {
                File.Delete(destination);
                report(-1, "Stock APK checksum mismatch: expected " + GameFiles.ApkStockSha256 +
                           ", got " + hash + ". The file was removed, please retry.");
                return false;
            }
            report(-1, "Stock APK verified (SHA256)");
            report(-1, "Stock APK downloaded: " + new FileInfo(destination).Length / 1048576.0 + " MB");
            return true;
        }

        private static async Task RunCurlAsync(string curl, string ua, string args, string url, CancellationToken ct)
        {
            ProcessStartInfo psi = new()
            {
                FileName = curl,
                // -A ua is part of args, but the UA contains no spaces risk:
                // pass it quoted through the whole argument string.
                Arguments = args.Replace(ua, "\"" + ua + "\"") + " \"" + url + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = false,
                RedirectStandardError = true,
            };
            using Process process = Process.Start(psi)!;
            await process.WaitForExitAsync(ct);
        }

        // ------------------------------------------------------------------
        // Build (apktool decompile -> patch -> rebuild -> align -> sign)
        // ------------------------------------------------------------------

        private static bool BuildCurrent()
        {
            if (!File.Exists(GameFiles.ApkOutput)) return false;
            string marker = Path.Combine(GameFiles.ApkOutDir, ".build.txt");
            if (!File.Exists(marker)) return false;
            string wanted = GameFiles.GrpcAddr + "|" + GameFiles.HttpAddr + "|" + GameFiles.AuthAddr;
            try
            {
                return File.ReadAllText(marker).Trim().Equals(wanted, StringComparison.Ordinal);
            }
            catch
            {
                return false;
            }
        }

        /// <summary>Build-ClientApk: each step fails on its own and is reported.</summary>
        public static async Task<bool> BuildClientApk(
            Downloader.ReportDelegate report, CancellationToken ct)
        {
            report(-1, "Client: building the patched APK (a few minutes)");

            double free = GameFiles.FreeSpaceGB();
            if (free < 8)
            {
                report(-1, "At least 8 GB free in the game files folder are required to build the APK (you have " + free + " GB).");
                return false;
            }

            if (BuildCurrent())
            {
                report(-1, "Patched APK already built for these addresses");
                return true;
            }

            // The stock APK is the most fragile step (upstream page): first.
            if (!await GetApkmirrorApk(GameFiles.ApkStockFile, report, ct)) return false;

            if (!await Toolchain.EnsureJdk(report, ct)) return false;
            if (!await Toolchain.EnsureApktool(report, ct)) return false;
            if (!await Toolchain.EnsureBuildTools(report, ct)) return false;
            string? python = await Toolchain.EnsurePython(report, ct);
            if (python == null) return false;

            string? java = Toolchain.FindJava();
            if (java == null)
            {
                report(-1, "Java runtime not found");
                return false;
            }
            (string? zipalign, string? signerJar) = Toolchain.BuildToolsState;
            if (zipalign == null || signerJar == null)
            {
                report(-1, "Android build tools missing");
                return false;
            }

            string work = GameFiles.ApkWorkDir;
            string unaligned = Path.Combine(GameFiles.ApkOutDir, "nier-unaligned.apk");
            string aligned = Path.Combine(GameFiles.ApkOutDir, "nier-aligned.apk");
            Directory.CreateDirectory(GameFiles.ApkOutDir);

            try
            {
                // 1) decompile (apktool)
                try { Directory.Delete(work, recursive: true); } catch { }
                await Downloader.InvokeToolAsync(java,
                    new[] { "-Xmx2g", "-jar", GameFiles.ApktoolJar, "d", GameFiles.ApkStockFile, "-o", work, "-f" },
                    "Decompiling the APK (apktool)", report, ct: ct);

                // 2) patch the decompiled tree (official patcher)
                string patcher = await Toolchain.GetLunarScript("android/patch_apk.py", report, ct);
                await Downloader.InvokeToolAsync(python,
                    new[] { "-X", "utf8", patcher, work, "--grpc-addr", GameFiles.GrpcAddr,
                            "--http-addr", GameFiles.HttpAddr, "--auth-host", GameFiles.AuthAddr },
                    "Patching the game client", report, ct: ct);

                // 3) rebuild
                try { File.Delete(unaligned); } catch { }
                await Downloader.InvokeToolAsync(java,
                    new[] { "-Xmx2g", "-jar", GameFiles.ApktoolJar, "b", work, "-o", unaligned },
                    "Rebuilding the APK (apktool)", report, ct: ct);

                // 4) align
                try { File.Delete(aligned); } catch { }
                await Downloader.InvokeToolAsync(zipalign,
                    new[] { "-p", "-f", "4", unaligned, aligned },
                    "Aligning the APK (zipalign)", report, ct: ct);

                // 5) signing key (created once, reused)
                if (!File.Exists(GameFiles.Keystore))
                {
                    string keytool = Path.Combine(Path.GetDirectoryName(java)!, "keytool.exe");
                    if (!File.Exists(keytool))
                    {
                        report(-1, "keytool.exe not found next to the Java runtime");
                        return false;
                    }
                    await Downloader.InvokeToolAsync(keytool,
                        new[]
                        {
                            "-genkeypair", "-keystore", GameFiles.Keystore, "-alias", "androiddebugkey",
                            "-storepass", "android", "-keypass", "android", "-keyalg", "RSA",
                            "-keysize", "2048", "-validity", "10000",
                            "-dname", "CN=Android Debug,O=Android,C=US",
                        },
                        "Creating the signing key", report, ct: ct);
                }

                // 6) sign + verify
                try { File.Delete(GameFiles.ApkOutput); } catch { }
                await Downloader.InvokeToolAsync(java,
                    new[]
                    {
                        "-jar", signerJar, "sign", "--ks", GameFiles.Keystore,
                        "--ks-pass", "pass:android", "--key-pass", "pass:android",
                        "--out", GameFiles.ApkOutput, aligned,
                    },
                    "Signing the APK (apksigner)", report, ct: ct);
                await Downloader.InvokeToolAsync(java,
                    new[] { "-jar", signerJar, "verify", "--print-certs", GameFiles.ApkOutput },
                    "Verifying the signature", report, ct: ct);

                string marker = GameFiles.GrpcAddr + "|" + GameFiles.HttpAddr + "|" + GameFiles.AuthAddr;
                await File.WriteAllTextAsync(Path.Combine(GameFiles.ApkOutDir, ".build.txt"), marker, ct);

                report(-1, "Patched APK ready: " + GameFiles.ApkOutput + " (" +
                           new FileInfo(GameFiles.ApkOutput).Length / 1048576.0 + " MB)");
                return true;
            }
            finally
            {
                try { Directory.Delete(work, recursive: true); } catch { }
                try { File.Delete(unaligned); } catch { }
                try { File.Delete(aligned); } catch { }
            }
        }
    }
}
