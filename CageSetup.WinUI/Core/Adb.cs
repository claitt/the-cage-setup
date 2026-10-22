using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace CageSetup.WinUI.Core
{
    /// <summary>
    /// ADB helpers for the client install, ported from lib\03-utilities.ps1
    /// (Find-AdbExe, Get-Adb, Test-EmulatorRunning, Test-GameInstalled,
    /// Test-DebloatApplied and Invoke-MuMuDebloat). MuMuPlayer exposes ADB
    /// on 127.0.0.1:7555; the binary ships in the engine folder, one per
    /// version, and the newest one wins (like Find-AdbExe).
    /// </summary>
    public static class Adb
    {
        public const string Serial = "127.0.0.1:7555";
        public const string PackageMatch = "nierspww";
        public const string DebloatProbe = "com.mumu.store";

        // 1.x Invoke-MuMuDebloat: only the NetEase/MuMu components, and
        // everything is reversible (pm install-existing / pm enable); the
        // game, Google services and the rest of Android stay untouched.
        public static readonly string[] DebloatRemove =
        {
            "com.mumu.store",             // MuMu app store
            "com.mumu.shared.sdk",        // MuMu shared SDK
            "com.mumu.acc",               // MuMu account
            "com.nemu.nlp",               // NetEase NLP service
            "com.nemu.oaidmanager",       // OAID / advertising id
            "com.netease.mumu.cloner",    // app cloner
        };

        public static readonly string[] DebloatDisable =
        {
            "com.sohu.inputmethod.sogou.chuizi",   // Chinese Sogou keyboard
        };

        // Small caches: a status refresh asks these several times and every
        // ADB call costs about a second (same idea as the 1.x script).
        private static (DateTime Time, bool Value) _runningCache;
        private static (DateTime Time, bool Value) _gameCache;
        private static (DateTime Time, bool Value) _debloatCache;

        private static bool CacheValid((DateTime Time, bool Value) cache) =>
            cache.Value && (DateTime.UtcNow - cache.Time).TotalSeconds < 3;

        // ------------------------------------------------------------------
        // adb discovery
        // ------------------------------------------------------------------

        /// <summary>
        /// Find-AdbExe: the newest engine folder wins, then the
        /// android-sdk copy inside the game files folder.
        /// </summary>
        public static string? FindAdbExe(string? muMuDir, string baseDir)
        {
            List<(Version Version, string Dir)> engines = new();
            if (!string.IsNullOrWhiteSpace(muMuDir))
            {
                string device = Path.Combine(muMuDir, "nx_device");
                if (Directory.Exists(device))
                {
                    try
                    {
                        foreach (string dir in Directory.GetDirectories(device))
                        {
                            Version version = Version.TryParse(Path.GetFileName(dir), out Version? parsed) && parsed != null
                                ? parsed
                                : new Version(0, 0);
                            engines.Add((version, dir));
                        }
                    }
                    catch
                    {
                        // Unreadable engine folders are skipped.
                    }
                }
            }

            List<string> candidates = new();
            foreach ((Version _, string dir) in engines.OrderByDescending(e => e.Version))
            {
                candidates.Add(Path.Combine(dir, "shell", "adb.exe"));
            }
            candidates.Add(Path.Combine(baseDir, "tools", "android-sdk", "platform-tools", "adb.exe"));

            return candidates.FirstOrDefault(File.Exists);
        }

        public static string? MuMuManagerPath(string? muMuDir) =>
            string.IsNullOrWhiteSpace(muMuDir)
                ? null
                : Path.Combine(muMuDir, "nx_main", "MuMuManager.exe");

        // ------------------------------------------------------------------
        // adb invocation
        // ------------------------------------------------------------------

        /// <summary>
        /// Runs adb (or MuMuManager) and returns the combined output.
        /// Cancels by killing the process; converts a timeout into a clear
        /// exception so callers can report it.
        /// </summary>
        private static async Task<string> RunAsync(
            string exe, string[] arguments, CancellationToken ct, int timeoutSeconds = 30)
        {
            var psi = new ProcessStartInfo
            {
                FileName = exe,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };
            foreach (string argument in arguments)
            {
                psi.ArgumentList.Add(argument);
            }

            using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));

            Process? process = Process.Start(psi);
            if (process == null)
            {
                throw new Exception("Cannot start " + Path.GetFileName(exe));
            }

            try
            {
                using (process)
                {
                    Task<string> stdout = process.StandardOutput.ReadToEndAsync();
                    Task<string> stderr = process.StandardError.ReadToEndAsync();
                    await process.WaitForExitAsync(timeout.Token);
                    await Task.WhenAll(stdout, stderr);
                    return stdout.Result + stderr.Result;
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                try { process.Kill(); } catch { /* already gone */ }
                throw;
            }
            catch (OperationCanceledException)
            {
                try { process.Kill(); } catch { /* already gone */ }
                throw new Exception(Path.GetFileName(exe) + " timed out after " + timeoutSeconds + " seconds");
            }
        }

        // ------------------------------------------------------------------
        // state probes (ports of Test-EmulatorRunning / Test-GameInstalled /
        // Test-DebloatApplied)
        // ------------------------------------------------------------------

        /// <summary>
        /// Test-EmulatorRunning: `adb devices`, and `adb connect`
        /// once when the serial is missing before giving up.
        /// </summary>
        public static async Task<bool> EmulatorRunningAsync(
            string? adb, bool force = false, CancellationToken ct = default)
        {
            if (!force && CacheValid(_runningCache)) return _runningCache.Value;

            bool result = false;
            if (!string.IsNullOrWhiteSpace(adb) && File.Exists(adb))
            {
                string pattern = Regex.Escape(Serial) + @"\s+device\b";
                string devices = await RunAsync(adb, new[] { "devices" }, ct);
                if (!Regex.IsMatch(devices, pattern))
                {
                    await RunAsync(adb, new[] { "connect", Serial }, ct);
                    devices = await RunAsync(adb, new[] { "devices" }, ct);
                }
                result = Regex.IsMatch(devices, pattern);
            }
            _runningCache = (DateTime.UtcNow, result);
            return result;
        }

        /// <summary>Test-GameInstalled: `pm list packages &lt;package&gt;`.</summary>
        public static async Task<bool> GameInstalledAsync(
            string? adb, bool force = false, CancellationToken ct = default)
        {
            if (!force && CacheValid(_gameCache)) return _gameCache.Value;

            bool result = false;
            if (!string.IsNullOrWhiteSpace(adb) && File.Exists(adb))
            {
                string output = await RunAsync(adb,
                    new[] { "-s", Serial, "shell", "pm", "list", "packages", GameFiles.PackageName },
                    ct);
                result = output.Contains(PackageMatch, StringComparison.OrdinalIgnoreCase);
            }
            _gameCache = (DateTime.UtcNow, result);
            return result;
        }

        /// <summary>
        /// the launch call in Start-Game: the ADB monkey intent
        /// opens the launcher activity of the game package.
        /// </summary>
        public static async Task<string> LaunchGameAsync(string adb, CancellationToken ct)
        {
            return await RunAsync(adb,
                new[] { "-s", Serial, "shell", "monkey", "-p", GameFiles.PackageName,
                        "-c", "android.intent.category.LAUNCHER", "1" },
                ct, timeoutSeconds: 60);
        }

        /// <summary>
        /// Test-DebloatApplied: the MuMu store probe is gone from
        /// the user packages.
        /// </summary>
        public static async Task<bool> DebloatAppliedAsync(
            string? adb, bool force = false, CancellationToken ct = default)
        {
            if (!force && CacheValid(_debloatCache)) return _debloatCache.Value;

            bool result = false;
            if (!string.IsNullOrWhiteSpace(adb) && File.Exists(adb))
            {
                string output = await RunAsync(adb,
                    new[] { "-s", Serial, "shell", "pm", "list", "packages", "--user", "0", DebloatProbe },
                    ct);
                result = !output.Contains(DebloatProbe, StringComparison.OrdinalIgnoreCase);
            }
            _debloatCache = (DateTime.UtcNow, result);
            return result;
        }

        // ------------------------------------------------------------------
        // actions
        // ------------------------------------------------------------------

        /// <summary>
        /// the 1.x launch loops (Action-Debloat / Action-StartServer
        /// use them): make sure an instance is reachable on ADB, starting
        /// MuMuManager if needed. Up to 40 polls, 3 seconds apart.
        /// </summary>
        public static async Task<bool> EnsureEmulatorRunningAsync(
            string? muMuDir, string baseDir, Downloader.ReportDelegate report, CancellationToken ct)
        {
            string? adb = FindAdbExe(muMuDir, baseDir);
            if (await EmulatorRunningAsync(adb, force: true, ct)) return true;

            string? manager = MuMuManagerPath(muMuDir);
            if (manager == null || !File.Exists(manager))
            {
                report(-1, "MuMu Player is not installed: install it in step 2 first");
                return false;
            }

            report(-1, "Starting the MuMu instance (MuMuManager control -v 0 launch)...");
            string output = await RunAsync(manager, new[] { "control", "-v", "0", "launch" }, ct, timeoutSeconds: 120);
            string trimmed = output.Trim();
            if (trimmed.Length > 0)
            {
                report(-1, "MuMuManager: " + (trimmed.Length > 160 ? trimmed[..160] : trimmed));
            }

            for (int i = 0; i < 40; i++)
            {
                await Task.Delay(3000, ct);
                if (await EmulatorRunningAsync(adb, force: true, ct)) return true;
            }
            report(-1, "MuMu instance not reachable via ADB after 2 minutes");
            return false;
        }

        /// <summary>Invoke-MuMuDebloat (uninstall + disable + verify).</summary>
        public static async Task<bool> ApplyDebloatAsync(
            string adb, Downloader.ReportDelegate report, CancellationToken ct)
        {
            foreach (string package in DebloatRemove)
            {
                string result = (await RunAsync(adb,
                    new[] { "-s", Serial, "shell", "pm", "uninstall", "--user", "0", package },
                    ct, timeoutSeconds: 60)).Trim();
                report(-1, package + " -> " + result);
            }
            foreach (string package in DebloatDisable)
            {
                string result = (await RunAsync(adb,
                    new[] { "-s", Serial, "shell", "pm", "disable-user", "--user", "0", package },
                    ct, timeoutSeconds: 60)).Trim();
                report(-1, package + " -> " + result);
            }
            foreach (string package in DebloatRemove.Concat(DebloatDisable))
            {
                string active = await RunAsync(adb,
                    new[] { "-s", Serial, "shell", "pm", "list", "packages", "--user", "0", package }, ct);
                string disabled = await RunAsync(adb,
                    new[] { "-s", Serial, "shell", "pm", "list", "packages", "-d", package }, ct);
                string state = active.Trim().Length == 0
                    ? "REMOVED"
                    : disabled.Trim().Length > 0 ? "DISABLED" : "STILL ACTIVE";
                report(-1, package + " " + state);
            }
            _debloatCache = (DateTime.UtcNow, true);
            return true;
        }

        /// <summary>The 1.x `adb -s ... install -r`, with a confirmation.</summary>
        public static async Task<bool> InstallApkAsync(
            string adb, string apk, Downloader.ReportDelegate report, CancellationToken ct)
        {
            report(-1, "Installing the APK on MuMu (this may take 1-2 minutes)");
            string output = await RunAsync(adb,
                new[] { "-s", Serial, "install", "-r", apk },
                ct, timeoutSeconds: 600);

            string tail = output.Trim().Replace("\r", "");
            if (tail.Length > 240) tail = tail[^240..];
            report(-1, "adb install: " + (tail.Length == 0 ? "(no output)" : tail.Replace("\n", " \u00B7 ")));

            return tail.Contains("Success", StringComparison.OrdinalIgnoreCase) ||
                   await GameInstalledAsync(adb, force: true, ct);
        }
    }
}
