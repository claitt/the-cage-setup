using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using CageSetup.WinUI.Core;
using Xunit;

namespace CageSetup.Tests
{
    /// <summary>
    /// End-to-end check of the segmented downloader against a local HTTP
    /// server that supports Range: the file must arrive byte-identical,
    /// pass the pinned SHA256 and leave no .part or state files behind.
    /// </summary>
    public class SegmentedDownloadTests : IDisposable
    {
        private const int Size = 40 * 1024 * 1024;

        private readonly string _folder;
        private readonly byte[] _payload;

        public SegmentedDownloadTests()
        {
            _folder = Path.Combine(Path.GetTempPath(), "cage-seg-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_folder);

            _payload = new byte[Size];
            for (int i = 0; i < _payload.Length; i++) _payload[i] = (byte)(i * 31 + 7);
        }

        public void Dispose()
        {
            try { Directory.Delete(_folder, recursive: true); } catch { }
        }

        [Fact]
        public async Task SendDownloadAsync_CompletesWithChecksumAndCleanState()
        {
            using RangeServer server = new(_payload);
            using CancellationTokenSource cts = new(TimeSpan.FromSeconds(90));

            string destination = Path.Combine(_folder, "asset.bin");
            string sha256 = Convert.ToHexString(SHA256.HashData(_payload));

            await Downloader.SendDownloadAsync(
                server.Url, destination, "Test asset",
                bytes: _payload.Length, sha256: sha256, retries: 2, ct: cts.Token);

            Assert.True(File.Exists(destination));
            Assert.Equal(_payload.Length, new FileInfo(destination).Length);
            Assert.Equal(sha256, HashHelper.Sha256(destination));
            Assert.False(File.Exists(destination + ".part"));
            Assert.False(File.Exists(destination + ".part.state"));
            Assert.Equal(_payload, await File.ReadAllBytesAsync(destination));
        }

        private sealed class RangeServer : IDisposable
        {
            private readonly TcpListener _listener;
            private readonly byte[] _data;
            private readonly CancellationTokenSource _cts = new();
            private readonly Task _loop;

            public RangeServer(byte[] data)
            {
                _data = data;
                _listener = new TcpListener(IPAddress.Loopback, 0);
                _listener.Start();
                Url = "http://127.0.0.1:" + ((IPEndPoint)_listener.LocalEndpoint).Port + "/asset.bin";
                _loop = Task.Run(AcceptAsync);
            }

            public string Url { get; }

            private async Task AcceptAsync()
            {
                while (!_cts.IsCancellationRequested)
                {
                    TcpClient client;
                    try
                    {
                        client = await _listener.AcceptTcpClientAsync(_cts.Token);
                    }
                    catch
                    {
                        break;
                    }
                    _ = Task.Run(() => HandleAsync(client));
                }
            }

            private async Task HandleAsync(TcpClient client)
            {
                using (client)
                {
                    try
                    {
                        NetworkStream stream = client.GetStream();
                        using StreamReader reader = new(stream, Encoding.ASCII, false, 1024, leaveOpen: true);
                        await reader.ReadLineAsync();

                        long start = 0;
                        long end = _data.Length - 1;
                        bool ranged = false;

                        string? line;
                        while (!string.IsNullOrEmpty(line = await reader.ReadLineAsync()))
                        {
                            if (!line.StartsWith("Range:", StringComparison.OrdinalIgnoreCase)) continue;

                            string[] parts = line["Range:".Length..].Trim()
                                .Replace("bytes=", string.Empty).Split('-');
                            start = long.Parse(parts[0]);
                            if (parts.Length > 1 && parts[1].Length > 0) end = long.Parse(parts[1]);
                            ranged = true;
                        }

                        end = Math.Min(end, _data.Length - 1);
                        int length = (int)(end - start + 1);

                        string headers =
                            (ranged ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n") +
                            "Content-Type: application/octet-stream\r\n" +
                            "Accept-Ranges: bytes\r\n" +
                            "Content-Length: " + length + "\r\n" +
                            (ranged ? "Content-Range: bytes " + start + "-" + end + "/" + _data.Length + "\r\n" : "") +
                            "Connection: close\r\n\r\n";

                        await stream.WriteAsync(Encoding.ASCII.GetBytes(headers));
                        await stream.WriteAsync(_data.AsMemory((int)start, length));
                        await stream.FlushAsync();
                    }
                    catch
                    {
                        // The client cancelled: nothing else to do.
                    }
                }
            }

            public void Dispose()
            {
                _cts.Cancel();
                _listener.Stop();
                try { _loop.Wait(TimeSpan.FromSeconds(2)); } catch { }
                _cts.Dispose();
            }
        }
    }
}
