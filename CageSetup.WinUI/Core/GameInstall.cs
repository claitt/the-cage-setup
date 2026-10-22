using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace CageSetup.WinUI.Core
{
    /// <summary>
    /// Action-InstallGame: server binaries, master data, patched
    /// client APK and game assets. Every block fails independently, like
    /// the 1.x installer (a broken APKMirror page must not stop the asset
    /// download); the aggregate result is reported at the end.
    /// </summary>
    public static class GameInstall
    {

        public sealed class GameState
        {
            public bool ServerFiles;
            public bool MasterPatched;
            public string? ClientApk;
            public bool GameAssets;
            public double FreeGB;

            public string Headline =>
                (ServerFiles && MasterPatched && ClientApk != null && GameAssets)
                    ? "All game files are ready"
                    : "Game files incomplete";
        }

        public static GameState Detect()
        {
            return new GameState
            {
                ServerFiles = GameFiles.ServerFilesPresent(),
                MasterPatched = GameFiles.MasterDataReady(),
                ClientApk = GameFiles.GetClientApkPath(),
                GameAssets = GameFiles.GameAssetsPresent(),
                FreeGB = GameFiles.FreeSpaceGB(),
            };
        }

        /// <summary>The full pipeline, mirroring Action-InstallGame.</summary>
        public static async Task<bool> InstallAllAsync(
            Downloader.ReportDelegate report, CancellationToken ct)
        {
            bool server = await GetServerBinaries(report, ct);
            bool master = await GetMasterData(report, ct);
            bool client = await GetClientApk(report, ct);
            bool assets = await GetGameAssets(report, ct);

            bool ok = server && master && client && assets;
            if (ok)
            {
                report(-1, "All game files are ready");
            }
            else
            {
                report(-1, "Some game files could not be prepared: see the messages above");
            }
            return ok;
        }

        // ------------------------------------------------------------------
        // 1) Server binaries (GitHub Releases)
        // ------------------------------------------------------------------

        public static async Task<bool> GetServerBinaries(Downloader.ReportDelegate report, CancellationToken ct)
        {
            report(-1, "Server: downloading the binaries (GitHub Releases)");
            if (GameFiles.ServerFilesPresent())
            {
                report(-1, "Server binaries already present");
                return true;
            }

            string url = await GameFiles.GetLatestServerUrlAsync();
            string zip = Path.Combine(GameFiles.Downloads, "lunar-tear-server.zip");
            await Downloader.SendDownloadAsync(url, zip, "Server binaries",
                bytes: url.Equals(GameFiles.ServerUrl, StringComparison.OrdinalIgnoreCase)
                    ? GameFiles.ServerBytes : 0,
                sha256: url.Equals(GameFiles.ServerUrl, StringComparison.OrdinalIgnoreCase)
                    ? GameFiles.ServerSha256 : "",
                report: report, ct: ct);

            // extract into a temp dir, flatten the single top folder, copy.
            string temp = Path.Combine(Path.GetTempPath(), "lunartear-bin-" + Guid.NewGuid().ToString("N"));
            try
            {
                await Downloader.ExtractZipAsync(zip, temp, report);
                report(-1, "Extracting the server binaries... placing into server\\");
                string source = Directory.GetDirectories(temp).FirstOrDefault() ?? temp;
                Directory.CreateDirectory(GameFiles.ServerDir);
                foreach (string path in Directory.EnumerateFileSystemEntries(source))
                {
                    string target = Path.Combine(GameFiles.ServerDir, Path.GetFileName(path));
                    if (Directory.Exists(path))
                    {
                        CopyTree(path, target);
                    }
                    else
                    {
                        File.Copy(path, target, overwrite: true);
                    }
                }
            }
            finally
            {
                try { Directory.Delete(temp, recursive: true); } catch { }
            }

            if (GameFiles.ServerFilesPresent())
            {
                report(-1, "Server binaries ready");
                return true;
            }
            report(-1, "Server binaries not found after extraction");
            return false;
        }

        private static void CopyTree(string source, string target)
        {
            Directory.CreateDirectory(target);
            foreach (string file in Directory.EnumerateFiles(source))
            {
                File.Copy(file, Path.Combine(target, Path.GetFileName(file)), overwrite: true);
            }
            foreach (string dir in Directory.EnumerateDirectories(source))
            {
                CopyTree(dir, Path.Combine(target, Path.GetFileName(dir)));
            }
        }

        // ------------------------------------------------------------------
        // 2) Master data (download + official patcher)
        // ------------------------------------------------------------------

        public static async Task<bool> GetMasterData(Downloader.ReportDelegate report, CancellationToken ct)
        {
            report(-1, "Server: preparing the master data");

            string file = GameFiles.MasterFile;
            if (File.Exists(file))
            {
                if (GameFiles.MasterDataReady())
                {
                    report(-1, "Master data already patched");
                    return true;
                }
                string hash = HashHelper.Sha1(file);
                if (hash.Equals(GameFiles.MasterSha1, StringComparison.OrdinalIgnoreCase))
                {
                    report(-1, "Master data is the original file: patching it now");
                    return await PatchMasterData(file, file, report, ct);
                }
                // anything else was supplied by the user: do not touch it
                await File.WriteAllTextAsync(file + ".patched", hash, ct);
                report(-1, "Master data supplied by the user (SHA1 " + hash + "): keeping it as is");
                return true;
            }

            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            await Downloader.SendDownloadAsync(GameFiles.MasterUrl, file, "Master data",
                bytes: GameFiles.MasterBytes, sha1: GameFiles.MasterSha1, report: report, ct: ct);
            if (!File.Exists(file)) return false;
            return await PatchMasterData(file, file, report, ct);
        }

        /// <summary>Invoke-MasterDataPatch (content unlocked to 2030).</summary>
        public static async Task<bool> PatchMasterData(
            string inputFile, string outputFile, Downloader.ReportDelegate report, CancellationToken ct)
        {
            string? python = await Toolchain.EnsurePython(report, ct);
            if (python == null)
            {
                report(-1, "Cannot patch the master data: the Python runtime is not available");
                return false;
            }

            string backup = inputFile + ".original";
            if (!File.Exists(backup)) File.Copy(inputFile, backup, overwrite: true);

            try
            {
                string script = await Toolchain.GetLunarScript("patch_masterdata.py", report, ct);
                await Downloader.InvokeToolAsync(python,
                    new[] { "-X", "utf8", script, "--input", inputFile, "--output", outputFile },
                    "Patching the master data (content unlocked to 2030)", report, ct: ct);
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

            string hash = HashHelper.Sha1(outputFile);
            await File.WriteAllTextAsync(outputFile + ".patched", hash, ct);
            report(-1, "Master data patched: " + new FileInfo(outputFile).Length / 1048576.0 +
                       " MB (SHA1 " + hash + ")");
            return true;
        }

        // ------------------------------------------------------------------
        // 3) Client APK (stock download + local build)
        // ------------------------------------------------------------------

        public static async Task<bool> GetClientApk(Downloader.ReportDelegate report, CancellationToken ct)
        {
            report(-1, "Client: preparing the patched APK");
            string? existing = GameFiles.GetClientApkPath();
            if (existing != null)
            {
                report(-1, "Patched APK already present: " + existing);
                return true;
            }
            return await ClientBuild.BuildClientApk(report, ct);
        }

        // ------------------------------------------------------------------
        // 4) Game assets (14.9 GB archive.org download + 7z extraction)
        // ------------------------------------------------------------------

        public static async Task<bool> GetGameAssets(Downloader.ReportDelegate report, CancellationToken ct)
        {
            report(-1, "Server: downloading the game assets (long operation)");
            if (GameFiles.GameAssetsPresent())
            {
                report(-1, "Game assets already present");
                return true;
            }

            string archive = GameFiles.AssetsArchive;
            bool ready = File.Exists(archive) && new FileInfo(archive).Length == GameFiles.AssetsBytes;
            if (ready)
            {
                report(-1, "Using the already downloaded archive: " + archive);
            }
            else
            {
                if (File.Exists(archive))
                {
                    report(-1, "The local archive has a different size: downloading it again.");
                    File.Delete(archive);
                }
                long partialBytes = 0;
                if (File.Exists(archive + ".part")) partialBytes = new FileInfo(archive + ".part").Length;
                double needGB = GameFiles.AssetsDiskRequirementGB(partialBytes);
                double free = GameFiles.FreeSpaceGB();
                if (free < needGB)
                {
                    report(-1, "Not enough disk space: about " + needGB.ToString("N1") +
                               " GB free in the game files folder are required (you have " + free + " GB).");
                    return false;
                }
                await Downloader.SendDownloadAsync(GameFiles.AssetsUrl, archive, "Game assets (14.9 GB)",
                    bytes: GameFiles.AssetsBytes, sha1: GameFiles.AssetsSha1, report: report, ct: ct);
            }

            Directory.CreateDirectory(GameFiles.AssetsDir);

            // Download and extraction need the disk at the same time: re-check.
            double needExtractGB = GameFiles.AssetsExtractGB + 2;
            if (GameFiles.FreeSpaceGB() < needExtractGB)
            {
                report(-1, "Not enough disk space: extracting the assets needs about " + needExtractGB +
                           " GB free (you have " + GameFiles.FreeSpaceGB() + " GB).");
                return false;
            }

            // the master data is NOT inside the asset dump: protect it and
            // restore it afterwards
            string backup = Path.Combine(Path.GetTempPath(), "lunartear-master.bak");
            bool hadMaster = File.Exists(GameFiles.MasterFile);
            if (hadMaster)
            {
                File.Copy(GameFiles.MasterFile, backup, overwrite: true);
            }

            try
            {
                await Downloader.Extract7zAsync(archive, GameFiles.AssetsDir,
                    "Extracting game assets (48.8 GB)", report, ct);
            }
            finally
            {
                if (hadMaster && File.Exists(backup))
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(GameFiles.MasterFile)!);
                    File.Copy(backup, GameFiles.MasterFile, overwrite: true);
                    File.Delete(backup);
                    report(-1, "Master data restored after extraction");
                }
            }

            if (GameFiles.GameAssetsPresent())
            {
                report(-1, "Game assets ready");
                return true;
            }
            report(-1, "Game assets not detected after extraction");
            return false;
        }
    }
}
