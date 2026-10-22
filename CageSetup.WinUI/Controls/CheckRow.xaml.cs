using CageSetup.WinUI.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;

namespace CageSetup.WinUI.Controls
{
    public enum CheckIconKind
    {
        Pc,
        Shield,
        Chip,
        Layers,
        Disk,
        Folder,
        Android,
        Installer,
    }

    /// <summary>
    /// One check row in the main card: icon, title, live value and a status
    /// pill that pops in with a small scale animation on every change.
    /// </summary>
    public partial class CheckRow : UserControl
    {
        private string _title = string.Empty;
        private string _detail = "Not checked yet";
        private CheckIconKind _icon = CheckIconKind.Pc;
        private CheckStatus _status = CheckStatus.Unknown;

        public CheckRow()
        {
            InitializeComponent();
            IconGlyph.Glyph = GlyphFor(_icon);
            TitleText.Text = _title;
            DetailText.Text = _detail;
        }

        public string Title
        {
            get => _title;
            set { _title = value; TitleText.Text = value; }
        }

        public CheckIconKind Icon
        {
            get => _icon;
            set { _icon = value; IconGlyph.Glyph = GlyphFor(value); }
        }

        public CheckStatus Status => _status;

        public void SetResult(CheckResult result)
        {
            _title = result.Title;
            TitleText.Text = result.Title;
            _detail = result.Value + " \u00B7 " + result.Detail;
            DetailText.Text = _detail;
            _status = result.Status;
            ApplyStatus();
        }

        public void SetPending()
        {
            _detail = "Not checked yet";
            DetailText.Text = _detail;
            _status = CheckStatus.Unknown;
            ApplyStatus();
        }

        private void ApplyStatus()
        {
            (SolidColorBrush soft, SolidColorBrush color, string label) = _status switch
            {
                CheckStatus.Ok => (Theme.B("CageOkSoftBrush"), Theme.B("CageOkBrush"), "OK"),
                CheckStatus.Warn => (Theme.B("CageWarnSoftBrush"), Theme.B("CageWarnBrush"), "CHECK"),
                CheckStatus.Error => (Theme.B("CageErrorSoftBrush"), Theme.B("CageErrorBrush"), "ERROR"),
                _ => (Theme.B("CagePendingSoftBrush"), Theme.B("CagePendingBrush"), "PENDING"),
            };

            Pill.Background = soft;
            PillText.Foreground = color;
            PillText.Text = label;

            Storyboard sb = new();
            DoubleAnimation fade = new()
            {
                From = 0,
                To = 1,
                Duration = new Duration(TimeSpan.FromMilliseconds(180)),
                EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut },
            };
            Storyboard.SetTarget(fade, Pill);
            Storyboard.SetTargetProperty(fade, "(UIElement.Opacity)");

            DoubleAnimation growX = new()
            {
                From = 0.88,
                To = 1,
                Duration = new Duration(TimeSpan.FromMilliseconds(220)),
                EasingFunction = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.3 },
            };
            Storyboard.SetTarget(growX, Pill);
            Storyboard.SetTargetProperty(growX, "(UIElement.RenderTransform).(ScaleTransform.ScaleX)");

            DoubleAnimation growY = new()
            {
                From = 0.88,
                To = 1,
                Duration = new Duration(TimeSpan.FromMilliseconds(220)),
                EasingFunction = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.3 },
            };
            Storyboard.SetTarget(growY, Pill);
            Storyboard.SetTargetProperty(growY, "(UIElement.RenderTransform).(ScaleTransform.ScaleY)");

            sb.Children.Add(fade);
            sb.Children.Add(growX);
            sb.Children.Add(growY);
            sb.Begin();
        }

        private static string GlyphFor(CheckIconKind kind) => kind switch
        {
            // Segoe Fluent Icons glyphs.
            CheckIconKind.Pc => "\uE7F4",       // desktop monitor
            CheckIconKind.Shield => "\uEA18",   // shield
            CheckIconKind.Chip => "\uE950",     // CPU with pins
            CheckIconKind.Layers => "\uEB91",   // stacked panes
            CheckIconKind.Disk => "\uE75A",     // drive bay
            CheckIconKind.Folder => "\uE8B7",   // folder
            CheckIconKind.Android => "\uE964",  // boxed chip (Android engine)
            CheckIconKind.Installer => "\uE9F9",// package page
            _ => "\uE713",
        };
    }
}
