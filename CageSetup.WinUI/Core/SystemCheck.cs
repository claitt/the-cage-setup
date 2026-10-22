using System.Globalization;
using System.IO;
using System.Management;
using System.Security.Principal;
using Microsoft.Win32;

namespace CageSetup.WinUI.Core
{
    /// <summary>
    /// The checks behind step 1, ported one to one from the 1.x installer
    /// via the WinForms prototype. Same questions, no downloads, no changes.
    /// </summary>
    public static class SystemCheck
    {
        public static List<CheckResult> RunAll(string root)
        {
            List<CheckResult> results = new()
            {
                CheckWindows(),
                CheckAdministrator(),
                CheckVirtualization(),
                CheckHyperV(),
                CheckDisk(root),
                CheckFolder(root),
            };
            return results;
        }

        private static CheckResult CheckWindows()
        {
            string product = "Windows";
            string display = string.Empty;
            int build = Environment.OSVersion.Version.Build;

            try
            {
                using RegistryKey key = Registry.LocalMachine.OpenSubKey(
                    @"SOFTWARE\Microsoft\Windows NT\CurrentVersion")!;
                if (key != null)
                {
                    object? p = key.GetValue("ProductName");
                    object? d = key.GetValue("DisplayVersion");
                    object? b = key.GetValue("CurrentBuild");
                    if (p != null) product = p.ToString()!;
                    if (d != null) display = d.ToString()!;
                    if (b != null && int.TryParse(b.ToString(), out int parsed)) build = parsed;
                }
            }
            catch
            {
                // The environment values above are enough if the registry is locked.
            }

            if (build >= 22000) product = product.Replace("Windows 10", "Windows 11");
            string value = product;
            if (!string.IsNullOrEmpty(display)) value += " " + display;
            value += " (build " + build.ToString(CultureInfo.InvariantCulture) + ")";

            bool ok = Environment.Is64BitOperatingSystem;
            return new CheckResult("Windows", value,
                ok ? "64-bit system" : "A 64-bit system is required",
                ok ? CheckStatus.Ok : CheckStatus.Error);
        }

        private static CheckResult CheckAdministrator()
        {
            bool admin = false;
            try
            {
                using WindowsIdentity identity = WindowsIdentity.GetCurrent();
                WindowsPrincipal principal = new(identity);
                admin = principal.IsInRole(WindowsBuiltInRole.Administrator);
            }
            catch
            {
                // Treated as "not elevated".
            }

            return new CheckResult("Administrator", admin ? "Yes" : "No",
                admin ? "Elevated process" : "Run as administrator to install MuMu",
                admin ? CheckStatus.Ok : CheckStatus.Warn);
        }

        private static CheckResult CheckVirtualization()
        {
            bool? enabled = null;

            try
            {
                using ManagementObjectSearcher searcher = new(
                    "SELECT VirtualizationFirmwareEnabled, SecondLevelAddressTranslationExtensions FROM Win32_Processor");
                foreach (ManagementObject processor in searcher.Get())
                {
                    object? firmware = processor["VirtualizationFirmwareEnabled"];
                    object? slat = processor["SecondLevelAddressTranslationExtensions"];

                    if (firmware != null) enabled = Convert.ToBoolean(firmware);
                    if (slat != null && Convert.ToBoolean(slat)) enabled = true;
                    break;
                }
            }
            catch
            {
                enabled = null;
            }

            if (enabled != true)
            {
                // AEHD and MuMuNxSup only exist when hardware virtualization works.
                try
                {
                    using ManagementObjectSearcher searcher = new(
                        "SELECT Name FROM Win32_SystemDriver WHERE Name='MuMuNxSup'");
                    if (searcher.Get().Count > 0) enabled = true;
                }
                catch { }

                if (enabled != true)
                {
                    try
                    {
                        using ManagementObjectSearcher searcher = new(
                            "SELECT Name FROM Win32_Service WHERE Name='aehd'");
                        if (searcher.Get().Count > 0) enabled = true;
                    }
                    catch { }
                }
            }

            if (enabled == true)
            {
                return new CheckResult("Virtualization", "Enabled",
                    "VT-x / AMD-V is available", CheckStatus.Ok);
            }
            if (enabled == false)
            {
                return new CheckResult("Virtualization", "Disabled",
                    "Enable VT-x / AMD-V in the BIOS", CheckStatus.Error);
            }
            return new CheckResult("Virtualization", "Unknown",
                "Could not read the firmware setting", CheckStatus.Warn);
        }

        private static CheckResult CheckHyperV()
        {
            bool? present = null;
            try
            {
                using ManagementObjectSearcher searcher = new(
                    "SELECT HypervisorPresent FROM Win32_ComputerSystem");
                foreach (ManagementObject system in searcher.Get())
                {
                    object? value = system["HypervisorPresent"];
                    if (value != null) present = Convert.ToBoolean(value);
                    break;
                }
            }
            catch
            {
                present = null;
            }

            if (present == true)
            {
                return new CheckResult("Hyper-V", "Active",
                    "Disable Hyper-V before installing MuMu", CheckStatus.Error);
            }
            if (present == false)
            {
                return new CheckResult("Hyper-V", "Off",
                    "No hypervisor detected", CheckStatus.Ok);
            }
            return new CheckResult("Hyper-V", "Unknown",
                "Could not read HypervisorPresent", CheckStatus.Warn);
        }

        private static CheckResult CheckDisk(string root)
        {
            long free = 0;
            try
            {
                string full = Path.GetFullPath(root);
                string drive = Path.GetPathRoot(full)!;
                DriveInfo info = new(drive);
                free = info.AvailableFreeSpace;
            }
            catch
            {
                free = 0;
            }

            double gb = free / 1073741824.0;
            bool ok = gb >= 25.0;
            return new CheckResult("Free space",
                gb.ToString("N1", CultureInfo.InvariantCulture) + " GB",
                ok ? "At least 25 GB required" : "25 GB minimum",
                ok ? CheckStatus.Ok : CheckStatus.Error);
        }

        private static CheckResult CheckFolder(string root)
        {
            if (!Directory.Exists(root))
            {
                return new CheckResult("Game folder", "Not found", root,
                    CheckStatus.Warn);
            }

            bool writable = false;
            try
            {
                string probe = Path.Combine(root, ".cage-setup-write-test");
                File.WriteAllText(probe, "x");
                File.Delete(probe);
                writable = true;
            }
            catch
            {
                writable = false;
            }

            return new CheckResult("Game folder",
                writable ? "Writable" : "Not writable",
                root,
                writable ? CheckStatus.Ok : CheckStatus.Warn);
        }
    }
}
