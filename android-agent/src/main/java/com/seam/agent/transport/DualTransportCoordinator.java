package com.seam.agent.transport;

import com.seam.agent.core.SeamInputEngine;
import com.seam.agent.protocol.SeamAuthenticator;
import com.seam.agent.protocol.SeamProtocol;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Coordinates simultaneous First-Class USB ({@link UsbLocalSocketServer}) and First-Class Wi-Fi
 * ({@link WifiTransportServer}) connections feeding the shared {@link SeamInputEngine}.
 *
 * <p>Live Transport Handover Invariant:
 * <ul>
 *   <li>Both USB and Wi-Fi servers accept authenticated connections concurrently.</li>
 *   <li>Outbound {@code EDGE_RETURN} telemetry is routed to the currently active primary channel
 *       (and mirrored to any standby channel if needed).</li>
 *   <li>If the user unplugs the USB cable while a Wi-Fi session is active (or vice versa),
 *       {@link SeamInputEngine#onCursorLeaveOrPanicReset()} is <b>not</b> invoked, preserving the
 *       exact native Android cursor position and any held mouse/keyboard state across the switch.</li>
 *   <li>Only when <i>all</i> authenticated transport channels have closed does the coordinator trigger
 *       the all-inputs-up panic reset on {@link SeamInputEngine}.</li>
 * </ul>
 */
public final class DualTransportCoordinator implements AutoCloseable {

    private final SeamInputEngine inputEngine;
    private final UsbLocalSocketServer usbServer;
    private final WifiTransportServer wifiServer;

    private final Set<SeamTransportChannel> openChannels = ConcurrentHashMap.newKeySet();
    private final AtomicReference<SeamTransportChannel> primaryChannel = new AtomicReference<>();

    public DualTransportCoordinator(
            SeamInputEngine inputEngine,
            SeamAuthenticator authenticator,
            int wifiPort
    ) {
        this.inputEngine = inputEngine;
        this.usbServer = new UsbLocalSocketServer(
                inputEngine,
                authenticator,
                this::onChannelActivated,
                this::onChannelClosed
        );
        this.wifiServer = new WifiTransportServer(
                wifiPort,
                inputEngine,
                authenticator,
                this::onChannelActivated,
                this::onChannelClosed
        );

        this.inputEngine.setEdgeReturnListener(this::dispatchEdgeReturn);
        this.inputEngine.setClipboardChangeListener(this::dispatchClipboardEvent);
    }

    /**
     * Starts both the USB and Wi-Fi transport servers and blocks until closed.
     */
    public void run() throws IOException {
        Thread wifiThread = new Thread(() -> {
            try {
                wifiServer.runServerLoop();
            } catch (IOException e) {
                System.err.println("[Dual-Coordinator] Wi-Fi server stopped: " + e.getMessage());
            }
        }, "seam-wifi-accept");
        wifiThread.setDaemon(true);
        wifiThread.start();

        // Run USB server loop on main thread
        usbServer.runServerLoop();
    }

    private void onChannelActivated(SeamTransportChannel channel) {
        openChannels.add(channel);
        SeamTransportChannel prev = primaryChannel.getAndSet(channel);
        if (prev != channel) {
            String kind = channel.getTransportType() == SeamProtocol.TRANSPORT_USB ? "USB" : "Wi-Fi";
            System.out.printf("[Dual-Coordinator] Active primary transport -> %s (sessionId=0x%016X, activeLinks=%d)%n",
                    kind, channel.getSessionId(), openChannels.size());
        }
    }

    private void onChannelClosed(SeamTransportChannel channel) {
        openChannels.remove(channel);
        String kind = channel.getTransportType() == SeamProtocol.TRANSPORT_USB ? "USB" : "Wi-Fi";

        if (openChannels.isEmpty()) {
            primaryChannel.set(null);
            System.out.printf("[Dual-Coordinator] %s closed; no standby links remaining -> triggering safe input reset.%n", kind);
            inputEngine.onCursorLeaveOrPanicReset();
        } else {
            SeamTransportChannel fallback = openChannels.iterator().next();
            primaryChannel.compareAndSet(channel, fallback);
            String fallbackKind = fallback.getTransportType() == SeamProtocol.TRANSPORT_USB ? "USB" : "Wi-Fi";
            System.out.printf("[Dual-Coordinator] %s closed -> seamlessly failed over to %s without resetting /dev/uhid!%n",
                    kind, fallbackKind);
        }
    }

    @FunctionalInterface
    private interface ChannelSender {
        void send(SeamTransportChannel channel) throws IOException;
    }

    private void dispatchEdgeReturn(byte edgeId, int normX, int normY, int velocity) {
        sendOnPrimaryOrStandby(ch -> ch.sendEdgeReturn(edgeId, normX, normY, velocity));
    }

    private void dispatchClipboardEvent(String text) {
        if (text == null || text.isEmpty()) {
            return;
        }
        byte[] utf8 = text.getBytes(StandardCharsets.UTF_8);
        if (utf8.length > SeamProtocol.MAX_CLIPBOARD_BYTES) {
            int len = SeamProtocol.MAX_CLIPBOARD_BYTES;
            while (len > 0 && (utf8[len] & 0xC0) == 0x80) {
                len--;
            }
            utf8 = Arrays.copyOf(utf8, len);
        }
        final byte[] payload = utf8;
        sendOnPrimaryOrStandby(ch -> ch.sendClipboardEvent(payload));
    }

    private void sendOnPrimaryOrStandby(ChannelSender sender) {
        SeamTransportChannel active = primaryChannel.get();
        if (active != null) {
            try {
                sender.send(active);
                return;
            } catch (IOException ignored) {
            }
        }
        // Fallback: try any open standby channel
        for (SeamTransportChannel ch : openChannels) {
            try {
                sender.send(ch);
                return;
            } catch (IOException ignored) {
            }
        }
    }

    @Override
    public void close() {
        usbServer.close();
        wifiServer.close();
        for (SeamTransportChannel ch : openChannels) {
            ch.close();
        }
        openChannels.clear();
        primaryChannel.set(null);
    }
}
