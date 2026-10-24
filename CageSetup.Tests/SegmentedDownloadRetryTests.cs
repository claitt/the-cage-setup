using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using CageSetup.WinUI.Core;
using Xunit;

namespace CageSetup.Tests
{
    /// <summary>
    /// Failure paths of the segmented downloader, which the happy-path test
    /// in SegmentedDownloadTests does not touch: a source that answers 500,
    /// the cooldown that follows, and cancellation with a later resume from
    /// the chunk map. The server is local and speaks just enough HTTP.
    /// </summary>
    public class SegmentedDownloadRetryTests : IDisposable
    {
        private const int Chunk = 128 * 1024;
        private const int Size = Chunk * 4;

        private readonly string _folder;
        private readonly byte[] _payload;

        public SegmentedDownloadRetryTests()
        {
            _folder = Path.Combine(Path.GetTempPath(), "cage-retry-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_folder);

            _payload = new byte[Size];
            for (int i = 0; i < _payload.Length; i++) _payload[i] = (byte)(i * 17 + 3);
        }

        public void Dispose()
        {
            try { Directory.Delete(_folder, recursive: true); } catch { }
        }

        [Fact]
        public void Cooldown_GrowsWithFailuresAndIsCapped()
        {
            Assert.Equal(5000, SegmentedDownload.CooldownMilliseconds(0));
            Assert.Equal(5000, SegmentedDownload.CooldownMilliseconds(1));
            Assert.Equal(10000, SegmentedDownload.CooldownMilliseconds(2));
            Assert.Equal(30000, SegmentedDownload.CooldownMilliseconds(6));
            Assert.Equal(30000, SegmentedDownload.CooldownMilliseconds(42));
        }

        [Fact]
        public async Task ChunkThatAnswers500Once_IsRetriedAfterTheCooldown()
        {
            using TestServer server = new(_payload);
            server.FailOnce(Chunk);
            using CancellationTokenSource cts = new(TimeSpan.FromSeconds(90));

            string part = Path.Combine(_folder, "flaky.part");

            bool done = await SegmentedDownload.TryDownloadAsync(
                server.Url, part, "Flaky", _payload.Length, report: null, ct: cts.Token, chunkSize: Chunk);

            Assert.True(done);
            Assert.Equal(_payload, await File.ReadAllBytesAsync(part));
        }

        [Fact]
        public async Task Cancel_KeepsTheChunkStateAndTheNextRunResumes()
        {
            using TestServer server = new(_payload);
            server.Stall(Chunk * 2);
            string part = Path.Combine(_folder, "resume.part");

            using (CancellationTokenSource cts = new(TimeSpan.FromSeconds(30)))
            {
                Task<bool> first = SegmentedDownload.TryDownloadAsync(
                    server.Url, part, "Cancel", _payload.Length, report: null, ct: cts.Token, chunkSize: Chunk);

                await Task.Delay(1500);
                cts.Cancel();

                await Assert.ThrowsAnyAsync<OperationCanceledException>(() => first);
            }

            Assert.True(File.Exists(part));
            Assert.True(File.Exists(part + ".state"));

            server.Unstall();
            using CancellationTokenSource second = new(TimeSpan.FromSeconds(60));
            bool done = await SegmentedDownload.TryDownloadAsync(
                server.Url, part, "Resume", _payload.Length, report: null, ct: second.Token, chunkSize: Chunk);

            Assert.True(done);
            Assert.Equal(_payload, await File.ReadAllBytesAsync(part));
        }

        /// <summary>
        /// Range-capable server with two knobs: fail the first request for a
        /// chunk (500) and hold one chunk open so a cancel can be tested.
        /// </summary>
        private sealed class TestServer : IDisposable
        {
            private readonly TcpListener _listener;
            private readonly byte[] _data;
            private readonly HashSet<long> _failOnce = new();
            private readonly object _gate = new();
            private readonly CancellationTokenSource _cts = new();
            private readonly Task _loop;
            private long _stallStart = -1;

            public TestServer(byte[] data)
            {
                _data = data;
                _listener = new TcpListener(System.Net.IPAddress.Loopback, 0);
                _listener.Start();
                Url = "http://127.0.0.1:" + ((System.Net.IPEndPoint)_listener.LocalEndpoint).Port + "/asset.bin";
                _loop = Task.Run(AcceptAsync);
            }

            public string Url { get; }

            public void FailOnce(long start)
            {
                lock (_gate) { _failOnce.Add(start); }
            }

            public void Stall(long start) => Interlocked.Exchange(ref _stallStart, start);

            public void Unstall() => Interlocked.Exchange(ref _stallStart, -1);

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

                        string? line;
                        while (!string.IsNullOrEmpty(line = await reader.ReadLineAsync()))
                        {
                            if (!line.StartsWith("Range:", StringComparison.OrdinalIgnoreCase)) continue;

                            string[] parts = line["Range:".Length..].Trim()
                                .Replace("bytes=", string.Empty).Split('-');
                            start = long.Parse(parts[0]);
                            if (parts.Length > 1 && parts[1].Length > 0) end = long.Parse(parts[1]);
                        }

                        end = Math.Min(end, _data.Length - 1);
                        if (end < start) end = start;
                        int length = (int)(end - start + 1);

                        bool fail;
                        lock (_gate) { fail = _failOnce.Remove(start); }
                        if (fail)
                        {
                            await stream.WriteAsync(Encoding.ASCII.GetBytes(
                                "HTTP/1.1 500 Internal Server Error\r\n" +
                                "Content-Length: 0\r\n" +
                                "Connection: close\r\n\r\n"));
                            return;
                        }

                        string headers =
                            "HTTP/1.1 206 Partial Content\r\n" +
                            "Content-Type: application/octet-stream\r\n" +
                            "Accept-Ranges: bytes\r\n" +
                            "Content-Length: " + length + "\r\n" +
                            "Content-Range: bytes " + start + "-" + end + "/" + _data.Length + "\r\n" +
                            "Connection: close\r\n\r\n";

                        await stream.WriteAsync(Encoding.ASCII.GetBytes(headers));

                        if (start == Interlocked.Read(ref _stallStart) && length > 4096)
                        {
                            await stream.WriteAsync(_data.AsMemory((int)start, 4096));
                            await stream.FlushAsync();
                            try { await Task.Delay(Timeout.Infinite, _cts.Token); } catch { }
                            return;
                        }

                        await stream.WriteAsync(_data.AsMemory((int)start, length));
                        await stream.FlushAsync();
                    }
                    catch
                    {
                        // The client cancelled or closed: nothing else to do.
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
