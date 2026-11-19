package com.seam.agent.telemetry;

/**
 * Immutable snapshot of the Android device's active primary display configuration.
 */
public record DisplayMetricsSnapshot(
        int widthPx,
        int heightPx,
        int densityDpi,
        int rotation,
        int refreshRateHz
) {
    /**
     * Converts Android Surface rotation constant (0..3) into degrees (0, 90, 180, 270).
     */
    public int rotationDegrees() {
        return switch (rotation) {
            case 1 -> 90;
            case 2 -> 180;
            case 3 -> 270;
            default -> 0;
        };
    }

    @Override
    public String toString() {
        return String.format(
                "DisplayMetricsSnapshot[%dx%d px, %d dpi, rotation=%d (%d°), %d Hz]",
                widthPx, heightPx, densityDpi, rotation, rotationDegrees(), refreshRateHz
        );
    }
}
