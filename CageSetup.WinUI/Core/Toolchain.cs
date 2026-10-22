using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace CageSetup.WinUI.Core
{
    /// <summary>
    /// The on-demand toolchain (Java, apktool, Android build tools, Python),
    /// ported from 05-client-build.ps1. Every download is pinned by size and
    /// SHA256; the Python runtime ships with site-packages disabled, which
    /// the .pth fix below re-enables before the wheels are unpacked.
    /// </summary>
    public static class Toolchain
    {
        private static string? _javaExe;
        private static string? _pythonExe;

        private static string? FindInDirectories(
            IEnumerable<string> directories, string leaf, Func<string, bool>? filter = null)
        {
            foreach (string dir in directories)
            {
                if (!Directory.Exists(dir)) continue;
                try
                {
                    foreach (string candidate in Directory.EnumerateFiles(dir, leaf, SearchOption.AllDirectories))
                    {
                        if (filter == null || filter(candidate)) return candidate;
                    }
                }
                catch
                {
                    // Unreadable folders are skipped.
                }
            }
            return null;
        }

        // ------------------------------------------------------------------
        // Java
        // ------------------------------------------------------------------

        public static string? FindJava()
        {
            if (_javaExe != null && File.Exists(_javaExe)) return _javaExe;

            string? found = FindInDirectories(new[] { GameFiles.JdkDir, GameFiles.ToolsDir },
                "java.exe", filter => !filter.Contains("android-sdk", StringComparison.OrdinalIgnoreCase));
            if (found == null)
            {
                string path = Environment.GetEnvironmentVariable("PATH") ?? "";
                foreach (string dir in path.Split(';', StringSplitOptions.RemoveEmptyEntries))
                {
                    try
                    {
                        string candidate = Path.Combine(dir.Trim(), "java.exe");
                        if (File.Exists(candidate)) { found = candidate; break; }
                    }
                    catch
                    {
                        // Skip malformed PATH entries.
                    }
                }
            }
            _javaExe = found;
            return found;
        }

        public static async Task<bool> EnsureJdk(Downloader.ReportDelegate report, CancellationToken ct)
        {
            string? java = FindJava();
            if (java != null)
            {
                report(-1, "Java runtime: " + java);
                return true;
            }

            report(-1, "Toolchain: downloading the Java runtime (JRE 17, about 44 MB)");
            string zip = Path.Combine(GameFiles.Downloads, "jre17.zip");
            await Downloader.SendDownloadAsync(GameFiles.JreUrl, zip, "Java runtime (JRE 17)",
                bytes: GameFiles.JreBytes, sha256: GameFiles.JreSha256, report: report, ct: ct);
            await Downloader.ExtractZipAsync(zip, GameFiles.JdkDir, report);
            java = FindJava();
            if (java != null)
            {
                report(-1, "Java runtime ready");
                return true;
            }
            report(-1, "Java runtime missing after extraction");
            return false;
        }

        // ------------------------------------------------------------------
        // apktool / build tools
        // ------------------------------------------------------------------

        public static async Task<bool> EnsureApktool(Downloader.ReportDelegate report, CancellationToken ct)
        {
            if (File.Exists(GameFiles.ApktoolJar))
            {
                report(-1, "apktool: " + GameFiles.ApktoolJar);
                return true;
            }
            report(-1, "Toolchain: downloading apktool (about 15 MB)");
            await Downloader.SendDownloadAsync(GameFiles.ApktoolUrl, GameFiles.ApktoolJar, "apktool",
                bytes: GameFiles.ApktoolBytes, sha256: GameFiles.ApktoolSha256, report: report, ct: ct);
            return File.Exists(GameFiles.ApktoolJar);
        }

        private static string? FindBuildTool(string leaf)
        {
            string[] dirs =
            {
                GameFiles.BuildToolsDir,
                Path.Combine(GameFiles.ToolsDir, "android-sdk", "build-tools"),
            };
            string? best = null;
            foreach (string dir in dirs)
            {
                if (!Directory.Exists(dir)) continue;
                try
                {
                    string? candidate = Directory.EnumerateFiles(dir, leaf, SearchOption.AllDirectories)
                        .OrderByDescending(f => f, StringComparer.OrdinalIgnoreCase)
                        .FirstOrDefault();
                    if (candidate != null && (best == null ||
                        string.CompareOrdinal(candidate, best) > 0)) best = candidate;
                }
                catch
                {
                    // Unreadable folders are skipped.
                }
            }
            return best;
        }

        public static (string? ZipAlign, string? ApkSigner) BuildToolsState =>
            (FindBuildTool("zipalign.exe"), FindBuildTool("apksigner.jar"));

        public static async Task<bool> EnsureBuildTools(Downloader.ReportDelegate report, CancellationToken ct)
        {
            (string? zipAlign, string? signer) = BuildToolsState;
            if (zipAlign != null && signer != null)
            {
                report(-1, "Android build tools: " + zipAlign);
                return true;
            }

            report(-1, "Toolchain: downloading the Android build tools (about 60 MB)");
            string zip = Path.Combine(GameFiles.Downloads, "build-tools.zip");
            await Downloader.SendDownloadAsync(GameFiles.BuildToolsUrl, zip, "Android build tools",
                bytes: GameFiles.BuildToolsBytes, sha256: GameFiles.BuildToolsSha256, report: report, ct: ct);
            await Downloader.ExtractZipAsync(zip, GameFiles.BuildToolsDir, report);

            (zipAlign, signer) = BuildToolsState;
            if (zipAlign != null && signer != null)
            {
                report(-1, "Android build tools ready");
                return true;
            }
            report(-1, "Android build tools missing after extraction");
            return false;
        }

        // ------------------------------------------------------------------
        // Python (embedded runtime + wheels)
        // ------------------------------------------------------------------

        private static bool TestPythonModules(string python)
        {
            if (!File.Exists(python)) return false;
            try
            {
                using Process process = Process.Start(new ProcessStartInfo
                {
                    FileName = python,
                    Arguments = "-c \"import Crypto, lz4.block, msgpack; print('modules-ok')\"",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                })!;
                process.WaitForExit(60000);
                string output = process.StandardOutput.ReadToEnd() + " " + process.StandardError.ReadToEnd();
                return output.Contains("modules-ok");
            }
            catch
            {
                return false;
            }
        }

        private static async Task<string> GetPyPiWheelUrl(string package, CancellationToken ct)
        {
            using HttpClient client = new();
            client.Timeout = TimeSpan.FromSeconds(60);
            using HttpResponseMessage response =
                await client.GetAsync("https://pypi.org/pypi/" + package + "/json", ct);
            response.EnsureSuccessStatusCode();
            await using Stream stream = await response.Content.ReadAsStreamAsync(ct);
            using JsonDocument doc = await JsonDocument.ParseAsync(stream, cancellationToken: ct);

            string? bestUrl = null;
            string? bestTime = null;
            foreach (JsonElement file in doc.RootElement.GetProperty("urls").EnumerateArray())
            {
                string? filename = file.TryGetProperty("filename", out JsonElement f) ? f.GetString() : null;
                if (filename == null || !filename.EndsWith("win_amd64.whl")) continue;
                if (!filename.Contains("cp312") && !filename.Contains("abi3")) continue;
                string? uploaded = file.TryGetProperty("upload_time", out JsonElement t) ? t.GetString() : null;
                if (uploaded == null || string.CompareOrdinal(uploaded, bestTime) > 0)
                {
                    bestTime = uploaded;
                    bestUrl = file.GetProperty("url").GetString();
                }
            }
            if (bestUrl == null)
            {
                throw new Exception("No Windows wheel available for " + package);
            }
            return bestUrl;
        }

        public static async Task<string?> EnsurePython(Downloader.ReportDelegate report, CancellationToken ct)
        {
            string python = Path.Combine(GameFiles.PythonDir, "python.exe");
            if (_pythonExe != null && TestPythonModules(_pythonExe)) return _pythonExe;

            if (!File.Exists(python))
            {
                report(-1, "Toolchain: downloading the Python runtime (about 11 MB)");
                string zip = Path.Combine(GameFiles.Downloads, "python-embed.zip");
                await Downloader.SendDownloadAsync(GameFiles.PythonUrl, zip, "Python runtime",
                    bytes: GameFiles.PythonBytes, sha256: GameFiles.PythonSha256, report: report, ct: ct);
                await Downloader.ExtractZipAsync(zip, GameFiles.PythonDir, report);
            }
            if (!File.Exists(python))
            {
                report(-1, "Python runtime missing after extraction");
                return null;
            }

            // The embedded runtime ships with site-packages disabled.
            try
            {
                string? pth = Directory.EnumerateFiles(GameFiles.PythonDir, "python*._pth").FirstOrDefault();
                if (pth != null)
                {
                    string[] lines = File.ReadAllLines(pth);
                    lines = lines.Select(l =>
                            Regex.IsMatch(l, @"^\s*#\s*import site") ? "import site" : l)
                        .ToList()
                        .Append(@"Lib\site-packages")
                        .DoNotRepeat()
                        .ToArray();
                    File.WriteAllLines(pth, lines);
                }
            }
            catch
            {
                // A read-only .pth only breaks the wheel install, caught below.
            }
            _pythonExe = python;
            if (TestPythonModules(python))
            {
                report(-1, "Python runtime ready");
                return python;
            }

            string site = Path.Combine(GameFiles.PythonDir, "Lib", "site-packages");
            Directory.CreateDirectory(site);
            foreach (string package in new[] { "pycryptodome", "msgpack", "lz4" })
            {
                string url = await GetPyPiWheelUrl(package, ct);
                string wheel = Path.Combine(GameFiles.Downloads, Path.GetFileName(url));
                await Downloader.SendDownloadAsync(url, wheel, "Python module: " + package,
                    report: report, ct: ct);
                await Downloader.ExtractZipAsync(wheel, site, report);
            }

            if (TestPythonModules(python))
            {
                report(-1, "Python modules ready");
                return python;
            }
            report(-1, "Python modules are not usable");
            return null;
        }

        // ------------------------------------------------------------------
        // Official patcher scripts (pinned commit)
        // ------------------------------------------------------------------

        public static async Task<string> GetLunarScript(string name, Downloader.ReportDelegate report, CancellationToken ct)
        {
            string dest = Path.Combine(GameFiles.ScriptsDir, name.Replace('/', '\\'));
            if (File.Exists(dest)) return dest;

            Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
            string url = GameFiles.ScriptsRaw + "/" + name;
            await Downloader.SendDownloadAsync(url, dest, "lunar-scripts: " + Path.GetFileName(name),
                retries: 3, report: report, ct: ct);
            if (!File.Exists(dest))
            {
                throw new Exception("Cannot download the script: " + url);
            }
            return dest;
        }
    }

    internal static class ToolchainLocal
    {
        /// <summary>Adds the value only when the list does not already contain it.</summary>
        public static IEnumerable<string> DoNotRepeat(this IEnumerable<string> source)
        {
            HashSet<string> seen = new(StringComparer.OrdinalIgnoreCase);
            foreach (string item in source)
            {
                if (seen.Add(item)) yield return item;
            }
        }
    }
}
