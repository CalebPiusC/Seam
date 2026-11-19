package com.seam.agent.uhid;

import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;

import java.io.FileDescriptor;
import java.io.IOException;
import java.io.InterruptedIOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;

/**
 * Low-level, zero-allocation POSIX driver for Linux kernel {@code /dev/uhid}.
 *
 * <p>Executes as {@code uid=2000 (shell)} which holds supplementary group {@code gid=3011 (uhid)}
 * on unrooted Android 15 devices. Matches the binary ABI of {@code include/uapi/linux/uhid.h}.
 */
public final class UhidDevice implements AutoCloseable {

    private static final String UHID_PATH = "/dev/uhid";

    // Linux kernel include/uapi/linux/uhid.h event types
    private static final int UHID_DESTROY = 1;
    private static final int UHID_CREATE2 = 11;
    private static final int UHID_INPUT2  = 12;

    // Linux kernel include/uapi/linux/input.h bus types
    private static final short BUS_USB = 0x03;

    // Header size of uhid_event up to rd_data[0] in UHID_CREATE2:
    // 4 (type) + 128 (name) + 64 (phys) + 64 (uniq) + 2 (rd_size) + 2 (bus)
    // + 4 (vendor) + 4 (product) + 4 (version) + 4 (country) = 280 bytes
    private static final int UHID_CREATE2_HEADER_SIZE = 280;

    // Header size of uhid_event up to data[0] in UHID_INPUT2:
    // 4 (type) + 2 (size) = 6 bytes
    private static final int UHID_INPUT2_HEADER_SIZE = 6;

    private final String deviceName;
    private final int reportSize;
    private final ByteBuffer inputBuffer;
    private FileDescriptor fd;
    private boolean registered;

    private UhidDevice(String deviceName, FileDescriptor fd, int reportSize) {
        this.deviceName = deviceName;
        this.fd = fd;
        this.reportSize = reportSize;
        this.inputBuffer = ByteBuffer.allocateDirect(UHID_INPUT2_HEADER_SIZE + reportSize)
                .order(ByteOrder.LITTLE_ENDIAN);
        this.inputBuffer.putInt(0, UHID_INPUT2);
        this.inputBuffer.putShort(4, (short) reportSize);
    }

    /**
     * Opens {@code /dev/uhid} and registers a virtual hardware HID device via {@code UHID_CREATE2}.
     *
     * @param name             Human-readable device name shown in {@code dumpsys input} (max 127 bytes).
     * @param vendorId         USB Vendor ID (e.g., {@code 0x18D1}).
     * @param productId        USB Product ID (e.g., {@code 0x5EA1}).
     * @param reportDescriptor Raw USB HID Report Descriptor bytes.
     * @param reportSize       Fixed byte size of input reports sent via {@link #writeInputReport}.
     */
    public static UhidDevice openAndRegister(
            String name,
            int vendorId,
            int productId,
            byte[] reportDescriptor,
            int reportSize
    ) throws IOException {
        FileDescriptor fd;
        try {
            fd = Os.open(UHID_PATH, OsConstants.O_RDWR | OsConstants.O_CLOEXEC, 0);
        } catch (ErrnoException e) {
            throw new IOException("Failed to open " + UHID_PATH + " (errno=" + e.errno + "): " + e.getMessage(), e);
        }

        UhidDevice device = new UhidDevice(name, fd, reportSize);
        try {
            device.sendCreate2(name, vendorId, productId, reportDescriptor);
            device.registered = true;
            return device;
        } catch (IOException | RuntimeException e) {
            device.close();
            throw e;
        }
    }

    private void sendCreate2(String name, int vendorId, int productId, byte[] rdData) throws IOException {
        int packetSize = UHID_CREATE2_HEADER_SIZE + rdData.length;
        ByteBuffer buf = ByteBuffer.allocateDirect(packetSize).order(ByteOrder.LITTLE_ENDIAN);

        // Offset 0: __u32 type = UHID_CREATE2 (11)
        buf.putInt(0, UHID_CREATE2);

        // Offset 4..131: __u8 name[128]
        byte[] nameBytes = name.getBytes(StandardCharsets.UTF_8);
        int copyLen = Math.min(nameBytes.length, 127);
        buf.position(4);
        buf.put(nameBytes, 0, copyLen);

        // Offset 132..195: __u8 phys[64] ("seam/uhid")
        byte[] physBytes = "seam/uhid".getBytes(StandardCharsets.UTF_8);
        buf.position(132);
        buf.put(physBytes, 0, Math.min(physBytes.length, 63));

        // Offset 196..259: __u8 uniq[64] (left zeroed)
        // Offset 260: __u16 rd_size
        buf.putShort(260, (short) rdData.length);
        // Offset 262: __u16 bus = BUS_USB (0x03)
        buf.putShort(262, BUS_USB);
        // Offset 264: __u32 vendor
        buf.putInt(264, vendorId);
        // Offset 268: __u32 product
        buf.putInt(268, productId);
        // Offset 272: __u32 version
        buf.putInt(272, 0x0001);
        // Offset 276: __u32 country
        buf.putInt(276, 0);

        // Offset 280: __u8 rd_data[rd_size]
        buf.position(UHID_CREATE2_HEADER_SIZE);
        buf.put(rdData);

        buf.position(0);
        buf.limit(packetSize);
        writeFully(buf);
    }

    /**
     * Writes a raw 7-byte mouse report or 8-byte keyboard report to {@code /dev/uhid} with zero allocation.
     */
    public synchronized void writeInputReport(byte[] report, int offset, int length) throws IOException {
        if (!registered || fd == null || !fd.valid()) {
            throw new IOException("UHID device '" + deviceName + "' is not registered or already closed");
        }
        if (length != reportSize) {
            throw new IllegalArgumentException(
                    "Invalid report length for " + deviceName + ": expected " + reportSize + ", got " + length);
        }
        inputBuffer.position(UHID_INPUT2_HEADER_SIZE);
        inputBuffer.put(report, offset, length);
        inputBuffer.position(0);
        inputBuffer.limit(UHID_INPUT2_HEADER_SIZE + reportSize);
        writeFully(inputBuffer);
    }

    /**
     * Convenience zero-allocation method for writing a 7-byte mouse report directly from primitive fields.
     *
     * @param buttons Bitmask of held mouse buttons ({@link HidKeycodes#MOUSE_BTN_LEFT}, etc.)
     * @param dx      16-bit signed relative X delta ({@code -32767..+32767})
     * @param dy      16-bit signed relative Y delta ({@code -32767..+32767})
     * @param vWheel  8-bit signed vertical scroll wheel delta ({@code -127..+127})
     * @param hWheel  8-bit signed horizontal pan delta ({@code -127..+127})
     */
    public synchronized void writeMouseReport(int buttons, int dx, int dy, int vWheel, int hWheel) throws IOException {
        if (!registered || fd == null || !fd.valid()) {
            throw new IOException("UHID mouse device is not open");
        }
        short clampedDx = (short) Math.max(-32767, Math.min(32767, dx));
        short clampedDy = (short) Math.max(-32767, Math.min(32767, dy));
        byte clampedVWheel = (byte) Math.max(-127, Math.min(127, vWheel));
        byte clampedHWheel = (byte) Math.max(-127, Math.min(127, hWheel));

        inputBuffer.put(6, (byte) (buttons & 0x1F));
        inputBuffer.putShort(7, clampedDx);
        inputBuffer.putShort(9, clampedDy);
        inputBuffer.put(11, clampedVWheel);
        inputBuffer.put(12, clampedHWheel);

        inputBuffer.position(0);
        inputBuffer.limit(UHID_INPUT2_HEADER_SIZE + HidDescriptors.MOUSE_REPORT_SIZE);
        writeFully(inputBuffer);
    }

    /**
     * Convenience zero-allocation method for writing an 8-byte keyboard report.
     */
    public synchronized void writeKeyboardReport(
            int modifiers,
            byte k0, byte k1, byte k2, byte k3, byte k4, byte k5
    ) throws IOException {
        if (!registered || fd == null || !fd.valid()) {
            throw new IOException("UHID keyboard device is not open");
        }
        inputBuffer.put(6, (byte) (modifiers & 0xFF));
        inputBuffer.put(7, (byte) 0x00); // Reserved
        inputBuffer.put(8, k0);
        inputBuffer.put(9, k1);
        inputBuffer.put(10, k2);
        inputBuffer.put(11, k3);
        inputBuffer.put(12, k4);
        inputBuffer.put(13, k5);

        inputBuffer.position(0);
        inputBuffer.limit(UHID_INPUT2_HEADER_SIZE + HidDescriptors.KEYBOARD_REPORT_SIZE);
        writeFully(inputBuffer);
    }

    private void writeFully(ByteBuffer buf) throws IOException {
        try {
            while (buf.hasRemaining()) {
                int written = Os.write(fd, buf);
                if (written <= 0) {
                    throw new IOException("Os.write(/dev/uhid) returned " + written);
                }
            }
        } catch (ErrnoException e) {
            throw new IOException("Os.write(/dev/uhid) failed for '" + deviceName + "' (errno=" + e.errno + "): " + e.getMessage(), e);
        } catch (InterruptedIOException e) {
            Thread.currentThread().interrupt();
            throw e;
        }
    }

    @Override
    public synchronized void close() {
        if (fd == null || !fd.valid()) {
            return;
        }
        if (registered) {
            try {
                ByteBuffer destroyBuf = ByteBuffer.allocateDirect(4).order(ByteOrder.LITTLE_ENDIAN);
                destroyBuf.putInt(0, UHID_DESTROY);
                destroyBuf.position(0);
                destroyBuf.limit(4);
                Os.write(fd, destroyBuf);
            } catch (Exception ignored) {
                // Best-effort UHID_DESTROY before closing descriptor
            }
            registered = false;
        }
        try {
            Os.close(fd);
        } catch (ErrnoException ignored) {
        }
        fd = null;
    }

    public String getDeviceName() {
        return deviceName;
    }
}
