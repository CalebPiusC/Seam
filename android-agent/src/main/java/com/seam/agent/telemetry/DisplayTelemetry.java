package com.seam.agent.telemetry;

import android.view.Display;

import java.lang.reflect.Field;
import java.lang.reflect.Method;

/**
 * Queries real-time display geometry, logical density, and orientation inside an {@code app_process}
 * daemon ({@code uid=2000}) via {@code android.hardware.display.DisplayManagerGlobal}.
 */
public final class DisplayTelemetry {

    private DisplayTelemetry() {}

    /**
     * Queries the active configuration of {@link Display#DEFAULT_DISPLAY} (Display 0).
     */
    public static DisplayMetricsSnapshot queryPrimaryDisplay() {
        try {
            Class<?> dmgClass = Class.forName("android.hardware.display.DisplayManagerGlobal");
            Method getInstanceMethod = dmgClass.getDeclaredMethod("getInstance");
            Object dmg = getInstanceMethod.invoke(null);

            Method getDisplayInfoMethod = dmgClass.getDeclaredMethod("getDisplayInfo", int.class);
            Object displayInfo = getDisplayInfoMethod.invoke(dmg, Display.DEFAULT_DISPLAY);

            if (displayInfo != null) {
                Class<?> diClass = displayInfo.getClass();
                int logicalWidth = getIntField(diClass, displayInfo, "logicalWidth", 720);
                int logicalHeight = getIntField(diClass, displayInfo, "logicalHeight", 1600);
                int logicalDensityDpi = getIntField(diClass, displayInfo, "logicalDensityDpi", 320);
                int rotation = getIntField(diClass, displayInfo, "rotation", 0);

                int refreshHz = 60;
                try {
                    Method getRefreshRate = diClass.getDeclaredMethod("getRefreshRate");
                    Object rateObj = getRefreshRate.invoke(displayInfo);
                    if (rateObj instanceof Float f) {
                        refreshHz = Math.round(f);
                    }
                } catch (Exception ignored) {
                }

                return new DisplayMetricsSnapshot(
                        logicalWidth,
                        logicalHeight,
                        logicalDensityDpi,
                        rotation,
                        refreshHz
                );
            }
        } catch (Exception e) {
            System.err.println("[WARN] DisplayManagerGlobal reflection fallback: " + e.getMessage());
        }

        // Default fallback dimensions if DisplayManagerGlobal reflection is unavailable
        return new DisplayMetricsSnapshot(720, 1600, 320, 0, 60);
    }

    private static int getIntField(Class<?> clazz, Object instance, String fieldName, int defaultValue) {
        try {
            Field f = clazz.getDeclaredField(fieldName);
            f.setAccessible(true);
            return f.getInt(instance);
        } catch (Exception e) {
            return defaultValue;
        }
    }
}
