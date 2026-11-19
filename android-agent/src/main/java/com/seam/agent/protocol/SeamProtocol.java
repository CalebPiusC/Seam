package com.seam.agent.protocol;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;

/**
 * {@code SEAM-Wire v1} protocol constants, opcodes, and coordinate normalization helpers.
 *
 * <p>Shared wire specification between the macOS Host ({@code seam-host}) and the Android Agent
 * ({@code seam-agent}) across both USB and Wi-Fi transports.
 */
public final class SeamProtocol {

    /** 4-byte ASCII protocol magic header: "SEAM" (0x53, 0x45, 0x41, 0x4D). */
    public static final byte[] MAGIC = new byte[] { 'S', 'E', 'A', 'M' };

    /** Wire protocol version 1. */
    public static final byte PROTOCOL_VERSION = 0x01;

    /** Abstract Unix domain socket name used by {@code adb forward} over USB. */
    public static final String USB_ABSTRACT_SOCKET_NAME = "seam_uhid";

    /** Default TCP and UDP port used by Wi-Fi transport. */
    public static final int WIFI_DEFAULT_PORT = 27186;

    // Transport identifiers
    public static final byte TRANSPORT_USB  = 0x01;
    public static final byte TRANSPORT_WIFI = 0x02;

    // Handshake status codes
    public static final byte AUTH_STATUS_OK     = 0x01;
    public static final byte AUTH_STATUS_FAILED = (byte) 0xFF;

    // Screen boundary edge identifiers
    public static final byte EDGE_LEFT   = 0x00;
    public static final byte EDGE_RIGHT  = 0x01;
    public static final byte EDGE_TOP    = 0x02;
    public static final byte EDGE_BOTTOM = 0x03;

    // Host -> Android Frame Opcodes
    public static final byte OP_MOUSE_REPORT  = 0x01; // 7B payload: buttons(1), dx(2), dy(2), vWheel(1), hWheel(1)
    public static final byte OP_KEY_REPORT    = 0x02; // 8B payload: modifiers(1), reserved(1), keys(6)
    public static final byte OP_CURSOR_ENTER  = 0x03; // 6B payload: edgeId(1), normX(2), normY(2), flags(1)
    public static final byte OP_CURSOR_LEAVE  = 0x04; // 1B payload: reason(1)
    public static final byte OP_CLIPBOARD_SET = 0x05; // 4B length + UTF-8 payload
    public static final byte OP_PING          = 0x06; // 8B payload: uint64_le timestampUs

    // Android -> Host Frame Opcodes
    public static final byte OP_DISPLAY_INFO    = (byte) 0x81; // 10B payload: width(2), height(2), dpi(2), rot(1), hz(1), flags(2)
    public static final byte OP_EDGE_RETURN     = (byte) 0x82; // 6B payload: edgeId(1), normX(2), normY(2), velocity(1)
    public static final byte OP_CLIPBOARD_EVENT = (byte) 0x83; // 4B length + UTF-8 payload
    public static final byte OP_PONG            = (byte) 0x84; // 8B payload: uint64_le timestampUs

    // Fixed payload lengths
    public static final int LEN_MOUSE_REPORT = 7;
    public static final int LEN_KEY_REPORT   = 8;
    public static final int LEN_CURSOR_ENTER = 6;
    public static final int LEN_CURSOR_LEAVE = 1;
    public static final int LEN_PING_PONG    = 8;
    public static final int LEN_DISPLAY_INFO = 10;
    public static final int LEN_EDGE_RETURN  = 6;
    public static final int MAX_CLIPBOARD_BYTES = 256 * 1024;

    // Heartbeat & watchdog intervals
    public static final long HEARTBEAT_TIMEOUT_MS = 3000L;

    /**
     * Converts a normalized 16-bit coordinate ({@code 0..65535}) to a screen pixel coordinate ({@code 0..dimensionPx-1}).
     */
    public static int denormalizeCoordinate(int normU16, int dimensionPx) {
        if (dimensionPx <= 1) {
            return 0;
        }
        int clampedNorm = Math.max(0, Math.min(65535, normU16 & 0xFFFF));
        return (int) Math.round((clampedNorm / 65535.0) * (dimensionPx - 1));
    }

    /**
     * Converts a screen pixel coordinate ({@code 0..dimensionPx-1}) to a normalized 16-bit integer ({@code 0..65535}).
     */
    public static int normalizeCoordinate(int pixel, int dimensionPx) {
        if (dimensionPx <= 1) {
            return 0;
        }
        int clampedPx = Math.max(0, Math.min(dimensionPx - 1, pixel));
        return (int) Math.round(((double) clampedPx / (dimensionPx - 1)) * 65535.0);
    }

    /**
     * Reads a length-prefixed UTF-8 clipboard payload ({@code uint32_le length + utf8}).
     */
    public static String readClipboardSetText(DataInputStream in) throws IOException {
        int len = Integer.reverseBytes(in.readInt());
        if (len < 0 || len > MAX_CLIPBOARD_BYTES) {
            throw new IOException("Invalid clipboard payload length: " + len);
        }
        if (len == 0) {
            return "";
        }
        byte[] buf = new byte[len];
        in.readFully(buf, 0, len);
        return new String(buf, StandardCharsets.UTF_8);
    }

    /**
     * Writes an {@link #OP_CLIPBOARD_EVENT} frame using {@code scratch} (little-endian, capacity >= 5).
     */
    public static void writeClipboardEvent(DataOutputStream out, ByteBuffer scratch, byte[] utf8Bytes)
            throws IOException {
        scratch.clear();
        scratch.put(OP_CLIPBOARD_EVENT);
        scratch.putInt(utf8Bytes.length);
        out.write(scratch.array(), 0, 5);
        if (utf8Bytes.length > 0) {
            out.write(utf8Bytes);
        }
        out.flush();
    }

    private SeamProtocol() {}
}
