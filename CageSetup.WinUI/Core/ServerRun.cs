using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.Sockets;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace CageSetup.WinUI.Core
{
    /// <summary>
    /// Server helpers ported from lib\03-utilities.ps1 and the server
    /// actions of lib\06-actions.ps1 (Test-ServerRunning, Get-PortOwner,
    /// Get-ServerPortConflicts, Get-ServerProcesses, Action-StartServer,
    /// Action-StopServer). The private server answers on gRPC 8003 and
    /// CDN 8080 (3000 is the auth endpoint).
    /// </summary>
    public static class ServerRun
    {
        public const int GrpcPort = 8003;
        public const int HttpPort = 8080;
        public const int AuthPort = 3000;

        public static readonly int[] Ports = { GrpcPort, HttpPort, AuthPort };

        // Same idea as the 1.x cache: a status refresh asks this several
        // times, and probing closed ports is slow on some machines.
        private static (DateTime Time, bool Value) _runCache;

        // ------------------------------------------------------------------
        // Probes
        // ------------------------------------------------------------------

        public static bool PortOpen(int port, int timeoutMs = 2000)
        {
            using TcpClient client = new();
            try
            {
                Task connect = client.ConnectAsync("127.0.0.1", port);
                return connect.Wait(timeoutMs) && client.Connected;
            }
            catch
            {
                return false;
            }
        }

        /// <summary>Test-ServerRunning: gRPC 8003 AND CDN 8080.</summary>
        public static async Task<bool> IsRunningAsync(bool force = false)
        {
            if (!force && _runCache.Value && (DateTime.UtcNow - _runCache.Time).TotalSeconds < 3)
            {
                return _runCache.Value;
            }
            bool result = await Task.Run(() => PortOpen(GrpcPort) && PortOpen(HttpPort));
            _runCache = (DateTime.UtcNow, result);
            return result;
        }

        // ------------------------------------------------------------------
        // Port owners
        // ------------------------------------------------------------------

        public sealed class PortOwner
        {
            public int Port;
            public int ProcessId;
            public string Name = "unknown";
            public string FullPath = string.Empty;

            public string Describe() =>
                "port " + Port + " is used by " + Name + " (PID " + ProcessId + ")";
        }

        /// <summary>
        /// netstat listener parse, like the 1.x Get-PortOwner fallback
        /// (Get-NetTCPConnection has no .NET equivalent): the state word is
        /// not matched, so localized output still works. Internal for tests.
        /// </summary>
        internal static int ParseListenerPid(string[] lines, int port)
        {
            Regex regex = new(@"^\s*TCP\s+\S+:" + port + @"\s+\S+:0\s+\S+\s+(\d+)\s*$");
            foreach (string line in lines)
            {
                Match match = regex.Match(line);
                if (match.Success) return int.Parse(match.Groups[1].Value);
            }
            return 0;
        }

        /// <summary>Get-PortOwner via netstat (works everywhere).</summary>
        public static PortOwner? GetPortOwner(int port)
        {
            string[] lines = Array.Empty<string>();
            try
            {
                var psi = new ProcessStartInfo("netstat")
                {
                    Arguments = "-ano -p tcp",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    CreateNoWindow = true,
                };
                using Process? process = Process.Start(psi);
                if (process != null)
                {
                    lines = process.StandardOutput.ReadToEnd().Split('\n');
                    process.WaitForExit(10000);
                }
            }
            catch
            {
                // No netstat? Rare; the conflicts check then simply misses.
            }

            int ownerId = ParseListenerPid(lines, port);
            if (ownerId <= 0) return null;

            PortOwner result = new() { Port = port, ProcessId = ownerId };
            try
            {
                Process owner = Process.GetProcessById(ownerId);
                result.Name = owner.ProcessName;
                result.FullPath = owner.MainModule?.FileName ?? string.Empty;
            }
            catch
            {
                // Cannot read the process details: keep the "unknown" name.
            }
            return result;
        }

        /// <summary>
        /// Ports held by something other than this installation's server.
        /// Starting the server in that case fails deep inside wizard.exe,
        /// so the installer checks this up front and names the process.
        /// </summary>
        public static List<PortOwner> ServerPortConflicts(string serverDir)
        {
            string prefix = serverDir.TrimEnd('\\') + "\\";
            List<PortOwner> conflicts = new();
            foreach (int port in Ports)
            {
                PortOwner? owner = GetPortOwner(port);
                if (owner == null) continue;
                if (!string.IsNullOrEmpty(owner.FullPath) &&
                    owner.FullPath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                {
                    continue;   // already bound by this server
                }
                conflicts.Add(owner);
            }
            return conflicts;
        }

        /// <summary>Get-ServerProcesses: any process under serverDir.</summary>
        public static List<Process> ServerProcesses(string serverDir)
        {
            List<Process> found = new();
            foreach (Process process in Process.GetProcesses())
            {
                try
                {
                    string? path = process.MainModule?.FileName;
                    if (path != null && path.StartsWith(
                            serverDir.TrimEnd('\\') + "\\",
                            StringComparison.OrdinalIgnoreCase))
                    {
                        found.Add(process);
                    }
                }
                catch
                {
                    // Access to protected processes is denied: skip them.
                }
            }
            return found;
        }

        // ------------------------------------------------------------------
        // Start / stop
        // ------------------------------------------------------------------

        /// <summary>
        /// Starts the server visibly: wizard.exe keeps its own console
        /// window, like Start-Process in the 1.x installer.
        /// </summary>
        public static void StartServer(string serverDir)
        {
            var psi = new ProcessStartInfo
            {
                FileName = Path.Combine(serverDir, "wizard.exe"),
                Arguments = "--prefer-saved",
                WorkingDirectory = serverDir,
                UseShellExecute = true,
                CreateNoWindow = false,
            };
            Process.Start(psi);
        }

        /// <summary>
        /// Action-StartServer: checks the files, names port
        /// conflicts, starts wizard.exe --prefer-saved and waits up to 30
        /// seconds for the ports. Shared by step 5 (start/restart) and
        /// step 6 (the launch starts the server first, like Start-Game).
        /// </summary>
        public static async Task<bool> EnsureRunningAsync(
            string serverDir, Downloader.ReportDelegate report, CancellationToken ct)
        {
            if (!GameFiles.ServerFilesPresent())
            {
                throw new Exception("Server binaries are missing: step 3 fetches them first");
            }

            report(-1, "Server: checking the status");
            if (await IsRunningAsync(force: true))
            {
                report(-1, "Server already running (ports 8003/8080)");
                return true;
            }

            List<PortOwner> conflicts = await Task.Run(
                () => ServerPortConflicts(serverDir), ct);
            if (conflicts.Count > 0)
            {
                foreach (PortOwner conflict in conflicts)
                {
                    report(-1, "Cannot start the server: " + conflict.Describe() + ".");
                }
                throw new Exception("Close that program and press Start again.");
            }

            report(-1, "Starting wizard.exe (the server keeps its own console window)...");
            await Task.Run(() => StartServer(serverDir), ct);

            for (int i = 0; i < 30; i++)
            {
                await Task.Delay(1000, ct);
                report(-1, "Waiting for the server... (" + (i + 1) + "s)");
                if (await IsRunningAsync(force: true))
                {
                    report(100, "Server started (8003/8080/3000)");
                    return true;
                }
            }
            throw new Exception("Server not detected on ports 8003/8080 after 30 seconds");
        }

        /// <summary>Action-StopServer; waits up to 15 seconds.</summary>
        public static async Task<bool> StopAsync(
            string serverDir, Downloader.ReportDelegate report, CancellationToken ct)
        {
            List<Process> processes = ServerProcesses(serverDir);
            if (processes.Count == 0)
            {
                report(-1, "Server is not running");
                return true;
            }
            foreach (Process process in processes)
            {
                try { process.Kill(); } catch { /* already gone */ }
            }

            for (int i = 0; i < 15; i++)
            {
                await Task.Delay(1000, ct);
                if (!await IsRunningAsync(force: true)) break;
            }

            bool stillRunning = await IsRunningAsync(force: true);
            if (stillRunning)
            {
                report(-1, "The server is still listening on its ports");
            }
            else
            {
                report(-1, "Server stopped (" + processes.Count + " process(es))");
            }
            return !stillRunning;
        }
    }
}
