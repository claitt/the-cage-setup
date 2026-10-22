using System;
using System.Threading.Tasks;

namespace CageSetup.WinUI.Core
{
    /// <summary>
    /// Auto-resume: on startup the shell opens the first step that is not
    /// completed yet, so an installer closed halfway reopens where it
    /// stopped, and a finished installation lands on step 6 (Launch the
    /// game). Every completion is either detected live (files on disk,
    /// package list over ADB) or remembered by the SetupState markers.
    /// </summary>
    public static class Resume
    {
        public static async Task<int> InitialStepAsync(string baseDir)
        {
            // Step 2: the emulator. Nothing there? Start from the checks.
            string? muMuDir = await Task.Run(() =>
            {
                try { return Emulator.FindMuMuDir(); }
                catch { return (string?)null; }
            });
            if (muMuDir == null) return 1;

            // Step 3: the game files (live check, the files are on disk).
            bool filesReady = await Task.Run(() =>
                GameFiles.ServerFilesPresent() &&
                GameFiles.MasterDataReady() &&
                GameFiles.GameAssetsPresent() &&
                GameFiles.GetClientApkPath() != null);
            if (!filesReady) return 3;

            // Step 4: the client on MuMu. A live check needs a reachable
            // instance; otherwise the completion marker keeps the memory.
            if (!SetupState.IsDone(4))
            {
                string? adb = Adb.FindAdbExe(muMuDir, baseDir);
                bool game = true;
                try
                {
                    game = await Adb.GameInstalledAsync(adb, force: true);
                }
                catch
                {
                    // adb broken? Keep the marker, it is the next best signal.
                }
                if (!game) return 4;
            }

            // Everything is installed: the launch page (it also starts the
            // server and the emulator when they are not running).
            return 6;
        }
    }
}
