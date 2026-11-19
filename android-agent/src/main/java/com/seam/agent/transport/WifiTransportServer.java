package com.seam.agent.transport;

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
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Consumer;

/**
 * First-Class Wi-Fi Hybrid Transport Server ({@code TCP + UDP port 27186}).
 *
 * <p>Architecture:
 * <ul>
 *   <li><b>TCP Control & Reliable Channel ({@code TCP_NODELAY = 1}, {@code IPTOS_LOWDELAY}):</b>
 *       Executes the {@link SeamAuthenticator} mutual HMAC-SHA256 handshake, receives reliable
 *       frames ({@code KEY_REPORT}, {@code MOUSE_REPORT} button transitions, {@code CURSOR_ENTER},
 *       {@code CURSOR_LEAVE}, {@code PING}), and sends {@code DISPLAY_INFO}, {@code EDGE_RETURN},
 *       and {@code PONG} back to the macOS host.</li>
 *   <li><b>UDP Fast-Path Datagram Channel (42-byte Authenticated Frames):</b>
 *       Receives pure mouse movement deltas ({@code SendReliability.UNRELIABLE_SEQUENCED}) and
 *       UDP latency probes with zero TCP Head-of-Line blocking. Every 42-byte datagram is verified
 *       against a 128-bit HMAC-SHA256 tag and a strictly monotonic 64-bit sequence counter.</li>
 * </ul>
 */
public final class WifiTransportServer implements AutoCloseable {

    /** 1-byte header magic for authenticated 42-byte UDP fast-path packets ('U' = 0x55). */
    public static final byte UDP_MAGIC = 0x55;

    /** Discovery probe prefix sent over UDP broadcast/unicast to locate a running agent. */
    private static final String DISCOVER_PROBE = "SEAM_DISCOVER_V1";

    private final int port;
    private final SeamInputEngine inputEngine;
    private final SeamAuthenticator authenticator;
    private final Consumer<SeamTransportChannel> onChannelActivated;
    private final Consumer<SeamTransportChannel> onChannelClosed;
    private final AtomicBoolean running = new AtomicBoolean(false);

    // Active authenticated session state shared with the UDP fast-path loop
    private final AtomicLong activeSessionId = new AtomicLong(0L);
    private final AtomicLong maxUdpSequence  = new AtomicLong(0L);
    private volatile WifiChannel activeWifiChannel;

    private ServerSocket tcpServerSocket;
    private DatagramSocket udpSocket;
    private Thread udpThread;

    public WifiTransportServer(
            int port,
            SeamInputEngine inputEngine,
            SeamAuthenticator authenticator,
            Consumer<SeamTransportChannel> onChannelActivated,
            Consumer<SeamTransportChannel> onChannelClosed
    ) {
        this.port = port;
        this.inputEngine = inputEngine;
        this.authenticator = authenticator;
        this.onChannelActivated = onChannelActivated;
        this.onChannelClosed = onChannelClosed;
    }

    /**
     * Binds both TCP and UDP port {@code 27186} and accepts incoming Wi-Fi sessions.
     */
    public void runServerLoop() throws IOException {
        tcpServerSocket = new ServerSocket();
        tcpServerSocket.setReuseAddress(true);
        tcpServerSocket.bind(new InetSocketAddress("0.0.0.0", port));

        udpSocket = new DatagramSocket(null);
        udpSocket.setReuseAddress(true);
        udpSocket.setTrafficClass(0x2E); // DSCP EF (Voice/Interactive WMM priority)
        udpSocket.bind(new InetSocketAddress("0.0.0.0", port));

        running.set(true);

        udpThread = new Thread(this::runUdpFastPathLoop, "seam-wifi-udp");
        udpThread.setPriority(Thread.MAX_PRIORITY);
        udpThread.setDaemon(true);
        udpThread.start();

        System.out.println("[WiFi-Server] Listening on TCP & UDP 0.0.0.0:" + port);

        while (running.get()) {
            Socket clientSocket;
            try {
                clientSocket = tcpServerSocket.accept();
            } catch (IOException e) {
                if (!running.get()) {
                    break;
                }
                throw e;
            }

            WifiChannel channel = null;
            try {
                clientSocket.setTcpNoDelay(true);
                clientSocket.setTrafficClass(0x10); // IPTOS_LOWDELAY
                clientSocket.setSoTimeout((int) SeamProtocol.HEARTBEAT_TIMEOUT_MS);

                DataInputStream in = new DataInputStream(new BufferedInputStream(clientSocket.getInputStream(), 4096));
                DataOutputStream out = new DataOutputStream(new BufferedOutputStream(clientSocket.getOutputStream(), 4096));

                long sessionId = authenticator.authenticateServerSocket(in, out, SeamProtocol.TRANSPORT_WIFI);
                System.out.printf("[WiFi-Server] Mutual auth succeeded from %s (sessionId=0x%016X)%n",
                        clientSocket.getRemoteSocketAddress(), sessionId);

                activeSessionId.set(sessionId);
                maxUdpSequence.set(0L);

                channel = new WifiChannel(sessionId, out, clientSocket);
                activeWifiChannel = channel;
                onChannelActivated.accept(channel);

                handleAuthenticatedTcpLoop(in, channel);
            } catch (EOFException e) {
                System.out.println("[WiFi-Server] Host disconnected cleanly (EOF).");
            } catch (Exception e) {
                System.err.println("[WiFi-Server] Session ended: " + e.getMessage());
            } finally {
                if (channel != null) {
                    activeWifiChannel = null;
                    activeSessionId.compareAndSet(channel.getSessionId(), 0L);
                    onChannelClosed.accept(channel);
                }
                try {
                    clientSocket.close();
                } catch (IOException ignored) {
                }
            }
        }
    }

    private void handleAuthenticatedTcpLoop(DataInputStream in, WifiChannel channel)
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
            // Only promote channel on actual input/control frames (not standby PING heartbeats)
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
                default -> throw new IOException(String.format("Unknown SEAM-Wire TCP opcode: 0x%02X", opcode));
            }
        }
    }

    /**
     * Zero-allocation UDP fast-path loop processing 42-byte HMAC-SHA256 authenticated datagrams.
     *
     * <p>42-Byte UDP Datagram Layout (Little-Endian):
     * <pre>
     *   Byte 0     : Magic 0x55 ('U')
     *   Bytes 1..8 : uint64_le sessionId
     *   Bytes 9..16: uint64_le monotonicSeq
     *   Byte 17    : opcode (0x01 = MOUSE_REPORT, 0x06 = PING)
     *   Bytes 18..25: 8-byte payload (7B mouse report + 1B pad, OR 8B uint64_le timestampUs)
     *   Bytes 26..41: 16-byte truncated HMAC-SHA256 tag over bytes[0..25]
     * </pre>
     */
    private void runUdpFastPathLoop() {
        byte[] buf = new byte[128];
        ByteBuffer view = ByteBuffer.wrap(buf).order(ByteOrder.LITTLE_ENDIAN);
        DatagramPacket packet = new DatagramPacket(buf, buf.length);

        byte[] pongBuf = new byte[SeamAuthenticator.UDP_PACKET_SIZE];
        ByteBuffer pongView = ByteBuffer.wrap(pongBuf).order(ByteOrder.LITTLE_ENDIAN);

        while (running.get()) {
            try {
                packet.setLength(buf.length);
                udpSocket.receive(packet);
                int len = packet.getLength();

                // 1. Check for authenticated 42-byte fast-path datagram
                if (len == SeamAuthenticator.UDP_PACKET_SIZE && buf[0] == UDP_MAGIC) {
                    long currentSession = activeSessionId.get();
                    if (currentSession == 0L) {
                        continue;
                    }
                    long pktSession = view.getLong(1);
                    if (pktSession != currentSession) {
                        continue;
                    }
                    long seq = view.getLong(9);
                    long prevMax = maxUdpSequence.get();
                    if (seq <= prevMax) {
                        continue; // Reject replay or out-of-order stale delta
                    }
                    if (!authenticator.verifyUdpDatagram(buf, 0)) {
                        continue; // Reject forged tag
                    }
                    maxUdpSequence.set(seq);

                    byte opcode = buf[17];
                    if (opcode == SeamProtocol.OP_MOUSE_REPORT) {
                        WifiChannel ch = activeWifiChannel;
                        if (ch != null) {
                            onChannelActivated.accept(ch);
                        }
                        inputEngine.onRawMousePayload(buf, 18);
                    } else if (opcode == SeamProtocol.OP_PING) {
                        long tsUs = view.getLong(18);
                        pongView.clear();
                        pongBuf[0] = UDP_MAGIC;
                        pongView.putLong(1, currentSession);
                        pongView.putLong(9, seq);
                        pongBuf[17] = SeamProtocol.OP_PONG;
                        pongView.putLong(18, tsUs);
                        authenticator.signUdpDatagram(pongBuf, 0);

                        DatagramPacket pongPkt = new DatagramPacket(
                                pongBuf,
                                SeamAuthenticator.UDP_PACKET_SIZE,
                                packet.getSocketAddress()
                        );
                        udpSocket.send(pongPkt);
                    }
                } else if (len >= DISCOVER_PROBE.length()) {
                    // 2. Check for lightweight LAN/Hotspot discovery probe
                    String msg = new String(buf, 0, len, StandardCharsets.UTF_8).trim();
                    if (msg.startsWith(DISCOVER_PROBE)) {
                        byte[] reply = ("SEAM_OFFER_V1:" + port).getBytes(StandardCharsets.UTF_8);
                        DatagramPacket replyPkt = new DatagramPacket(reply, reply.length, packet.getSocketAddress());
                        udpSocket.send(replyPkt);
                    }
                }
            } catch (IOException e) {
                if (!running.get()) {
                    break;
                }
            }
        }
    }

    @Override
    public void close() {
        running.set(false);
        if (tcpServerSocket != null) {
            try {
                tcpServerSocket.close();
            } catch (IOException ignored) {
            }
        }
        if (udpSocket != null) {
            udpSocket.close();
        }
    }

    private static final class WifiChannel implements SeamTransportChannel {
        private final long sessionId;
        private final DataOutputStream out;
        private final Socket socket;
        private final ByteBuffer scratch = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN);

        WifiChannel(long sessionId, DataOutputStream out, Socket socket) {
            this.sessionId = sessionId;
            this.out = out;
            this.socket = socket;
        }

        @Override
        public byte getTransportType() {
            return SeamProtocol.TRANSPORT_WIFI;
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
