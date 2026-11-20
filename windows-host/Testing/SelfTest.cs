using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using Seam.WindowsHost.Protocol;
using Seam.WindowsHost.Transport;

namespace Seam.WindowsHost.Testing
{
    /// <summary>
    /// Offline conformance tests. Runnable with `seam-host --self-test` on any OS that has
    /// the .NET 8 SDK — no phone, no adb, no Windows APIs required.
    ///
    /// 1. Golden vectors: the 68-byte client response and 41-byte ack verification are
    ///    checked against constants derived independently from the Java server source
    ///    (fixed key + fixed nonces), so a nonce-ordering or domain-string drift fails loudly.
    /// 2. Frame layout: DISPLAY_INFO / MOUSE_REPORT / KEY_REPORT bytes match the Android
    ///    agent's declared payload lengths and little-endian field order.
    /// 3. End-to-end loopback: a real TCP handshake + frame exchange against a fixture that
    ///    transliterates the agent's server code.
    /// </summary>
    public static class SelfTest
    {
        private static int _passed;
        private static int _failed;

        // ---- Golden vectors (computed from SeamAuthenticator.java semantics) --------------
        private const string KeyHex =
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
        private const string ServerNonceHex =
            "a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf";
        private const string ClientNonceHex =
            "303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f";
        private const string ExpectedClientHmacHex =
            "e9c7aec0a81566c23cdd13fe335c8cda5fc4ce80b69ee6bc9e1f55c3171ec9e7";
        private const string ExpectedServerHmacHex =
            "c44d92e6dc72f81024bad8eb57dcc2a85b290c9f07c05ef80d2410b4e1657caf";
        private const ulong ExpectedSessionId = 0x1122334455667788UL;

        public static int Run()
        {
            Console.WriteLine("=== SEAM Windows host — offline self-test ===");

            TestGoldenHandshakeVector();
            TestFrameLayouts();
            TestLoopbackHandshakeAndFrames();

            Console.WriteLine();
            Console.WriteLine($"=== {_passed} passed, {_failed} failed ===");
            return _failed == 0 ? 0 : 1;
        }

        private static void TestGoldenHandshakeVector()
        {
            byte[] key = Convert.FromHexString(KeyHex);
            byte[] serverNonce = Convert.FromHexString(ServerNonceHex);
            byte[] clientNonce = Convert.FromHexString(ClientNonceHex);
            byte[] sessionIdLe = BitConverter.GetBytes(ExpectedSessionId);
            if (!BitConverter.IsLittleEndian) Array.Reverse(sessionIdLe);

            byte[] challenge = new byte[38];
            Array.Copy(SeamWireProtocol.Magic, 0, challenge, 0, 4);
            challenge[4] = SeamWireProtocol.ProtocolVersion;
            challenge[5] = SeamWireProtocol.TransportUsb;
            Array.Copy(serverNonce, 0, challenge, 6, 32);

            byte[] ack = new byte[41];
            ack[0] = SeamWireProtocol.AuthStatusOk;
            Array.Copy(sessionIdLe, 0, ack, 1, 8);
            Array.Copy(Convert.FromHexString(ExpectedServerHmacHex), 0, ack, 9, 32);

            var reads = new Queue<byte[]>(new[] { challenge, ack });
            byte[]? written = null;

            var auth = new SeamAuthenticator(key);
            ulong sessionId = auth.AuthenticateClientStream(
                _ => reads.Dequeue(),
                bytes => written = bytes,
                clientNonce);

            Check("handshake: client response is 68 bytes", written != null && written.Length == 68);
            Check("handshake: response magic 'SEAM'",
                written != null && written.Take(4).SequenceEqual(SeamWireProtocol.Magic));
            Check("handshake: client nonce echoed after magic",
                written != null && written.Skip(4).Take(32).SequenceEqual(clientNonce));
            Check("handshake: client HMAC matches Java-derived vector",
                written != null && Convert.ToHexString(written.Skip(36).Take(32).ToArray())
                    .Equals(ExpectedClientHmacHex, StringComparison.OrdinalIgnoreCase));
            Check("handshake: server HMAC verified and session id decoded",
                sessionId == ExpectedSessionId);
        }

        private static void TestFrameLayouts()
        {
            byte[] mouse = SeamFrames.MouseReport(0x01, 5, -3, 0, 0);
            Check("frame: MOUSE_REPORT is 8 bytes (opcode+7)", mouse.Length == 8);
            Check("frame: MOUSE_REPORT bytes",
                Convert.ToHexString(mouse).Equals("01010500FDFF0000", StringComparison.OrdinalIgnoreCase));

            byte[] key = SeamFrames.KeyReport(0x02, 0x04, 0, 0, 0, 0, 0);
            Check("frame: KEY_REPORT is 9 bytes (opcode+8)", key.Length == 9);
            Check("frame: KEY_REPORT bytes",
                Convert.ToHexString(key).Equals("020200040000000000", StringComparison.OrdinalIgnoreCase));

            byte[] enter = SeamFrames.CursorEnter(SeamWireProtocol.EdgeLeft, 360, 32768, 0);
            Check("frame: CURSOR_ENTER is 7 bytes (opcode+6)", enter.Length == 7);
            Check("frame: CURSOR_ENTER little-endian normX/normY",
                Convert.ToHexString(enter).Equals("03006801008000", StringComparison.OrdinalIgnoreCase));

            byte[] clipboard = SeamFrames.ClipboardSet("hi");
            Check("frame: CLIPBOARD_SET is 5+len bytes", clipboard.Length == 7);
            Check("frame: CLIPBOARD_SET length prefix is LE",
                Convert.ToHexString(clipboard).Equals("05020000006869", StringComparison.OrdinalIgnoreCase));

            byte[] ping = SeamFrames.Ping(0x0102030405060708UL);
            Check("frame: PING is 9 bytes with LE uint64",
                ping.Length == 9 &&
                Convert.ToHexString(ping).Equals("060807060504030201", StringComparison.OrdinalIgnoreCase));

            // DISPLAY_INFO parse, mirroring UsbChannel.sendDisplayInfo layout.
            byte[] payload = Convert.FromHexString("38046009a40100780000");
            AndroidDisplayInfo info = AndroidDisplayInfo.Parse(payload);
            Check("parse: DISPLAY_INFO 1080x2400 @420dpi 120Hz",
                info.WidthPx == 1080 && info.HeightPx == 2400 &&
                info.DensityDpi == 420 && info.RefreshRateHz == 120 && info.Rotation == 0);

            byte[] edgeReturn = Convert.FromHexString("8200aabb008010");
            AndroidEdgeReturnEvent evt = AndroidEdgeReturnEvent.Parse(edgeReturn.Skip(1).ToArray());
            Check("parse: EDGE_RETURN edge/normY/velocity",
                evt.Edge == SeamWireProtocol.EdgeLeft && evt.NormY == 0x8000 && evt.Velocity == 0x10);
        }

        private static void TestLoopbackHandshakeAndFrames()
        {
            byte[] key = Convert.FromHexString(KeyHex);

            using var agent = new LoopbackAgent(key);
            agent.Start();

            SeamConnection? conn = null;
            try
            {
                var auth = new SeamAuthenticator(key);
                conn = SeamConnection.Connect("127.0.0.1", agent.Port, auth);
                Check("loopback: mutual HMAC handshake succeeded", conn.SessionId != 0);

                AndroidDisplayInfo? display = null;
                ulong pongSent = 0;
                bool pongSeen = false;
                var displaySeen = new ManualResetEventSlim(false);
                var clipboardSeen = new ManualResetEventSlim(false);

                conn.DisplayInfoReceived += d => { display = d; displaySeen.Set(); };
                conn.PongReceived += ts => { pongSent = ts; pongSeen = true; };
                conn.ClipboardReceived += _ => clipboardSeen.Set();

                // Reader must not start before the handlers exist, or DISPLAY_INFO is lost.
                conn.Start();

                Check("loopback: DISPLAY_INFO received within 2s", displaySeen.Wait(2000));
                Check("loopback: DISPLAY_INFO parsed as 1080x2400@420/120",
                    display != null && display.WidthPx == 1080 && display.HeightPx == 2400 &&
                    display.DensityDpi == 420 && display.RefreshRateHz == 120);

                conn.SendPing();
                Thread.Sleep(120);
                Check("loopback: PING answered with PONG", pongSeen && pongSent > 0);

                // 50 reliable mouse frames, as the real host would send.
                for (int i = 0; i < 50; i++)
                {
                    conn.Send(SeamFrames.MouseReport(0, 4, 2, 0, 0));
                }
                Thread.Sleep(200);
                Check("loopback: 50 MOUSE_REPORT frames reached the agent", agent.MouseFrames >= 50);

                // Keyboard: Ctrl+C (modifier + usage 0x06)
                conn.Send(SeamFrames.KeyReport(0x01, 0x06, 0, 0, 0, 0, 0));
                conn.Send(SeamFrames.KeyReport(0x00, 0, 0, 0, 0, 0, 0));
                Thread.Sleep(120);
                Check("loopback: KEY_REPORT frames reached the agent", agent.KeyFrames >= 2);

                conn.Send(SeamFrames.ClipboardSet("seam-from-windows"));
                Thread.Sleep(150);
                Check("loopback: CLIPBOARD_SET text decoded by agent",
                    agent.LastClipboardText == "seam-from-windows");

                Check("loopback: agent observed no auth failure", agent.AuthSucceeded && agent.AuthFailure == null);
            }
            catch (Exception ex)
            {
                Check($"loopback: exception {ex.GetType().Name}: {ex.Message}", false);
            }
            finally
            {
                conn?.Dispose();
            }
        }

        private static void Check(string name, bool condition)
        {
            if (condition)
            {
                _passed++;
                Console.WriteLine($"  [PASS] {name}");
            }
            else
            {
                _failed++;
                Console.WriteLine($"  [FAIL] {name}");
            }
        }
    }
}
