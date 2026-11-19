package com.seam.agent.uhid;

/**
 * USB HID Usage Page {@code 0x07} (Keyboard/Keypad) and Mouse Button constants.
 */
public final class HidKeycodes {

    // Mouse Button Bitmasks (Byte 0 of Mouse Report)
    public static final int MOUSE_BTN_NONE    = 0x00;
    public static final int MOUSE_BTN_LEFT    = 1 << 0; // 0x01 (Primary Click)
    public static final int MOUSE_BTN_RIGHT   = 1 << 1; // 0x02 (Secondary / Android Back)
    public static final int MOUSE_BTN_MIDDLE  = 1 << 2; // 0x04
    public static final int MOUSE_BTN_BACK    = 1 << 3; // 0x08
    public static final int MOUSE_BTN_FORWARD = 1 << 4; // 0x10

    // Keyboard Modifier Bitmasks (Byte 0 of Keyboard Report)
    public static final int MOD_NONE        = 0x00;
    public static final int MOD_LEFT_CTRL   = 1 << 0; // 0x01
    public static final int MOD_LEFT_SHIFT  = 1 << 1; // 0x02
    public static final int MOD_LEFT_ALT    = 1 << 2; // 0x04
    public static final int MOD_LEFT_META   = 1 << 3; // 0x08 (Command / GUI)
    public static final int MOD_RIGHT_CTRL  = 1 << 4; // 0x10
    public static final int MOD_RIGHT_SHIFT = 1 << 5; // 0x20
    public static final int MOD_RIGHT_ALT   = 1 << 6; // 0x40
    public static final int MOD_RIGHT_META  = 1 << 7; // 0x80

    // Common USB HID Usage IDs (Usage Page 0x07)
    public static final byte KEY_NONE       = 0x00;
    public static final byte KEY_A          = 0x04;
    public static final byte KEY_B          = 0x05;
    public static final byte KEY_C          = 0x06;
    public static final byte KEY_V          = 0x19;
    public static final byte KEY_X          = 0x1B;
    public static final byte KEY_Z          = 0x1D;
    public static final byte KEY_1          = 0x1E;
    public static final byte KEY_0          = 0x27;
    public static final byte KEY_ENTER      = 0x28;
    public static final byte KEY_ESCAPE     = 0x29;
    public static final byte KEY_BACKSPACE  = 0x2A;
    public static final byte KEY_TAB        = 0x2B;
    public static final byte KEY_SPACE      = 0x2C;

    /**
     * Encodes an ASCII character into a 16-bit integer where the high byte is the modifier bitmask
     * and the low byte is the USB HID Usage Page 0x07 key code. Returns 0 if unmapped.
     */
    public static int asciiToHid(char ch) {
        if (ch >= 'a' && ch <= 'z') {
            return (KEY_A + (ch - 'a')) & 0xFF;
        }
        if (ch >= 'A' && ch <= 'Z') {
            return (MOD_LEFT_SHIFT << 8) | ((KEY_A + (ch - 'A')) & 0xFF);
        }
        if (ch >= '1' && ch <= '9') {
            return (KEY_1 + (ch - '1')) & 0xFF;
        }
        if (ch == '0') {
            return KEY_0 & 0xFF;
        }
        return switch (ch) {
            case ' ' -> KEY_SPACE & 0xFF;
            case '\n' -> KEY_ENTER & 0xFF;
            case '!' -> (MOD_LEFT_SHIFT << 8) | (KEY_1 & 0xFF);
            case '-' -> 0x2D;
            case '.' -> 0x37;
            case ':' -> (MOD_LEFT_SHIFT << 8) | 0x33;
            case '/' -> 0x38;
            default -> 0;
        };
    }

    private HidKeycodes() {}
}
