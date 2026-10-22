using System;
using System.IO;
using CageSetup.WinUI.Core;
using Xunit;

namespace CageSetup.Tests
{
    /// <summary>
    /// The SetupState markers used by the auto-resume (state\stepN.done
    /// inside the game files root of the test process).
    /// </summary>
    public class SetupStateTests : IDisposable
    {
        private readonly int _step = 5;

        public SetupStateTests()
        {
            try { File.Delete(SetupState.DonePath(_step)); } catch { }
        }

        [Fact]
        public void MissingMarker_IsNotDone()
        {
            Assert.False(SetupState.IsDone(_step));
        }

        [Fact]
        public void MarkThenCheck_IsDone()
        {
            SetupState.MarkDone(_step);
            Assert.True(SetupState.IsDone(_step));
            Assert.True(new FileInfo(SetupState.DonePath(_step)).Length > 0);
        }

        [Fact]
        public void MarkIsIdempotent()
        {
            SetupState.MarkDone(_step);
            SetupState.MarkDone(_step);
            Assert.True(SetupState.IsDone(_step));
        }

        public void Dispose()
        {
            try { File.Delete(SetupState.DonePath(_step)); } catch { }
        }
    }
}
