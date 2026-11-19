package com.seam.agent.pointer;

import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.MotionEvent;

import java.lang.reflect.Method;

/**
 * Injects fractional high-resolution {@link MotionEvent#ACTION_SCROLL} mouse scroll events
 * directly into Android's {@code InputManagerGlobal}, bypassing Linux kernel {@code REL_WHEEL}
 * integer quantization and {@code VelocityControl} 4.0x acceleration jumps.
 */
public final class SmoothScrollInjector {

    private static final int INJECT_INPUT_EVENT_MODE_ASYNC = 0;
    private static final float HI_RES_UNITS_PER_NOTCH = 32.0f;

    private final MotionEvent.PointerProperties[] pointerProps = new MotionEvent.PointerProperties[1];
    private final MotionEvent.PointerCoords[] pointerCoords = new MotionEvent.PointerCoords[1];

    private Object inputManagerGlobal;
    private Method injectInputEventMethod;
    private boolean initAttempted;

    public SmoothScrollInjector() {
        MotionEvent.PointerProperties prop = new MotionEvent.PointerProperties();
        prop.id = 0;
        prop.toolType = MotionEvent.TOOL_TYPE_MOUSE;
        pointerProps[0] = prop;

        pointerCoords[0] = new MotionEvent.PointerCoords();
    }

    private void ensureInitialized() {
        if (initAttempted) {
            return;
        }
        initAttempted = true;
        try {
            Class<?> imgClass = Class.forName("android.hardware.input.InputManagerGlobal");
            Method getInstance = imgClass.getDeclaredMethod("getInstance");
            inputManagerGlobal = getInstance.invoke(null);
            injectInputEventMethod = imgClass.getDeclaredMethod("injectInputEvent", InputEvent.class, int.class);
            injectInputEventMethod.setAccessible(true);
            System.out.println("[SmoothScroll] InputManagerGlobal high-res scroll injector ready.");
        } catch (Exception e) {
            System.err.println("[SmoothScroll] Could not initialize InputManagerGlobal injector (falling back to /dev/uhid wheel): " + e);
            inputManagerGlobal = null;
            injectInputEventMethod = null;
        }
    }

    /**
     * Injects a fractional mouse wheel scroll event at {@code (x, y)}.
     *
     * @param x           Current Android cursor X coordinate in display pixels.
     * @param y           Current Android cursor Y coordinate in display pixels.
     * @param hiResVWheel Vertical scroll delta in {@code 1/32}-notch sub-units.
     * @param hiResHWheel Horizontal pan delta in {@code 1/32}-notch sub-units.
     * @return {@code true} if the fractional {@code ACTION_SCROLL} event was accepted.
     */
    public synchronized boolean injectScroll(float x, float y, int hiResVWheel, int hiResHWheel) {
        if (hiResVWheel == 0 && hiResHWheel == 0) {
            return false;
        }
        ensureInitialized();
        if (inputManagerGlobal == null || injectInputEventMethod == null) {
            return false;
        }

        float vScroll = hiResVWheel / HI_RES_UNITS_PER_NOTCH;
        float hScroll = -hiResHWheel / HI_RES_UNITS_PER_NOTCH;

        MotionEvent.PointerCoords coords = pointerCoords[0];
        coords.clear();
        coords.x = x;
        coords.y = y;
        coords.setAxisValue(MotionEvent.AXIS_VSCROLL, vScroll);
        coords.setAxisValue(MotionEvent.AXIS_HSCROLL, hScroll);

        long now = SystemClock.uptimeMillis();
        MotionEvent event = MotionEvent.obtain(
                now,
                now,
                MotionEvent.ACTION_SCROLL,
                1,
                pointerProps,
                pointerCoords,
                0,
                0,
                1.0f,
                1.0f,
                0,
                0,
                InputDevice.SOURCE_MOUSE,
                0
        );
        try {
            Object result = injectInputEventMethod.invoke(inputManagerGlobal, event, INJECT_INPUT_EVENT_MODE_ASYNC);
            return Boolean.TRUE.equals(result);
        } catch (Exception e) {
            System.err.println("[SmoothScroll] injectInputEvent failed: " + e);
            return false;
        } finally {
            event.recycle();
        }
    }
}
