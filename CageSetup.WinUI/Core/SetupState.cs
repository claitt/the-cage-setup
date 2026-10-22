using System;
using System.IO;

namespace CageSetup.WinUI.Core
{
    /// <summary>
    /// Tiny local completion markers (state\stepN.done inside the game
    /// files folder). The auto-resume uses them to remember that an
    /// installation step finished, even when the emulator is not running
    /// (a live check via ADB would then look like "not done").
    /// </summary>
    public static class SetupState
    {
        public static string DonePath(int step) =>
            Path.Combine(GameFiles.Root, "state", "step" + step + ".done");

        public static bool IsDone(int step) => File.Exists(DonePath(step));

        public static void MarkDone(int step)
        {
            try
            {
                string path = DonePath(step);
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllText(path, DateTime.UtcNow.ToString("o"));
            }
            catch
            {
                // A failed marker write must never break a finished install.
            }
        }
    }
}
