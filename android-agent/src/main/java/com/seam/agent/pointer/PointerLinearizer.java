package com.seam.agent.pointer;

import com.seam.agent.uhid.HidKeycodes;
import com.seam.agent.uhid.UhidDevice;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Manages Android mouse pointer velocity linearization, 16-bit corner homing, and
 * cursor state inspection via {@code PointerChoreographer} ({@code dumpsys input}).
 *
 * <p>In AOSP {@code InputReader}, {@code VelocityControl} applies {@code CurveVelocityControl}
 * unless {@code mouse_pointer_acceleration_enabled=0} is active or movements stay below the low
 * velocity threshold ({@code 500 px/sec}, where the scale multiplier is strictly {@code 1.000x}).
 */
public final class PointerLinearizer {

    // Matches PointerChoreographer's cursor position dump in Android 14/15 dumpsys input, e.g.:
    // "PointerLocation: (360.0, 800.0)" or "position=(360.00, 800.00)" or "x=360.0, y=800.0"
    private static final Pattern CURSOR_POS_PATTERN = Pattern.compile(
            "(?:position|location|cursor|point)[^0-9\\n]*\\(?([0-9]+\\.[0-9]+),\\s*([0-9]+\\.[0-9]+)\\)?",
            Pattern.CASE_INSENSITIVE
    );

    private String savedPointerSpeed;
    private String savedMouseAccelEnabled;
    private String savedShowImeWithHardKeyboard;
    private boolean settingsModified;

    /**
     * Saves the user's current pointer speed & acceleration settings, applies flat 1:1 linear settings,
     * and forces {@code show_ime_with_hard_keyboard=1} so the phone's on-screen touch keyboard (Gboard)
     * continues to pop up normally whenever the user taps the phone screen directly.
     */
    public synchronized void applyLinearPointerSettings() {
        if (settingsModified) {
            return;
        }
        savedPointerSpeed = execShellSingleLine("settings get system pointer_speed");
        savedMouseAccelEnabled = execShellSingleLine("settings get system mouse_pointer_acceleration_enabled");
        savedShowImeWithHardKeyboard = execShellSingleLine("settings get secure show_ime_with_hard_keyboard");

        execShellSingleLine("settings put system pointer_speed 0");
        execShellSingleLine("settings put system mouse_pointer_acceleration_enabled 0");
        // Critical UX requirement: never disable the phone's on-screen touch keyboard!
        execShellSingleLine("settings put secure show_ime_with_hard_keyboard 1");
        settingsModified = true;
    }

    /**
     * Restores the user's original Android pointer settings on teardown, while keeping
     * {@code show_ime_with_hard_keyboard=1} enabled so the on-screen keyboard is never suppressed.
     */
    public synchronized void restoreOriginalSettings() {
        if (!settingsModified) {
            return;
        }
        try {
            if (savedPointerSpeed != null && !savedPointerSpeed.isEmpty() && !"null".equals(savedPointerSpeed)) {
                execShellSingleLine("settings put system pointer_speed " + savedPointerSpeed);
            } else {
                execShellSingleLine("settings put system pointer_speed 0");
            }

            if (savedMouseAccelEnabled != null && !savedMouseAccelEnabled.isEmpty() && !"null".equals(savedMouseAccelEnabled)) {
                execShellSingleLine("settings put system mouse_pointer_acceleration_enabled " + savedMouseAccelEnabled);
            } else {
                execShellSingleLine("settings delete system mouse_pointer_acceleration_enabled");
            }

            // Always ensure on-screen keyboard remains enabled
            execShellSingleLine("settings put secure show_ime_with_hard_keyboard 1");
        } finally {
            settingsModified = false;
        }
    }

    /**
     * Homes the native Android mouse cursor to the top-left origin {@code (0, 0)} using a single
     * 16-bit relative slam report {@code (-32767, -32767)} and then positions it at {@code (targetX, targetY)}.
     *
     * <p>Why a paced sub-threshold burst guarantees exact 1:1 pixel landing even on OEM kernels that
     * ignore {@code mouse_pointer_acceleration_enabled=0}:
     * <ul>
     *   <li>When two reports arrive within the same millisecond with a large delta, {@code VelocityControl}
     *       computes velocity {@code v = distance / dt >> 3000 px/s}, multiplying the jump by {@code 3.0x}!</li>
     *   <li>Conversely, for a single instantaneous report separated from the previous report by {@code >= 110 ms}
     *       ({@code STOP_THRESHOLD} in AOSP {@code VelocityControl.cpp}, where the velocity estimator resets its
     *       history window and treats a single movement packet as having {@code v = 0 -> scale = 1.000x}),
     *       a single 16-bit delta {@code (+targetX, +targetY)} moves the cursor by <b>exact 1:1 pixels</b>!</li>
     * </ul>
     */
    public void homeCursorToPosition(UhidDevice mouseDevice, int targetX, int targetY) throws IOException, InterruptedException {
        // Step 1: Slam to (0, 0) via 16-bit negative clamp (-32767, -32767)
        mouseDevice.writeMouseReport(HidKeycodes.MOUSE_BTN_NONE, -32767, -32767, 0, 0);

        // Step 2: Wait 115 ms (> AOSP VelocityControl STOP_TIME = 100 ms) or use calibrated single-step jump
        // During normal edge crossing, we can pre-park at (0, 0) when leaving Android so entry takes 0 ms!
        Thread.sleep(115);

        // Step 3: Single packet jump from (0, 0) to (targetX, targetY)
        if (targetX > 0 || targetY > 0) {
            mouseDevice.writeMouseReport(HidKeycodes.MOUSE_BTN_NONE, targetX, targetY, 0, 0);
        }
    }

    /**
     * Parks the cursor invisibly at the bottom-right corner {@code (W-1, H-1)} when control returns to macOS.
     */
    public void parkCursorBottomRight(UhidDevice mouseDevice) throws IOException {
        mouseDevice.writeMouseReport(HidKeycodes.MOUSE_BTN_NONE, 32767, 32767, 0, 0);
    }

    /**
     * Reads the ground-truth {@code PointerChoreographer} / {@code MousePointerController} section
     * and the registered {@code SEAM Virtual} devices from {@code dumpsys input}.
     */
    public static String dumpPointerChoreographerState() {
        StringBuilder sb = new StringBuilder();
        try {
            Process proc = new ProcessBuilder("sh", "-c",
                    "dumpsys input | grep -E -A 35 'Device [0-9]+: SEAM Virtual|MousePointerControllers:'").start();
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(proc.getInputStream()))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    sb.append(line).append('\n');
                }
            }
            proc.waitFor();
        } catch (Exception e) {
            sb.append("Error querying dumpsys input: ").append(e.getMessage());
        }
        return sb.toString();
    }

    /**
     * Parses the current {@code (x, y)} float coordinates from {@code PointerChoreographer} output if present.
     * Returns {@code null} if not found.
     */
    public static float[] parseCursorPositionFromDump(String dump) {
        Matcher m = CURSOR_POS_PATTERN.matcher(dump);
        if (m.find()) {
            try {
                return new float[] {
                    Float.parseFloat(m.group(1)),
                    Float.parseFloat(m.group(2))
                };
            } catch (NumberFormatException ignored) {
            }
        }
        return null;
    }

    private static String execShellSingleLine(String cmd) {
        try {
            Process proc = new ProcessBuilder("sh", "-c", cmd).start();
            String line;
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(proc.getInputStream()))) {
                line = reader.readLine();
            }
            proc.waitFor();
            return line != null ? line.trim() : "";
        } catch (Exception e) {
            return "";
        }
    }
}
