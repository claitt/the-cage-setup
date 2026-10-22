using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography.X509Certificates;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace CageSetup.WinUI.Core
{
    /// <summary>Snapshot of the emulator status for page 2.</summary>
    public sealed class EmulatorState
    {
        public string? MuMuDir { get; set; }
        public string? ManagerPath { get; set; }
        public bool Installed { get; set; }
        public bool EnginePresent { get; set; }
        public List<string> EngineFolders { get; } = new();
        public string OfflineInstallerPath { get; set; } = string.Empty;
        public bool OfflineInstallerPresent { get; set; }
        public string InstallerPath { get; set; } = string.Empty;
        public bool InstallerPresent { get; set; }

        public string Headline =>
            Installed ? "MuMu Player installed" : "MuMu Player not installed";
    }

    /// <summary>
    /// Emulator helpers ported from the 1.x installer (Find-MuMuDir,
    /// Test-MuMuEngine and the signature check). Same questions as the
    /// PowerShell script: discovery first, no changes.
    /// </summary>
    public static class Emulator
    {
        // From the 1.x The Cage Setup script: $Config.MuMuInstallerUrl.
        public const string InstallerUrl = "https://api.mumuplayer.com/api/dl/win?channel=gw-overseas12";

        // Silent flags used by the 1.x installer.
        public const string SilentArgs = "/S /fchannel=gw-overseas12 /auto_start=false";

        // $Script:EngineBytes: the Android engine is ~4 GB, used for progress.
        public const double EngineBytes = 4200000000;

        // Watched Netease base folders (UNC free; program files only).
        public static IEnumerable<string> ProgramRoots()
        {
            string? programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            string? programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
            if (!string.IsNullOrEmpty(programFiles)) yield return programFiles;
            if (!string.IsNullOrEmpty(programFilesX86) &&
                !string.Equals(programFilesX86, programFiles, StringComparison.OrdinalIgnoreCase))
            {
                yield return programFilesX86;
            }
        }

        /// <summary>Find-MuMuDir: uninstall entries, then netease folders.</summary>
        public static string? FindMuMuDir()
        {
            List<string> candidates = new();

            string[][] uninstallRoots =
            {
                new[] { "HKEY_LOCAL_MACHINE", @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" },
                new[] { "HKEY_LOCAL_MACHINE", @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" },
                new[] { "HKEY_CURRENT_USER", @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" },
            };

            foreach (string[] rootSpec in uninstallRoots)
            {
                string hiveName = rootSpec[0];
                string path = rootSpec[1];
                RegistryKey? hive = hiveName switch
                {
                    "HKEY_LOCAL_MACHINE" => Registry.LocalMachine,
                    "HKEY_CURRENT_USER" => Registry.CurrentUser,
                    _ => null,
                };
                if (hive == null) continue;

                try
                {
                    using RegistryKey? root = hive.OpenSubKey(path);
                    if (root == null) continue;
                    foreach (string sub in root.GetSubKeyNames())
                    {
                        try
                        {
                            using RegistryKey? key = root.OpenSubKey(sub);
                            if (key == null) continue;
                            object? name = key.GetValue("DisplayName");
                            object? location = key.GetValue("InstallLocation");
                            if (name is string displayName && displayName.Contains("MuMu", StringComparison.OrdinalIgnoreCase) &&
                                location is string locationText && locationText.Length > 0)
                            {
                                candidates.Add(locationText);
                            }
                        }
                        catch
                        {
                            // Broken uninstall entries are skipped.
                        }
                    }
                }
                catch
                {
                    // Locked registries are skipped.
                }
            }

            foreach (string baseDir in ProgramRoots())
            {
                string netease = Path.Combine(baseDir, "Netease");
                candidates.Add(Path.Combine(netease, "MuMuPlayer"));
                try
                {
                    if (Directory.Exists(netease))
                    {
                        foreach (string dir in Directory.GetDirectories(netease, "MuMuPlayer*"))
                        {
                            candidates.Add(dir);
                        }
                    }
                }
                catch
                {
                    // Unreadable folders are skipped.
                }
            }

            foreach (string candidate in candidates)
            {
                if (string.IsNullOrWhiteSpace(candidate)) continue;
                string dir = candidate.Trim().Trim('"').TrimEnd('\\');
                if (File.Exists(Path.Combine(dir, "nx_main", "MuMuManager.exe"))) return dir;
            }
            return null;
        }

        /// <summary>Test-MuMuEngine: a numeric engine folder under nx_device.</summary>
        public static bool EnginePresent(string? muMuDir, List<string>? foundFolders = null)
        {
            if (string.IsNullOrWhiteSpace(muMuDir)) return false;
            string deviceRoot = Path.Combine(muMuDir, "nx_device");
            if (!Directory.Exists(deviceRoot)) return false;

            try
            {
                foreach (string dir in Directory.GetDirectories(deviceRoot))
                {
                    string name = Path.GetFileName(dir);
                    if (Regex.IsMatch(name, @"^\d+\.\d+$"))
                    {
                        foundFolders?.Add(name);
                    }
                }
            }
            catch
            {
                return false;
            }
            return foundFolders == null || foundFolders.Count > 0;
        }

        /// <summary>Authenticode publisher check (1.x Confirm-SignedInstaller / Test-Signature).</summary>
        public static bool IsSignedBy(string path, string publisher)
        {
            try
            {
                X509Certificate cert = X509Certificate.CreateFromSignedFile(path);
                string subject = cert.Subject;
                return subject.Contains(publisher, StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        public static string ToolsMumuDir(string baseDir) => Path.Combine(baseDir, "tools", "mumu");

        public static string InstallerPath(string baseDir) => Path.Combine(ToolsMumuDir(baseDir), "MuMu-installer.exe");

        public static string OfflineInstallerPath(string baseDir) => Path.Combine(ToolsMumuDir(baseDir), "offline", "MuMuNG-offline-setup.exe");

        /// <summary>
        /// Size of the folder watched during the install: the discovered
        /// MuMu dir when present, otherwise Program Files\Netease. Measuring
        /// a single folder (like Get-FolderSize in 1.x) keeps the 2-second
        /// watch loop cheap.
        /// </summary>
        public static long MeasuredInstallBytes(string? muMuDir)
        {
            string target = !string.IsNullOrWhiteSpace(muMuDir) && Directory.Exists(muMuDir)
                ? muMuDir
                : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Netease");
            long total = 0;
            if (!Directory.Exists(target)) return 0;
            try
            {
                foreach (string file in Directory.EnumerateFiles(target, "*", SearchOption.AllDirectories))
                {
                    try
                    {
                        var info = new FileInfo(file);
                        if (info.Length > 0) total += info.Length;
                    }
                    catch
                    {
                        // Files locked by the setup are skipped.
                    }
                }
            }
            catch
            {
                // Unreadable subfolders are skipped.
            }
            return total;
        }

        public static EmulatorState Detect(string baseDir)
        {
            EmulatorState state = new()
            {
                InstallerPath = InstallerPath(baseDir),
                OfflineInstallerPath = OfflineInstallerPath(baseDir),
            };
            state.InstallerPresent = File.Exists(state.InstallerPath);
            state.OfflineInstallerPresent = File.Exists(state.OfflineInstallerPath);

            state.MuMuDir = FindMuMuDir();
            if (state.MuMuDir != null)
            {
                state.Installed = true;
                state.ManagerPath = Path.Combine(state.MuMuDir, "nx_main", "MuMuManager.exe");
            }
            state.EnginePresent = EnginePresent(state.MuMuDir, state.EngineFolders);
            return state;
        }
    }
}
