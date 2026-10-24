using CageSetup.WinUI.Core;
using Xunit;

namespace CageSetup.Tests
{
    /// <summary>
    /// The window opens at a fixed DIP size scaled by the monitor DPI; the
    /// fit math must keep it inside the work area on small panels and honor
    /// a secondary monitor's offset.
    /// </summary>
    public class WindowLayoutTests
    {
        [Fact]
        public void LargeWorkArea_KeepsTheRequestedSizeAndCenters()
        {
            (int width, int height, int x, int y) = WindowLayout.Fit(
                1120, 760, 0, 0, 2560, 1400, margin: 16);

            Assert.Equal(1120, width);
            Assert.Equal(760, height);
            Assert.Equal(720, x);
            Assert.Equal(320, y);
        }

        [Fact]
        public void TaskbarHeight_ShrinksTheWindowInsteadOfOverflowing()
        {
            // 1366x768 at 100%: the work area is only 728 px tall.
            (int width, int height, int x, int y) = WindowLayout.Fit(
                1120, 760, 0, 0, 1366, 728, margin: 16);

            Assert.Equal(1120, width);
            Assert.Equal(696, height);
            Assert.Equal(123, x);
            Assert.Equal(16, y);
        }

        [Fact]
        public void OversizedRequest_IsClampedToTheWorkArea()
        {
            (int width, int height, int x, int y) = WindowLayout.Fit(
                2000, 1500, 0, 0, 1366, 728, margin: 16);

            Assert.Equal(1334, width);
            Assert.Equal(696, height);
            Assert.Equal(16, x);
            Assert.Equal(16, y);
        }

        [Fact]
        public void SecondaryMonitor_UsesItsOwnOffset()
        {
            (int width, int height, int x, int y) = WindowLayout.Fit(
                1120, 760, 1920, 0, 1920, 1040, margin: 16);

            Assert.Equal(1120, width);
            Assert.Equal(760, height);
            Assert.Equal(2320, x);
            Assert.Equal(140, y);
        }
    }
}
