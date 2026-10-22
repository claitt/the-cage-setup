using System.Collections.Generic;
using CageSetup.WinUI.Controls;
using CageSetup.WinUI.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace CageSetup.WinUI.Pages
{
    public partial class Step1Page : Page
    {
        private static readonly string[] RowTitles =
        {
            "Windows",
            "Administrator",
            "Virtualization",
            "Hyper-V",
            "Free space",
            "Game folder",
        };

        private static readonly CheckIconKind[] RowIcons =
        {
            CheckIconKind.Pc,
            CheckIconKind.Shield,
            CheckIconKind.Chip,
            CheckIconKind.Layers,
            CheckIconKind.Disk,
            CheckIconKind.Folder,
        };

        public IReadOnlyList<CheckRow> Rows { get; }

        public Step1Page()
        {
            InitializeComponent();

            List<CheckRow> rows = new();
            for (int i = 0; i < RowTitles.Length; i++)
            {
                CheckRow row = new()
                {
                    Title = RowTitles[i],
                    Icon = RowIcons[i],
                };
                row.SetPending();
                Grid.SetRow(row, i);
                RowsHost.Children.Add(row);
                rows.Add(row);
            }

            Rows = rows;
        }

        public void SetPendingAll()
        {
            foreach (CheckRow row in Rows) row.SetPending();
        }

        public void ApplyResults(List<CheckResult> results)
        {
            for (int i = 0; i < Rows.Count; i++)
            {
                if (i < results.Count) Rows[i].SetResult(results[i]);
                else Rows[i].SetPending();
            }
        }
    }
}
