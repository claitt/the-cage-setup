using System;
using System.IO;
using CageSetup.WinUI.Core;
using Xunit;

namespace CageSetup.Tests
{
    /// <summary>
    /// The server wizard exits with "no saved config" when .wizard.json is
    /// missing. Step 5 writes it before the first start; the file must be
    /// plain UTF-8 without a BOM, because the Go JSON decoder rejects it.
    /// </summary>
    public class ServerConfigTests : IDisposable
    {
        private readonly string _folder;

        public ServerConfigTests()
        {
            _folder = Path.Combine(Path.GetTempPath(), "cage-server-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_folder);
        }

        public void Dispose()
        {
            try { Directory.Delete(_folder, recursive: true); } catch { }
        }

        [Fact]
        public void EnsureWizardConfig_WritesBomlessMumuConfig()
        {
            ServerRun.EnsureWizardConfig(_folder, (_, _) => { });

            string path = Path.Combine(_folder, ".wizard.json");
            Assert.True(File.Exists(path));

            byte[] bytes = File.ReadAllBytes(path);
            Assert.Equal((byte)'{', bytes[0]);   // UTF-8 without BOM

            string text = File.ReadAllText(path);
            Assert.Contains("\"ip\": \"10.0.2.2\"", text);
            Assert.Contains("\"grpc_port\": 8003", text);
            Assert.Contains("\"cdn_port\": 8080", text);
            Assert.Contains("\"auth_port\": 3000", text);
        }

        [Fact]
        public void EnsureWizardConfig_ReplacesAConfigWithAWrongPort()
        {
            string path = Path.Combine(_folder, ".wizard.json");
            File.WriteAllText(path, "{ \"ip\": \"10.0.2.2\", \"grpc_port\": 9999 }");

            ServerRun.EnsureWizardConfig(_folder, (_, _) => { });

            Assert.Contains("\"grpc_port\": 8003", File.ReadAllText(path));
        }
    }
}
