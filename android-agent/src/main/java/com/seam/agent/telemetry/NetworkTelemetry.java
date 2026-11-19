package com.seam.agent.telemetry;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Enumeration;
import java.util.List;

/**
 * Discovers active Wi-Fi LAN and Personal Hotspot IPv4 addresses on the Android device.
 *
 * <p>Handles standard Wi-Fi client interfaces ({@code wlan0}, {@code wlan1}) as well as Android
 * Wi-Fi Hotspot / SoftAP interfaces ({@code ap0}, {@code swlan0}, {@code p2p0}), while filtering
 * out loopback ({@code lo}), dummy ({@code dummy0}), and cellular data ({@code ccmni*}, {@code rmnet*})
 * interfaces.
 */
public final class NetworkTelemetry {

    public record InterfaceAddress(String interfaceName, String ipv4Address) {
        @Override
        public String toString() {
            return interfaceName + "=" + ipv4Address;
        }
    }

    private NetworkTelemetry() {}

    /**
     * Returns all active Wi-Fi / Hotspot IPv4 addresses ordered by preference ({@code wlan*} and {@code ap*} first).
     */
    public static List<InterfaceAddress> queryWifiAddresses() {
        List<InterfaceAddress> results = new ArrayList<>();
        try {
            Enumeration<NetworkInterface> interfaces = NetworkInterface.getNetworkInterfaces();
            if (interfaces == null) {
                return results;
            }
            for (NetworkInterface nif : Collections.list(interfaces)) {
                if (!nif.isUp() || nif.isLoopback()) {
                    continue;
                }
                String name = nif.getName().toLowerCase();
                if (name.startsWith("ccmni") || name.startsWith("rmnet") || name.startsWith("dummy")) {
                    continue;
                }
                for (InetAddress addr : Collections.list(nif.getInetAddresses())) {
                    if (addr instanceof Inet4Address ipv4 && !ipv4.isLoopbackAddress()) {
                        results.add(new InterfaceAddress(name, ipv4.getHostAddress()));
                    }
                }
            }
        } catch (Exception ignored) {
        }

        results.sort((a, b) -> Integer.compare(scoreInterface(a.interfaceName()), scoreInterface(b.interfaceName())));
        return results;
    }

    private static int scoreInterface(String name) {
        if (name.startsWith("wlan")) return 0;
        if (name.startsWith("ap"))   return 1;
        if (name.startsWith("swlan")) return 2;
        if (name.startsWith("p2p"))  return 3;
        return 4;
    }
}
