using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using CageSetup.WinUI.Controls;
using CageSetup.WinUI.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace CageSetup.WinUI.Pages
{
    /// <summary>
    /// Step 6, "Launch the game": the Start-Game from the 1.x
    /// installer. One click: the server starts if it is not running, the
    /// MuMu instance launches if needed and the ADB monkey intent opens
    /// the game. Cancellable while the launch sequence runs.
    /// </summary>
    public partial class Step6Page : Page
    {
        private bool _busy;
        private bool _playMode;
        private LaunchState? _state;
        private CancellationTokenSource? _cts;

        /// <summary>Raised whenever the page state text changes.</summary>
        public event Action? StateChanged;

        /// <summary>Play mode entry: the user asked for the wizard again.</summary>
        public event Action? WizardRequested;

        /// <summary>
        /// Play mode: shows after a completed installation. Adds the
        /// "Re-run the installation wizard" entry and swaps the secondary
        /// button for a "Stop the server" shortcut.
        /// </summary>
        public bool PlayMode
        {
            get => _playMode;
            set
            {
                _playMode = value;
                WizardButton.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
            }
        }

        private static readonly (string Title, CheckIconKind Icon)[] RowSpec =
        {
            ("Server status", CheckIconKind.Pc),
            ("MuMu instance", CheckIconKind.Android),
            ("Game package", CheckIconKind.Disk),
        };

        private List<CheckRow> _rows = new();

        public Step6Page()
        {
            InitializeComponent();

            Actions.ActionLabel = "Launch the game";
            Actions.Activity = "Starts the server and MuMu if they are not running, then opens the game.";
            Actions.Note = "One click handles everything: server on ports 8003/8080 first, then the MuMu instance, then the launch intent of the game client.";
            Actions.SecondaryLabel = "Refresh state";
            Actions.ActionRequested += OnLaunchRequested;
            Actions.CancelRequested += () => _cts?.Cancel();
            Actions.SecondaryRequested += async () =>
            {
                if (_busy) return;
                if (_playMode && await ServerRun.IsRunningAsync())
                {
                    await RunStopServerAsync();
                }
                else
                {
                    await RefreshStateAsync(report: true);
                }
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
        public sealed class LaunchState
        {
            public bool ServerRunning;
            public string? MuMuDir;
            public string? Adb;
            public bool EmuRunning;
            public bool Game;

            public string SummaryText()
            {
                List<string> parts = new();
                parts.Add(ServerRunning ? "server running" : "server wakes on launch");
                if (Adb == null) parts.Add("adb missing");
                else if (EmuRunning && Game) parts.Add("ready to launch");
                else if (EmuRunning) parts.Add("client not detected");
                else parts.Add("instance not reachable");
                return string.Join(" \u00B7 ", parts);
            }
        }

        public bool IsBusy => _busy;

        public string SummaryText() =>
            _state != null ? _state.SummaryText() : "Detecting the launch readiness...";

        // ------------------------------------------------------------------
        // State
        // ------------------------------------------------------------------

        private async Task<LaunchState> DetectAsync()
        {
            LaunchState state = new()
            {
                ServerRunning = await ServerRun.IsRunningAsync(),
            };
            state.MuMuDir = Emulator.FindMuMuDir();
            state.Adb = Adb.FindAdbExe(state.MuMuDir, GameFiles.Root);
            if (state.Adb != null)
            {
                state.EmuRunning = await Adb.EmulatorRunningAsync(state.Adb);
                if (state.EmuRunning)
                {
                    state.Game = await Adb.GameInstalledAsync(state.Adb);
                    SetupState.MarkDone(4);   // backfill: the client is verifiably there
                }
            }
            return state;
        }

        private async Task RefreshStateAsync(bool report)
        {
            if (_busy) return;

            LaunchState state = await Task.Run(DetectAsync);
            _state = state;
            ApplyRows(state);

            // Play mode turns the secondary into a live stop shortcut.
            if (_playMode)
            {
                Actions.SecondaryLabel = state.ServerRunning ? "Stop the server" : "Refresh state";
            }

            if (report)
            {
                MainWindow.LogToWindow?.Invoke("Launch: state refreshed. " + state.SummaryText());
            }
            StateChanged?.Invoke();
        }

        private void ApplyRows(LaunchState state)
        {
            ApplyRow(_rows[0],
                state.ServerRunning ? "Running" : "Not running",
                state.ServerRunning ? "8003 and 8080 answer" : "the launch starts it automatically",
                state.ServerRunning ? CheckStatus.Ok : CheckStatus.Unknown);

            ApplyRow(_rows[1],
                state.Adb == null ? "adb not found" : state.EmuRunning ? "Running" : "Not reachable",
                state.EmuRunning ? "serial " + Adb.Serial : "adb connect " + Adb.Serial + " finds no device",
                state.EmuRunning ? CheckStatus.Ok
                    : state.Adb == null ? CheckStatus.Unknown : CheckStatus.Warn);

            ApplyRow(_rows[2],
                state.EmuRunning
                    ? (state.Game ? "Installed" : "Not detected")
                    : "Unknown",
                state.EmuRunning
                    ? state.Game ? GameFiles.PackageName : "install it in step 4 first"
                    : "checked on a reachable instance",
                !state.EmuRunning ? CheckStatus.Unknown
                    : state.Game ? CheckStatus.Ok : CheckStatus.Warn);
        }

        private static void ApplyRow(CheckRow row, string value, string detail, CheckStatus status)
        {
            row.SetResult(new CheckResult(row.Title, value, detail, status));
        }

        // ------------------------------------------------------------------
        // Launch pipeline (Start-Game)
        // ------------------------------------------------------------------

        private async void OnLaunchRequested()
        {
            if (_busy) return;
            _cts = new CancellationTokenSource();
            try
            {
                Actions.SetBusy(true);
                _busy = true;
                Actions.SecondaryButtonEnabled = false;
                await LaunchPipelineAsync(Actions.Report, _cts.Token);
                await RefreshStateAsync(report: false);
            }
            catch (OperationCanceledException)
            {
                MainWindow.LogToWindow?.Invoke("Launch: cancelled.");
                Actions.Activity = "Cancelled - the game did not open.";
            }
            catch (Exception ex)
            {
                MainWindow.LogToWindow?.Invoke("Launch: failed - " + ex.Message);
                Actions.Activity = "Launch failed - see the log strip for details.";
            }
            finally
            {
                _busy = false;
                Actions.SetBusy(false);
                Actions.SecondaryButtonEnabled = true;
                StateChanged?.Invoke();
            }
        }

        private async Task LaunchPipelineAsync(Downloader.ReportDelegate report, CancellationToken ct)
        {
            report(-1, "Launching the game...");

            // 1) Start-Game starts the server first when it is not running.
            await ServerRun.EnsureRunningAsync(GameFiles.ServerDir, report, ct);

            // 2) Then the emulator: MuMuManager + the 40x3s wait loop.
            string muMuDir = Emulator.FindMuMuDir();
            if (!await Adb.EnsureEmulatorRunningAsync(muMuDir, GameFiles.Root, report, ct))
            {
                throw new Exception("Cannot launch the game: the emulator is not running.");
            }
            string? adb = Adb.FindAdbExe(muMuDir, GameFiles.Root);
            if (adb == null)
            {
                throw new Exception("adb.exe not found in the MuMu folders");
            }

            // 3) The launch intent: monkey -p <package> -c LAUNCHER 1.
            report(-1, "Opening the game client...");
            string output = (await Adb.LaunchGameAsync(adb, ct)).Trim();
            if (output.Length > 0)
            {
                int cut = Math.Min(160, output.Length);
                report(-1, "adb: " + output[..cut].Replace("\r", "").Replace("\n", " \u00B7 "));
            }
            report(100, "Game launched. Have fun.");
        }

        /// <summary>Play mode: quick server stop (same as step 5's).</summary>
        private async Task RunStopServerAsync()
        {
            if (_busy) return;
            _cts = new CancellationTokenSource();
            try
            {
                Actions.SetBusy(true);
                _busy = true;
                Actions.SecondaryButtonEnabled = false;

                if (!await ServerRun.StopAsync(GameFiles.ServerDir, Actions.Report, _cts.Token))
                {
                    Actions.Activity = "Warning: the server is still listening.";
                }
                await RefreshStateAsync(report: false);
            }
            catch (OperationCanceledException)
            {
                MainWindow.LogToWindow?.Invoke("Play: stop cancelled.");
            }
            catch (Exception ex)
            {
                MainWindow.LogToWindow?.Invoke("Play: stop failed - " + ex.Message);
                Actions.Activity = "Stop failed - see the log strip for details.";
            }
            finally
            {
                _busy = false;
                Actions.SetBusy(false);
                Actions.SecondaryButtonEnabled = true;
                StateChanged?.Invoke();
            }
        }

        private void WizardButton_Click(object sender, RoutedEventArgs e)
        {
            if (_busy) return;
            WizardRequested?.Invoke();
        }
    }
}
