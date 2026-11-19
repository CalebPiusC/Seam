package com.seam.agent.transport;

import com.seam.agent.telemetry.DisplayMetricsSnapshot;

import java.io.IOException;

/**
 * Transport-agnostic egress interface representing an active, authenticated {@code SEAM-Wire v1}
 * connection to the macOS Host (backed by either USB or Wi-Fi).
 */
public interface SeamTransportChannel extends AutoCloseable {

    /** Returns the transport identifier ({@code TRANSPORT_USB} or {@code TRANSPORT_WIFI}). */
    byte getTransportType();

    /** Returns the authenticated 64-bit session ID for this connection. */
    long getSessionId();

    /** Sends a 10-byte {@code DISPLAY_INFO (0x81)} telemetry frame to the macOS host. */
    void sendDisplayInfo(DisplayMetricsSnapshot metrics) throws IOException;

    /**
     * Sends a 6-byte {@code EDGE_RETURN (0x82)} frame when the native Android mouse cursor crosses
     * the return screen boundary back toward macOS.
     */
    void sendEdgeReturn(byte edgeId, int normX, int normY, int velocity) throws IOException;

    /** Sends an {@code OP_CLIPBOARD_EVENT (0x83)} frame carrying UTF-8 clipboard text to macOS. */
    void sendClipboardEvent(byte[] utf8Bytes) throws IOException;

    /** Sends an 8-byte {@code PONG (0x84)} frame echoing the host's microsecond timestamp. */
    void sendPong(long timestampUs) throws IOException;

    @Override
    void close();
}
