using System;
using System.Buffers;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace CageSetup.WinUI.Core
{
    /// <summary>
    /// Chunk bookkeeping for the segmented downloader: which 4 MB blocks
    /// of the .part file are already on disk. The state file is a small
    /// text header plus a base64 bitset, so a 15 GB download can resume
    /// without a second copy of the data.
    /// </summary>
    internal sealed class ChunkMap
    {
        private const string Marker = "cage-chunks-1";
        private const int BitShift = 3;
        private const int BitsPerByte = 8;

        private readonly object _gate = new();
        private readonly bool[] _done;

        public ChunkMap(int count, long chunkSize, long totalBytes)
        {
            _done = new bool[count];
            ChunkSize = chunkSize;
            TotalBytes = totalBytes;
        }

        public int Count => _done.Length;
        public long ChunkSize { get; }
        public long TotalBytes { get; }
        public bool Loaded { get; private set; }
        public long DoneBytes { get; private set; }

        public long LengthOf(int index) =>
            Math.Min(ChunkSize, TotalBytes - (long)index * ChunkSize);

        public bool IsDone(int index) => _done[index];

        public static ChunkMap Load(string path, long chunkSize, long totalBytes)
        {
            int count = (int)((totalBytes + chunkSize - 1) / chunkSize);
            ChunkMap map = new(count, chunkSize, totalBytes);
            try
            {
                if (!File.Exists(path)) return map;

                string[] lines = File.ReadAllLines(path);
                if (lines.Length < 4 || lines[0] != Marker) return map;
                if (!long.TryParse(lines[1], out long storedSize) || storedSize != chunkSize) return map;
                if (!long.TryParse(lines[2], out long storedTotal) || storedTotal != totalBytes) return map;

                byte[] bits = Convert.FromBase64String(lines[3]);
                if (bits.Length < (count + BitsPerByte - 1) / BitsPerByte) return map;

                for (int i = 0; i < count; i++)
                {
                    if ((bits[i >> BitShift] & (1 << (i & (BitsPerByte - 1)))) == 0) continue;
                    map._done[i] = true;
                    map.DoneBytes += map.LengthOf(i);
                }
                map.Loaded = true;
            }
            catch
            {
                // A damaged state file only costs a restart of the download.
            }
            return map;
        }

        /// <summary>Trusts the first <paramref name="bytes"/> as sequential
        /// data, as written by the older single-stream downloader.</summary>
        public void SeedPrefix(long bytes)
        {
            lock (_gate)
            {
                long limit = Math.Min(bytes, TotalBytes);
                for (int i = 0; i < Count; i++)
                {
                    if ((long)i * ChunkSize + LengthOf(i) > limit) break;
                    if (_done[i]) continue;
                    _done[i] = true;
                    DoneBytes += LengthOf(i);
                }
            }
        }

        public void MarkDone(int index)
        {
            lock (_gate)
            {
                _done[index] = true;
            }
        }

        public void Save(string path)
        {
            try
            {
                byte[] bits = new byte[(Count + BitsPerByte - 1) / BitsPerByte];
                lock (_gate)
                {
                    for (int i = 0; i < Count; i++)
                    {
                        if (_done[i]) bits[i >> BitShift] |= (byte)(1 << (i & (BitsPerByte - 1)));
                    }
                }

                string temp = path + ".tmp";
                File.WriteAllText(temp, Marker + "\n" + ChunkSize + "\n" + TotalBytes + "\n" +
                                        Convert.ToBase64String(bits) + "\n");
                File.Move(temp, path, overwrite: true);
            }
            catch
            {
                // State is an optimisation: losing it never corrupts the file.
            }
        }
    }

    /// <summary>
    /// Range-based downloader for large files. It splits the file into
    /// chunks and spreads them over several archive.org servers, because
    /// a single node caps the speed per client. Falls back to the serial
    /// downloader when the server does not support ranges.
    /// </summary>
    internal static class SegmentedDownload
    {
        internal const long ThresholdBytes = 32L * 1024 * 1024;

        private const long ChunkSize = 4L * 1024 * 1024;
        private const int WorkersPerSource = 4;
        private const int SingleSourceWorkers = 8;
        private const int MaxAttemptsPerChunk = 4;
        private const int BufferSize = 1024 * 1024;

        private sealed class Probe
        {
            public Probe(Uri finalUri, long totalBytes)
            {
                FinalUri = finalUri;
                TotalBytes = totalBytes;
            }

            public Uri FinalUri { get; }
            public long TotalBytes { get; }
        }

        /// <summary>
        /// Returns false when the source cannot be segmented (no range
        /// support or unknown size); the caller then downloads serially.
        /// </summary>
        public static async Task<bool> TryDownloadAsync(
            string url, string destination, string label, long totalBytes,
            Downloader.ReportDelegate? report, CancellationToken ct)
        {
            using HttpClient client = CreateClient();

            Probe? probe = await ProbeWithRetriesAsync(client, url, ct, attempts: 3);

            List<Uri> uris = new();
            if (probe != null && probe.TotalBytes == totalBytes)
            {
                uris.Add(probe.FinalUri);
            }
            else if (probe != null)
            {
                return false;
            }

            await AddArchiveMirrorsAsync(client, url, totalBytes, uris, ct);

            List<Uri> sources = uris
                .GroupBy(uri => uri.Host, StringComparer.OrdinalIgnoreCase)
                .Select(group => group.First())
                .ToList();

            if (sources.Count == 0) return false;

            string statePath = destination + ".state";
            ChunkMap map = ChunkMap.Load(statePath, ChunkSize, totalBytes);
            if (!map.Loaded && File.Exists(destination))
            {
                long length = new FileInfo(destination).Length;
                if (length > 0 && length < totalBytes)
                {
                    map.SeedPrefix(length);
                }
                else
                {
                    try { File.Delete(destination); } catch { }
                }
            }

            Directory.CreateDirectory(Path.GetDirectoryName(destination) ?? ".");

            using FileStream file = new(
                destination, FileMode.OpenOrCreate, FileAccess.Write, FileShare.Read,
                1 << 20, FileOptions.Asynchronous | FileOptions.RandomAccess);
            file.SetLength(totalBytes);
            map.Save(statePath);

            long downloaded = map.DoneBytes;
            int nextChunk = -1;
            int workers = sources.Count > 1 ? sources.Count * WorkersPerSource : SingleSourceWorkers;

            report?.Invoke(-1, label + ": " + sources.Count + " server(s), " + workers +
                               " connections, " + Downloader.FormatSize(ChunkSize) + " chunks");
            if (map.DoneBytes > 0)
            {
                report?.Invoke(-1, label + ": resuming at " + Downloader.FormatSize(map.DoneBytes));
            }

            using CancellationTokenSource linked = CancellationTokenSource.CreateLinkedTokenSource(ct);
            Exception? failure = null;
            object failureGate = new();

            long ReadProgress() => Interlocked.Read(ref downloaded);

            async Task WorkAsync(Uri source)
            {
                byte[] buffer = ArrayPool<byte>.Shared.Rent(BufferSize);
                try
                {
                    while (true)
                    {
                        linked.Token.ThrowIfCancellationRequested();
                        int index = Interlocked.Increment(ref nextChunk);
                        if (index >= map.Count) break;
                        if (map.IsDone(index)) continue;

                        long start = (long)index * ChunkSize;
                        long length = map.LengthOf(index);
                        long end = start + length - 1;

                        for (int attempt = 1; ; attempt++)
                        {
                            try
                            {
                                await FetchChunkAsync(
                                    client, source, file, start, end, length, buffer, linked.Token);
                                map.MarkDone(index);
                                Interlocked.Add(ref downloaded, length);
                                break;
                            }
                            catch (OperationCanceledException)
                            {
                                throw;
                            }
                            catch (Exception ex)
                            {
                                if (attempt >= MaxAttemptsPerChunk)
                                {
                                    throw new Exception("chunk " + index + " of " + Path.GetFileName(destination) +
                                                        " failed: " + ex.Message, ex);
                                }
                                await Task.Delay(TimeSpan.FromSeconds(2 * attempt), linked.Token);
                            }
                        }

                        if (index % 16 == 0) map.Save(statePath);
                    }
                }
                catch (Exception ex)
                {
                    lock (failureGate)
                    {
                        failure ??= ex;
                    }
                    linked.Cancel();
                    throw;
                }
                finally
                {
                    ArrayPool<byte>.Shared.Return(buffer);
                }
            }

            Task[] tasks = sources.Count > 1
                ? sources.SelectMany(source => Enumerable.Range(0, WorkersPerSource)
                        .Select(_ => Task.Run(() => WorkAsync(source), linked.Token)))
                    .ToArray()
                : Enumerable.Range(0, SingleSourceWorkers)
                    .Select(_ => Task.Run(() => WorkAsync(sources[0]), linked.Token))
                    .ToArray();

            Task monitor = MonitorAsync(report, label, ReadProgress, totalBytes, linked.Token);

            try
            {
                await Task.WhenAll(tasks);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                throw;
            }
            catch
            {
                if (failure != null && !ct.IsCancellationRequested) throw failure;
                throw;
            }
            finally
            {
                linked.Cancel();
                try { await monitor; } catch { }
                map.Save(statePath);
            }

            ct.ThrowIfCancellationRequested();
            return true;
        }

        private static HttpClient CreateClient()
        {
            SocketsHttpHandler handler = new()
            {
                MaxConnectionsPerServer = 32,
                ConnectTimeout = TimeSpan.FromSeconds(30),
                AutomaticDecompression = DecompressionMethods.None,
                PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            };
            return new HttpClient(handler) { Timeout = TimeSpan.FromHours(10) };
        }

        private static async Task<Probe?> ProbeWithRetriesAsync(
            HttpClient client, string url, CancellationToken ct, int attempts)
        {
            for (int attempt = 1; attempt <= attempts; attempt++)
            {
                ct.ThrowIfCancellationRequested();
                try
                {
                    Probe? probe = await ProbeAsync(client, url, ct, TimeSpan.FromSeconds(20));
                    if (probe != null) return probe;
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch
                {
                    // A transient network error: try again.
                }

                if (attempt < attempts) await Task.Delay(TimeSpan.FromSeconds(attempt), ct);
            }
            return null;
        }

        private static async Task<Probe?> ProbeAsync(
            HttpClient client, string url, CancellationToken ct, TimeSpan timeout)
        {
            using CancellationTokenSource guard = CancellationTokenSource.CreateLinkedTokenSource(ct);
            guard.CancelAfter(timeout);

            using HttpRequestMessage request = new(HttpMethod.Get, url);
            request.Headers.Range = new RangeHeaderValue(0, 0);

            using HttpResponseMessage response =
                await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, guard.Token);
            if (response.StatusCode != HttpStatusCode.PartialContent) return null;

            long? total = response.Content.Headers.ContentRange?.Length;
            if (total == null) return null;

            Uri final = response.RequestMessage?.RequestUri ?? new Uri(url);
            return new Probe(final, total.Value);
        }

        /// <summary>
        /// archive.org serves the same file from a CDN edge and from the
        /// two storage nodes named in the item metadata. Each one caps the
        /// speed, so the downloader uses all of them at once.
        /// </summary>
        private static async Task AddArchiveMirrorsAsync(
            HttpClient client, string url, long totalBytes, List<Uri> sources, CancellationToken ct)
        {
            try
            {
                Uri original = new(url);
                if (!original.Host.Equals("archive.org", StringComparison.OrdinalIgnoreCase)) return;

                string[] parts = original.AbsolutePath.Trim('/').Split('/');
                if (parts.Length < 3 || !parts[0].Equals("download", StringComparison.OrdinalIgnoreCase))
                {
                    return;
                }

                string identifier = parts[1];
                string file = parts[^1];

                using CancellationTokenSource guard = CancellationTokenSource.CreateLinkedTokenSource(ct);
                guard.CancelAfter(TimeSpan.FromSeconds(15));

                using HttpResponseMessage response =
                    await client.GetAsync("https://archive.org/metadata/" + identifier, guard.Token);
                response.EnsureSuccessStatusCode();

                using JsonDocument document = JsonDocument.Parse(
                    await response.Content.ReadAsStringAsync(guard.Token));
                JsonElement root = document.RootElement;

                string? dir = root.TryGetProperty("dir", out JsonElement dirElement)
                    ? dirElement.GetString()
                    : null;
                if (string.IsNullOrEmpty(dir)) return;

                foreach (string key in new[] { "d1", "d2", "server" })
                {
                    if (!root.TryGetProperty(key, out JsonElement element)) continue;
                    string? host = element.ValueKind == JsonValueKind.String ? element.GetString() : null;
                    if (string.IsNullOrEmpty(host)) continue;

                    Uri candidate = new("https://" + host + dir.TrimEnd('/') + "/" +
                                        Uri.EscapeDataString(file));
                    try
                    {
                        Probe? probe = await ProbeAsync(client, candidate.ToString(), ct,
                            TimeSpan.FromSeconds(20));
                        if (probe != null && probe.TotalBytes == totalBytes)
                        {
                            sources.Add(candidate);
                        }
                    }
                    catch (OperationCanceledException)
                    {
                        throw;
                    }
                    catch
                    {
                        // One mirror less; the remaining ones still work.
                    }
                }
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch
            {
                // Metadata is optional: the CDN response is enough.
            }
        }

        private static async Task FetchChunkAsync(
            HttpClient client, Uri source, FileStream file,
            long start, long end, long length, byte[] buffer,
            CancellationToken ct)
        {
            using CancellationTokenSource guard = CancellationTokenSource.CreateLinkedTokenSource(ct);
            guard.CancelAfter(TimeSpan.FromMinutes(5));

            try
            {
                using HttpRequestMessage request = new(HttpMethod.Get, source);
                request.Headers.Range = new RangeHeaderValue(start, end);

                using HttpResponseMessage response =
                    await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, guard.Token);
                if (response.StatusCode != HttpStatusCode.PartialContent)
                {
                    throw new Exception("HTTP " + (int)response.StatusCode + " for bytes " + start + "-" + end);
                }

                await using Stream stream = await response.Content.ReadAsStreamAsync(guard.Token);

                long position = start;
                while (position <= end)
                {
                    int want = (int)Math.Min(buffer.Length, end - position + 1);
                    int read = await stream.ReadAsync(buffer.AsMemory(0, want), guard.Token);
                    if (read <= 0) throw new IOException("the connection closed at byte " + position);

                    await RandomAccess.WriteAsync(file.SafeFileHandle, buffer.AsMemory(0, read), position, guard.Token);
                    position += read;
                }

                if (position - start != length)
                {
                    throw new IOException("short read for bytes " + start + "-" + end);
                }
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                throw new IOException("no answer for bytes " + start + "-" + end + " within 5 minutes");
            }
        }

        private static async Task MonitorAsync(
            Downloader.ReportDelegate? report, string label,
            Func<long> readProgress, long totalBytes, CancellationToken ct)
        {
            Stopwatch watch = Stopwatch.StartNew();
            double lastMs = 0;
            long lastBytes = readProgress();

            while (!ct.IsCancellationRequested)
            {
                try
                {
                    await Task.Delay(500, ct);
                }
                catch (OperationCanceledException)
                {
                    break;
                }

                long now = readProgress();
                double ms = watch.Elapsed.TotalMilliseconds;
                double seconds = (ms - lastMs) / 1000.0;
                double speed = seconds > 0 ? (now - lastBytes) / seconds : 0;
                lastMs = ms;
                lastBytes = now;

                report?.Invoke(
                    totalBytes > 0 ? now * 100.0 / totalBytes : -1,
                    Downloader.ProgressText(label, now, totalBytes, speed));
            }
        }
    }
}
