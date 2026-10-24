using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using CageSetup.WinUI.Controls;
using CageSetup.WinUI.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace CageSetup.WinUI.Pages
{
    /// <summary>
    /// Step 5, "Start the server": the local private server, ported from
    /// the 1.x installer. Start = wizard.exe --prefer-saved after a port
    /// conflicts check (Action-StartServer); Stop and when running, the
    /// primary button restarts (Action-StopServer + StartServer).
    /// Cancellable: the shared ActionPanel hosts the Cancel button.
    /// </summary>
    public partial class Step5Page : Page
    {
        private bool _busy;
        private ServerState? _state;
        private CancellationTokenSource? _cts;

        /// <summary>Raised whenever the page state text changes.</summary>
        public event Action? StateChanged;

        private static readonly (string Title, CheckIconKind Icon)[] RowSpec =
        {
            ("Server binaries", CheckIconKind.Pc),
            ("Ports 8003 / 8080 / 3000", CheckIconKind.Chip),
            ("Server status", CheckIconKind.Disk),
        };

        private List<CheckRow> _rows = new();

        public Step5Page()
        {
            InitializeComponent();

            Actions.ActionLabel = "Start the server";
            Actions.Activity = "wizard.exe --prefer-saved; gRPC 8003, CDN 8080, auth 3000.";
            Actions.Note = "The server keeps its own console window. If another program holds its ports, the check names that process before wizard.exe would fail deep inside.";
            Actions.SecondaryLabel = "Refresh state";
            Actions.ActionRequested += OnActionRequested;
            Actions.CancelRequested += () => _cts?.Cancel();
            Actions.SecondaryRequested += async () =>
            {
                if (!_busy)
                {
                    if (await ServerRun.IsRunningAsync()) await RunStopAsync();
                    else await RefreshStateAsync(report: true);
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
        public sealed class ServerState
        {
            public bool Files;
            public bool Running;
            public List<ServerRun.PortOwner> Conflicts = new();

            public string SummaryText()
            {
                List<string> parts = new();
                parts.Add(Files ? "wizard.exe + bin present" : "server binaries missing");
                if (Running) parts.Add("server running (8003/8080)");
                else if (Conflicts.Count > 0)
                {
                    parts.Add(Conflicts.Count + " port(s) held by other programs");
                }
                else parts.Add("server not running");
                return string.Join(" \u00B7 ", parts);
            }
        }

        public bool IsBusy => _busy;

        /// <summary>Step is complete while the server answers on its ports.</summary>
        public bool IsComplete => _state?.Running == true;

        public string SummaryText() =>
            _state != null ? _state.SummaryText() : "Detecting the server...";

        // ------------------------------------------------------------------
        // State
        // ------------------------------------------------------------------

        private async Task<ServerState> DetectAsync()
        {
            ServerState state = new()
            {
                Files = GameFiles.ServerFilesPresent(),
                Running = await ServerRun.IsRunningAsync(),
            };
            state.Conflicts = await Task.Run(() =>
                ServerRun.ServerPortConflicts(GameFiles.ServerDir));
            return state;
        }

        private async Task RefreshStateAsync(bool report, bool force = false)
        {
            if (_busy && !force) return;

            ServerState state = await Task.Run(DetectAsync);
            _state = state;
            ApplyRows(state);
            if (state.Running) SetupState.MarkDone(5);   // backfill for the auto-resume

            bool running = await ServerRun.IsRunningAsync();
            Actions.ActionLabel = running ? "Restart the server" : "Start the server";
            Actions.SecondaryLabel = running ? "Stop the server" : "Refresh state";

            if (report)
            {
                MainWindow.LogToWindow?.Invoke("Server: state refreshed. " + state.SummaryText());
            }
            StateChanged?.Invoke();
        }

        private void ApplyRows(ServerState state)
        {
            ApplyRow(_rows[0],
                state.Files ? "Present" : "Not downloaded",
                state.Files ? GameFiles.ServerExe : "step 3 fetches them from GitHub (SHA256)",
                state.Files ? CheckStatus.Ok : CheckStatus.Unknown);

            if (state.Running)
            {
                ApplyRow(_rows[1], "Bound by the server",
                    "8003 gRPC \u00B7 8080 CDN \u00B7 3000 auth", CheckStatus.Ok);
            }
            else if (state.Conflicts.Count > 0)
            {
                StringBuilder detail = new();
                foreach (ServerRun.PortOwner conflict in state.Conflicts)
                {
                    if (detail.Length > 0) detail.Append(" \u00B7 ");
                    detail.Append(conflict.Describe());
                }
                ApplyRow(_rows[1], state.Conflicts.Count + " conflict(s)", detail.ToString(), CheckStatus.Error);
            }
            else
            {
                ApplyRow(_rows[1], "Free", "no other program holds the server ports", CheckStatus.Ok);
            }

            ApplyRow(_rows[2],
                state.Running ? "Running" : "Not running",
                state.Running ? "8003 and 8080 answer" : "wizard.exe --prefer-saved",
                state.Running ? CheckStatus.Ok : CheckStatus.Unknown);
        }

        private static void ApplyRow(CheckRow row, string value, string detail, CheckStatus status)
        {
            row.SetResult(new CheckResult(row.Title, value, detail, status));
        }

        // ------------------------------------------------------------------
        // Actions (start / restart / stop)
        // ------------------------------------------------------------------

        private async void OnActionRequested()
        {
            if (_busy) return;
            _cts = new CancellationTokenSource();
            try
            {
                Actions.SetBusy(true);
                _busy = true;
                Actions.SecondaryButtonEnabled = false;

                Downloader.ReportDelegate report = Actions.Report;
                if (await ServerRun.IsRunningAsync(force: true))
                {
                    report(-1, "Restarting the server (stop + start)...");
                    if (!await ServerRun.StopAsync(GameFiles.ServerDir, report, _cts.Token))
                    {
                        throw new Exception("The old server never left its ports: close it manually first.");
                    }
                    await Task.Delay(2000, _cts.Token);
                }
                await ServerRun.EnsureRunningAsync(GameFiles.ServerDir, report, _cts.Token);
                await RefreshStateAsync(report: false, force: true);
            }
            catch (OperationCanceledException)
            {
                MainWindow.LogToWindow?.Invoke("Server: operation cancelled.");
                Actions.Activity = "Cancelled - the server state did not change.";
            }
            catch (Exception ex)
            {
                MainWindow.LogToWindow?.Invoke("Server: failed - " + ex.Message);
                Actions.Activity = "Failed - see the log strip for details.";
            }
            finally
            {
                _busy = false;
                Actions.SetBusy(false);
                Actions.SecondaryButtonEnabled = true;
                StateChanged?.Invoke();
            }
        }

        private async Task RunStopAsync()
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
                await RefreshStateAsync(report: false, force: true);
            }
            catch (OperationCanceledException)
            {
                MainWindow.LogToWindow?.Invoke("Server: stop cancelled.");
            }
            catch (Exception ex)
            {
                MainWindow.LogToWindow?.Invoke("Server: stop failed - " + ex.Message);
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

    }
}
