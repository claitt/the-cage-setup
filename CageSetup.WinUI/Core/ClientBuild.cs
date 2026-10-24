using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace CageSetup.WinUI.Core
{
    /// <summary>
    /// Client build, ported from 05-client-build.ps1: the stock APK comes
    /// from the archive.org mirror of the APKMirror file (APKMirror blocks
    /// automated downloads), gets decompiled with apktool, patched with the
    /// official lunar-scripts patcher, rebuilt, aligned, signed and verified.
    /// The toolchain is downloaded on demand.
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

        // ------------------------------------------------------------------
        // Stock APK from archive.org
        // ------------------------------------------------------------------

        /// <summary>
        /// The stock 3.7.1 APK is the same file APKMirror used to serve; the
        /// archive.org item mirrors it byte for byte. APKMirror itself now
        /// answers automated requests with a browser challenge.
        /// </summary>
        public static async Task<bool> GetStockApk(
            string destination, Downloader.ReportDelegate report, CancellationToken ct)
        {
            if (IsApkArchive(destination))
            {
                report(-1, "Stock APK already downloaded: " + destination);
                return true;
            }

            report(-1, "Client: downloading the stock APK from archive.org");
            try
            {
                await Downloader.SendDownloadAsync(
                    GameFiles.ApkStockUrl, destination, "Stock APK (3.7.1)",
                    bytes: GameFiles.ApkStockBytes, sha256: GameFiles.ApkStockSha256,
                    report: report, ct: ct);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                report(-1, "Client: stock APK download failed: " + ex.Message);
                return false;
            }

            if (!IsApkArchive(destination))
            {
                report(-1, "The downloaded file is not a valid APK");
                return false;
            }

            report(-1, "Stock APK verified (SHA256)");
            report(-1, "Stock APK downloaded: " + new FileInfo(destination).Length / 1048576.0 + " MB");
            return true;
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
            if (!await GetStockApk(GameFiles.ApkStockFile, report, ct)) return false;

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
