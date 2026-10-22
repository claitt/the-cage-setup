using System;
using System.IO;
using CageSetup.WinUI.Core;
using Xunit;

namespace CageSetup.Tests
{
    /// <summary>
    /// Pure logic of the Core layer: sizes, progress formatting, argument
    /// quoting, disk requirements and the master data marker logic. No
    /// WinUI and no network involved.
    /// </summary>
    public class FormatSizeTests
    {
        [Theory]
        [InlineData(0, "0 B")]
        [InlineData(512, "512 B")]
        [InlineData(1024, "1 KB")]
        [InlineData(1048576, "1.0 MB")]
        [InlineData(1572864, "1.5 MB")]
        [InlineData(1610612736, "1.50 GB")]
        public void FormatSize_RendersHumanReadableValues(double bytes, string expected)
        {
            Assert.Equal(expected, Downloader.FormatSize(bytes));
        }

        [Fact]
        public void ProgressText_IncludesDoneTotalPercentageAndSpeed()
        {
            string text = Downloader.ProgressText("Download", 500, 1000, 100.0);
            Assert.Contains("Download", text);
            Assert.Contains("50%", text);
            Assert.Contains("500 B", text);
            Assert.Contains("1,000 B", text);  // totals keep the thousand separator, like 1.x
            Assert.Contains("100 B/s", text);
            Assert.Contains("left", text);     // estimated time left
        }

        [Fact]
        public void ProgressText_WithoutTotal_BringsOnlySpeed()
        {
            string text = Downloader.ProgressText("Label", 10, 0, 5.0);
            Assert.Contains("Label", text);
            Assert.DoesNotContain("%", text);
        }
    }

    public class QuoteArgumentsTests
    {
        [Fact]
        public void PlainArguments_StayUnquoted()
        {
            Assert.Equal("-X utf8 script.py", Downloader.QuoteArguments(new[] { "-X", "utf8", "script.py" }));
        }

        [Fact]
        public void ArgumentWithSpace_GetQuoted()
        {
            Assert.Equal("\"C:\\Program Files\\x\"", Downloader.QuoteArguments(new[] { "C:\\Program Files\\x" }));
        }

        [Fact]
        public void EmptyArgument_IsQuoted()
        {
            Assert.Contains("\"\"", Downloader.QuoteArguments(new[] { "" }));
        }
    }

    public class DiskRequirementTests
    {
        [Fact]
        public void Requirement_IncludesExtractAndBuffer()
        {
            // 0 downloaded: extract (49) + the full 15 GB rounded up + 2 buffer.
            double requirement = GameFiles.AssetsDiskRequirementGB(0);
            Assert.Equal(49 + Math.Ceiling(GameFiles.AssetsBytes / 1073741824.0) + 2, requirement);

            // Fully downloaded: only extraction + buffer, no download size.
            double afterDownload = GameFiles.AssetsDiskRequirementGB(GameFiles.AssetsBytes);
            Assert.Equal(51, afterDownload);
        }

        [Fact]
        public void Requirement_NeverGoesNegative()
        {
            double overDownloaded = GameFiles.AssetsDiskRequirementGB(GameFiles.AssetsBytes * 2);
            Assert.Equal(51, overDownloaded);
        }

        [Fact]
        public void FreeSpace_IsReportedPositive()
        {
            Assert.True(GameFiles.FreeSpaceGB() > 0);
        }
    }

    /// <summary>
    /// The master data marker logic (Test-MasterData port) on real files,
    /// written under the game files root of the test process.
    /// </summary>
    public class MasterDataTests : IDisposable
    {
        private readonly string _file;
        private readonly string _marker;

        public MasterDataTests()
        {
            _file = GameFiles.MasterFile;
            _marker = _file + ".patched";
            Directory.CreateDirectory(Path.GetDirectoryName(_file)!);
            CleanupFiles();
        }

        private void CleanupFiles()
        {
            if (File.Exists(_file)) File.Delete(_file);
            if (File.Exists(_marker)) File.Delete(_marker);
        }

        [Fact]
        public void MissingFile_IsNotReady()
        {
            Assert.False(GameFiles.MasterDataReady());
        }

        [Fact]
        public void MarkerWithMatchingHash_IsReady()
        {
            File.WriteAllBytes(_file, new byte[] { 1, 2, 3, 4 });
            string hash = HashHelper.Sha1(_file);
            File.WriteAllText(_marker, hash);
            Assert.True(GameFiles.MasterDataReady());
        }

        [Fact]
        public void MarkerWithWrongHash_IsNotReady()
        {
            File.WriteAllBytes(_file, new byte[] { 1, 2, 3, 4 });
            File.WriteAllText(_marker, "0000000000000000000000000000000000000000");
            Assert.False(GameFiles.MasterDataReady());
        }

        public void Dispose() => CleanupFiles();
    }

    public class LastLogLinesTests : IDisposable
    {
        private readonly string _log = Path.Combine(
            Path.GetTempPath(), "cagesetup-tests-log.txt");

        public LastLogLinesTests()
        {
            if (File.Exists(_log)) File.Delete(_log);
        }

        [Fact]
        public void Tail_ReturnsTheLatestLinesOnly()
        {
            File.WriteAllLines(_log, new[] { "first", "middle", "last" });
            string[] lines = Downloader.LastLogLines(_log, 2);
            Assert.Equal(new[] { "middle", "last" }, lines);
        }

        [Fact]
        public void MissingLog_ReturnsEmpty()
        {
            Assert.Empty(Downloader.LastLogLines(_log + "-missing", 3));
        }

        public void Dispose()
        {
            if (File.Exists(_log)) File.Delete(_log);
        }
    }

    public class EngineFolderTests
    {
        [Fact]
        public void NumericVersionFolders_AreDetected()
        {
            string root = Path.Combine(Path.GetTempPath(),
                "cagesetup-tests-engine-" + Guid.NewGuid().ToString("N"));
            try
            {
                string engine = Path.Combine(root, "nx_device", "5.1");
                Directory.CreateDirectory(engine);
                Directory.CreateDirectory(Path.Combine(root, "nx_device", "not-numeric"));

                List<string> found = new();
                bool present = Emulator.EnginePresent(root, found);

                Assert.True(present);
                Assert.Equal(new[] { "5.1" }, found);
            }
            finally
            {
                Directory.Delete(root, recursive: true);
            }
        }

        [Fact]
        public void MissingDeviceRoot_IsNotPresent()
        {
            string root = Path.Combine(Path.GetTempPath(),
                "cagesetup-tests-engine-missing-" + Guid.NewGuid().ToString("N"));
            Assert.False(Emulator.EnginePresent(root));
        }
    }
}
