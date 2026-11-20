using System;
using System.Threading;
using Seam.WindowsHost.Bootstrap;
using Seam.WindowsHost.Input;
using Seam.WindowsHost.Protocol;
using Seam.WindowsHost.Testing;
using Seam.WindowsHost.Transport;

namespace Seam.WindowsHost
{
    internal sealed class Options
    {
        public bool ShowHelp;
        public bool SelfTest;
        public bool Trajectory;
        public bool ForceCapture;
        public string? Connect;
        public string? JarPath;
        public string? AdbPath;
        public string? Serial;
        public byte Edge = SeamWireProtocol.EdgeRight;
    }

    internal static class Program
    {
        private static int Main(string[] args)
        {
            Options options = ParseArgs(args);

            if (options.ShowHelp)
            {
                PrintUsage();
                return 0;
            }
            if (options.SelfTest)
            {
                return SelfTest.Run();
            }

            try
            {
                Console.WriteLine("=== SEAM Windows host — prototype ===");

                SeamAuthenticator authenticator = SeamAuthenticator.LoadOrCreatePersistentKey();
                Console.WriteLine($"[Auth ] pairing key  {Mask(authenticator.KeyHex)}");

                (string host, int port, string label) = ResolveEndpoint(options, authenticator);
                Console.WriteLine($"[Link ] {label}");

                using SeamConnection connection = SeamConnection.Connect(host, port, authenticator);
                Console.WriteLine($"[Auth ] mutual HMAC-SHA256 OK — session 0x{connection.SessionId:X16}");

                AndroidDisplayInfo? display = null;
                var displayReady = new ManualResetEventSlim(false);
                connection.DisplayInfoReceived += d =>
                {
                    display = d;
                    Console.WriteLine($"[Displ] DISPLAY_INFO  {d}");
                    displayReady.Set();
                };
                connection.ClipboardReceived += text =>
                    Console.WriteLine($"[Clip ] <- Android: '{Truncate(text)}'");
                connection.EdgeReturnReceived += evt =>
                    Console.WriteLine($"[Edge ] <- Android: {evt}");
                connection.Closed += reason =>
                    Console.WriteLine($"[Link ] closed: {reason}");

                // Handlers are attached: only now is it safe to start reading (the agent sends
                // DISPLAY_INFO immediately after auth and a frame read by nobody is lost).
                connection.Start();

                if (!displayReady.Wait(3000))
                {
                    Console.WriteLine("[WARN] No DISPLAY_INFO within 3 s — continuing anyway.");
                }

                if (options.Trajectory)
                {
                    return RunTrajectory(connection, display);
                }

                return RunInteractive(connection, display, options);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[FATAL] {ex.Message}");
                return 1;
            }
        }

        // ---- Connection resolution -------------------------------------------------------

        private static (string host, int port, string label) ResolveEndpoint(
            Options options, SeamAuthenticator authenticator)
        {
            if (!string.IsNullOrEmpty(options.Connect))
            {
                string connect = options.Connect!;
                int colon = connect.LastIndexOf(':');
                if (colon <= 0 || !int.TryParse(connect.Substring(colon + 1), out int parsedPort))
                {
                    throw new ArgumentException($"--connect expects host:port, got '{connect}'");
                }
                return (connect.Substring(0, colon), parsedPort,
                        $"direct TCP -> {connect} (bypassing ADB)");
            }

            string jarPath = options.JarPath ?? ResolveAgentJar();
            Console.WriteLine($"[Boot ] agent jar: {jarPath}");

            var bootstrapper = new AdbBootstrapper(jarPath, options.AdbPath);
            Console.WriteLine($"[Boot ] adb: {bootstrapper.AdbPath}");

            var devices = bootstrapper.ListDevices();
            if (devices.Count == 0)
            {
                throw new InvalidOperationException(
                    "No Android device visible to `adb devices`. Checklist:\n" +
                    "  - USB debugging enabled and the 'Allow USB debugging' prompt accepted\n" +
                    "  - an ADB-capable USB driver installed (Windows needs one; macOS does not)\n" +
                    "  - or use Wireless Debugging (`adb pair` / `adb connect`), which needs no driver\n" +
                    "  - or bypass ADB entirely with --connect <phone-ip>:27186");
            }

            AdbDevice device = options.Serial != null
                ? devices.Find(d => d.Serial == options.Serial)
                  ?? throw new InvalidOperationException($"Device '{options.Serial}' not found.")
                : devices.Find(d => d.IsAuthorized)
                  ?? throw new InvalidOperationException(
                      $"Device(s) present but not authorized: {string.Join(", ", devices)}");

            Console.WriteLine($"[Dev ] {device}");

            var endpoints = bootstrapper.BootstrapSession(device, authenticator);
            if (endpoints.Count > 0)
            {
                Console.WriteLine($"[Boot ] agent Wi-Fi endpoints: {string.Join(", ", endpoints)}");
            }

            int forwardedPort = bootstrapper.SetupUsbForward(device.Serial);
            Console.WriteLine($"[Boot ] adb forward tcp:{forwardedPort} -> localabstract:seam_uhid");

            return ("127.0.0.1", forwardedPort,
                    $"USB via ADB forward -> 127.0.0.1:{forwardedPort} ({device.Model})");
        }

        private static string ResolveAgentJar()
        {
            string[] candidates =
            {
                System.IO.Path.Combine(AppContext.BaseDirectory, "seam-agent.jar"),
                System.IO.Path.Combine(AppContext.BaseDirectory, "Resources", "seam-agent.jar"),
                System.IO.Path.Combine(Environment.CurrentDirectory, "dist", "seam-agent.jar"),
                System.IO.Path.Combine(Environment.CurrentDirectory, "..", "dist", "seam-agent.jar")
            };
            foreach (string c in candidates)
            {
                if (System.IO.File.Exists(c)) return System.IO.Path.GetFullPath(c);
            }
            return candidates[0]; // report the expected location; BootstrapSession gives a clear error
        }

        // ---- Scripted mouse stream (phone-free / hook-free verification) -----------------

        private static int RunTrajectory(SeamConnection connection, AndroidDisplayInfo? display)
        {
            Console.WriteLine("[Test ] Streaming a scripted figure-eight to Android (no input hooks).");

            connection.Send(SeamFrames.CursorEnter(SeamWireProtocol.EdgeLeft, 360, 32768, 0));
            Thread.Sleep(60);

            int frames = 240;
            double radius = Math.Min(display?.WidthPx ?? 720, display?.HeightPx ?? 1600) * 0.25;
            int prevX = 0, prevY = 0;

            for (int i = 1; i <= frames; i++)
            {
                double theta = (2.0 * Math.PI * i) / frames;
                int curX = (int)Math.Round(radius * Math.Sin(theta));
                int curY = (int)Math.Round(radius * Math.Sin(2.0 * theta) * 0.5);
                short dx = (short)(curX - prevX);
                short dy = (short)(curY - prevY);
                prevX = curX;
                prevY = curY;

                connection.Send(SeamFrames.MouseReport(0, dx, dy, 0, 0));
                Thread.Sleep(4);
            }

            // Push hard to the left to provoke EDGE_RETURN from the agent.
            for (int i = 0; i < 120; i++)
            {
                connection.Send(SeamFrames.MouseReport(0, -4, 0, 0, 0));
                Thread.Sleep(4);
            }
            Thread.Sleep(200);

            Console.WriteLine($"[Test ] trajectory complete — frames sent={connection.FramesSent}, " +
                              $"frames received={connection.FramesReceived}");

            connection.Send(SeamFrames.CursorLeave(1));
            Thread.Sleep(100);
            Console.WriteLine("[Test ] CURSOR_LEAVE sent. If the phone's cursor moved, the " +
                              "protocol path is proven end-to-end.");
            return 0;
        }

        // ---- Interactive desktop mode ----------------------------------------------------

        private static int RunInteractive(SeamConnection connection, AndroidDisplayInfo? display, Options options)
        {
            WindowsInputCapture.EnableDpiAwareness();

            using var capture = new WindowsInputCapture(connection, options.Edge, options.ForceCapture,
                                                        msg => Console.WriteLine(msg));
            connection.EdgeReturnReceived += evt => capture.HandleEdgeReturn(evt);

            capture.Start();

            Console.WriteLine();
            Console.WriteLine("  Move the pointer to the " + EdgeName(options.Edge) + " edge to take control of the phone.");
            Console.WriteLine("  Ctrl+Alt+Q returns control to Windows. Press 'q' here to quit.");
            if (options.ForceCapture)
            {
                Console.WriteLine("  --capture: the FIRST mouse movement will route to Android immediately.");
            }
            Console.WriteLine();

            var quit = new ManualResetEventSlim(false);
            Console.CancelKeyPress += (_, e) =>
            {
                e.Cancel = true;
                quit.Set();
            };

            DateTime nextStatus = DateTime.UtcNow.AddSeconds(2);
            while (!quit.IsSet && connection.IsRunning)
            {
                // Console.KeyAvailable/ReadKey throw InvalidOperationException when stdin is
                // redirected (service wrapper, IDE runner, `... | tee`). Skip polling then; the
                // Ctrl+Alt+Q panic hotkey and Ctrl+C still work.
                if (!Console.IsInputRedirected && Console.KeyAvailable)
                {
                    ConsoleKeyInfo key = Console.ReadKey(true);
                    if (key.Key == ConsoleKey.Q) break;
                    if (key.Key == ConsoleKey.R) capture.ForceReturn();
                }

                // Polling keeps the loop responsive without a busy spin.
                Thread.Sleep(40);

                // Hook-thread messages are queued, not written from the callback (console I/O
                // inside a low-level hook can block past LowLevelHooksTimeout and be unhooked).
                capture.DrainLog();

                if (DateTime.UtcNow >= nextStatus)
                {
                    nextStatus = DateTime.UtcNow.AddSeconds(2);
                    Console.WriteLine(
                        $"  [status] routing={(capture.IsRoutingToAndroid ? "ANDROID" : "windows")} " +
                        $"fwd={capture.EventsForwarded} recv={connection.FramesReceived} " +
                        $"sent={connection.FramesSent} unmappedKeys={capture.UnsupportedKeys}");
                }
            }

            capture.ForceReturn();
            Console.WriteLine("[Exit ] control returned to Windows; hooks removed.");
            return 0;
        }

        private static string EdgeName(byte edge) => edge switch
        {
            SeamWireProtocol.EdgeLeft => "left",
            SeamWireProtocol.EdgeTop => "top",
            SeamWireProtocol.EdgeBottom => "bottom",
            _ => "right"
        };

        private static string Mask(string hex) =>
            hex.Length >= 8 ? $"{hex.Substring(0, 4)}…{hex.Substring(hex.Length - 4)}" : hex;

        private static string Truncate(string s) =>
            s.Length <= 48 ? s : s.Substring(0, 45) + "…";

        // ---- CLI -------------------------------------------------------------------------

        private static Options ParseArgs(string[] args)
        {
            var o = new Options();
            for (int i = 0; i < args.Length; i++)
            {
                switch (args[i])
                {
                    case "--self-test": o.SelfTest = true; break;
                    case "--trajectory": o.Trajectory = true; break;
                    case "--capture": o.ForceCapture = true; break;
                    case "-h":
                    case "--help": o.ShowHelp = true; break;
                    case "--connect": o.Connect = Next(args, ref i); break;
                    case "--jar": o.JarPath = Next(args, ref i); break;
                    case "--adb": o.AdbPath = Next(args, ref i); break;
                    case "--device": o.Serial = Next(args, ref i); break;
                    case "--edge":
                        o.Edge = (Next(args, ref i) ?? "right") switch
                        {
                            "left" => SeamWireProtocol.EdgeLeft,
                            "top" => SeamWireProtocol.EdgeTop,
                            "bottom" => SeamWireProtocol.EdgeBottom,
                            _ => SeamWireProtocol.EdgeRight
                        };
                        break;
                    default:
                        Console.Error.WriteLine($"Unknown argument: {args[i]}");
                        o.ShowHelp = true;
                        break;
                }
            }
            return o;
        }

        private static string? Next(string[] args, ref int i)
        {
            if (i + 1 >= args.Length) return null;
            return args[++i];
        }

        private static void PrintUsage()
        {
            Console.WriteLine(
@"
SEAM Windows host (prototype) — talks to the existing, unmodified Android agent.

USAGE
  seam-host.exe [options]

MODES
  (default)        Discover a device over ADB, bootstrap seam-agent, connect,
                   then capture Windows input at the configured screen edge.
  --self-test      Offline protocol/auth/frame conformance tests (no phone needed).
  --trajectory     Connect and stream a scripted mouse path (no input hooks).
                   Use this to prove the wire path on real hardware.

OPTIONS
  --connect H:P    Bypass ADB and connect directly to H:P (e.g. phone-ip:27186).
  --edge E         Screen edge the phone sits on: right (default), left, top, bottom.
  --capture        Route to Android on the first mouse movement (deterministic demo).
  --device SERIAL  Pick a specific adb serial.
  --jar PATH       Path to seam-agent.jar (defaults to next to the exe or dist/).
  --adb PATH       Path to adb.exe (defaults to PATH / Platform-Tools locations).
  -h, --help       This text.

WHERE THE AGENT JAR COMES FROM
  The Android agent is unchanged. Build it once on macOS with `make build-agent`
  (produces dist/seam-agent.jar) or extract it from the shipped SEAM.app bundle,
  then place it next to seam-host.exe.

PANIC
  Ctrl+Alt+Q returns control to Windows while routing.
");
        }
    }
}
