using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using Seam.WindowsHost.Protocol;

namespace Seam.WindowsHost.Bootstrap
{
    /// <summary>An Android device as reported by `adb devices -l`.</summary>
    public sealed class AdbDevice
    {
        public string Serial { get; init; } = "";
        public string State { get; init; } = "";
        public string Model { get; init; } = "Android";
        public string TransportId { get; init; } = "0";

        public bool IsAuthorized => State == "device";
        public bool IsWirelessAdb => Serial.Contains(':') || Serial.Contains("._adb-tls-connect._tcp");

        public override string ToString() =>
            $"{Serial} [state={State}, model={Model}, transport_id={TransportId}]";
    }

    /// <summary>
    /// Windows port of Bootstrap/UsbBootstrapper.swift — the ADB half.
    ///
    /// The command *semantics* are identical to macOS because they are all `adb` CLI calls;
    /// only binary discovery and the detached-daemon launch script quoting differ. The agent
    /// jar, remote paths, log markers and stamp scheme are copied verbatim so an agent
    /// started by the Mac host is reused rather than duplicated.
    /// </summary>
    public sealed class AdbBootstrapper
    {
        public const string RemoteJarPath = "/data/local/tmp/seam-agent.jar";
        public const string RemoteLogPath = "/data/local/tmp/seam-agent.log";
        public const string RemoteStampPath = "/data/local/tmp/seam-agent.stamp";
        private const string ReadyMarker = "SEAM_AGENT_READY";
        private const string WifiEndpointPrefix = "SEAM_WIFI_ENDPOINT:";

        private readonly string _adbPath;
        private readonly string _localJarPath;

        public AdbBootstrapper(string localJarPath, string? adbPath = null)
        {
            _localJarPath = localJarPath;
            _adbPath = adbPath ?? ResolveAdbPath();
        }

        public string AdbPath => _adbPath;

        /// <summary>
        /// adb.exe discovery. The macOS port hard-codes /opt/homebrew/bin/adb then falls back to
        /// PATH; on Windows we accept an explicit override, then PATH, then the usual
        /// Platform-Tools install locations.
        /// </summary>
        public static string ResolveAdbPath()
        {
            string[] candidates =
            {
                Path.Combine(AppContext.BaseDirectory, "platform-tools", "adb.exe"),
                Path.Combine(AppContext.BaseDirectory, "adb.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                             "Android", "Sdk", "platform-tools", "adb.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
                             "Android", "android-sdk", "platform-tools", "adb.exe"),
                "adb.exe",
                "adb"
            };

            foreach (string candidate in candidates)
            {
                if (candidate.Contains(Path.DirectorySeparatorChar) || candidate.Contains('/'))
                {
                    if (File.Exists(candidate)) return candidate;
                }
                else
                {
                    return candidate; // let PATH resolution decide
                }
            }
            return "adb.exe";
        }

        /// <summary>`adb devices -l` — same parsing rules as UsbBootstrapper.listDevices().</summary>
        public List<AdbDevice> ListDevices()
        {
            string output = Run(new[] { "devices", "-l" });
            var devices = new List<AdbDevice>();

            foreach (string rawLine in output.Split('\n'))
            {
                string line = rawLine.Trim();
                if (line.Length == 0 || line.StartsWith("List of devices") || line.StartsWith("*"))
                {
                    continue;
                }

                string[] tokens = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                if (tokens.Length < 2) continue;

                string model = "Android";
                string transportId = "0";
                for (int i = 2; i < tokens.Length; i++)
                {
                    if (tokens[i].StartsWith("model:"))
                    {
                        model = tokens[i].Substring("model:".Length);
                    }
                    else if (tokens[i].StartsWith("transport_id:"))
                    {
                        transportId = tokens[i].Substring("transport_id:".Length);
                    }
                }

                devices.Add(new AdbDevice
                {
                    Serial = tokens[0],
                    State = tokens[1],
                    Model = model,
                    TransportId = transportId
                });
            }
            return devices;
        }

        /// <summary>`adb forward tcp:0 localabstract:seam_uhid` -> allocated local port.</summary>
        public int SetupUsbForward(string serial)
        {
            string output = Run(new[]
            {
                "-s", serial, "forward", "tcp:0", "localabstract:" + SeamWireProtocol.UsbAbstractSocketName
            }).Trim();

            if (!int.TryParse(output, out int port) || port <= 0)
            {
                throw new InvalidOperationException($"Failed to parse forwarded TCP port: '{output}'");
            }
            return port;
        }

        /// <summary>
        /// Pushes the agent (if needed) and launches it detached, returning any Wi-Fi endpoints
        /// it advertised. Mirrors bootstrapSession()/deployAndLaunchDetachedDaemon().
        /// </summary>
        public List<(string iface, string ip, int port)> BootstrapSession(AdbDevice device, SeamAuthenticator auth)
        {
            if (!File.Exists(_localJarPath))
            {
                throw new FileNotFoundException(
                    $"Local agent archive missing at {_localJarPath}. Build it with scripts/build-agent.sh on macOS, or ship the jar next to seam-host.");
            }

            string serial = device.Serial;

            // Keep the phone's on-screen keyboard working (CONTRIBUTING.md invariant).
            TryRun(new[] { "-s", serial, "shell", "settings put secure show_ime_with_hard_keyboard 1" });

            string expectedStamp = ComputeAgentStamp(_localJarPath, auth.KeyHex);
            string probe =
                "((pgrep -f seam_agent >/dev/null 2>&1 || ps -A 2>/dev/null | grep -q '[s]eam_agent') && cat " +
                RemoteStampPath + " 2>/dev/null) || true";
            string runningStamp = TryRun(new[] { "-s", serial, "shell", probe })?.Trim() ?? "";

            if (expectedStamp.Length > 0 && runningStamp == expectedStamp)
            {
                var (ready, endpoints) = WaitForDaemonReady(serial, 0.5);
                if (ready) return endpoints;
            }

            return DeployAndLaunch(serial, auth.KeyHex, expectedStamp);
        }

        private List<(string, string, int)> DeployAndLaunch(string serial, string authKeyHex, string stamp)
        {
            TryRun(new[] { "-s", serial, "shell", "pkill -f seam_agent || true" });
            Run(new[] { "-s", serial, "push", _localJarPath, RemoteJarPath });

            // Same launch line as the macOS host: nohup + setsid-equivalent detach, uid 2000.
            string launch =
                $"rm -f {RemoteLogPath}; " +
                $"printf '%s' '{stamp}' > {RemoteStampPath}; " +
                "nohup sh -c 'ANDROID_NO_USE_FWMARK_CLIENT=1 " +
                $"CLASSPATH={RemoteJarPath} app_process /system/bin --nice-name=seam_agent " +
                "com.seam.agent.Main --server --detach " +
                $"--auth-key={authKeyHex}' >{RemoteLogPath} 2>&1 </dev/null &";

            TryRun(new[] { "-s", serial, "shell", launch });

            var (ready, endpoints) = WaitForDaemonReady(serial, 4.0);
            if (!ready)
            {
                string tail = TryRun(new[] { "-s", serial, "shell", "tail -n 20 " + RemoteLogPath + " 2>/dev/null" }) ?? "";
                throw new InvalidOperationException(
                    "Timed out waiting for the detached seam-agent daemon.\n--- agent log ---\n" + tail);
            }
            return endpoints;
        }

        private (bool, List<(string, string, int)>) WaitForDaemonReady(string serial, double timeoutSeconds)
        {
            var endpoints = new List<(string, string, int)>();
            DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);

            while (DateTime.UtcNow < deadline)
            {
                string? log = TryRun(new[]
                {
                    "-s", serial, "shell", "cat " + RemoteLogPath + " 2>/dev/null || true"
                });

                if (log != null && log.Contains(ReadyMarker))
                {
                    foreach (string rawLine in log.Split('\n'))
                    {
                        string line = rawLine.Trim();
                        if (!line.StartsWith(WifiEndpointPrefix)) continue;

                        string[] parts = line.Split(':');
                        // SEAM_WIFI_ENDPOINT:<iface>:<ip>:<port>
                        if (parts.Length == 4 && int.TryParse(parts[3], out int port))
                        {
                            endpoints.Add((parts[1], parts[2], port));
                        }
                    }
                    return (true, endpoints);
                }
                Thread.Sleep(60);
            }
            return (false, endpoints);
        }

        /// <summary>Mirror of UsbBootstrapper.computeAgentStamp (jar + key digest prefix).</summary>
        private static string ComputeAgentStamp(string jarPath, string authKeyHex)
        {
            try
            {
                byte[] jar = File.ReadAllBytes(jarPath);
                byte[] jarHash = System.Security.Cryptography.SHA256.HashData(jar);
                byte[] keyHash = System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(authKeyHex));
                return $"{ToHexPrefix(jarHash, 8)}:{ToHexPrefix(keyHash, 8)}";
            }
            catch
            {
                return "";
            }
        }

        private static string ToHexPrefix(byte[] bytes, int count)
        {
            var sb = new StringBuilder(count * 2);
            for (int i = 0; i < count && i < bytes.Length; i++)
            {
                sb.Append(bytes[i].ToString("x2"));
            }
            return sb.ToString();
        }

        private string Run(string[] args)
        {
            var (exitCode, stdout, stderr) = Execute(args);
            if (exitCode != 0)
            {
                throw new InvalidOperationException(
                    $"'{_adbPath} {string.Join(" ", args)}' exited with {exitCode}: {stderr.Trim()}");
            }
            return stdout;
        }

        private string? TryRun(string[] args)
        {
            try
            {
                var (exitCode, stdout, _) = Execute(args);
                return exitCode == 0 ? stdout : null;
            }
            catch
            {
                return null;
            }
        }

        private (int exitCode, string stdout, string stderr) Execute(string[] args)
        {
            var psi = new ProcessStartInfo
            {
                FileName = _adbPath,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            // ArgumentList handles Windows quoting correctly, including the single quotes
            // inside the remote launch script above (they are consumed by the device's sh).
            foreach (string a in args) psi.ArgumentList.Add(a);

            using var process = Process.Start(psi)
                ?? throw new InvalidOperationException($"Failed to start '{_adbPath}'");

            // Drain both pipes concurrently: reading stdout to EOF first can deadlock when the
            // child fills the stderr buffer (classic redirected-stream deadlock).
            var stdoutTask = process.StandardOutput.ReadToEndAsync();
            var stderrTask = process.StandardError.ReadToEndAsync();
            process.WaitForExit();
            Task.WaitAll(stdoutTask, stderrTask);
            return (process.ExitCode, stdoutTask.Result, stderrTask.Result);
        }
    }
}
