using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using CageSetup.WinUI.Controls;
using CageSetup.WinUI.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace CageSetup.WinUI.Pages
{
    /// <summary>
    /// Step 2, "Install the emulator": the MuMu Player checks and install
    /// action, ported from the 1.x PowerShell installer (Action-InstallMuMu
    /// = offline-first installer, signature check, silent setup, watch).
    /// Supports cancellation: the shared ActionPanel hosts the Cancel button
    /// and aborts the watch loop.
    /// </summary>
    public partial class Step2Page : Page
    {
        private EmulatorState? _state;
        private bool _busy;
        private CancellationTokenSource? _cts;

        /// <summary>Raised whenever the page state text changes.</summary>
        public event Action? StateChanged;

        private static readonly (string Title, CheckIconKind Icon)[] RowSpec =
        {
            ("MuMu Player", CheckIconKind.Android),
            ("Install folder", CheckIconKind.Folder),
            ("Android engine", CheckIconKind.Disk),
            ("Installer package", CheckIconKind.Installer),
        };

        public Step2Page()
        {
            InitializeComponent();

            Actions.ActionLabel = "Install MuMu Player";
            Actions.Activity = "Install runs the official NetEase installer (/S, signed by Netease).";
            Actions.Note = "The debloat (store, SDK and account packs) is applied later, in the running phase. The Android engine (~4 GB) downloads on the first launch.";
            Actions.SecondaryLabel = "Refresh state";
            Actions.ActionRequested += OnInstallRequested;
            Actions.CancelRequested += () => _cts?.Cancel();
            Actions.SecondaryRequested += async () =>
            {
                if (!_busy) await RefreshStateAsync(logReport: true);
            };

            BuildRows();
            _ = RefreshStateAsync(logReport: false);
        }

        private List<CheckRow> _rows = new();

        private void BuildRows()
        {
            RowsHost.Children.Clear();
            _rows.Clear();
            for (int i = 0; i < RowSpec.Length; i++)
            {
                CheckRow row = new()
                {
                    Title = RowSpec[i].Item1,
                    Icon = RowSpec[i].Item2,
                };
                row.SetPending();
                Grid.SetRow(row, i);
                RowsHost.Children.Add(row);
                _rows.Add(row);
            }
        }

        public string SummaryText()
        {
            EmulatorState? state = _state;
            if (state == null) return "Detecting the emulator...";

            List<string> parts = new();
            if (state.Installed)
            {
                parts.Add("MuMu Player installed");
                parts.Add(state.EnginePresent ? "engine present" : "engine downloads on first launch");
            }
            else
            {
                parts.Add("not installed");
            }
            return string.Join(" \u00B7 ", parts);
        }

        public bool IsInstalling => _busy;

        // ------------------------------------------------------------------
        // State
        // ------------------------------------------------------------------

        private async Task RefreshStateAsync(bool logReport)
        {
            if (_busy) return;

            EmulatorState state = await Task.Run(() => Emulator.Detect(AppContext.BaseDirectory));
            _state = state;

            string? dir = state.MuMuDir;
            ApplyRow(_rows[0],
                state.Installed ? "Installed" : "Not installed",
                state.Installed ? "MuMuManager available" : "Install with the button below",
                state.Installed ? CheckStatus.Ok : CheckStatus.Unknown);

            ApplyRow(_rows[1],
                state.Installed ? "Found" : "Not found",
                state.Installed ? dir! : "Use the registry + Program Files discovery",
                state.Installed ? CheckStatus.Ok : CheckStatus.Unknown);

            ApplyRow(_rows[2],
                state.EnginePresent ? "Present" : "Not downloaded",
                state.EnginePresent
                    ? string.Join(", ", state.EngineFolders) + " engine folders"
                    : "~4 GB downloads on first launch",
                state.Installed
                    ? (state.EnginePresent ? CheckStatus.Ok : CheckStatus.Warn)
                    : CheckStatus.Unknown);

            ApplyRow(_rows[3],
                state.OfflineInstallerPresent
                    ? "OFFLINE package"
                    : state.InstallerPresent ? "MuMu-installer.exe" : "Not downloaded",
                state.OfflineInstallerPresent
                    ? state.OfflineInstallerPath
                    : state.InstallerPresent ? state.InstallerPath : "Downloaded from api.mumuplayer.com",
                state.InstallerPresent || state.OfflineInstallerPresent
                    ? CheckStatus.Ok : CheckStatus.Unknown);

            if (logReport)
            {
                MainWindow.LogToWindow?.Invoke("Emulator: state refreshed. " + SummaryText());
            }
            if (state.Installed) SetupState.MarkDone(2);   // backfill for the auto-resume
            Actions.ActionLabel = state.Installed ? "Already installed" : "Install MuMu Player";
            Actions.ActionButtonEnabled = !_busy && !state.Installed;
            StateChanged?.Invoke();
        }

        private static void ApplyRow(CheckRow row, string value, string detail, CheckStatus status)
        {
            row.SetResult(new CheckResult(row.Title, value, detail, status));
        }

        // ------------------------------------------------------------------
        // Install pipeline
        // ------------------------------------------------------------------

        private async void OnInstallRequested()
        {
            if (_busy) return;
            _cts = new CancellationTokenSource();
            try
            {
                Actions.SetBusy(true);
                _busy = true;
                RefreshStateEnabled(false);
                await InstallPipelineAsync(Actions.Report, _cts.Token);
                await RefreshStateAsync(logReport: false);
            }
            catch (OperationCanceledException)
            {
                MainWindow.LogToWindow?.Invoke("Emulator: installation cancelled.");
                Actions.Activity = "Installation cancelled.";
            }
            catch (Exception ex)
            {
                MainWindow.LogToWindow?.Invoke("Emulator: installation failed - " + ex.Message);
                Actions.Activity = "Installation failed - see the log.";
            }
            finally
            {
                _busy = false;
                Actions.SetBusy(false);
                RefreshStateEnabled(true);
                StateChanged?.Invoke();
            }
        }

        private void RefreshStateEnabled(bool enabled)
        {
            Actions.SecondaryButtonEnabled = enabled;
        }

        /// <summary>The 1.x Action-InstallMuMu flow.</summary>
        private async Task InstallPipelineAsync(Downloader.ReportDelegate report, CancellationToken ct)
        {
            string baseDir = AppContext.BaseDirectory;
            report(-1, "Detecting MuMu Player...");
            EmulatorState current = Emulator.Detect(baseDir);
            if (current.Installed)
            {
                report(-1, "MuMu Player is already installed: " + current.MuMuDir);
                return;
            }

            // 1) Choose the installer: offline package first (1.x behaviour).
            //    Uses the shared Downloader (resume, retries, "already present").
            string setup = current.OfflineInstallerPresent
                ? current.OfflineInstallerPath!
                : current.InstallerPath!;
            if (!current.OfflineInstallerPresent && !current.InstallerPresent)
            {
                await Downloader.SendDownloadAsync(
                    Emulator.InstallerUrl, setup, "MuMu Player installer",
                    retries: 3, report: report, ct: ct);
            }
            else
            {
                report(-1, "Using the local installer: " + Path.GetFileName(setup));
            }

            // 2) Signature check (Netease), same as Confirm-SignedInstaller.
            report(-1, "Verifying the installer signature...");
            if (!Emulator.IsSignedBy(setup, "Netease"))
            {
                report(-1, "The installer is not signed by Netease. Installation STOPPED.");
                throw new Exception("Untrusted installer signature.");
            }
            report(-1, "Signature verified: " + Path.GetFileName(setup) + " (Netease)");

            // 3) Elevation: the installer requires admin (like RunAs in 1.x).
            report(-1, "Starting the silent installation (/S). Confirm the UAC prompt.");
            ProcessStartInfo info = new(setup)
            {
                Arguments = Emulator.SilentArgs,
                UseShellExecute = true,
                Verb = "runas",
            };
            Process.Start(info);
            ct.ThrowIfCancellationRequested();

            // 4) Watch: prefer the discovered folder, like Get-FolderSize in 1.x.
            string? watchDir = current.MuMuDir;
            long baseSize = Emulator.MeasuredInstallBytes(watchDir);
            DateTime start = DateTime.UtcNow;
            DateTime lastGrowth = start;
            long lastSize = baseSize;
            bool uacSeen = false;

            while (true)
            {
                await Task.Delay(2000, ct);
                if (watchDir == null)
                {
                    watchDir = Emulator.FindMuMuDir();
                    if (watchDir != null)
                    {
                        baseSize = Emulator.MeasuredInstallBytes(null);
                        lastSize = baseSize;
                    }
                }
                if (watchDir != null &&
                    File.Exists(Path.Combine(watchDir, "nx_main", "MuMuManager.exe")))
                {
                    report(100, "MuMu Player installed: " + watchDir);
                    SetupState.MarkDone(2);
                    return;
                }

                long size = Emulator.MeasuredInstallBytes(watchDir);
                if (size > lastSize)
                {
                    lastSize = size;
                    lastGrowth = DateTime.UtcNow;
                    uacSeen = true;
                }

                double pct = size > 0 ? Math.Min(99, size / Emulator.EngineBytes * 100.0) : -1;
                string note = uacSeen ? "Installing MuMu Player (silent)..." : "Waiting for the UAC prompt...";
                if (size > baseSize)
                {
                    long delta = size - baseSize;
                    note = "Installing MuMu Player... " + (delta / 1048576.0).ToString("F0") + " MB written";
                }
                report(pct, note);

                if (!uacSeen && (DateTime.UtcNow - start).TotalSeconds > 120)
                {
                    report(-1, "No elevation after 120 seconds: the installation was not started.");
                    throw new Exception("UAC prompt not confirmed.");
                }
                if (uacSeen && (DateTime.UtcNow - lastGrowth).TotalSeconds > 240)
                {
                    report(-1, "No progress for 240 seconds: the installation looks stuck.");
                    throw new Exception("Installation stalled.");
                }
                if ((DateTime.UtcNow - start).TotalSeconds > 3600)
                {
                    report(-1, "Timed out while waiting for the MuMu installation.");
                    throw new Exception("Installation timed out.");
                }
            }
        }
    }
}
