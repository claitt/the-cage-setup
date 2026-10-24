using System;
using System.Collections.Generic;
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
    /// Step 4, "Install the game": the client install on MuMu, ported from
    /// the 1.x installer (Action-InstallClient + Action-Debloat). The debloat
    /// (NetEase/MuMu bloat, reversible) runs here since it needs a live
    /// ADB connection; it is installed before the APK, in the 1.x order.
    /// Cancellable: the shared ActionPanel hosts the Cancel button.
    /// </summary>
    public partial class Step4Page : Page
    {
        private bool _busy;
        private ClientState? _state;
        private CancellationTokenSource? _cts;

        /// <summary>Raised whenever the page state text changes.</summary>
        public event Action? StateChanged;

        private static readonly (string Title, CheckIconKind Icon)[] RowSpec =
        {
            ("Patched APK", CheckIconKind.Layers),
            ("MuMu instance", CheckIconKind.Android),
            ("Bloatware", CheckIconKind.Chip),
            ("Game package", CheckIconKind.Disk),
        };

        private List<CheckRow> _rows = new();

        public Step4Page()
        {
            InitializeComponent();

            Actions.ActionLabel = "Install the game";
            Actions.Activity = "Launches MuMu if needed, applies the debloat and installs the APK via ADB.";
            Actions.Note = "The APK is patched in step 3 (archive.org source). ADB talks to MuMu on 127.0.0.1:7555; the debloat removes only NetEase/MuMu components and is reversible (pm install-existing).";
            Actions.SecondaryLabel = "Refresh state";
            Actions.ActionRequested += OnInstallRequested;
            Actions.CancelRequested += () => _cts?.Cancel();
            Actions.SecondaryRequested += async () =>
            {
                if (!_busy) await RefreshStateAsync(report: true);
            };

            BuildRows();
            _ = RefreshStateAsync(report: false);
        }

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

        /// <summary>Snapshot shown in the footer of the card.</summary>
        public sealed class ClientState
        {
            public string? Apk;
            public string? MuMuDir;
            public string? Adb;
            public bool Running;
            public bool Debloat;
            public bool Game;

            public string SummaryText()
            {
                List<string> parts = new();
                parts.Add(Apk != null ? "APK ready" : "APK missing");
                if (Adb == null) parts.Add("adb missing");
                else if (Running && Game) parts.Add("game installed");
                else if (Running) parts.Add("instance reachable");
                else parts.Add("instance not reachable");
                return string.Join(" \u00B7 ", parts);
            }
        }

        public bool IsBusy => _busy;

        /// <summary>Step is complete once the client is installed on the instance.</summary>
        public bool IsComplete => _state?.Game == true;

        public string SummaryText() =>
            _state != null ? _state.SummaryText() : "Detecting the game client...";

        // ------------------------------------------------------------------
        // State
        // ------------------------------------------------------------------

        private async Task<ClientState> DetectAsync()
        {
            ClientState state = new();
            state.MuMuDir = Emulator.FindMuMuDir();
            state.Adb = Adb.FindAdbExe(state.MuMuDir, GameFiles.Root);
            state.Apk = GameFiles.GetClientApkPath();

            if (state.Adb != null)
            {
                state.Running = await Adb.EmulatorRunningAsync(state.Adb);
                if (state.Running)
                {
                    state.Debloat = await Adb.DebloatAppliedAsync(state.Adb);
                    state.Game = await Adb.GameInstalledAsync(state.Adb);
                }
            }
            return state;
        }

        private async Task RefreshStateAsync(bool report)
        {
            if (_busy) return;

            ClientState state = await Task.Run(DetectAsync);
            _state = state;
            ApplyRows(state);

            if (report)
            {
                MainWindow.LogToWindow?.Invoke("Game client: state refreshed. " + state.SummaryText());
            }
            StateChanged?.Invoke();
        }

        private void ApplyRows(ClientState state)
        {
            ApplyRow(_rows[0],
                state.Apk != null ? "Present" : "Not built",
                state.Apk ?? "Step 3 builds it (tools), or drop it in apk\\out",
                state.Apk != null ? CheckStatus.Ok : CheckStatus.Unknown);

            ApplyRow(_rows[1],
                state.Adb == null ? "adb not found" : state.Running ? "Running" : "Not reachable",
                state.Running ? "serial " + Adb.Serial : "adb connect " + Adb.Serial + " finds no device",
                state.Running ? CheckStatus.Ok
                    : state.Adb == null ? CheckStatus.Unknown : CheckStatus.Warn);

            ApplyRow(_rows[2],
                state.Running
                    ? (state.Debloat ? "Removed" : "Active")
                    : "Unknown",
                state.Running
                    ? (state.Debloat
                        ? "com.mumu.store and friends are not active"
                        : "the install removes the NetEase/MuMu packs")
                    : "checked on a running instance",
                !state.Running ? CheckStatus.Unknown
                    : state.Debloat ? CheckStatus.Ok : CheckStatus.Warn);

            ApplyRow(_rows[3],
                state.Running
                    ? (state.Game ? "Installed" : "Not installed")
                    : "Unknown",
                state.Running
                    ? state.Game ? GameFiles.PackageName : "the install pushes the APK to MuMu"
                    : "needs a reachable instance",
                !state.Running ? CheckStatus.Unknown
                    : state.Game ? CheckStatus.Ok : CheckStatus.Warn);
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
                Actions.SecondaryButtonEnabled = false;
                await InstallPipelineAsync(Actions.Report, _cts.Token);
                await RefreshStateAsync(report: false);
            }
            catch (OperationCanceledException)
            {
                MainWindow.LogToWindow?.Invoke("Game client: operation cancelled.");
                Actions.Activity = "Cancelled - whatever was downloaded stays in place.";
            }
            catch (Exception ex)
            {
                MainWindow.LogToWindow?.Invoke("Game client: install failed - " + ex.Message);
                Actions.Activity = "Install failed - see the log strip for details.";
            }
            finally
            {
                _busy = false;
                Actions.SetBusy(false);
                Actions.SecondaryButtonEnabled = true;
                StateChanged?.Invoke();
            }
        }

        /// <summary>Action-InstallClient preceded by the debloat.</summary>
        private async Task InstallPipelineAsync(Downloader.ReportDelegate report, CancellationToken ct)
        {
            report(-1, "Client: preparing the patched APK");

            string muMuDir = Emulator.FindMuMuDir();
            string? adb = Adb.FindAdbExe(muMuDir, GameFiles.Root);

            string? apk = GameFiles.GetClientApkPath();
            if (apk == null)
            {
                if (!await GameInstall.GetClientApk(report, ct))
                {
                    throw new Exception("Patched APK not available");
                }
                apk = GameFiles.GetClientApkPath();
                if (apk == null) throw new Exception("Patched APK not available");
            }
            else
            {
                report(-1, "Patched APK already present: " + Path.GetFileName(apk));
            }

            if (!await Adb.EnsureEmulatorRunningAsync(muMuDir, GameFiles.Root, report, ct))
            {
                throw new Exception("MuMu instance not reachable via ADB");
            }
            adb = Adb.FindAdbExe(muMuDir, GameFiles.Root);
            if (adb == null) throw new Exception("adb.exe not found in the MuMu folders");

            bool debloat = await Adb.DebloatAppliedAsync(adb, force: true, ct);
            if (debloat)
            {
                report(-1, "Debloat already applied (com.mumu.store is gone)");
            }
            else
            {
                report(-1, "Removing the NetEase/MuMu bloatware (reversible)...");
                await Adb.ApplyDebloatAsync(adb, report, ct);
            }

            if (!await Adb.InstallApkAsync(adb, apk, report, ct))
            {
                throw new Exception("Client installation not confirmed on MuMu");
            }

            bool game = await Adb.GameInstalledAsync(adb, force: true, ct);
            if (!game)
            {
                throw new Exception("Client installation not confirmed on MuMu");
            }
            report(100, "Client installed: the launch check happens in step 6");
            SetupState.MarkDone(4);
        }
    }
}
