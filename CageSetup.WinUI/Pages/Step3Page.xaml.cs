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
    /// Step 3, "Get the game files": the four game sources of the 1.x
    /// installer with their real statuses and the combined install action.
    /// Cancellable: the shared ActionPanel hosts the Cancel button and the
    /// token aborts the running download, tool or 7z extraction.
    /// </summary>
    public partial class Step3Page : Page
    {
        private GameInstall.GameState? _state;
        private bool _busy;
        private CancellationTokenSource? _cts;

        /// <summary>Raised whenever the page state text changes.</summary>
        public event Action? StateChanged;

        private static readonly (string Title, CheckIconKind Icon)[] RowSpec =
        {
            ("Server binaries", CheckIconKind.Pc),
            ("Master data", CheckIconKind.Layers),
            ("Game client (APK)", CheckIconKind.Android),
            ("Game assets", CheckIconKind.Disk),
        };

        private List<CheckRow> _rows = new();

        public Step3Page()
        {
            InitializeComponent();

            Actions.ActionLabel = "Download the files";
            Actions.Activity = "Every block is independent: a failure does not stop the others.";
            Actions.SecondaryLabel = "Refresh state";
            Actions.ActionRequested += OnInstallRequested;
            Actions.CancelRequested += () => _cts?.Cancel();
            Actions.SecondaryRequested += async () =>
            {
                if (!_busy) await RefreshStateAsync(report: true);
            };

            BuildRows();
            UpdateNote();
            _ = RefreshStateAsync(report: false);
        }

        private void UpdateNote()
        {
            Actions.Note =
                "Server binaries (GitHub, SHA256), master data (SHA1 + patcher), stock APK from APKMirror patched locally, game assets (14.9 GB download, 48.8 GB extracted)." +
                Environment.NewLine +
                "Files are downloaded to " + GameFiles.Root;
        }

        private async void ChooseFolderButton_Click(object sender, RoutedEventArgs e)
        {
            if (_busy) return;

            try
            {
                Windows.Storage.Pickers.FolderPicker picker = new()
                {
                    SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.ComputerFolder,
                };
                picker.FileTypeFilter.Add("*");

                if (App.Shell == null)
                {
                    MainWindow.LogToWindow?.Invoke("Folder picker: window not available.");
                    return;
                }
                IntPtr hwnd = WinRT.Interop.WindowNative.GetWindowHandle(App.Shell);
                WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);

                Windows.Storage.StorageFolder? folder = await picker.PickSingleFolderAsync();
                if (folder == null) return;

                GameFiles.SetRoot(folder.Path);
                UpdateNote();
                MainWindow.LogToWindow?.Invoke("Game files folder: " + folder.Path);
                await RefreshStateAsync(report: false);
            }
            catch (Exception ex)
            {
                MainWindow.LogToWindow?.Invoke("Folder selection failed: " + ex.Message);
            }
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

        public bool IsBusy => _busy;

        /// <summary>Step is complete when all four game sources are ready.</summary>
        public bool IsComplete =>
            _state != null && _state.ServerFiles && _state.MasterPatched &&
            _state.ClientApk != null && _state.GameAssets;

        public string SummaryText()
        {
            GameInstall.GameState? state = _state;
            if (state == null) return "Detecting the game files...";

            List<string> parts = new();
            parts.Add(state.FreeGB.ToString("N1") + " GB free");
            int ready = 0;
            if (state.ServerFiles) ready++;
            if (state.MasterPatched) ready++;
            if (state.ClientApk != null) ready++;
            if (state.GameAssets) ready++;
            parts.Add(ready + " of 4 ready");
            return string.Join(" \u00B7 ", parts);
        }

        private void ApplyRows()
        {
            GameInstall.GameState state = _state ?? GameInstall.Detect();

            ApplyRow(_rows[0],
                state.ServerFiles ? "Present" : "Not downloaded",
                state.ServerFiles ? "wizard.exe + bin" : "GitHub release v1.0.2 (SHA256)",
                state.ServerFiles ? CheckStatus.Ok : CheckStatus.Unknown);

            ApplyRow(_rows[1],
                state.MasterPatched ? "Patched" : "Not patched",
                state.MasterPatched ? "content unlocked to 2030" : "archive.org (SHA1) + official patcher",
                state.MasterPatched ? CheckStatus.Ok : CheckStatus.Unknown);

            ApplyRow(_rows[2],
                state.ClientApk != null ? "Patched" : "Not built",
                state.ClientApk ?? "APKMirror stock APK, patched locally",
                state.ClientApk != null ? CheckStatus.Ok : CheckStatus.Unknown);

            ApplyRow(_rows[3],
                state.GameAssets ? "Present" : "Not downloaded",
                state.GameAssets ? "revisions ready" : "~15 GB download + 49 GB extracted",
                state.GameAssets ? CheckStatus.Ok : CheckStatus.Unknown);
        }

        private static void ApplyRow(CheckRow row, string value, string detail, CheckStatus status)
        {
            row.SetResult(new CheckResult(row.Title, value, detail, status));
        }

        private async Task RefreshStateAsync(bool report)
        {
            if (_busy) return;
            _state = await Task.Run(GameInstall.Detect);
            ApplyRows();
            if (_state.ServerFiles && _state.MasterPatched && _state.ClientApk != null && _state.GameAssets)
            {
                SetupState.MarkDone(3);   // backfill for the auto-resume
            }
            if (report)
            {
                MainWindow.LogToWindow?.Invoke("Game files: state refreshed. " + SummaryText());
            }
            StateChanged?.Invoke();
        }

        private async void OnInstallRequested()
        {
            if (_busy) return;
            _cts = new CancellationTokenSource();
            try
            {
                Actions.SetBusy(true);
                _busy = true;
                Actions.SecondaryButtonEnabled = false;
                bool ok = await Task.Run(() => GameInstall.InstallAllAsync(Actions.Report, _cts.Token));
                if (ok) SetupState.MarkDone(3);
                await RefreshStateAsync(report: false);
            }
            catch (OperationCanceledException)
            {
                MainWindow.LogToWindow?.Invoke("Game files: operation cancelled.");
                Actions.Activity = "Cancelled - the completed blocks stay in place.";
            }
            catch (Exception ex)
            {
                MainWindow.LogToWindow?.Invoke("Game files: failed - " + ex.Message);
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
    }
}
