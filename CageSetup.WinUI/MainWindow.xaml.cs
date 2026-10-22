using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using CageSetup.WinUI.Core;
using CageSetup.WinUI.Pages;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Navigation;
using Windows.Graphics;
using WColor = Windows.UI.Color;

namespace CageSetup.WinUI
{
    public partial class MainWindow : Window
    {
        private readonly string _root = AppContext.BaseDirectory;

        private static readonly string[] StepTitles =
        {
            "Check your PC",
            "Install the emulator",
            "Get the game files",
            "Install the game",
            "Start the server",
            "Launch the game",
        };

        private static readonly string[] StepSubtitles =
        {
            "The Cage Setup checks Windows, virtualization and disk space. Checking does not change anything.",
            "MuMu Player and cleanup",
            "Server, client and assets",
            "Client on the emulator",
            "gRPC 8003 / CDN 8080",
            "Opens the game",
        };

        private bool _busy;
        private bool _checked;
        private bool _logOpen;
        private bool _pendingLogOpen;
        private bool _hasErrors;
        private bool _hasWarnings;
        private int _step = -1;
        private bool _playMode;
        private bool _welcome;
        private int _wizardResumeStep = 1;

        private List<CheckResult>? _step1Results;

        /// <summary>
        /// Static hook so pages can append to the shell log strip.
        /// </summary>
        public static Action<string>? LogToWindow { get; private set; }

        public MainWindow()
        {
            InitializeComponent();

            ExtendsContentIntoTitleBar = true;
            Title = "Lunar Tear \u00B7 The Cage Setup 2.0";
            ApplyTitleBarTheme();

            StepStrip.Count = 6;
            StepStrip.Current = 1;
            StepStrip.Completed = 0;

            StepsFrame.Navigated += StepsFrame_Navigated;

            Log("Lunar Tear / The Cage Setup 2.0 \u2014 WinUI 3 build.");
            Log("Welcome: press Get started to run the six guided steps.");
            LogToWindow = message => Log(message);

            Theme.Key = "Dark";
            Root.RequestedTheme = ElementTheme.Dark;
            NavigateStep(0, animate: false);
            SizeAndPosition();

            // Optional automation for screenshots/tests:
            //  --auto-check : runs the checks shortly after launch
            //  --show-log   : opens the log strip
            //  --step N     : initial step (skips welcome/resume)
            //  --welcome    : force the welcome page (skips auto-resume)
            //  --no-resume  : start on step 1, no welcome, no auto-resume
            //  (the log opens on Loaded, when the target is in the visual tree)
            Root.Loaded += (_, _) =>
            {
                if (_pendingLogOpen) SetLogOpen(true);
            };
            string[] args = Environment.GetCommandLineArgs();
            int? stepArg = FindArgInt(args, "--step");
            if (stepArg is >= 1 and <= 6)
            {
                NavigateStep(stepArg.Value - 1, animate: false);
            }
            else if (HasArg(args, "--no-resume"))
            {
                NavigateStep(0, animate: false);
            }
            else
            {
                // Plain launch (or forced --welcome): greet first. The
                // probes below then either open the first undone step or
                // the play page; on a fresh machine they leave the welcome.
                NavigateWelcome(animate: false);
                if (!HasArg(args, "--welcome"))
                {
                    // Auto-resume: after startup, detect how far the setup
                    // got. A completed installation opens the streamlined
                    // play page (server, emulator and game in one click +
                    // the wizard re-entry); anything else opens the first
                    // undone step. The callback only fires while the user
                    // is still sitting on the welcome page.
                    _ = DispatcherQueue.TryEnqueue(async () =>
                    {
                        await Task.Delay(400);
                        try
                        {
                            if (await Task.Run(() =>
                                SetupState.IsDone(2) && SetupState.IsDone(3) && SetupState.IsDone(4)))
                            {
                                if (_busy || !_welcome) return;
                                Log("Auto-resume: the installation is complete, opening the play page.");
                                _wizardResumeStep = 1;   // a wizard re-run starts from the checks
                                NavigatePlay(animate: true);
                                return;
                            }

                            int initial = await Task.Run(() => Resume.InitialStepAsync(_root));
                            if (_busy || !_welcome) return;
                            if (initial > 1)
                            {
                                Log("Auto-resume: opening step " + initial + " (" + StepTitles[initial - 1] + ").");
                                _wizardResumeStep = initial;
                                NavigateStep(initial - 1, animate: true);
                            }
                            // initial == 1: the setup never started, keep
                            // showing the welcome page.
                        }
                        catch (Exception ex)
                        {
                            Log("Auto-resume skipped: " + ex.Message);
                        }
                    });
                }
            }
            if (HasArg(args, "--show-log")) _pendingLogOpen = true;
            if (HasArg(args, "--auto-check"))
            {
                DispatcherQueue.TryEnqueue(async () =>
                {
                    await Task.Delay(600);
                    RunChecks();
                });
            }
            if (HasArg(args, "--get-server"))
            {
                // Demo flag: fetch the server binaries (download + SHA256 +
                // extract) exactly like step 3's first block.
                DispatcherQueue.TryEnqueue(async () =>
                {
                    await Task.Delay(600);
                    void GameReport(double percent, string message)
                    {
                        DispatcherQueue.TryEnqueue(() => Log(message));
                    }
                    try
                    {
                        await Task.Run(() => GameInstall.GetServerBinaries(GameReport, CancellationToken.None));
                    }
                    catch (Exception ex)
                    {
                        Log("Game: server binaries failed - " + ex.Message);
                    }
                });
            }
        }

        private void SizeAndPosition()
        {
            try
            {
                AppWindow appWindow = AppWindow;
                SizeInt32 size = new(1120, 760);
                appWindow.Resize(size);

                DisplayArea area = DisplayArea.GetFromWindowId(appWindow.Id, DisplayAreaFallback.Primary);
                int x = area.WorkArea.X + (area.WorkArea.Width - size.Width) / 2;
                int y = area.WorkArea.Y + (area.WorkArea.Height - size.Height) / 2;
                appWindow.Move(new PointInt32(x, y));

                string icon = System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "Lunar_Tear.ico");
                if (System.IO.File.Exists(icon)) appWindow.SetIcon(icon);
            }
            catch
            {
                // Older builds may not expose every AppWindow member; the
                // default window is fine.
            }
        }

        private void ApplyTitleBarTheme()
        {
            try
            {
                AppWindowTitleBar bar = AppWindow.TitleBar;
                bar.ButtonBackgroundColor = WColor.FromArgb(0, 0, 0, 0);
                bar.ButtonForegroundColor = WColor.FromArgb(255, 238, 236, 226);   // cream over the art
                bar.ButtonHoverForegroundColor = WColor.FromArgb(255, 252, 250, 244);
                bar.ButtonPressedForegroundColor = WColor.FromArgb(255, 252, 250, 244);
                bar.ButtonHoverBackgroundColor = WColor.FromArgb(46, 252, 250, 244);
                bar.ButtonPressedBackgroundColor = WColor.FromArgb(80, 252, 250, 244);
                bar.InactiveBackgroundColor = WColor.FromArgb(0, 0, 0, 0);
                bar.InactiveForegroundColor = WColor.FromArgb(255, 150, 147, 133);
                bar.BackgroundColor = WColor.FromArgb(0, 0, 0, 0);
                bar.ForegroundColor = WColor.FromArgb(255, 238, 236, 226);
            }
            catch
            {
                // Fallback to system colors on very old builds.
            }
        }

        // ------------------------------------------------------------------
        // Navigation
        // ------------------------------------------------------------------

        private void NavigateStep(int index, bool animate)
        {
            if (index < 0 || index > 5) index = 0;
            _playMode = false;
            _welcome = false;
            WelcomeHost.Visibility = Visibility.Collapsed;
            Client.Visibility = Visibility.Visible;
            SettingsChip.Visibility = Visibility.Visible;
            bool goingBack = index < _step;
            _step = index;

            StepStrip.Current = index + 1;
            StepStrip.Completed = index;

            TitleText.Text = StepTitles[index];
            SubtitleText.Text = index == 0
                ? StepSubtitles[0]
                : StepSubtitles[index] + ".";
            BackChip.Visibility = index > 0 ? Visibility.Visible : Visibility.Collapsed;

            AnimateHeader();
            if (_step != 0 && _logOpen) SetLogOpen(false);
            UpdateCardTexts();
            UpdateAction();

            if (animate)
            {
                SlideNavigationTransitionInfo transition = new()
                {
                    Effect = goingBack
                        ? SlideNavigationTransitionEffect.FromLeft
                        : SlideNavigationTransitionEffect.FromRight,
                };

                if (index == 0)
                {
                    StepsFrame.Navigate(typeof(Step1Page), null, transition);
                }
                else if (index == 1)
                {
                    StepsFrame.Navigate(typeof(Step2Page), null, transition);
                    WireStep2Events(StepsFrame.Content as Step2Page);
                }
                else if (index == 2)
                {
                    StepsFrame.Navigate(typeof(Step3Page), null, transition);
                    WireStep3Events(StepsFrame.Content as Step3Page);
                }
                else if (index == 3)
                {
                    StepsFrame.Navigate(typeof(Step4Page), null, transition);
                    WireStep4Events(StepsFrame.Content as Step4Page);
                }
                else if (index == 4)
                {
                    StepsFrame.Navigate(typeof(Step5Page), null, transition);
                    WireStep5Events(StepsFrame.Content as Step5Page);
                }
                else
                {
                    StepsFrame.Navigate(typeof(Step6Page), null, transition);
                    WireStep6Events(StepsFrame.Content as Step6Page);
                }
            }
            else
            {
                if (index == 0)
                {
                    Step1Page page = new();
                    if (_step1Results != null) page.ApplyResults(_step1Results);
                    StepsFrame.Content = page;
                }
                else if (index == 1)
                {
                    Step2Page page2 = new();
                    StepsFrame.Content = page2;
                    WireStep2Events(page2);
                }
                else if (index == 2)
                {
                    Step3Page page3 = new();
                    StepsFrame.Content = page3;
                    WireStep3Events(page3);
                }
                else if (index == 3)
                {
                    Step4Page page4 = new();
                    StepsFrame.Content = page4;
                    WireStep4Events(page4);
                }
                else if (index == 4)
                {
                    Step5Page page5 = new();
                    StepsFrame.Content = page5;
                    WireStep5Events(page5);
                }
                else
                {
                    Step6Page page6 = new();
                    StepsFrame.Content = page6;
                    WireStep6Events(page6);
                }
            }
        }

        private void WireStep2Events(Step2Page? page)
        {
            if (page != null)
            {
                page.StateChanged += UpdateCardTexts;
            }
        }

        private void WireStep3Events(Step3Page? page)
        {
            if (page != null)
            {
                page.StateChanged += UpdateCardTexts;
            }
        }

        private void WireStep4Events(Step4Page? page)
        {
            if (page != null)
            {
                page.StateChanged += UpdateCardTexts;
            }
        }

        private void WireStep5Events(Step5Page? page)
        {
            if (page != null)
            {
                page.StateChanged += UpdateCardTexts;
            }
        }

        private void WireStep6Events(Step6Page? page)
        {
            if (page != null)
            {
                page.StateChanged += UpdateCardTexts;
            }
        }

        private void StepsFrame_Navigated(object sender, NavigationEventArgs e)
        {
            if (StepsFrame.Content is Step1Page page && _step1Results != null)
            {
                page.ApplyResults(_step1Results);
            }
            if (StepsFrame.Content is Step2Page step2)
            {
                WireStep2Events(step2);
            }
            if (StepsFrame.Content is Step3Page step3)
            {
                WireStep3Events(step3);
            }
            if (StepsFrame.Content is Step4Page step4)
            {
                WireStep4Events(step4);
            }
            if (StepsFrame.Content is Step5Page step5)
            {
                WireStep5Events(step5);
            }
            if (StepsFrame.Content is Step6Page step6)
            {
                WireStep6Events(step6);
            }
            UpdateCardTexts();
        }

        private void AnimateHeader()
        {
            HeaderHost.Opacity = 0;
            HeaderShift.Y = 10;

            Storyboard sb = new();
            DoubleAnimation fade = new()
            {
                From = 0,
                To = 1,
                Duration = new Duration(TimeSpan.FromMilliseconds(240)),
                EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut },
            };
            Storyboard.SetTarget(fade, HeaderHost);
            Storyboard.SetTargetProperty(fade, "(UIElement.Opacity)");

            DoubleAnimation slide = new()
            {
                From = 10,
                To = 0,
                Duration = new Duration(TimeSpan.FromMilliseconds(300)),
                EasingFunction = new CircleEase { EasingMode = EasingMode.EaseOut },
            };
            Storyboard.SetTarget(slide, HeaderShift);
            Storyboard.SetTargetProperty(slide, "Y");

            sb.Children.Add(fade);
            sb.Children.Add(slide);
            sb.Begin();
        }

        /// <summary>
        /// Gentle fade for content swaps that bypass Frame.Navigate
        /// (play mode): same feel as AnimateHeader.
        /// </summary>
        private void AnimateCard()
        {
            StepsFrame.Opacity = 0;
            Storyboard sb = new();
            DoubleAnimation fade = new()
            {
                From = 0,
                To = 1,
                Duration = new Duration(TimeSpan.FromMilliseconds(260)),
                EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut },
            };
            Storyboard.SetTarget(fade, StepsFrame);
            Storyboard.SetTargetProperty(fade, "(UIElement.Opacity)");
            sb.Children.Add(fade);
            sb.Begin();
        }

        // ------------------------------------------------------------------
        // Checks
        // ------------------------------------------------------------------

        private async void RunChecks()
        {
            if (_busy) return;

            _busy = true;
            _checked = false;
            _hasErrors = false;
            _hasWarnings = false;
            _step1Results = null;

            BackChip.IsEnabled = false;
            SettingsChip.IsEnabled = false;
            HintText.Text = "Checking does not change anything on your PC.";
            StatusText.Text = "Step 1 of 6 \u00B7 Checking your PC...";
            CardFooterText.Text = "Running the six checks...";
            UpdateAction();
            Log("Checking the PC...");

            List<CheckResult> results;
            try
            {
                results = await Task.Run(() => SystemCheck.RunAll(_root));
            }
            catch (Exception ex)
            {
                _busy = false;
                BackChip.IsEnabled = true;
                SettingsChip.IsEnabled = true;
                StatusText.Text = "Step 1 of 6 \u00B7 Check failed";
                HintText.Text = "The checks could not run. Open the log for details.";
                CardFooterText.Text = "Check failed \u00B7 see the log";
                UpdateAction();
                Log("Check failed: " + ex.Message);
                return;
            }

            if (StepsFrame.Content is Step1Page page)
            {
                page.ApplyResults(results);
            }
            _step1Results = results;

            foreach (CheckResult result in results)
            {
                if (result.Status == CheckStatus.Error) _hasErrors = true;
                if (result.Status == CheckStatus.Warn) _hasWarnings = true;
                Log(result.Title + ": " + result.Value + " \u00B7 " + result.Detail + " [" + StatusLabel(result.Status) + "]");
            }

            if (_hasErrors) Log("Step 1 found issues that need attention.");
            else if (_hasWarnings) Log("Step 1 is ready with warnings.");
            else Log("Step 1 checks passed.");

            _busy = false;
            _checked = true;
            BackChip.IsEnabled = true;
            SettingsChip.IsEnabled = true;
            UpdateCardTexts();
            UpdateAction();
        }

        private static string StatusLabel(CheckStatus status) => status switch
        {
            CheckStatus.Ok => "OK",
            CheckStatus.Warn => "CHECK",
            CheckStatus.Error => "ERROR",
            _ => "PENDING",
        };

        private string Step1StatusText()
        {
            if (_hasErrors) return "Step 1 of 6 \u00B7 Issues found";
            if (_hasWarnings) return "Step 1 of 6 \u00B7 Ready with warnings";
            return "Step 1 of 6 \u00B7 Ready";
        }

        private string SummaryText()
        {
            int ok = 0, warnings = 0, errors = 0;

            if (StepsFrame.Content is Step1Page page)
            {
                foreach (var row in page.Rows)
                {
                    if (row.Status == CheckStatus.Ok) ok++;
                    else if (row.Status == CheckStatus.Warn) warnings++;
                    else if (row.Status == CheckStatus.Error) errors++;
                }
            }

            if (errors > 0)
                return errors + (errors == 1 ? " issue found" : " issues found") + " \u00B7 fix it before continuing";
            if (warnings > 0)
                return ok + " of 6 checks passed \u00B7 " + warnings + (warnings == 1 ? " warning" : " warnings");
            return "6 of 6 checks passed \u00B7 ready to continue";
        }

private void UpdateCardTexts()
        {
            if (_step < 0) return;

            if (_welcome)
            {
                StatusText.Text = "The Cage Setup 2.0 \u00B7 welcome";
                CardFooterText.Text =
                    "A fan-made offline server setup \u00B7 six guided steps, everything local.";
                LinksRow.Visibility = Visibility.Collapsed;
                HintText.Text = "Nothing runs until you press Get started.";
                return;
            }

            if (_playMode)
            {
                StatusText.Text = "Lunar Tear \u00B7 ready to play";
                CardFooterText.Text = StepsFrame.Content is Step6Page play
                    ? play.SummaryText()
                    : "Detecting the launch readiness...";
                LinksRow.Visibility = Visibility.Collapsed;
                HintText.Text = "Server, emulator and game are installed. Re-run the wizard whenever you want.";
                return;
            }

            if (_step == 0)
            {
                StatusText.Text = _busy
                    ? "Step 1 of 6 \u00B7 Checking your PC..."
                    : _checked ? Step1StatusText() : "Step 1 of 6 \u00B7 Check your PC";
                CardFooterText.Text = _busy
                    ? "Running the six checks..."
                    : _checked ? SummaryText() : "6 checks ready \u00B7 nothing runs until you press Check PC";
                LinksRow.Visibility = _checked ? Visibility.Visible : Visibility.Collapsed;
                HintText.Text = "Checking does not change anything on your PC.";
            }
            else if (_step == 1)
            {
                StatusText.Text = "Step 2 of 6 \u00B7 Install the emulator";
                CardFooterText.Text = StepsFrame.Content is Step2Page step2
                    ? step2.SummaryText()
                    : "Detecting the emulator...";
                LinksRow.Visibility = Visibility.Collapsed;
                HintText.Text = "Install runs the official NetEase installer (silent).";
            }
            else if (_step == 2)
            {
                StatusText.Text = "Step 3 of 6 \u00B7 Get the game files";
                CardFooterText.Text = StepsFrame.Content is Step3Page step3
                    ? step3.SummaryText()
                    : "Detecting the game files...";
                LinksRow.Visibility = Visibility.Collapsed;
                HintText.Text = "Server + master data + client + assets; every block is independent.";
            }
            else if (_step == 3)
            {
                StatusText.Text = "Step 4 of 6 \u00B7 Install the game";
                CardFooterText.Text = StepsFrame.Content is Step4Page step4
                    ? step4.SummaryText()
                    : "Detecting the game client...";
                LinksRow.Visibility = Visibility.Collapsed;
                HintText.Text = "Debloat + APK over ADB; reversible, cancellable while running.";
            }
            else if (_step == 4)
            {
                StatusText.Text = "Step 5 of 6 \u00B7 Start the server";
                CardFooterText.Text = StepsFrame.Content is Step5Page step5p
                    ? step5p.SummaryText()
                    : "Detecting the server...";
                LinksRow.Visibility = Visibility.Collapsed;
                HintText.Text = "wizard.exe --prefer-saved; restart or stop with the buttons on the page.";
            }
            else
            {
                StatusText.Text = "Step 6 of 6 \u00B7 Launch the game";
                CardFooterText.Text = StepsFrame.Content is Step6Page step6
                    ? step6.SummaryText()
                    : "Detecting the launch readiness...";
                LinksRow.Visibility = Visibility.Collapsed;
                HintText.Text = "One click: starts the server and MuMu when they are not running, then opens the game.";
            }
        }

        private void UpdateAction()
        {
            bool pageBusy =
                (_step == 1 && StepsFrame.Content is Step2Page step2 && step2.IsInstalling) ||
                (_step == 2 && StepsFrame.Content is Step3Page step3p && step3p.IsBusy) ||
                (_step == 3 && StepsFrame.Content is Step4Page step4p && step4p.IsBusy) ||
                (_step == 4 && StepsFrame.Content is Step5Page step5p && step5p.IsBusy) ||
                (_step == 5 && StepsFrame.Content is Step6Page step6p && step6p.IsBusy);
            BackChip.IsEnabled = !pageBusy;
            if (_welcome)
            {
                ButtonRing.IsActive = false;
                ButtonRing.Visibility = Visibility.Collapsed;
                PrimaryLabel.Text = "Get started";
                PrimaryButton.IsEnabled = true;
                return;
            }
            if (_playMode)
            {
                ButtonRing.IsActive = false;
                ButtonRing.Visibility = Visibility.Collapsed;
                PrimaryLabel.Text = pageBusy ? "Playing..." : "Re-run the wizard";
                PrimaryButton.IsEnabled = !pageBusy;
                return;
            }
            if (_busy)
            {
                PrimaryLabel.Text = "Checking...";
                ButtonRing.IsActive = true;
                ButtonRing.Visibility = Visibility.Visible;
                PrimaryButton.IsEnabled = false;
                return;
            }

            ButtonRing.IsActive = false;
            ButtonRing.Visibility = Visibility.Collapsed;
            PrimaryButton.IsEnabled = true;

            if (_step <= 0)
            {
                if (_checked)
                {
                    PrimaryLabel.Text = "Continue";
                    if (_hasErrors) PrimaryButton.IsEnabled = false;
                }
                else
                {
                    PrimaryLabel.Text = "Check PC";
                }
            }
            else
            {
                PrimaryLabel.Text = pageBusy ? "Working..." : "Back to step " + _step;
                if (pageBusy) PrimaryButton.IsEnabled = false;
            }
        }

        // ------------------------------------------------------------------
        // Log
        // ------------------------------------------------------------------

        private void Log(string message)
        {
            string line = "[" + DateTime.Now.ToString("HH:mm:ss") + "] " + message;
            LogBox.Text += line + Environment.NewLine;
            LogBox.SelectionStart = LogBox.Text.Length;
            LogBox.SelectionLength = 0;
        }

        private void SetLogOpen(bool open)
        {
            if (_logOpen == open) return;

            _logOpen = open;
            ShowLogButton.Content = open ? "Hide log" : "Show log";
            LogBox.Visibility = Visibility.Visible;

            double from = open ? 0 : 92;
            double to = open ? 92 : 0;

            // Small ease-out tween: storyboards are unreliable for Height
            // before the strip has been laid out once.
            DispatcherQueueTimer? timer = _logTween;
            if (timer != null) { timer.Stop(); }

            if (from == to)
            {
                LogBox.Height = to;
                if (!open) LogBox.Visibility = Visibility.Collapsed;
                return;
            }

            _logTween = DispatcherQueue.CreateTimer();
            int elapsed = 0;
            int total = 220;
            _logTween.Interval = TimeSpan.FromMilliseconds(16);
            _logTween.Tick += (_, _) =>
            {
                elapsed = Math.Min(elapsed + 16, total);
                double t = elapsed / (double)total;
                double eased = 1 - (1 - t) * (1 - t); // ease-out quad
                double value = from + (to - from) * eased;
                LogBox.Height = Math.Max(1, value);
                if (elapsed >= total)
                {
                    _logTween!.Stop();
                    LogBox.Height = to;
                    if (!open) LogBox.Visibility = Visibility.Collapsed;
                    else LogBox.UpdateLayout();
                }
            };
            _logTween.Start();
        }

        private DispatcherQueueTimer? _logTween;

        // ------------------------------------------------------------------
        // Play mode (post-first-install streamlined page)
        // ------------------------------------------------------------------

        /// <summary>
        /// The streamlined page after a completed installation: server,
        /// emulator and game in one click, plus the wizard re-entry.
        /// </summary>
        private void NavigatePlay(bool animate)
        {
            _playMode = true;
            _welcome = false;
            WelcomeHost.Visibility = Visibility.Collapsed;
            Client.Visibility = Visibility.Visible;
            SettingsChip.Visibility = Visibility.Visible;
            _step = 5;                 // strip arithmetic: step 6 of 6
            StepStrip.Current = 6;
            StepStrip.Completed = 6;

            TitleText.Text = "Lunar Tear";
            SubtitleText.Text = "Everything is installed \u00B7 server, emulator and game in one click.";
            BackChip.Visibility = Visibility.Collapsed;

            AnimateHeader();
            if (_logOpen) SetLogOpen(false);
            UpdateCardTexts();
            UpdateAction();

            Step6Page page = new() { PlayMode = true };
            page.StateChanged += UpdateCardTexts;
            page.WizardRequested += OnWizardRequested;
            if (animate)
            {
                AnimateCard();
            }
            StepsFrame.Content = page;
        }

        /// <summary>Requested "Re-run the installation wizard" in play mode.</summary>
        private void OnWizardRequested()
        {
            if (_playMode)
            {
                NavigateStep(Math.Clamp(_wizardResumeStep, 1, 6) - 1, animate: true);
            }
        }

        /// <summary>
        /// First-run splash over the whole window: the project name, a
        /// one-paragraph summary of what The Cage Setup does (including
        /// the Walter Sparrow note) and an arrow button. Shown only when
        /// nothing is installed yet; the arrow opens step 1.
        /// </summary>
        private void NavigateWelcome(bool animate)
        {
            _welcome = true;
            _playMode = false;
            _step = 0;                 // next step is step 1
            StepStrip.Current = 1;
            StepStrip.Completed = 0;

            BackChip.Visibility = Visibility.Collapsed;
            SettingsChip.Visibility = Visibility.Collapsed;
            Client.Visibility = Visibility.Collapsed;   // full-window splash: no cards, no strip
            if (_logOpen) SetLogOpen(false);

            WelcomeHost.Visibility = Visibility.Visible;
            if (animate)
            {
                WelcomeHost.Opacity = 0;
                Storyboard sb = new();
                DoubleAnimation fade = new()
                {
                    From = 0,
                    To = 1,
                    Duration = new Duration(TimeSpan.FromMilliseconds(240)),
                    EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut },
                };
                Storyboard.SetTarget(fade, WelcomeHost);
                Storyboard.SetTargetProperty(fade, "(UIElement.Opacity)");
                sb.Children.Add(fade);
                sb.Begin();
            }
        }

        private void WelcomeStartButton_Click(object sender, RoutedEventArgs e)
        {
            if (!_welcome) return;
            NavigateStep(0, animate: true);
        }

        /// <summary>"Lunar Tear" inside the splash description: the
        /// project page on GitHub (the repo the server ships from).</summary>
        private void LunarTearLink_Click(
            Microsoft.UI.Xaml.Documents.Hyperlink sender,
            Microsoft.UI.Xaml.Documents.HyperlinkClickEventArgs args)
        {
            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "https://github.com/Walter-Sparrow/lunar-tear",
                    UseShellExecute = true,
                });
            }
            catch
            {
                // No default browser handler: ignore, never break the splash.
            }
        }

        private void BackChip_Click(object sender, RoutedEventArgs e)
        {
            if (_busy) return;
            if (StepsFrame.Content is Step2Page { IsInstalling: true }) return;
            if (StepsFrame.Content is Step3Page { IsBusy: true }) return;
            if (StepsFrame.Content is Step4Page { IsBusy: true }) return;
            if (StepsFrame.Content is Step5Page { IsBusy: true }) return;
            if (StepsFrame.Content is Step6Page { IsBusy: true }) return;
            if (_step > 0) NavigateStep(_step - 1, animate: true);
        }

        private void SettingsChip_Click(object sender, RoutedEventArgs e)
        {
            if (_busy) return;
            _ = ShowSettingsDialogAsync();
        }

        private async Task ShowSettingsDialogAsync()
        {
            string root = AppContext.BaseDirectory;

            StackPanel content = new() { Spacing = 10 };
            content.Children.Add(new TextBlock
            {
                FontSize = 12.5,
                Foreground = Theme.B("CageBodyBrush"),
                TextWrapping = TextWrapping.Wrap,
                MaxWidth = 340,
                Text = "Lunar Tear \u00B7 The Cage Setup 2.0  \u00B7  v" +
                       typeof(App).Assembly.GetName().Version?.ToString(3) +
                       "  \u00B7  dark theme",
            });
            content.Children.Add(new TextBlock
            {
                FontSize = 12,
                Foreground = Theme.B("CageMutedBrush"),
                TextWrapping = TextWrapping.Wrap,
                MaxWidth = 340,
                Text = "Game files folder: " + root,
            });

            Button openFolder = new()
            {
                Content = "Open the game files folder",
                MinWidth = 200,
            };
            openFolder.Click += (_, _) =>
            {
                try
                {
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = "explorer.exe",
                        Arguments = "\"" + root.TrimEnd('\\') + "\"",
                        UseShellExecute = true,
                    });
                }
                catch
                {
                    // The folder always exists here; ignore Explorer failures.
                }
            };
            content.Children.Add(openFolder);

            ContentDialog dialog = new()
            {
                XamlRoot = Root.XamlRoot,
                Title = "Impostazioni",
                CloseButtonText = "Chiudi",
                DefaultButton = ContentDialogButton.Close,
                Content = content,
            };
            await dialog.ShowAsync();
        }

        private void CheckAgainButton_Click(object sender, RoutedEventArgs e)
        {
            if (!_busy) RunChecks();
        }

        private void ShowLogButton_Click(object sender, RoutedEventArgs e)
        {
            SetLogOpen(!_logOpen);
        }

        private void PrimaryButton_Click(object sender, RoutedEventArgs e)
        {
            if (_busy) return;
            if (StepsFrame.Content is Step2Page { IsInstalling: true }) return;
            if (StepsFrame.Content is Step3Page { IsBusy: true }) return;
            if (StepsFrame.Content is Step4Page { IsBusy: true }) return;
            if (StepsFrame.Content is Step5Page { IsBusy: true }) return;
            if (StepsFrame.Content is Step6Page { IsBusy: true }) return;

            if (_playMode)
            {
                // Re-run the installation wizard: back to the first step
                // that is not done yet (step 1 when everything completed).
                NavigateStep(Math.Clamp(_wizardResumeStep, 1, 6) - 1, animate: true);
                return;
            }

            if (_welcome)
            {
                NavigateStep(0, animate: true);
                return;
            }

            if (_step <= 0)
            {
                if (_checked) NavigateStep(1, animate: true);
                else RunChecks();
            }
            else
            {
                NavigateStep(0, animate: true);
            }
        }

        // ------------------------------------------------------------------
        // Small command line helpers (demo/screenshot automation).
        // ------------------------------------------------------------------

        private static bool HasArg(string[] args, string name) => Array.Exists(args, a => a == name);

        private static int? FindArgInt(string[] args, string name)
        {
            for (int i = 0; i < args.Length - 1; i++)
            {
                if (args[i] == name && int.TryParse(args[i + 1], out int value)) return value;
            }
            return null;
        }
    }
}
