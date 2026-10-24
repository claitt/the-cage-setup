using System;
using System.Buffers;
using System.Collections.Concurrent;
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
    /// Chunk bookkeeping for the segmented downloader: which blocks of the
    /// .part file are already on disk. The state file is a small text header
    /// plus a base64 bitset, so a 15 GB download can resume without a second
    /// copy of the data. The block size is stored in the header, so a map
    /// written with an older block size still resumes.
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

        public static ChunkMap Load(string path, long defaultChunkSize, long totalBytes)
        {
            ChunkMap empty = Create(defaultChunkSize, totalBytes);
            try
            {
                if (!File.Exists(path)) return empty;

                string[] lines = File.ReadAllLines(path);
                if (lines.Length < 4 || lines[0] != Marker) return empty;
                if (!long.TryParse(lines[1], out long storedChunk) || storedChunk <= 0) return empty;
                if (!long.TryParse(lines[2], out long storedTotal) || storedTotal != totalBytes) return empty;

                ChunkMap map = Create(storedChunk, totalBytes);
                byte[] bits = Convert.FromBase64String(lines[3]);
                if (bits.Length < (map.Count + BitsPerByte - 1) / BitsPerByte) return empty;

                for (int i = 0; i < map.Count; i++)
                {
                    if ((bits[i >> BitShift] & (1 << (i & (BitsPerByte - 1)))) == 0) continue;
                    map._done[i] = true;
                    map.DoneBytes += map.LengthOf(i);
                }
                map.Loaded = true;
                return map;
            }
            catch
            {
                // A damaged state file only costs a restart of the download.
                return empty;
            }
        }

        private static ChunkMap Create(long chunkSize, long totalBytes)
        {
            long count = (totalBytes + chunkSize - 1) / chunkSize;
            if (count <= 0 || count > int.MaxValue)
            {
                throw new ArgumentOutOfRangeException(nameof(totalBytes));
            }
            return new ChunkMap((int)count, chunkSize, totalBytes);
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
    /// Range-based downloader for large files. Chunks are pulled from a
    /// shared queue by every connection, so a fast server gets more work
    /// and a stalled one is retried elsewhere after a short cooldown. For
    /// archive.org the chunks are spread over the CDN edge and the two
    /// storage nodes, because a single node caps the speed per client.
    /// </summary>
    internal static class SegmentedDownload
    {
        internal const long ThresholdBytes = 32L * 1024 * 1024;
        internal const long DefaultChunkSize = 4 * 1024 * 1024;

        private const int SlotsPerSource = 4;
        private const int SingleSourceSlots = 8;
        private const int MaxAttemptsPerChunk = 6;
        private const int BufferSize = 1024 * 1024;
        private const int SaveEveryChunks = 32;

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

        private sealed class Source
        {
            private const double InitialSpeed = 1.5 * 1024 * 1024;

            public Source(Uri uri, int slots)
            {
                Uri = uri;
                Slots = new SemaphoreSlim(slots, slots);
                Ewma = InitialSpeed;
            }

            public Uri Uri { get; }
            public SemaphoreSlim Slots { get; }
            public double Ewma { get; set; }
            public long CooldownUntil { get; set; }
            public int Failures { get; set; }
        }

        /// <summary>
        /// Returns false when the source cannot be segmented (no range
        /// support or unknown size); the caller then downloads serially.
        /// </summary>
        public static Task<bool> TryDownloadAsync(
            string url, string destination, string label, long totalBytes,
            Downloader.ReportDelegate? report, CancellationToken ct) =>
            TryDownloadAsync(url, destination, label, totalBytes, report, ct, DefaultChunkSize);

        internal static async Task<bool> TryDownloadAsync(
            string url, string destination, string label, long totalBytes,
            Downloader.ReportDelegate? report, CancellationToken ct, long chunkSize)
        {
            using HttpClient client = CreateClient();

            Probe? probe = await ProbeWithRetriesAsync(client, url, ct, attempts: 3);

            List<Uri> uris = new();
            if (probe != null)
            {
                if (probe.TotalBytes != totalBytes) return false;
                uris.Add(probe.FinalUri);
            }

            await AddArchiveMirrorsAsync(client, url, totalBytes, uris, ct);

            List<Uri> sources = uris
                .GroupBy(uri => uri.Host, StringComparer.OrdinalIgnoreCase)
                .Select(group => group.First())
                .ToList();

            if (sources.Count == 0) return false;

            string statePath = destination + ".state";
            ChunkMap map = ChunkMap.Load(statePath, chunkSize, totalBytes);
            if (!map.Loaded && File.Exists(destination))
            {
                long length = new FileInfo(destination).Length;
                if (length > 0 && length < totalBytes)
                {
                    map.SeedPrefix(length);
                }
                else
                {
                    TryDelete(destination);
                }
            }

            Directory.CreateDirectory(Path.GetDirectoryName(destination) ?? ".");

            using FileStream file = new(
                destination, FileMode.OpenOrCreate, FileAccess.Write, FileShare.Read,
                1 << 20, FileOptions.Asynchronous | FileOptions.RandomAccess);
            file.SetLength(totalBytes);
            map.Save(statePath);

            int slots = sources.Count > 1 ? SlotsPerSource : SingleSourceSlots;
            List<Source> states = sources.Select(uri => new Source(uri, slots)).ToList();
            int workers = states.Count * slots;

            long downloaded = map.DoneBytes;
            int nextChunk = -1;
            ConcurrentQueue<int> retries = new();
            int[] attempts = new int[map.Count];

            report?.Invoke(-1, label + ": " + sources.Count + " server(s), " + workers +
                               " connections, " + Downloader.FormatSize(map.ChunkSize) + " chunks");
            if (map.DoneBytes > 0)
            {
                report?.Invoke(-1, label + ": resuming at " + Downloader.FormatSize(map.DoneBytes));
            }

            using CancellationTokenSource linked = CancellationTokenSource.CreateLinkedTokenSource(ct);
            Exception? failure = null;
            object failureGate = new();

            long ReadProgress() => Interlocked.Read(ref downloaded);

            int TakeIndex()
            {
                if (retries.TryDequeue(out int retry)) return retry;
                int next = Interlocked.Increment(ref nextChunk);
                return next < map.Count ? next : -1;
            }

            async Task WorkAsync(int workerIndex)
            {
                byte[] buffer = ArrayPool<byte>.Shared.Rent(BufferSize);
                try
                {
                    if (workerIndex > 0) await Task.Delay(workerIndex * 75, linked.Token);

                    while (true)
                    {
                        linked.Token.ThrowIfCancellationRequested();

                        int index = TakeIndex();
                        if (index < 0)
                        {
                            if (Interlocked.Read(ref downloaded) >= map.TotalBytes) break;
                            await Task.Delay(200, linked.Token);
                            continue;
                        }
                        if (map.IsDone(index)) continue;

                        long length = map.LengthOf(index);
                        long start = (long)index * map.ChunkSize;
                        long end = start + length - 1;
                        long startedTicks = Stopwatch.GetTimestamp();

                        Source source = await PickSourceAsync(states, linked.Token);
                        try
                        {
                            await FetchChunkAsync(
                                client, source.Uri, file, start, end, length, buffer, linked.Token);

                            double seconds = (Stopwatch.GetTimestamp() - startedTicks) /
                                             (double)Stopwatch.Frequency;
                            double speed = seconds > 0 ? length / seconds : 0;
                            source.Ewma = source.Ewma * 0.7 + speed * 0.3;
                            source.Failures = 0;

                            map.MarkDone(index);
                            Interlocked.Add(ref downloaded, length);
                            if (index % SaveEveryChunks == 0) map.Save(statePath);
                        }
                        catch (OperationCanceledException) when (linked.IsCancellationRequested)
                        {
                            throw;
                        }
                        catch (Exception ex)
                        {
                            source.Failures++;
                            source.CooldownUntil = Environment.TickCount64 +
                                Math.Min(30000, 5000L * source.Failures);

                            int failed = Interlocked.Increment(ref attempts[index]);
                            if (failed >= MaxAttemptsPerChunk)
                            {
                                throw new Exception("chunk " + index + " failed " + failed +
                                                    " times: " + ex.Message, ex);
                            }

                            retries.Enqueue(index);
                        }
                        finally
                        {
                            source.Slots.Release();
                        }
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

            Task[] tasks = Enumerable.Range(0, workers)
                .Select(index => Task.Run(() => WorkAsync(index), linked.Token))
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

        /// <summary>
        /// Picks the fastest server with a free slot. A server that just
        /// failed is skipped for a few seconds and the chunk is retried
        /// on another one, so a stalled node cannot hold the download.
        /// </summary>
        private static async Task<Source> PickSourceAsync(
            List<Source> sources, CancellationToken ct)
        {
            long noSourceSince = 0;

            while (true)
            {
                ct.ThrowIfCancellationRequested();
                long now = Environment.TickCount64;

                Source? best = null;
                double bestScore = double.NegativeInfinity;
                foreach (Source source in sources)
                {
                    if (source.CooldownUntil > now) continue;
                    if (source.Slots.CurrentCount == 0) continue;

                    if (source.Ewma > bestScore)
                    {
                        bestScore = source.Ewma;
                        best = source;
                    }
                }

                if (best != null && await best.Slots.WaitAsync(0, ct)) return best;

                if (noSourceSince == 0)
                {
                    noSourceSince = now;
                }
                else if (now - noSourceSince > 120000)
                {
                    throw new Exception("no archive.org server is answering");
                }

                await Task.Delay(200, ct);
            }
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

                string identifier = Uri.UnescapeDataString(parts[1]);
                string file = Uri.UnescapeDataString(parts[^1]);

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
            int timeoutSeconds = (int)Math.Min(120, Math.Max(30, length / (64 * 1024)));
            using CancellationTokenSource guard = CancellationTokenSource.CreateLinkedTokenSource(ct);
            guard.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));

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
                throw new IOException("no answer for bytes " + start + "-" + end +
                                      " within " + timeoutSeconds + " seconds");
            }
        }

        private static async Task MonitorAsync(
            Downloader.ReportDelegate? report, string label,
            Func<long> readProgress, long totalBytes, CancellationToken ct)
        {
            SpeedMeter meter = new();
            meter.Reset(readProgress());

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
                meter.Add(now);

                report?.Invoke(
                    totalBytes > 0 ? now * 100.0 / totalBytes : -1,
                    Downloader.ProgressText(label, now, totalBytes, meter.Speed));
            }
        }

        private static void TryDelete(string path)
        {
            try
            {
                if (File.Exists(path)) File.Delete(path);
            }
            catch
            {
                // A leftover .part is harmless.
            }
        }
    }
}
