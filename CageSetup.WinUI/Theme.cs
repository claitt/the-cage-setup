using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace CageSetup.WinUI
{
    /// <summary>
    /// Resource lookup helper. The palette lives in ThemeDictionaries;
    /// the app is always dark, so the theme key is fixed.
    /// </summary>
    internal static class Theme
    {
        /// <summary>The app keeps a single dark look.</summary>
        public static string Key { get; set; } = "Dark";

        /// <summary>
        /// Look up a themed brush. The theme dictionaries are inside the
        /// merged Palette.xaml, not on the top-level dictionary, so every
        /// merged dictionary has to be scanned.
        /// </summary>
        public static SolidColorBrush B(string key)
        {
            Microsoft.UI.Xaml.ResourceDictionary? resources = Application.Current?.Resources;
            if (resources != null && FindThemed(resources, key) is SolidColorBrush brush) return brush;

            if (resources != null && resources.TryGetValue(key, out object? plainValue) &&
                plainValue is SolidColorBrush plain) return plain;

            if (resources != null)
            {
                foreach (Microsoft.UI.Xaml.ResourceDictionary merged in resources.MergedDictionaries)
                {
                    if (merged.TryGetValue(key, out object? value) && value is SolidColorBrush found) return found;
                    foreach (Microsoft.UI.Xaml.ResourceDictionary nested in merged.MergedDictionaries)
                    {
                        if (nested.TryGetValue(key, out object? nestedValue) &&
                            nestedValue is SolidColorBrush nestedBrush) return nestedBrush;
                    }
                }
            }

            return new SolidColorBrush(Windows.UI.Color.FromArgb(255, 0, 0, 0));
        }

        private static object? FindThemed(Microsoft.UI.Xaml.ResourceDictionary dictionary, string key)
        {
            // NOTE: the indexer of ThemeDictionaries throws a COMException
            // ("Cannot find a resource") when the key is missing, so the
            // non-throwing IDictionary.TryGetValue is used instead.
            if (dictionary.ThemeDictionaries.TryGetValue(Theme.Key, out object? themedObject) &&
                themedObject is Microsoft.UI.Xaml.ResourceDictionary themed &&
                themed.TryGetValue(key, out object? value))
            {
                return value;
            }
            foreach (Microsoft.UI.Xaml.ResourceDictionary merged in dictionary.MergedDictionaries)
            {
                object? result = FindThemed(merged, key);
                if (result != null) return result;
            }
            return null;
        }
    }
}
