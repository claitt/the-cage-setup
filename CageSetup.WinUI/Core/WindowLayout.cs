using System;

namespace CageSetup.WinUI.Core
{
    /// <summary>
    /// Window placement math kept out of the WinUI shell so it can be
    /// unit-tested. The setup opens at a fixed size in device-independent
    /// pixels; the shell scales it by the monitor DPI and clamps it to the
    /// work area, because a 1366x768 panel only has ~728 px of height once
    /// the taskbar is excluded.
    /// </summary>
    public static class WindowLayout
    {
        public const int DefaultWidthDip = 1120;
        public const int DefaultHeightDip = 760;

        /// <summary>
        /// Fits the requested size into the monitor work area and centers
        /// it. All values are physical pixels, as AppWindow expects.
        /// </summary>
        public static (int Width, int Height, int X, int Y) Fit(
            int desiredWidth, int desiredHeight,
            int workX, int workY, int workWidth, int workHeight,
            int margin)
        {
            margin = Math.Max(0, margin);

            int maxWidth = Math.Max(1, workWidth - margin * 2);
            int maxHeight = Math.Max(1, workHeight - margin * 2);
            int width = Math.Clamp(desiredWidth, 1, maxWidth);
            int height = Math.Clamp(desiredHeight, 1, maxHeight);

            int x = workX + Math.Max(0, (workWidth - width) / 2);
            int y = workY + Math.Max(0, (workHeight - height) / 2);
            return (width, height, x, y);
        }
    }
}
