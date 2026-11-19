package com.seam.agent.transport;

import android.net.Credentials;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.SystemClock;

import com.seam.agent.core.SeamInputEngine;
import com.seam.agent.protocol.SeamAuthenticator;
import com.seam.agent.protocol.SeamProtocol;
import com.seam.agent.telemetry.DisplayMetricsSnapshot;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Consumer;

/**
 * First-Class USB Transport Server ({@code localabstract:seam_uhid}).
 *
 * <p>Security & Determinism Guarantees:
 * <ul>
 *   <li><b>Kernel {@code SO_PEERCRED} Guard:</b> Inspects {@link LocalSocket#getPeerCredentials()}
 *       immediately on {@code accept()} and rejects any connection not originating from
 *       {@code uid=2000 (shell / adbd)} or {@code uid=0 (root)}.</li>
 *   <li><b>Mutual Cryptographic Handshake:</b> Enforces {@link SeamAuthenticator} HMAC-SHA256
 *       challenge-response before routing a single byte to {@link SeamInputEngine}.</li>
 *   <li><b>Coordinated Multi-Transport Handover:</b> Notifies {@link DualTransportCoordinator}
 *       on channel activation and closure so live {@code USB <-> Wi-Fi} switching never drops
 *       the {@code /dev/uhid} cursor state.</li>
 * </ul>
 */
public final class UsbLocalSocketServer implements AutoCloseable {

    private static final int SHELL_UID = 2000;
    private static final int ROOT_UID  = 0;

    private final SeamInputEngine inputEngine;
    private final SeamAuthenticator authenticator;
    private final Consumer<SeamTransportChannel> onChannelActivated;
    private final Consumer<SeamTransportChannel> onChannelClosed;
    private final AtomicBoolean running = new AtomicBoolean(false);
    private LocalServerSocket serverSocket;

    public UsbLocalSocketServer(
            SeamInputEngine inputEngine,
            SeamAuthenticator authenticator,
            Consumer<SeamTransportChannel> onChannelActivated,
            Consumer<SeamTransportChannel> onChannelClosed
    ) {
        this.inputEngine = inputEngine;
        this.authenticator = authenticator;
        this.onChannelActivated = onChannelActivated;
        this.onChannelClosed = onChannelClosed;
    }

    /**
     * Binds {@code localabstract:seam_uhid} and processes incoming USB sessions until closed.
     */
    public void runServerLoop() throws IOException {
        serverSocket = new LocalServerSocket(SeamProtocol.USB_ABSTRACT_SOCKET_NAME);
        running.set(true);
        System.out.println("[USB-Server] Listening on localabstract:" + SeamProtocol.USB_ABSTRACT_SOCKET_NAME);

        while (running.get()) {
            LocalSocket clientSocket;
            try {
                clientSocket = serverSocket.accept();
            } catch (IOException e) {
                if (!running.get()) {
                    break;
                }
                throw e;
            }

            UsbChannel channel = null;
            try {
                if (!verifyPeerCredentials(clientSocket)) {
                    clientSocket.close();
                    continue;
                }
                clientSocket.setSoTimeout((int) SeamProtocol.HEARTBEAT_TIMEOUT_MS);

                DataInputStream in = new DataInputStream(new BufferedInputStream(clientSocket.getInputStream(), 4096));
                DataOutputStream out = new DataOutputStream(new BufferedOutputStream(clientSocket.getOutputStream(), 4096));

                long sessionId = authenticator.authenticateServerSocket(in, out, SeamProtocol.TRANSPORT_USB);
                System.out.printf("[USB-Server] Mutual auth succeeded (sessionId=0x%016X)%n", sessionId);

                channel = new UsbChannel(sessionId, out, clientSocket);
                onChannelActivated.accept(channel);

                handleAuthenticatedLoop(in, channel);
            } catch (EOFException e) {
                System.out.println("[USB-Server] Host disconnected cleanly (EOF).");
            } catch (Exception e) {
                System.err.println("[USB-Server] Session ended: " + e.getMessage());
            } finally {
                if (channel != null) {
                    onChannelClosed.accept(channel);
                }
                try {
                    clientSocket.close();
                } catch (IOException ignored) {
                }
            }
        }
    }

    private boolean verifyPeerCredentials(LocalSocket socket) throws IOException {
        Credentials creds = socket.getPeerCredentials();
        int peerUid = creds.getUid();
        int peerPid = creds.getPid();
        if (peerUid != SHELL_UID && peerUid != ROOT_UID) {
            System.err.printf("[SECURITY] Rejected unauthorized local connection from uid=%d, pid=%d%n",
                    peerUid, peerPid);
            return false;
        }
        return true;
    }

    private void handleAuthenticatedLoop(DataInputStream in, UsbChannel channel)
            throws IOException, InterruptedException {
        DisplayMetricsSnapshot initialDisplay = inputEngine.refreshDisplayMetrics();
        channel.sendDisplayInfo(initialDisplay);

        byte[] mouseBuf = new byte[SeamProtocol.LEN_MOUSE_REPORT];
        byte[] keyBuf = new byte[SeamProtocol.LEN_KEY_REPORT];
        byte[] enterBuf = new byte[SeamProtocol.LEN_CURSOR_ENTER];
        byte[] pingBuf = new byte[SeamProtocol.LEN_PING_PONG];
        ByteBuffer enterView = ByteBuffer.wrap(enterBuf).order(ByteOrder.LITTLE_ENDIAN);
        ByteBuffer pingView = ByteBuffer.wrap(pingBuf).order(ByteOrder.LITTLE_ENDIAN);

        long lastDisplayCheckMs = SystemClock.uptimeMillis();
        int lastRotation = initialDisplay.rotation();

        while (running.get()) {
            byte opcode = in.readByte();
            if (opcode != SeamProtocol.OP_PING) {
                onChannelActivated.accept(channel);
            }

            switch (opcode) {
                case SeamProtocol.OP_MOUSE_REPORT -> {
                    in.readFully(mouseBuf, 0, SeamProtocol.LEN_MOUSE_REPORT);
                    inputEngine.onRawMousePayload(mouseBuf, 0);
                }
                case SeamProtocol.OP_KEY_REPORT -> {
                    in.readFully(keyBuf, 0, SeamProtocol.LEN_KEY_REPORT);
                    inputEngine.onRawKeyboardPayload(keyBuf, 0);
                }
                case SeamProtocol.OP_CURSOR_ENTER -> {
                    in.readFully(enterBuf, 0, SeamProtocol.LEN_CURSOR_ENTER);
                    byte edgeId = enterBuf[0];
                    int normX = enterView.getShort(1) & 0xFFFF;
                    int normY = enterView.getShort(3) & 0xFFFF;

                    DisplayMetricsSnapshot disp = inputEngine.getDisplayMetrics();
                    int targetX = SeamProtocol.denormalizeCoordinate(normX, disp.widthPx());
                    int targetY = SeamProtocol.denormalizeCoordinate(normY, disp.heightPx());
                    inputEngine.onCursorEnter(edgeId, targetX, targetY);
                }
                case SeamProtocol.OP_CURSOR_LEAVE -> {
                    in.readByte();
                    inputEngine.onCursorLeaveOrPanicReset();
                }
                case SeamProtocol.OP_CLIPBOARD_SET -> {
                    String text = SeamProtocol.readClipboardSetText(in);
                    inputEngine.onClipboardSet(text);
                }
                case SeamProtocol.OP_PING -> {
                    in.readFully(pingBuf, 0, SeamProtocol.LEN_PING_PONG);
                    long timestampUs = pingView.getLong(0);
                    channel.sendPong(timestampUs);

                    long now = SystemClock.uptimeMillis();
                    if (now - lastDisplayCheckMs >= 450L) {
                        lastDisplayCheckMs = now;
                        DisplayMetricsSnapshot current = inputEngine.refreshDisplayMetrics();
                        if (current.rotation() != lastRotation) {
                            lastRotation = current.rotation();
                            channel.sendDisplayInfo(current);
                        }
                    }
                }
                default -> throw new IOException(String.format("Unknown SEAM-Wire USB opcode: 0x%02X", opcode));
            }
        }
    }

    @Override
    public void close() {
        running.set(false);
        if (serverSocket != null) {
            try {
                serverSocket.close();
            } catch (IOException ignored) {
            }
        }
    }

    private static final class UsbChannel implements SeamTransportChannel {
        private final long sessionId;
        private final DataOutputStream out;
        private final LocalSocket socket;
        private final ByteBuffer scratch = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN);

        UsbChannel(long sessionId, DataOutputStream out, LocalSocket socket) {
            this.sessionId = sessionId;
            this.out = out;
            this.socket = socket;
        }

        @Override
        public byte getTransportType() {
            return SeamProtocol.TRANSPORT_USB;
        }

        @Override
        public long getSessionId() {
            return sessionId;
        }

        @Override
        public synchronized void sendDisplayInfo(DisplayMetricsSnapshot metrics) throws IOException {
            scratch.clear();
            scratch.put(SeamProtocol.OP_DISPLAY_INFO);
            scratch.putShort((short) metrics.widthPx());
            scratch.putShort((short) metrics.heightPx());
            scratch.putShort((short) metrics.densityDpi());
            scratch.put((byte) metrics.rotation());
            scratch.put((byte) metrics.refreshRateHz());
            scratch.putShort((short) 0);
            out.write(scratch.array(), 0, 1 + SeamProtocol.LEN_DISPLAY_INFO);
            out.flush();
        }

        @Override
        public synchronized void sendEdgeReturn(byte edgeId, int normX, int normY, int velocity) throws IOException {
            scratch.clear();
            scratch.put(SeamProtocol.OP_EDGE_RETURN);
            scratch.put(edgeId);
            scratch.putShort((short) (normX & 0xFFFF));
            scratch.putShort((short) (normY & 0xFFFF));
            scratch.put((byte) Math.max(0, Math.min(255, velocity)));
            out.write(scratch.array(), 0, 1 + SeamProtocol.LEN_EDGE_RETURN);
            out.flush();
        }

        @Override
        public synchronized void sendClipboardEvent(byte[] utf8Bytes) throws IOException {
            SeamProtocol.writeClipboardEvent(out, scratch, utf8Bytes);
        }

        @Override
        public synchronized void sendPong(long timestampUs) throws IOException {
            scratch.clear();
            scratch.put(SeamProtocol.OP_PONG);
            scratch.putLong(timestampUs);
            out.write(scratch.array(), 0, 1 + SeamProtocol.LEN_PING_PONG);
            out.flush();
        }

        @Override
        public void close() {
            try {
                socket.close();
            } catch (IOException ignored) {
            }
        }
    }
}
