using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using CageSetup.WinUI.Core;
using Microsoft.UI.Xaml;

namespace CageSetup.WinUI
{
    public partial class App : Application
    {
        private MainWindow? _window;
        private Mutex? _instanceMutex;

        /// <summary>The shell window, for pages that need a window handle
        /// (folder pickers and similar WinRT interop).</summary>
        public static MainWindow? Shell { get; private set; }

        public App()
        {
            InitializeComponent();
            UnhandledException += OnUnhandledException;
        }

        protected override void OnLaunched(LaunchActivatedEventArgs args)
        {
            try
            {
                // One installer per folder (Get-InstanceMutexName):
                // two windows would fight over the same downloads and ports,
                // and the resource loader of the first instance misloads on
                // simultaneous starts (0x80073B01).
                if (!AcquireInstanceMutex())
                {
                    NativeMethods.MessageBoxW(IntPtr.Zero,
                        "The Cage Setup window is already running for this folder.\r\n\r\n" +
                        "Close that window first: two installers in the same folder " +
                        "would fight over downloads and ports.",
                        "Lunar Tear \u00B7 The Cage Setup 2.0", 0x40);
                    Environment.Exit(0);
                }

                _window = new MainWindow();
                Shell = _window;
                _window.Activate();
            }
            catch (Exception ex)
            {
                WriteCrash(ex, "OnLaunched");
                throw;
            }
        }

        /// <summary>
        /// Mutex name keyed by folder, like the 1.x installer: installs in
        /// different folders stay allowed. The mutex is released by the
        /// operating system when the process ends.
        /// </summary>
        private bool AcquireInstanceMutex()
        {
            string path = GameFiles.BaseDir.ToLowerInvariant();
            byte[] bytes = Encoding.UTF8.GetBytes(path);
            using SHA256 sha = SHA256.Create();
            string hash = BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "");
            string name = "Local\\CageSetup-" + hash[..16];

            _instanceMutex = new Mutex(initiallyOwned: true, name, out bool createdNew);
            return createdNew || _instanceMutex.WaitOne(0, exitContext: false);
        }

        private void OnUnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs e)
        {
            WriteCrash(e.Exception, "UnhandledException");
        }

        private static void WriteCrash(Exception ex, string source)
        {
            try
            {
                string path = Path.Combine(GameFiles.BaseDir, "crash.txt");
                File.WriteAllText(path,
                    "[" + source + "] " + DateTime.Now.ToString("HH:mm:ss") + Environment.NewLine +
                    ex.Message + Environment.NewLine + Environment.NewLine + ex);
            }
            catch
            {
                // Ignore failures while writing the crash log.
            }
        }

        private static class NativeMethods
        {
            [DllImport("user32.dll", SetLastError = false, CharSet = CharSet.Unicode)]
            internal static extern int MessageBoxW(IntPtr owner, string text, string caption, uint type);
        }
    }
}
