using System;
using System.IO;
using CageSetup.WinUI.Core;
using Xunit;

namespace CageSetup.Tests
{
    /// <summary>
    /// Pure logic of the step 4 and step 5 helpers: adb discovery (newest
    /// engine wins, like Find-AdbExe of the 1.x installer) and the netstat
    /// listener parsing used to name port owners.
    /// </summary>
    public class AdbTests : IDisposable
    {
        private readonly string _root = Path.Combine(
            Path.GetTempPath(), "cagesetup-tests-adb-" + Guid.NewGuid().ToString("N"));

        public AdbTests()
        {
            Directory.CreateDirectory(_root);
        }

        private static void WriteExe(string path)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, "stub adb");
        }

        [Fact]
        public void NewestEngineFolder_Wins()
        {
            WriteExe(Path.Combine(_root, "mumu", "nx_device", "10.0", "shell", "adb.exe"));
            WriteExe(Path.Combine(_root, "mumu", "nx_device", "12.0", "shell", "adb.exe"));
            WriteExe(Path.Combine(_root, "tools", "android-sdk", "platform-tools", "adb.exe"));

            string? adb = Adb.FindAdbExe(
                Path.Combine(_root, "mumu"), _root);

            Assert.StartsWith(
                Path.Combine(_root, "mumu", "nx_device", "12.0", "shell", "adb.exe"),
                adb);
        }

        [Fact]
        public void PlatformTools_IsTheFallback()
        {
            WriteExe(Path.Combine(_root, "tools", "android-sdk", "platform-tools", "adb.exe"));

            string? adb = Adb.FindAdbExe(Path.Combine(_root, "mumu-missing"), _root);

            Assert.Equal(
                Path.Combine(_root, "tools", "android-sdk", "platform-tools", "adb.exe"),
                adb);
        }

        [Fact]
        public void NoCandidate_ReturnsNull()
        {
            Assert.Null(Adb.FindAdbExe(Path.Combine(_root, "empty"), _root));
        }

        [Fact]
        public void ManagerPath_IsUnderNxMain()
        {
            string manager = Adb.MuMuManagerPath(@"C:\Netease\MuMuPlayer")!;
            Assert.Equal(@"C:\Netease\MuMuPlayer\nx_main\MuMuManager.exe", manager);
            Assert.Null(Adb.MuMuManagerPath(null));
        }

        public void Dispose()
        {
            try { Directory.Delete(_root, recursive: true); } catch { }
        }
    }

    public class ServerRunTests
    {
        // Sample netstat -ano -p tcp output (the state word is not matched,
        // so a localized "IN ASCOLTO" style word still works).
        private static readonly string[] NetstatSample =
        {
            "",
            "Active Connections",
            "",
            "  Proto  Local Address          Foreign Address        State           PID",
            "  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       4012",
            "  TCP    0.0.0.0:8003           0.0.0.0:0              LISTENING       5678",
            "  TCP    [::]:8003              [::]:0                 LISTENING       5678",
            "  TCP    127.0.0.1:8080         0.0.0.0:0              LISTENING       5679",
            "  TCP    0.0.0.0:443            0.0.0.0:0              LISTENING       9988",
        };

        [Fact]
        public void ListenerPid_IsFound()
        {
            Assert.Equal(5678, ServerRun.ParseListenerPid(NetstatSample, 8003));
            Assert.Equal(5679, ServerRun.ParseListenerPid(NetstatSample, 8080));
        }

        [Fact]
        public void Port3000_HasNoListener()
        {
            // nothing matches: the auth port is not a listener here.
            Assert.Equal(0, ServerRun.ParseListenerPid(NetstatSample, 3000));
        }

        [Fact]
        public void NonListenerRows_Ignored()
        {
            string[] lines = { "  TCP    0.0.0.0:8003    1.2.3.4:5555       ESTABLISHED     42" };
            Assert.Equal(0, ServerRun.ParseListenerPid(lines, 8003));
        }
    }
}
