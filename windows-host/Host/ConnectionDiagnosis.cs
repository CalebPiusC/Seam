using System;
using System.Collections.Generic;
using Seam.WindowsHost.Bootstrap;

namespace Seam.WindowsHost.Host
{
    /// <summary>
    /// Conditions SEAM can actually detect on Windows. Nothing here is speculative: each value
    /// comes from what adb reports, from the agent bootstrap, or from our own transport error,
    /// and each one has exactly one piece of advice attached to it.
    /// </summary>
    public enum ConnectionProblem
    {
        None,
        AdbMissing,
        NoDevice,
        Unauthorized,
        Offline,
        WirelessUnavailable,
        AgentNotReady,
        AgentClosed,
        HandshakeFailed,
        TransportError
    }

    /// <summary>
    /// Turns a detected condition into the two lines the Home page shows: a headline and what to
    /// do next.
    ///
    /// Why this exists: the window used to print one fixed paragraph whenever
    /// <c>adb devices</c> was empty. That paragraph told every user to install an OEM USB driver
    /// and to "use Wireless debugging", even though this host connects over USB only - so a
    /// phone that simply was not plugged in read as a driver problem. The wording now depends on
    /// the detected condition, and USB and wireless requirements are no longer mixed together.
    ///
    /// Kept free of WinForms so the mapping can be unit-tested without a desktop or a phone.
    /// </summary>
    public static class ConnectionDiagnosis
    {
        /// <summary>
        /// Classifies what <c>adb devices</c> returned. <paramref name="adbAvailable"/> is false
        /// when the host could not even start adb (missing resource).
        /// </summary>
        public static ConnectionProblem ClassifyDevices(bool adbAvailable, IReadOnlyList<AdbDevice> devices)
        {
            if (!adbAvailable)
            {
                return ConnectionProblem.AdbMissing;
            }

            if (devices == null || devices.Count == 0)
            {
                return ConnectionProblem.NoDevice;
            }

            bool anyAuthorized = false;
            bool anyOffline = false;
            bool anyWirelessUnavailable = false;

            foreach (AdbDevice device in devices)
            {
                if (device.IsAuthorized)
                {
                    anyAuthorized = true;
                }
                else if (device.IsWirelessAdb)
                {
                    // adb still remembers a Wi-Fi address that is no longer answering.
                    anyWirelessUnavailable = true;
                }
                else if (string.Equals(device.State, "offline", StringComparison.OrdinalIgnoreCase))
                {
                    anyOffline = true;
                }
            }

            if (anyAuthorized)
            {
                // A USB phone, or a Wi-Fi transport that another tool already established: adb
                // forwards work over both, so this is ready rather than a problem.
                return ConnectionProblem.None;
            }

            if (anyWirelessUnavailable)
            {
                return ConnectionProblem.WirelessUnavailable;
            }

            if (anyOffline)
            {
                return ConnectionProblem.Offline;
            }

            // Everything else is "unauthorized" or a state adb reports before authorisation.
            return ConnectionProblem.Unauthorized;
        }

        /// <summary>
        /// Classifies a failed connection attempt from the message SEAM itself produced. The
        /// three agent-related strings are ours, not adb's, so they are stable.
        /// </summary>
        public static ConnectionProblem ClassifyFailure(string? message)
        {
            if (string.IsNullOrWhiteSpace(message))
            {
                return ConnectionProblem.TransportError;
            }

            if (message.Contains("Timed out waiting for the detached seam-agent daemon", StringComparison.OrdinalIgnoreCase) ||
                message.Contains("agent did not", StringComparison.OrdinalIgnoreCase))
            {
                return ConnectionProblem.AgentNotReady;
            }

            if (message.Contains("Remote peer closed the connection", StringComparison.OrdinalIgnoreCase) ||
                message.Contains("Peer closed the connection", StringComparison.OrdinalIgnoreCase) ||
                message.Contains("agent closed", StringComparison.OrdinalIgnoreCase))
            {
                return ConnectionProblem.AgentClosed;
            }

            if (message.Contains("handshake", StringComparison.OrdinalIgnoreCase) ||
                message.Contains("auth", StringComparison.OrdinalIgnoreCase) ||
                message.Contains("HMAC", StringComparison.OrdinalIgnoreCase))
            {
                return ConnectionProblem.HandshakeFailed;
            }

            if (message.Contains("no longer visible to adb", StringComparison.OrdinalIgnoreCase))
            {
                return ConnectionProblem.NoDevice;
            }

            if (message.Contains("not authorised", StringComparison.OrdinalIgnoreCase) ||
                message.Contains("not authorized", StringComparison.OrdinalIgnoreCase))
            {
                return ConnectionProblem.Unauthorized;
            }

            if (message.Contains("adb", StringComparison.OrdinalIgnoreCase) &&
                message.Contains("missing", StringComparison.OrdinalIgnoreCase))
            {
                return ConnectionProblem.AdbMissing;
            }

            return ConnectionProblem.TransportError;
        }

        /// <summary>One short line: what SEAM found. Never a raw exception.</summary>
        public static string Headline(ConnectionProblem problem) => problem switch
        {
            ConnectionProblem.AdbMissing => "SEAM cannot find adb",
            ConnectionProblem.NoDevice => "No phone detected",
            ConnectionProblem.Unauthorized => "The phone has not authorised this PC",
            ConnectionProblem.Offline => "The phone stopped responding",
            ConnectionProblem.WirelessUnavailable => "The phone is not answering over Wi-Fi",
            ConnectionProblem.AgentNotReady => "The SEAM agent did not start on the phone",
            ConnectionProblem.AgentClosed => "The phone closed the connection",
            ConnectionProblem.HandshakeFailed => "The pairing keys do not match",
            ConnectionProblem.TransportError => "The connection did not succeed",
            _ => string.Empty
        };

        /// <summary>
        /// What to do next, in user language. USB requirements are only mentioned for the USB
        /// situations, and a USB driver is only suggested where Windows itself is the suspect.
        /// </summary>
        public static string Guidance(ConnectionProblem problem) => problem switch
        {
            ConnectionProblem.AdbMissing =>
                "The bundled adb.exe is missing or cannot start. Reinstall SEAM, or run \"seam-host.exe --diagnose\" to see where it looked.",

            ConnectionProblem.NoDevice =>
                "Turn on Developer options and USB debugging on the phone, plug in the USB cable, " +
                "then tap ALLOW on the prompt that appears on the phone. " +
                "A driver is only the problem if Windows itself shows the phone with a warning in Device Manager.",

            ConnectionProblem.Unauthorized =>
                "Unlock the phone and tap ALLOW on the \"Allow USB debugging?\" prompt, then press Connect. " +
                "Tick \"Always allow from this computer\" so it stops asking.",

            ConnectionProblem.Offline =>
                "The USB connection went stale. Unplug the cable, plug it back in, then press Connect.",

            ConnectionProblem.WirelessUnavailable =>
                "adb remembers a Wi-Fi connection to this phone and the phone is not answering. " +
                "Reconnect it (\"adb connect <phone-ip>:<port>\") or plug the USB cable in, then press Refresh. " +
                "SEAM does not create the wireless pairing itself; INSTALL.md has the one-time adb pair step.",

            ConnectionProblem.AgentNotReady =>
                "The agent is what carries your mouse and keyboard. Unlock the phone, keep USB debugging on, " +
                "then unplug and re-plug the cable and press Connect. Its log is on the Diagnostics page.",

            ConnectionProblem.AgentClosed =>
                "The phone accepted the connection and closed it straight away, which usually means a stale " +
                "agent or a pairing key that changed. SEAM restarted the agent - press Connect again.",

            ConnectionProblem.HandshakeFailed =>
                "The phone and this PC disagree about the pairing key. Press Connect again so SEAM " +
                "reinstalls the agent with the current key; the fingerprint is on the Diagnostics page.",

            ConnectionProblem.TransportError =>
                "Check the cable and the phone's USB mode (file transfer), then press Connect. " +
                "The exact error is in Activity.",

            _ => string.Empty
        };

        /// <summary>One imperative clause for the inline banner, where space is one line.</summary>
        public static string ShortGuidance(ConnectionProblem problem) => problem switch
        {
            ConnectionProblem.AdbMissing => "reinstall SEAM or run --diagnose to see where it looked.",
            ConnectionProblem.NoDevice => "enable USB debugging, plug in the cable and tap ALLOW on the phone.",
            ConnectionProblem.Unauthorized => "unlock the phone and tap ALLOW, then press Connect.",
            ConnectionProblem.Offline => "unplug and re-plug the cable, then press Connect.",
            ConnectionProblem.WirelessUnavailable => "reconnect it with adb connect, or plug the USB cable in.",
            ConnectionProblem.AgentNotReady => "unplug and re-plug the cable, then press Connect.",
            ConnectionProblem.AgentClosed => "SEAM restarted the phone's agent - press Connect again.",
            ConnectionProblem.HandshakeFailed => "press Connect again so the agent is reinstalled.",
            ConnectionProblem.TransportError => "check the cable, then press Connect. Details are in Activity.",
            _ => string.Empty
        };

        /// <summary>Short technical tail for the mono line under the headline.</summary>
        public static string TechnicalHint(ConnectionProblem problem) => problem switch
        {
            ConnectionProblem.AdbMissing => "adb: not found",
            ConnectionProblem.NoDevice => "adb sees no device",
            ConnectionProblem.WirelessUnavailable => "adb TCP/IP transport is not answering",
            ConnectionProblem.AgentNotReady => "no SEAM_AGENT_READY marker",
            ConnectionProblem.AgentClosed => "socket closed before the first frame",
            ConnectionProblem.HandshakeFailed => "HMAC-SHA256 handshake rejected",
            _ => string.Empty
        };
    }
}
