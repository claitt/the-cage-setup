# Window control (hides the MuMu installer windows)
# (moved out of Cage Setup.ps1; the build script inlines it again)

# =====================================================================
#  WINDOW CONTROL (makes the MuMu installation silent)
# =====================================================================
if (-not ('LunarTear.WinApi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace LunarTear
{
    public class WinApi
    {
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
        delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

        static HashSet<uint> Set(int[] pids)
        {
            var s = new HashSet<uint>();
            if (pids != null) foreach (var p in pids) s.Add((uint)p);
            return s;
        }

        public static int HideForPids(int[] pids, bool hide)
        {
            var set = Set(pids);
            int n = 0;
            EnumWindows((h, l) =>
            {
                uint pid; GetWindowThreadProcessId(h, out pid);
                if (set.Contains(pid)) { ShowWindow(h, hide ? 0 : 5); n++; }
                return true;
            }, IntPtr.Zero);
            return n;
        }

        public static int CountVisibleForPids(int[] pids)
        {
            var set = Set(pids);
            int n = 0;
            EnumWindows((h, l) =>
            {
                uint pid; GetWindowThreadProcessId(h, out pid);
                if (set.Contains(pid) && IsWindowVisible(h)) n++;
                return true;
            }, IntPtr.Zero);
            return n;
        }
    }
}
'@
}

function Get-ProcessIdsByName {
    param([string[]]$Names)
    @(Get-Process -Name $Names -ErrorAction SilentlyContinue | Select-Object -Expand Id)
}
function Hide-MuMuWindows {
    $p = Get-ProcessIdsByName $Script:HideProcessNames
    if ($p -and $p.Count -gt 0) { [void][LunarTear.WinApi]::HideForPids([int[]]$p, $true) }
}
# NOTE: Windows does not allow one process to re-show another process' window
# (verified: ShowWindow(SW_SHOW), ShowWindowAsync and SetWindowPos(SWP_SHOWWINDOW)
# all fail). So if the hidden installation gets stuck we kill it and retry with
# the window visible instead of trying to re-show it.
function Get-VisibleMuMuWindows {
    $p = Get-ProcessIdsByName $Script:HideProcessNames
    if ($p -and $p.Count -gt 0) { [LunarTear.WinApi]::CountVisibleForPids([int[]]$p) } else { 0 }
}
