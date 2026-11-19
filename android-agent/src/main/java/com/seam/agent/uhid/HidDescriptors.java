package com.seam.agent.uhid;

/**
 * Standard USB HID Report Descriptors for SEAM's virtual kernel input devices.
 *
 * <p>These descriptors are parsed directly by the Linux kernel {@code hid-core} subsystem via
 * {@code /dev/uhid} and mapped by Android's {@code EventHub} and {@code InputReader}:
 * <ul>
 *   <li><b>Mouse ({@link #MOUSE_16BIT_REL_DESCRIPTOR}):</b> Classified as {@code InputDeviceClass::CURSOR},
 *       bound to {@code CursorInputMapper} and {@code PointerChoreographer} / {@code PointerController},
 *       which renders Android's genuine native hardware mouse cursor sprite. Uses 16-bit signed relative
 *       axes ({@code -32767..+32767}) so SEAM can perform single-report corner homing without 8-bit clipping.</li>
 *   <li><b>Keyboard ({@link #KEYBOARD_6KRO_DESCRIPTOR}):</b> Classified as {@code InputDeviceClass::KEYBOARD},
 *       bound to {@code KeyboardInputMapper} supporting 8 modifier bits and 6 concurrent key codes.</li>
 * </ul>
 */
public final class HidDescriptors {

    /** Google / AOSP Vendor ID used for virtual accessories. */
    public static final int SEAM_VENDOR_ID = 0x18D1;

    /** SEAM Virtual 16-Bit Relative Mouse Product ID. */
    public static final int SEAM_MOUSE_PRODUCT_ID = 0x5EA1;

    /** SEAM Virtual Keyboard Product ID. */
    public static final int SEAM_KEYBOARD_PRODUCT_ID = 0x5EA2;

    /** Fixed byte length of a SEAM Mouse Input Report (1B buttons + 2B dx + 2B dy + 1B vWheel + 1B hWheel). */
    public static final int MOUSE_REPORT_SIZE = 7;

    /** Fixed byte length of a SEAM Keyboard Input Report (1B modifiers + 1B reserved + 6B key codes). */
    public static final int KEYBOARD_REPORT_SIZE = 8;

    /**
     * 16-Bit Signed Relative Mouse + Vertical Wheel + Horizontal Pan (AC Pan) HID Report Descriptor.
     */
    public static final byte[] MOUSE_16BIT_REL_DESCRIPTOR = new byte[] {
        (byte) 0x05, (byte) 0x01,                   // Usage Page (Generic Desktop)
        (byte) 0x09, (byte) 0x02,                   // Usage (Mouse)
        (byte) 0xA1, (byte) 0x01,                   // Collection (Application)
        (byte) 0x09, (byte) 0x01,                   //   Usage (Pointer)
        (byte) 0xA1, (byte) 0x00,                   //   Collection (Physical)

        // 1. 5 Buttons (Left, Right, Middle, Back, Forward) -> 5 bits
        (byte) 0x05, (byte) 0x09,                   //     Usage Page (Buttons)
        (byte) 0x19, (byte) 0x01,                   //     Usage Minimum (Button 1)
        (byte) 0x29, (byte) 0x05,                   //     Usage Maximum (Button 5)
        (byte) 0x15, (byte) 0x00,                   //     Logical Minimum (0)
        (byte) 0x25, (byte) 0x01,                   //     Logical Maximum (1)
        (byte) 0x95, (byte) 0x05,                   //     Report Count (5)
        (byte) 0x75, (byte) 0x01,                   //     Report Size (1)
        (byte) 0x81, (byte) 0x02,                   //     Input (Data, Variable, Absolute)

        // 2. 3-bit padding -> completes Byte 0
        (byte) 0x95, (byte) 0x01,                   //     Report Count (1)
        (byte) 0x75, (byte) 0x03,                   //     Report Size (3)
        (byte) 0x81, (byte) 0x01,                   //     Input (Constant)

        // 3. 16-bit Signed Relative X and Y -> Bytes 1..4
        (byte) 0x05, (byte) 0x01,                   //     Usage Page (Generic Desktop)
        (byte) 0x09, (byte) 0x30,                   //     Usage (X)
        (byte) 0x09, (byte) 0x31,                   //     Usage (Y)
        (byte) 0x16, (byte) 0x01, (byte) 0x80,      //     Logical Minimum (-32767)
        (byte) 0x26, (byte) 0xFF, (byte) 0x7F,      //     Logical Maximum (+32767)
        (byte) 0x95, (byte) 0x02,                   //     Report Count (2)
        (byte) 0x75, (byte) 0x10,                   //     Report Size (16)
        (byte) 0x81, (byte) 0x06,                   //     Input (Data, Variable, Relative)

        // 4. 8-bit Signed Relative Vertical Wheel -> Byte 5
        (byte) 0x09, (byte) 0x38,                   //     Usage (Wheel)
        (byte) 0x15, (byte) 0x81,                   //     Logical Minimum (-127)
        (byte) 0x25, (byte) 0x7F,                   //     Logical Maximum (+127)
        (byte) 0x95, (byte) 0x01,                   //     Report Count (1)
        (byte) 0x75, (byte) 0x08,                   //     Report Size (8)
        (byte) 0x81, (byte) 0x06,                   //     Input (Data, Variable, Relative)

        // 5. 8-bit Signed Relative Horizontal Pan (AC Pan) -> Byte 6
        (byte) 0x05, (byte) 0x0C,                   //     Usage Page (Consumer Devices)
        (byte) 0x0A, (byte) 0x38, (byte) 0x02,      //     Usage (AC Pan = 0x0238)
        (byte) 0x15, (byte) 0x81,                   //     Logical Minimum (-127)
        (byte) 0x25, (byte) 0x7F,                   //     Logical Maximum (+127)
        (byte) 0x95, (byte) 0x01,                   //     Report Count (1)
        (byte) 0x75, (byte) 0x08,                   //     Report Size (8)
        (byte) 0x81, (byte) 0x06,                   //     Input (Data, Variable, Relative)

        (byte) 0xC0,                                //   End Collection (Physical)
        (byte) 0xC0                                 // End Collection (Application)
    };

    /**
     * Standard USB HID 6-Key Rollover (6KRO) Keyboard Report Descriptor.
     */
    public static final byte[] KEYBOARD_6KRO_DESCRIPTOR = new byte[] {
        (byte) 0x05, (byte) 0x01,                   // Usage Page (Generic Desktop)
        (byte) 0x09, (byte) 0x06,                   // Usage (Keyboard)
        (byte) 0xA1, (byte) 0x01,                   // Collection (Application)

        // 1. 8 Modifier Keys (224..231) -> Byte 0
        (byte) 0x05, (byte) 0x07,                   //   Usage Page (Key Codes)
        (byte) 0x19, (byte) 0xE0,                   //   Usage Minimum (224 - Left Control)
        (byte) 0x29, (byte) 0xE7,                   //   Usage Maximum (231 - Right GUI)
        (byte) 0x15, (byte) 0x00,                   //   Logical Minimum (0)
        (byte) 0x25, (byte) 0x01,                   //   Logical Maximum (1)
        (byte) 0x75, (byte) 0x01,                   //   Report Size (1)
        (byte) 0x95, (byte) 0x08,                   //   Report Count (8)
        (byte) 0x81, (byte) 0x02,                   //   Input (Data, Variable, Absolute)

        // 2. Reserved Byte -> Byte 1
        (byte) 0x75, (byte) 0x08,                   //   Report Size (8)
        (byte) 0x95, (byte) 0x01,                   //   Report Count (1)
        (byte) 0x81, (byte) 0x01,                   //   Input (Constant)

        // 3. 5 Status LEDs + 3-bit padding (Output report)
        (byte) 0x05, (byte) 0x08,                   //   Usage Page (LEDs)
        (byte) 0x19, (byte) 0x01,                   //   Usage Minimum (1)
        (byte) 0x29, (byte) 0x05,                   //   Usage Maximum (5)
        (byte) 0x75, (byte) 0x01,                   //   Report Size (1)
        (byte) 0x95, (byte) 0x05,                   //   Report Count (5)
        (byte) 0x91, (byte) 0x02,                   //   Output (Data, Variable, Absolute)
        (byte) 0x75, (byte) 0x03,                   //   Report Size (3)
        (byte) 0x95, (byte) 0x01,                   //   Report Count (1)
        (byte) 0x91, (byte) 0x01,                   //   Output (Constant)

        // 4. 6 Concurrent Key Codes -> Bytes 2..7
        (byte) 0x05, (byte) 0x07,                   //   Usage Page (Key Codes)
        (byte) 0x19, (byte) 0x00,                   //   Usage Minimum (0)
        (byte) 0x29, (byte) 0xE7,                   //   Usage Maximum (231)
        (byte) 0x15, (byte) 0x00,                   //   Logical Minimum (0)
        (byte) 0x26, (byte) 0xE7, (byte) 0x00,      //   Logical Maximum (231)
        (byte) 0x75, (byte) 0x08,                   //   Report Size (8)
        (byte) 0x95, (byte) 0x06,                   //   Report Count (6)
        (byte) 0x81, (byte) 0x00,                   //   Input (Data, Array)

        (byte) 0xC0                                 // End Collection
    };

    private HidDescriptors() {}
}
