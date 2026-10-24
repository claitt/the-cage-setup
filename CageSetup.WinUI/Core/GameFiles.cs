using System;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading.Tasks;

namespace CageSetup.WinUI.Core
{
    /// <summary>
    /// The four sources of step 3, ported from the 1.x installer
    /// ($Config / $Paths): pinned URLs, sizes and checksums, plus the
    /// presence checks (Test-ServerFiles / Test-MasterData /
    /// Test-GameAssets / Get-ClientApkPath).
    /// </summary>
    public static class GameFiles
    {
        // ---- server binaries (GitHub Releases, pinned to a known version) ----
        public const string ServerRepo = "Walter-Sparrow/lunar-tear";
        public const string ServerAssetMatch = "windows-amd64";
        public const string ServerUrl =
            "https://github.com/Walter-Sparrow/lunar-tear/releases/download/v1.0.2/" +
            "lunar-tear-server-v1.0.2-windows-amd64.zip";
        public const string ServerUrlFallback = ServerUrl;
        public const long ServerBytes = 33872763;
        public const string ServerSha256 = "d8f6330a8f3a8788a89ba8ecfc01a5ff40ab566a9c46d9ff6fd0929503dd5f0a";

        // ---- game assets (archive.org), ~14.93 GB download, ~48.8 GB on disk ----
        public const string AssetsUrl = "https://archive.org/download/nier_reincarnation_assets/resource_dump_android.7z";
        public const long AssetsBytes = 14928186871;
        public const string AssetsSha1 = "49ad027ee838811ecf37dacfbdac1b3e7711253e";
        public const int AssetsExtractGB = 49;   // extracted size of the archive

        // ---- master data (archive.org), ~7.4 MB ----
        public const string MasterUrl = "https://archive.org/download/20240404193219.bin/20240404193219.bin.e";
        public const long MasterBytes = 7801104;
        public const string MasterSha1 = "9b7b1a077e557a5b7d3c63f0ef62a2d39fd1d899";

        // SHA1 of the master data after the official patcher extended the
        // content to 2030; used to tell an already-patched file from the original.
        public const string MasterPatchedSha1 = "DF6F4F1AC90466F940DDB3F18E1FA9627D5B9DFA";

        // ---- game client: the STOCK apk comes from the archive.org mirror
        //      of the same APKMirror file (APKMirror now blocks automated
        //      downloads), and is patched locally ----
        public const string ApkStockUrl =
            "https://archive.org/download/" +
            "com.square_enix.android_googleplay.nierspww_3.7.1-152_minapi24arm64-v8anodpi_apkmirror.com/" +
            "com.square_enix.android_googleplay.nierspww_3.7.1-152_minAPI24(arm64-v8a)(nodpi)_apkmirror.com.apk";
        public const long ApkStockBytes = 263571029;
        public const string ApkStockSha256 = "9ded0797ee607b6892b531ba3a02f4c4510774f5fe098ccada78ccff881c9209";
        public const string PackageName = "com.square_enix.android_googleplay.nierspww";

        // ---- toolchain, downloaded on demand (pinned version + size + SHA256) ----
        public const string JreUrl =
            "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20.1%2B1/" +
            "OpenJDK17U-jre_x64_windows_hotspot_17.0.20.1_1.zip";
        public const long JreBytes = 43780109;
        public const string JreSha256 = "bc21a93923103cdaac93ee337b0ae4365e739fde36df823dd456bc67c8a9d352";

        public const string ApktoolUrl = "https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar";
        public const long ApktoolBytes = 15478013;
        public const string ApktoolSha256 = "dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423";

        public const string BuildToolsUrl = "https://dl.google.com/android/repository/build-tools_r35_windows.zip";
        public const long BuildToolsBytes = 59878107;
        public const string BuildToolsSha256 = "5753c679a1b90bcf6fbc9945a2ce39dfb9e74f1df0831a1e1866ae5b594326f0";

        public const string PythonUrl = "https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip";
        public const long PythonBytes = 11133606;
        public const string PythonSha256 = "4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3";

        // Patcher scripts, pinned to a commit of the upstream repository.
        public const string ScriptsRaw = "https://gitlab.com/walter-sparrow-group/lunar-scripts/-/raw/942dced617ea836a0e3abcfc0e0befec42baab11";

        // Server addresses used by the client patch.
        public const string GrpcAddr = "10.0.2.2:8003";
        public const string HttpAddr = "10.0.2.2:8080";
        public const string AuthAddr = "10.0.2.2:3000";

        // 7-Zip standalone console: shipped with the 1.x package; downloaded
        // from 7-zip.org when missing so extraction keeps working. The x64
        // build in the "extra" package decodes on several cores (7zr is x86
        // and single-threaded), which is what makes the 49 GB extraction fast.
        public const string SevenZipUrl = "https://www.7-zip.org/a/7zr.exe";
        public const string SevenZipExtraUrl =
            "https://github.com/ip7z/7zip/releases/download/26.05/7z2605-extra.7z";
        public const long SevenZipExtraBytes = 1763900;
        public const string SevenZipExtraSha256 =
            "f27a8f103c84785026edcba1f67faf1357225df9d19ddb0b7760d55947141bc7";

        // The extracted assets are about 48.8 GB; anything clearly smaller is
        // a partial extraction from an older build (before the markers).
        public const long AssetsCompleteBytes = 45L * 1024 * 1024 * 1024;

        // ---- paths (mirror of $Paths, rooted next to the EXE by default) ----
        // The root can be pointed at a folder that already holds the game
        // files; the choice is saved in settings.ini next to the EXE.
        private static string? _root;

        public static string Root => _root ??= LoadRoot();

        /// <summary>
        /// Folder of the real executable. In a single-file build
        /// AppContext.BaseDirectory points at the extraction folder under
        /// %TEMP%, which is the wrong place for downloads and state.
        /// </summary>
        public static string BaseDir
        {
            get
            {
                string? exe = Environment.ProcessPath;
                return !string.IsNullOrEmpty(exe)
                    ? Path.GetDirectoryName(exe)!
                    : AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            }
        }

        private static string SettingsPath => Path.Combine(BaseDir, "settings.ini");

        private static string LoadRoot()
        {
            string baseDir = BaseDir;
            try
            {
                if (!File.Exists(SettingsPath)) return baseDir;

                foreach (string line in File.ReadAllLines(SettingsPath))
                {
                    int eq = line.IndexOf('=');
                    if (eq <= 0) continue;
                    if (!line[..eq].Trim().Equals("root", StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }

                    string value = line[(eq + 1)..].Trim().Trim('"');
                    if (value.Length > 0 && Directory.Exists(value))
                    {
                        return Path.GetFullPath(value).TrimEnd(Path.DirectorySeparatorChar);
                    }
                }
            }
            catch
            {
                // Unreadable settings fall back to the folder next to the EXE.
            }
            return baseDir;
        }

        /// <summary>
        /// Points the setup at <paramref name="path"/> and remembers it.
        /// Used by "Choose local files" on step 3.
        /// </summary>
        public static void SetRoot(string path)
        {
            string full = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);
            _root = full;
            try
            {
                File.WriteAllText(SettingsPath, "root=" + full + Environment.NewLine);
            }
            catch
            {
                // A read-only install folder must not break the current run.
            }
        }

        public static string Downloads => Path.Combine(Root, "downloads");
        public static string ToolsDir => Path.Combine(Root, "tools");
        public static string SevenZip => Path.Combine(ToolsDir, "7zr.exe");
        public static string SevenZip64 => Path.Combine(ToolsDir, "7za.exe");
        public static string ServerDir => Path.Combine(Root, "server");
        public static string ServerExe => Path.Combine(ServerDir, "wizard.exe");
        public static string ServerBinDir => Path.Combine(ServerDir, "bin");
        public static string AssetsDir => Path.Combine(ServerDir, "assets");
        public static string MasterFile => Path.Combine(AssetsDir, "release", "20240404193219.bin.e");
        public static string AssetsArchive => Path.Combine(Downloads, "resource_dump_android.7z");
        public static string ApkStockFile => Path.Combine(Root, "apk", "stock", "nier-3.7.1-stock.apk");
        public static string ApkWorkDir => Path.Combine(Root, "apk", "work");
        public static string ApkOutDir => Path.Combine(Root, "apk", "out");
        public static string ApkOutput => Path.Combine(ApkOutDir, "nier-patched.apk");
        public static string Keystore => Path.Combine(ApkOutDir, "debug.keystore");
        public static string JdkDir => Path.Combine(ToolsDir, "jdk");
        public static string ApktoolJar => Path.Combine(ToolsDir, "apktool.jar");
        public static string BuildToolsDir => Path.Combine(ToolsDir, "build-tools");
        public static string PythonDir => Path.Combine(ToolsDir, "python");
        public static string ScriptsDir => Path.Combine(ToolsDir, "lunar-scripts");

        // ---- checks ------------------------------------------------------

        /// <summary>Test-ServerFiles: wizard.exe + bin folder.</summary>
        public static bool ServerFilesPresent() =>
            File.Exists(ServerExe) && Directory.Exists(ServerBinDir);

        /// <summary>Get-ClientApkPath: accepted output candidates.</summary>
        public static string? GetClientApkPath()
        {
            string[] candidates =
            {
                ApkOutput,
                Path.Combine(ApkOutDir, "nier_aligned.apk"),
                Path.Combine(Root, "client-nier-reincarnation-patched.apk"),
            };
            return candidates.FirstOrDefault(File.Exists);
        }

        /// <summary>Marker written only after a complete extraction. It lives
        /// in state\ so the game server never sees it in the asset tree.</summary>
        public static string AssetsDoneMarker => Path.Combine(Root, "state", "assets.done");

        /// <summary>Marker written while an extraction is running; a partial
        /// extraction must never count as ready.</summary>
        public static string AssetsPartialMarker => Path.Combine(Root, "state", "assets.partial");

        /// <summary>
        /// Test-GameAssets: the revisions folder plus a completed extraction.
        /// The marker is required because 7-Zip creates revisions early, so a
        /// cancelled extraction used to look complete.
        /// </summary>
        public static bool GameAssetsPresent()
        {
            string revisions = Path.Combine(AssetsDir, "revisions");
            if (!Directory.Exists(revisions)) return false;
            if (File.Exists(AssetsDoneMarker)) return true;
            if (File.Exists(AssetsPartialMarker)) return false;

            // Install made before the markers existed: accept it only when the
            // extracted size matches the expected content.
            try
            {
                if (DirectorySize(AssetsDir) >= AssetsCompleteBytes)
                {
                    MarkAssetsComplete();
                    return true;
                }
                MarkAssetsPartial();
            }
            catch
            {
                // Unreadable folder: treat it as not ready.
            }
            return false;
        }

        public static void MarkAssetsComplete()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(AssetsDoneMarker)!);
                File.WriteAllText(AssetsDoneMarker,
                    DateTime.UtcNow.ToString("O") + Environment.NewLine + AssetsSha1 + Environment.NewLine);
                TryDeleteFile(AssetsPartialMarker);
                TryDeleteFile(Path.Combine(AssetsDir, ".cage-assets.done"));
                TryDeleteFile(Path.Combine(AssetsDir, ".cage-assets.partial"));
            }
            catch
            {
                // The next check falls back to the size heuristic.
            }
        }

        public static void MarkAssetsPartial()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(AssetsPartialMarker)!);
                File.WriteAllText(AssetsPartialMarker, DateTime.UtcNow.ToString("O") + Environment.NewLine);
                TryDeleteFile(AssetsDoneMarker);
                TryDeleteFile(Path.Combine(AssetsDir, ".cage-assets.done"));
            }
            catch
            {
                // A missing marker only means an extra size scan.
            }
        }

        private static long DirectorySize(string folder)
        {
            long total = 0;

            // DirectoryInfo carries the length from the directory
            // enumeration; building a FileInfo per path costs ~3x more on a
            // folder with 200k files.
            foreach (FileInfo file in new DirectoryInfo(folder)
                         .EnumerateFiles("*", SearchOption.AllDirectories))
            {
                total += file.Length;
            }
            return total;
        }

        private static void TryDeleteFile(string path)
        {
            try
            {
                if (File.Exists(path)) File.Delete(path);
            }
            catch
            {
                // Harmless leftover.
            }
        }

        /// <summary>SHA1 of the master data file ('' when missing).</summary>
        public static string MasterDataHash()
        {
            string file = MasterFile;
            if (!File.Exists(file)) return string.Empty;
            using FileStream stream = File.OpenRead(file);
            return Convert.ToHexString(SHA1.HashData(stream));
        }

        /// <summary>
        /// Test-MasterData: patched by us (reference SHA1) or marked
        /// with the written hash (a file supplied by the user).
        /// </summary>
        public static bool MasterDataReady()
        {
            string file = MasterFile;
            if (!File.Exists(file)) return false;
            string hash = MasterDataHash();
            if (string.Equals(hash, MasterPatchedSha1, StringComparison.OrdinalIgnoreCase)) return true;

            string marker = file + ".patched";
            if (!File.Exists(marker)) return false;
            try
            {
                string recorded = File.ReadAllText(marker).Trim();
                return recorded.Equals(hash, StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        /// <summary>
        /// GB that must be free before the assets archive download+extract
        /// (Get-AssetsDiskRequirementGB).
        /// </summary>
        public static double AssetsDiskRequirementGB(long partialBytes)
        {
            long remaining = Math.Max(0, AssetsBytes - Math.Max(0, partialBytes));
            return AssetsExtractGB + Math.Ceiling(remaining / 1073741824.0) + 2;
        }

        /// <summary>Free GB on the drive holding the game files (1.x Get-FreeSpaceGB).</summary>
        public static double FreeSpaceGB()
        {
            try
            {
                DriveInfo drive = new(Path.GetPathRoot(Path.GetFullPath(Root))!);
                return Math.Round(drive.AvailableFreeSpace / 1073741824.0, 1);
            }
            catch
            {
                return 0;
            }
        }

        /// <summary>Get-LatestServerUrl: latest GitHub release asset.</summary>
        public static async Task<string?> GetLatestServerUrlAsync()
        {
            try
            {
                using HttpClient client = new();
                client.Timeout = TimeSpan.FromSeconds(30);
                using HttpRequestMessage request = new(HttpMethod.Get,
                    "https://api.github.com/repos/" + ServerRepo + "/releases/latest");
                request.Headers.TryAddWithoutValidation("User-Agent", "cage-setup");
                request.Headers.TryAddWithoutValidation("Accept", "application/vnd.github+json");

                using HttpResponseMessage response = await client.SendAsync(request);
                response.EnsureSuccessStatusCode();
                await using Stream stream = await response.Content.ReadAsStreamAsync();
                using JsonDocument doc = await JsonDocument.ParseAsync(stream);
                JsonElement assets = doc.RootElement.GetProperty("assets");
                foreach (JsonElement asset in assets.EnumerateArray())
                {
                    string? name = asset.TryGetProperty("name", out JsonElement n) ? n.GetString() : null;
                    if (name != null && name.Contains(ServerAssetMatch) && name.EndsWith(".zip"))
                    {
                        return asset.GetProperty("browser_download_url").GetString();
                    }
                }
            }
            catch
            {
                // GitHub unreachable: the pinned fallback link is used.
            }
            return ServerUrlFallback;
        }
    }

    /// <summary>Emulator state snapshot for page 3 (kept simple).</summary>
    public static class HashHelper
    {
        public static string Sha256(string path)
        {
            using FileStream stream = File.OpenRead(path);
            return Convert.ToHexString(SHA256.HashData(stream));
        }

        public static string Sha1(string path)
        {
            using FileStream stream = File.OpenRead(path);
            return Convert.ToHexString(SHA1.HashData(stream));
        }
    }
}
