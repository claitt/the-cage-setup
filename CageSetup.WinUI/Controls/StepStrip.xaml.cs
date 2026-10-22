using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;

namespace CageSetup.WinUI.Controls
{
    /// <summary>
    /// Six-segment progress strip, Windows 11 pill style: the current
    /// segment grows to a taller pill with an animated height.
    /// </summary>
    public partial class StepStrip : UserControl
    {
        private readonly List<Border> _segments = new();

        private int _count = 6;
        private int _current = 1;
        private int _completed = 0;

        public StepStrip()
        {
            InitializeComponent();
            Build();
        }

        public int Count
        {
            get => _count;
            set { _count = Math.Max(1, value); Build(); }
        }

        public int Current
        {
            get => _current;
            set { _current = value; Update(animate: true); }
        }

        public int Completed
        {
            get => _completed;
            set { _completed = Math.Max(0, value); Update(animate: false); }
        }

        private void Build()
        {
            _segments.Clear();
            SegmentsGrid.Children.Clear();
            SegmentsGrid.ColumnDefinitions.Clear();

            for (int i = 0; i < _count; i++)
            {
                ColumnDefinition column = new() { Width = new GridLength(1, GridUnitType.Star) };
                SegmentsGrid.ColumnDefinitions.Add(column);

                Border segment = new()
                {
                    CornerRadius = new CornerRadius(2),
                    Height = 4,
                    VerticalAlignment = VerticalAlignment.Center,
                    Background = Theme.B("CageStepIdleBrush"),
                };
                if (i < _count - 1)
                {
                    segment.Margin = new Thickness(0, 0, 8, 0);
                }

                Grid.SetColumn(segment, i);
                SegmentsGrid.Children.Add(segment);
                _segments.Add(segment);
            }

            Update(animate: false);
        }

        private void Update(bool animate)
        {
            if (_segments.Count == 0) return;

            for (int i = 0; i < _segments.Count; i++)
            {
                SolidColorBrush brush = i < _completed
                    ? Theme.B("CageAccentBrush")
                    : i == _current - 1
                        ? Theme.B("CageStepCurrentBrush")
                        : Theme.B("CageStepIdleBrush");

                Border segment = _segments[i];
                double oldHeight = segment.Height;
                double targetHeight = i == _current - 1 ? 7 : 4;

                if (segment.Background != brush) segment.Background = brush;

                if (animate && Math.Abs(oldHeight - targetHeight) > 0.1)
                {
                    Storyboard sb = new();
                    DoubleAnimation grow = new()
                    {
                        From = oldHeight,
                        To = targetHeight,
                        Duration = new Duration(TimeSpan.FromMilliseconds(240)),
                        EasingFunction = new CircleEase { EasingMode = EasingMode.EaseOut },
                    };
                    Storyboard.SetTarget(grow, segment);
                    Storyboard.SetTargetProperty(grow, "Height");
                    sb.Children.Add(grow);
                    sb.Begin();
                }
                else
                {
                    segment.Height = targetHeight;
                }
            }
        }
    }
}
