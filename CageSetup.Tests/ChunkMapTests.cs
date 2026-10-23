using System;
using System.IO;
using CageSetup.WinUI.Core;
using Xunit;

namespace CageSetup.Tests
{
    /// <summary>
    /// Chunk bookkeeping of the segmented downloader: resume state must
    /// survive restarts, ignore mismatched files and never trust a partial
    /// chunk.
    /// </summary>
    public class ChunkMapTests : IDisposable
    {
        private const long Chunk = 4L * 1024 * 1024;
        private const long Total = Chunk * 3 + 1234;

        private readonly string _folder;
        private readonly string _state;

        public ChunkMapTests()
        {
            _folder = Path.Combine(Path.GetTempPath(), "cage-chunks-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_folder);
            _state = Path.Combine(_folder, "file.7z.part.state");
        }

        public void Dispose()
        {
            try { Directory.Delete(_folder, recursive: true); } catch { }
        }

        [Fact]
        public void MissingState_StartsEmpty()
        {
            ChunkMap map = ChunkMap.Load(_state, Chunk, Total);

            Assert.False(map.Loaded);
            Assert.Equal(4, map.Count);
            Assert.Equal(0, map.DoneBytes);
        }

        [Fact]
        public void SaveAndLoad_KeepsCompletedChunks()
        {
            ChunkMap map = ChunkMap.Load(_state, Chunk, Total);
            map.MarkDone(0);
            map.MarkDone(2);
            map.Save(_state);

            ChunkMap again = ChunkMap.Load(_state, Chunk, Total);

            Assert.True(again.Loaded);
            Assert.True(again.IsDone(0));
            Assert.False(again.IsDone(1));
            Assert.True(again.IsDone(2));
            Assert.False(again.IsDone(3));
            Assert.Equal(Chunk * 2, again.DoneBytes);
        }

        [Fact]
        public void SeedPrefix_TrustsOnlyCompleteChunks()
        {
            ChunkMap map = ChunkMap.Load(_state, Chunk, Total);
            map.SeedPrefix(Chunk + 100);

            Assert.True(map.IsDone(0));
            Assert.False(map.IsDone(1));
            Assert.Equal(Chunk, map.DoneBytes);
        }

        [Fact]
        public void Load_WithDifferentTotal_IsIgnored()
        {
            ChunkMap map = ChunkMap.Load(_state, Chunk, Total);
            map.MarkDone(1);
            map.Save(_state);

            ChunkMap other = ChunkMap.Load(_state, Chunk, Total + 1);

            Assert.False(other.Loaded);
            Assert.Equal(0, other.DoneBytes);
        }

        [Fact]
        public void Load_KeepsTheChunkSizeFromTheState()
        {
            ChunkMap map = ChunkMap.Load(_state, Chunk, Total);
            map.MarkDone(0);
            map.Save(_state);

            ChunkMap resumed = ChunkMap.Load(_state, Chunk / 4, Total);

            Assert.True(resumed.Loaded);
            Assert.Equal(Chunk, resumed.ChunkSize);
            Assert.Equal(4, resumed.Count);
            Assert.True(resumed.IsDone(0));
        }

        [Fact]
        public void CorruptedState_IsIgnored()
        {
            File.WriteAllText(_state, "not a chunk map");

            ChunkMap map = ChunkMap.Load(_state, Chunk, Total);

            Assert.False(map.Loaded);
        }
    }
}
