using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace CageSetup.WinUI.Controls
{
    /// <summary>
    /// Shared action strip for the step pages: activity label, progress
    /// bar, primary action button with busy ring, a cancel button while
    /// running and an optional secondary button (Refresh state). Both step
    /// 2 and step 3 use it, so the report logic lives in exactly one place.
    /// </summary>
    public partial class ActionPanel : UserControl
    {
        /// <summary>The user pressed the primary action button.</summary>
        public event Action? ActionRequested;

        /// <summary>The user pressed Cancel while an operation was running.</summary>
        public event Action? CancelRequested;

        /// <summary>The user pressed the optional secondary button.</summary>
        public event Action? SecondaryRequested;

        public ActionPanel()
        {
            InitializeComponent();
        }

        public bool IsBusy { get; private set; }

        public string ActionLabel
        {
            get => ActionLabelText.Text;
            set => ActionLabelText.Text = value;
        }

        public string Activity
        {
            get => ActivityLabel.Text;
            set => ActivityLabel.Text = value;
        }

        public string Note
        {
            get => NoteLabel.Text;
            set
            {
                NoteLabel.Text = value;
                NoteLabel.Visibility = string.IsNullOrEmpty(value)
                    ? Visibility.Collapsed
                    : Visibility.Visible;
            }
        }

        public string SecondaryLabel
        {
            get => SecondaryButton.Content as string ?? string.Empty;
            set
            {
                SecondaryButton.Content = value;
                SecondaryButton.Visibility = string.IsNullOrEmpty(value)
                    ? Visibility.Collapsed
                    : Visibility.Visible;
            }
        }

        public bool ActionButtonEnabled
        {
            get => ActionButton.IsEnabled;
            set => ActionButton.IsEnabled = value;
        }

        public bool SecondaryButtonEnabled
        {
            get => SecondaryButton.IsEnabled;
            set => SecondaryButton.IsEnabled = value;
        }

        /// <summary>Enter/leave the busy state (ring, buttons, progress bar).</summary>
        public void SetBusy(bool busy)
        {
            IsBusy = busy;
            BusyRing.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
            BusyRing.IsActive = busy;
            ActionButton.IsEnabled = !busy;
            CancelButton.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
            if (busy)
            {
                ProgressBar.IsIndeterminate = true;
                ProgressBar.Value = 0;
                ProgressBar.Visibility = Visibility.Visible;
            }
            else
            {
                ProgressBar.Visibility = Visibility.Collapsed;
                ProgressBar.IsIndeterminate = false;
            }
        }

        /// <summary>
        /// Pipeline progress: (percent, message); percent &lt; 0 = indeterminate.
        /// Safe to call from any thread; marshals onto the UI thread.
        /// </summary>
        public void Report(double percent, string message)
        {
            _ = DispatcherQueue.TryEnqueue(() =>
            {
                if (percent >= 0)
                {
                    ProgressBar.IsIndeterminate = false;
                    ProgressBar.Value = Math.Clamp(percent, 0, 100);
                }
                else
                {
                    ProgressBar.IsIndeterminate = true;
                }
                ActivityLabel.Text = message;
            });
        }

        private void ActionButton_Click(object sender, RoutedEventArgs e)
        {
            ActionRequested?.Invoke();
        }

        private void CancelButton_Click(object sender, RoutedEventArgs e)
        {
            CancelRequested?.Invoke();
        }

        private void SecondaryButton_Click(object sender, RoutedEventArgs e)
        {
            SecondaryRequested?.Invoke();
        }
    }
}
