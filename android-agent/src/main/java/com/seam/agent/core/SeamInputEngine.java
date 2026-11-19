package com.seam.agent.core;

import android.os.SystemClock;

import com.seam.agent.clipboard.AndroidClipboardController;
import com.seam.agent.pointer.PointerLinearizer;
import com.seam.agent.pointer.SmoothScrollInjector;
import com.seam.agent.protocol.SeamProtocol;
import com.seam.agent.telemetry.DisplayMetricsSnapshot;
import com.seam.agent.telemetry.DisplayTelemetry;
import com.seam.agent.uhid.HidDescriptors;
import com.seam.agent.uhid.HidKeycodes;
import com.seam.agent.uhid.UhidDevice;

import java.io.IOException;

/**
 * Transport-independent Android Input Engine ({@code SeamInputEngine}).
 *
 * <p>This engine owns the Linux kernel {@code /dev/uhid} virtual Mouse and Keyboard devices,
 * tracks shadow cursor coordinates across the active display viewport, detects return-edge
 * crossings back toward macOS, and executes safe atomic teardown regardless of whether upstream
 * commands arrive over USB, Wi-Fi, or local diagnostics.
 */
public final class SeamInputEngine implements AutoCloseable {

    /**
     * Listener invoked when the native Android mouse cursor hits the configured return edge of the
     * Android display and pushes outward toward the macOS host screen.
     */
    @FunctionalInterface
    public interface EdgeReturnListener {
        void onEdgeReturn(byte edgeId, int normX, int normY, int velocity);
    }

    private static final String MOUSE_DEVICE_NAME    = "SEAM Virtual Mouse";
    private static final String KEYBOARD_DEVICE_NAME = "SEAM Virtual Keyboard";

    /** Minimum outward push delta in pixels at the screen bezel required to trigger edge return. */
    private static final int EDGE_RETURN_PUSH_THRESHOLD_PX = 4;

    /** Grace window (ms) right after entering Android before allowing EDGE_RETURN. */
    private static final long ENTRY_GRACE_MS = 160L;

    /** Minimum quiet time (ms) required by AOSP VelocityControl to reset velocity history at origin. */
    private static final long ORIGIN_QUIET_THRESHOLD_MS = 115L;

    // AOSP CurveVelocityControl parameters observed on device pointer profile
    private static final double CURVE_SCALE = 1.0;
    private static final double CURVE_LOW_THRESHOLD_PX_PER_SEC = 500.0;
    private static final double CURVE_HIGH_THRESHOLD_PX_PER_SEC = 3000.0;
    private static final double CURVE_ACCELERATION = 3.0;

    private final PointerLinearizer pointerLinearizer;
    private final AndroidClipboardController clipboardController = new AndroidClipboardController();
    private final SmoothScrollInjector smoothScrollInjector = new SmoothScrollInjector();
    private UhidDevice mouseDevice;
    private UhidDevice keyboardDevice;
    private DisplayMetricsSnapshot displayMetrics;
    private volatile EdgeReturnListener edgeReturnListener;

    // Clamped shadow coordinate tracker in Android display pixels
    private int shadowX;
    private int shadowY;
    private int activeButtons;
    private int lastWrittenButtons;
    private byte activeReturnEdge = SeamProtocol.EDGE_LEFT;
    private int outwardEdgePushAccumulator;
    private boolean cursorActiveOnAndroid;
    private boolean preParkedAtOrigin;
    private long parkedAtOriginTimestampMs;
    private long cursorEnterTimestampMs;
    private long lastMouseReportTimestampMs;
    private boolean initialized;

    public SeamInputEngine() {
        this.pointerLinearizer = new PointerLinearizer();
        this.displayMetrics = DisplayTelemetry.queryPrimaryDisplay();
    }

    /**
     * Registers both the 16-bit relative {@code /dev/uhid} Mouse and 6KRO Keyboard with the Android kernel.
     */
    public synchronized void initialize() throws IOException {
        if (initialized) {
            return;
        }
        displayMetrics = DisplayTelemetry.queryPrimaryDisplay();
        pointerLinearizer.applyLinearPointerSettings();

        mouseDevice = UhidDevice.openAndRegister(
                MOUSE_DEVICE_NAME,
                HidDescriptors.SEAM_VENDOR_ID,
                HidDescriptors.SEAM_MOUSE_PRODUCT_ID,
                HidDescriptors.MOUSE_16BIT_REL_DESCRIPTOR,
                HidDescriptors.MOUSE_REPORT_SIZE
        );

        keyboardDevice = UhidDevice.openAndRegister(
                KEYBOARD_DEVICE_NAME,
                HidDescriptors.SEAM_VENDOR_ID,
                HidDescriptors.SEAM_KEYBOARD_PRODUCT_ID,
                HidDescriptors.KEYBOARD_6KRO_DESCRIPTOR,
                HidDescriptors.KEYBOARD_REPORT_SIZE
        );

        shadowX = 0;
        shadowY = 0;
        activeButtons = 0;
        lastWrittenButtons = 0;
        cursorActiveOnAndroid = false;
        preParkedAtOrigin = false;
        initialized = true;
        clipboardController.start();
    }

    public void setClipboardChangeListener(AndroidClipboardController.ClipboardChangeListener listener) {
        clipboardController.setClipboardChangeListener(listener);
    }

    public void onClipboardSet(String text) {
        clipboardController.setPrimaryClipText(text);
    }

    public void setEdgeReturnListener(EdgeReturnListener listener) {
        this.edgeReturnListener = listener;
    }

    public synchronized DisplayMetricsSnapshot getDisplayMetrics() {
        return displayMetrics;
    }

    /**
     * Injects a 7-byte mouse report (buttons, 16-bit dx, 16-bit dy, vertical wheel, horizontal pan).
     */
    public synchronized void onMouseReport(int buttons, int dx, int dy, int vWheel, int hWheel) throws IOException {
        ensureInitialized();
        activeButtons = buttons & 0x1F;
        if (dx != 0 || dy != 0) {
            preParkedAtOrigin = false;
            updateShadowAndCheckEdgeReturn(dx, dy);
        }

        boolean injectedScroll = false;
        if (vWheel != 0 || hWheel != 0) {
            injectedScroll = smoothScrollInjector.injectScroll(shadowX, shadowY, vWheel, hWheel);
        }

        int uhidVWheel = injectedScroll ? 0 : vWheel;
        int uhidHWheel = injectedScroll ? 0 : hWheel;
        if (dx != 0 || dy != 0 || activeButtons != lastWrittenButtons || uhidVWheel != 0 || uhidHWheel != 0) {
            mouseDevice.writeMouseReport(activeButtons, dx, dy, uhidVWheel, uhidHWheel);
            lastWrittenButtons = activeButtons;
        }
    }

    /**
     * Injects a raw 7-byte {@code MOUSE_REPORT} payload directly from the transport wire buffer.
     */
    public synchronized void onRawMousePayload(byte[] payload, int offset) throws IOException {
        int buttons = payload[offset] & 0x1F;
        short dx = (short) ((payload[offset + 1] & 0xFF) | ((payload[offset + 2] & 0xFF) << 8));
        short dy = (short) ((payload[offset + 3] & 0xFF) | ((payload[offset + 4] & 0xFF) << 8));
        int vWheel = payload[offset + 5];
        int hWheel = payload[offset + 6];
        onMouseReport(buttons, dx, dy, vWheel, hWheel);
    }

    private double computeCurveGain(int dx, int dy, long nowMs) {
        double dtSeconds = Math.max(0.002, Math.min(0.080, (nowMs - lastMouseReportTimestampMs) / 1000.0));
        lastMouseReportTimestampMs = nowMs;
        double speed = Math.hypot(dx, dy) / dtSeconds;

        if (speed <= CURVE_LOW_THRESHOLD_PX_PER_SEC) {
            return CURVE_SCALE;
        }
        if (speed >= CURVE_HIGH_THRESHOLD_PX_PER_SEC) {
            return CURVE_SCALE * CURVE_ACCELERATION;
        }
        double t = (speed - CURVE_LOW_THRESHOLD_PX_PER_SEC)
                / (CURVE_HIGH_THRESHOLD_PX_PER_SEC - CURVE_LOW_THRESHOLD_PX_PER_SEC);
        return CURVE_SCALE * (1.0 + t * (CURVE_ACCELERATION - 1.0));
    }

    private void updateShadowAndCheckEdgeReturn(int dx, int dy) {
        if (dx == 0 && dy == 0) {
            return;
        }
        long now = SystemClock.uptimeMillis();
        double gain = computeCurveGain(dx, dy, now);
        int scaledDx = (int) Math.round(dx * gain);
        int scaledDy = (int) Math.round(dy * gain);

        int maxW = Math.max(1, displayMetrics.widthPx() - 1);
        int maxH = Math.max(1, displayMetrics.heightPx() - 1);

        shadowX = Math.max(0, Math.min(maxW, shadowX + scaledDx));
        shadowY = Math.max(0, Math.min(maxH, shadowY + scaledDy));

        if (!cursorActiveOnAndroid
                || activeButtons != 0
                || (now - cursorEnterTimestampMs) < ENTRY_GRACE_MS) {
            outwardEdgePushAccumulator = 0;
            return;
        }

        boolean atBoundaryAndPushingOut = switch (activeReturnEdge) {
            case SeamProtocol.EDGE_LEFT -> shadowX == 0 && dx < 0;
            case SeamProtocol.EDGE_RIGHT -> shadowX == maxW && dx > 0;
            case SeamProtocol.EDGE_TOP -> shadowY == 0 && dy < 0;
            case SeamProtocol.EDGE_BOTTOM -> shadowY == maxH && dy > 0;
            default -> false;
        };

        if (atBoundaryAndPushingOut) {
            int outwardDelta = switch (activeReturnEdge) {
                case SeamProtocol.EDGE_LEFT -> -dx;
                case SeamProtocol.EDGE_RIGHT -> dx;
                case SeamProtocol.EDGE_TOP -> -dy;
                case SeamProtocol.EDGE_BOTTOM -> dy;
                default -> 0;
            };
            outwardEdgePushAccumulator += outwardDelta;

            if (outwardEdgePushAccumulator >= EDGE_RETURN_PUSH_THRESHOLD_PX) {
                int velocity = Math.min(255, outwardEdgePushAccumulator);
                int exitNormX = SeamProtocol.normalizeCoordinate(shadowX, displayMetrics.widthPx());
                int exitNormY = SeamProtocol.normalizeCoordinate(shadowY, displayMetrics.heightPx());
                byte returnEdge = activeReturnEdge;

                // Park cursor and mark inactive on Android before firing callback
                onCursorLeaveOrPanicReset();

                EdgeReturnListener listener = this.edgeReturnListener;
                if (listener != null) {
                    listener.onEdgeReturn(returnEdge, exitNormX, exitNormY, velocity);
                }
            }
        } else {
            outwardEdgePushAccumulator = 0;
        }
    }

    /**
     * Injects an 8-byte keyboard report (modifiers + up to 6 concurrent USB HID Usage Page 0x07 key codes).
     */
    public synchronized void onKeyReport(
            int modifiers,
            byte k0, byte k1, byte k2, byte k3, byte k4, byte k5
    ) throws IOException {
        ensureInitialized();
        keyboardDevice.writeKeyboardReport(modifiers, k0, k1, k2, k3, k4, k5);
        maybeSchedulePostCopyCheck(modifiers, k0, k1, k2, k3, k4, k5);
    }

    /**
     * Injects a raw 8-byte {@code KEY_REPORT} payload directly from the transport wire buffer.
     */
    public synchronized void onRawKeyboardPayload(byte[] payload, int offset) throws IOException {
        ensureInitialized();
        keyboardDevice.writeInputReport(payload, offset, HidDescriptors.KEYBOARD_REPORT_SIZE);
        int modifiers = payload[offset] & 0xFF;
        maybeSchedulePostCopyCheck(
                modifiers,
                payload[offset + 2], payload[offset + 3], payload[offset + 4],
                payload[offset + 5], payload[offset + 6], payload[offset + 7]
        );
    }

    private void maybeSchedulePostCopyCheck(
            int modifiers,
            byte k0, byte k1, byte k2, byte k3, byte k4, byte k5
    ) {
        if ((modifiers & (HidKeycodes.MOD_LEFT_CTRL | HidKeycodes.MOD_RIGHT_CTRL)) == 0) {
            return;
        }
        if (isCopyOrCutKey(k0) || isCopyOrCutKey(k1) || isCopyOrCutKey(k2)
                || isCopyOrCutKey(k3) || isCopyOrCutKey(k4) || isCopyOrCutKey(k5)) {
            clipboardController.schedulePostCopyCheck();
        }
    }

    private static boolean isCopyOrCutKey(byte hidUsage) {
        return hidUsage == HidKeycodes.KEY_C || hidUsage == HidKeycodes.KEY_X;
    }

    /**
     * Homes the native Android mouse cursor to an exact target pixel position {@code (targetX, targetY)}
     * on the default left return edge.
     */
    public synchronized void onCursorEnter(int targetX, int targetY) throws IOException, InterruptedException {
        onCursorEnter(SeamProtocol.EDGE_LEFT, targetX, targetY);
    }

    /**
     * Homes the native Android mouse cursor to an exact target pixel position {@code (targetX, targetY)}
     * and configures the active return boundary edge.
     *
     * <p>If the cursor was already pre-parked at {@code (0, 0)} for at least {@code 115 ms}, this method
     * jumps directly to {@code (targetX, targetY)} with {@code 1.0x} velocity. Otherwise it homes
     * instantaneously with {@code 0 ms} sleep, compensating for back-to-back {@code 3.0x} velocity gain.
     */
    public synchronized void onCursorEnter(byte entryEdgeId, int targetX, int targetY)
            throws IOException, InterruptedException {
        ensureInitialized();
        displayMetrics = DisplayTelemetry.queryPrimaryDisplay();
        int clampedX = Math.max(0, Math.min(displayMetrics.widthPx() - 1, targetX));
        int clampedY = Math.max(0, Math.min(displayMetrics.heightPx() - 1, targetY));

        long now = SystemClock.uptimeMillis();
        if (preParkedAtOrigin && (now - parkedAtOriginTimestampMs) >= ORIGIN_QUIET_THRESHOLD_MS) {
            if (clampedX > 0 || clampedY > 0) {
                mouseDevice.writeMouseReport(HidKeycodes.MOUSE_BTN_NONE, clampedX, clampedY, 0, 0);
            }
        } else {
            mouseDevice.writeMouseReport(HidKeycodes.MOUSE_BTN_NONE, -32767, -32767, 0, 0);
            int compX = Math.round(clampedX / 3.0f);
            int compY = Math.round(clampedY / 3.0f);
            if (compX > 0 || compY > 0) {
                mouseDevice.writeMouseReport(HidKeycodes.MOUSE_BTN_NONE, compX, compY, 0, 0);
            }
        }

        cursorEnterTimestampMs = now;
        lastMouseReportTimestampMs = now;
        preParkedAtOrigin = false;
        activeReturnEdge = entryEdgeId;
        outwardEdgePushAccumulator = 0;
        shadowX = clampedX;
        shadowY = clampedY;
        cursorActiveOnAndroid = true;
    }

    /**
     * Releases any held buttons/keys and pre-parks the Android cursor at origin {@code (0, 0)}
     * when the cursor transitions back to macOS or on transport timeout.
     */
    public synchronized void onCursorLeaveOrPanicReset() {
        if (!initialized) {
            return;
        }
        cursorActiveOnAndroid = false;
        outwardEdgePushAccumulator = 0;
        try {
            if (mouseDevice != null) {
                // Release all mouse buttons and pre-slam to origin (0, 0) for instant 0ms next entry
                mouseDevice.writeMouseReport(HidKeycodes.MOUSE_BTN_NONE, -32767, -32767, 0, 0);
                preParkedAtOrigin = true;
                parkedAtOriginTimestampMs = SystemClock.uptimeMillis();
            }
        } catch (Exception ignored) {
        }
        try {
            if (keyboardDevice != null) {
                keyboardDevice.writeKeyboardReport(
                        HidKeycodes.MOD_NONE,
                        HidKeycodes.KEY_NONE, HidKeycodes.KEY_NONE, HidKeycodes.KEY_NONE,
                        HidKeycodes.KEY_NONE, HidKeycodes.KEY_NONE, HidKeycodes.KEY_NONE
                );
            }
        } catch (Exception ignored) {
        }
        activeButtons = 0;
        lastWrittenButtons = 0;
        shadowX = 0;
        shadowY = 0;
    }

    /**
     * Types an ASCII string via the virtual {@code /dev/uhid} keyboard.
     */
    public synchronized void typeAsciiString(String text, long interKeyDelayMs)
            throws IOException, InterruptedException {
        ensureInitialized();
        for (int i = 0; i < text.length(); i++) {
            int encoded = HidKeycodes.asciiToHid(text.charAt(i));
            if (encoded == 0) {
                continue;
            }
            int mod = (encoded >> 8) & 0xFF;
            byte key = (byte) (encoded & 0xFF);

            onKeyReport(mod, key, (byte) 0, (byte) 0, (byte) 0, (byte) 0, (byte) 0);
            Thread.sleep(Math.max(8, interKeyDelayMs / 2));
            onKeyReport(0, (byte) 0, (byte) 0, (byte) 0, (byte) 0, (byte) 0, (byte) 0);
            Thread.sleep(Math.max(8, interKeyDelayMs / 2));
        }
    }

    public synchronized DisplayMetricsSnapshot refreshDisplayMetrics() {
        displayMetrics = DisplayTelemetry.queryPrimaryDisplay();
        return displayMetrics;
    }

    public int getShadowX() {
        return shadowX;
    }

    public int getShadowY() {
        return shadowY;
    }

    private void ensureInitialized() throws IOException {
        if (!initialized) {
            throw new IOException("SeamInputEngine is not initialized");
        }
    }

    @Override
    public synchronized void close() {
        if (!initialized) {
            return;
        }
        onCursorLeaveOrPanicReset();

        if (mouseDevice != null) {
            mouseDevice.close();
            mouseDevice = null;
        }
        if (keyboardDevice != null) {
            keyboardDevice.close();
            keyboardDevice = null;
        }
        clipboardController.close();
        pointerLinearizer.restoreOriginalSettings();
        lastWrittenButtons = 0;
        initialized = false;
    }
}
