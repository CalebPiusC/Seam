package com.seam.agent.clipboard;

import android.content.ClipData;
import android.content.ClipDescription;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;
import android.os.SystemClock;

import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/**
 * Bridges Android's system clipboard ({@code android.content.IClipboard}) directly from the
 * {@code uid=2000 (shell)} daemon process without requiring an APK or foreground Activity.
 *
 * <p>Uses {@link ClipDescription#getTimestamp()} before reading clip items so background polling
 * inspects change timestamps silently without triggering Android 12–15 clipboard access toasts
 * unless the clipboard genuinely changed.
 */
public final class AndroidClipboardController implements AutoCloseable {

    @FunctionalInterface
    public interface ClipboardChangeListener {
        void onClipboardChanged(String text);
    }

    private static final String SHELL_PACKAGE = "com.android.shell";
    private static final String LISTENER_DESCRIPTOR = "android.content.IOnPrimaryClipChangedListener";
    private static final int USER_ID = 0;
    private static final int DEVICE_ID_DEFAULT = 0;
    private static final long POLL_INTERVAL_MS = 450L;
    private static final long ECHO_SUPPRESS_MS = 300L;

    private volatile ClipboardChangeListener listener;
    private Object iClipboard;
    private Method setPrimaryClipMethod;
    private Method getPrimaryClipMethod;
    private Method getPrimaryClipDescriptionMethod;
    private Method addListenerMethod;
    private Method removeListenerMethod;
    private Object registeredListenerProxy;

    private ScheduledExecutorService executor;
    private String lastSyncedText;
    private long lastSetTimestampMs;
    private long lastSeenClipTimestamp = Long.MIN_VALUE;
    private volatile boolean running;

    public void setClipboardChangeListener(ClipboardChangeListener listener) {
        this.listener = listener;
    }

    /**
     * Connects to the Android system {@code clipboard} Binder service, registers a change
     * listener, and starts background change monitoring.
     */
    public synchronized void start() {
        if (running) {
            return;
        }
        try {
            Class<?> serviceManagerClass = Class.forName("android.os.ServiceManager");
            Method getServiceMethod = serviceManagerClass.getDeclaredMethod("getService", String.class);
            IBinder binder = (IBinder) getServiceMethod.invoke(null, "clipboard");
            if (binder == null) {
                System.err.println("[Clipboard] System clipboard binder service unavailable.");
                return;
            }

            Class<?> stubClass = Class.forName("android.content.IClipboard$Stub");
            Method asInterfaceMethod = stubClass.getDeclaredMethod("asInterface", IBinder.class);
            iClipboard = asInterfaceMethod.invoke(null, binder);

            Class<?> iClipboardClass = Class.forName("android.content.IClipboard");
            Class<?> listenerInterface = Class.forName(LISTENER_DESCRIPTOR);

            setPrimaryClipMethod = resolveClipboardMethod(iClipboardClass, "setPrimaryClip", ClipData.class);
            getPrimaryClipMethod = resolveClipboardMethod(iClipboardClass, "getPrimaryClip", null);
            getPrimaryClipDescriptionMethod = resolveClipboardMethod(iClipboardClass, "getPrimaryClipDescription", null);
            addListenerMethod = resolveClipboardMethod(iClipboardClass, "addPrimaryClipChangedListener", listenerInterface);
            removeListenerMethod = resolveClipboardMethod(iClipboardClass, "removePrimaryClipChangedListener", listenerInterface);

            executor = Executors.newSingleThreadScheduledExecutor(r -> {
                Thread t = new Thread(r, "seam-clipboard-monitor");
                t.setDaemon(true);
                return t;
            });

            ClipDescription initialDesc = queryPrimaryClipDescription();
            if (initialDesc != null) {
                lastSeenClipTimestamp = initialDesc.getTimestamp();
            }

            registerPrimaryClipListener(listenerInterface);
            running = true;

            executor.scheduleAtFixedRate(
                    () -> checkClipboard(false),
                    POLL_INTERVAL_MS,
                    POLL_INTERVAL_MS,
                    TimeUnit.MILLISECONDS
            );
            System.out.println("[Clipboard] Android system IClipboard bridge initialized.");
        } catch (Exception e) {
            System.err.println("[Clipboard] Failed to initialize IClipboard bridge: " + e);
            close();
        }
    }

    /**
     * Writes plain UTF-8 text received from macOS into Android's system primary clipboard.
     */
    public synchronized void setPrimaryClipText(String text) {
        if (text == null || text.isEmpty() || iClipboard == null || setPrimaryClipMethod == null) {
            return;
        }
        try {
            lastSyncedText = text;
            lastSetTimestampMs = SystemClock.uptimeMillis();
            ClipData clip = ClipData.newPlainText("SEAM", text);
            invokeClipboardMethod(setPrimaryClipMethod, clip, true);

            ClipDescription updatedDesc = queryPrimaryClipDescription();
            if (updatedDesc != null) {
                lastSeenClipTimestamp = updatedDesc.getTimestamp();
            }
        } catch (Exception e) {
            System.err.println("[Clipboard] setPrimaryClipText failed: " + e);
        }
    }

    /**
     * Triggers rapid post-keystroke checks shortly after {@code Ctrl+C} or {@code Ctrl+X}
     * so newly copied Android text syncs to macOS immediately.
     */
    public void schedulePostCopyCheck() {
        ScheduledExecutorService exec = this.executor;
        if (!running || exec == null || exec.isShutdown()) {
            return;
        }
        exec.schedule(() -> checkClipboard(false), 55L, TimeUnit.MILLISECONDS);
        exec.schedule(() -> checkClipboard(false), 140L, TimeUnit.MILLISECONDS);
    }

    private void scheduleImmediateCheck() {
        ScheduledExecutorService exec = this.executor;
        if (!running || exec == null || exec.isShutdown()) {
            return;
        }
        exec.execute(() -> checkClipboard(true));
    }

    private synchronized void checkClipboard(boolean forceRead) {
        if (!running || iClipboard == null || getPrimaryClipMethod == null) {
            return;
        }
        try {
            long now = SystemClock.uptimeMillis();
            if (!forceRead && getPrimaryClipDescriptionMethod != null) {
                ClipDescription desc = queryPrimaryClipDescription();
                if (desc == null) {
                    return;
                }
                long ts = desc.getTimestamp();
                if (ts == lastSeenClipTimestamp) {
                    return;
                }
                lastSeenClipTimestamp = ts;
            } else if (getPrimaryClipDescriptionMethod != null) {
                ClipDescription desc = queryPrimaryClipDescription();
                if (desc != null) {
                    lastSeenClipTimestamp = desc.getTimestamp();
                }
            }

            ClipData clip = (ClipData) invokeClipboardMethod(getPrimaryClipMethod, null, false);
            if (clip == null || clip.getItemCount() <= 0) {
                return;
            }
            ClipData.Item item = clip.getItemAt(0);
            if (item == null) {
                return;
            }
            CharSequence cs = item.getText();
            if (cs == null || cs.length() == 0) {
                return;
            }

            String text = cs.toString();
            boolean changed = !text.equals(lastSyncedText);
            if (!changed) {
                return;
            }
            if ((now - lastSetTimestampMs) <= ECHO_SUPPRESS_MS && text.equals(lastSyncedText)) {
                return;
            }

            lastSyncedText = text;
            ClipboardChangeListener cb = this.listener;
            if (cb != null) {
                cb.onClipboardChanged(text);
            }
        } catch (Exception e) {
            System.err.println("[Clipboard] checkClipboard failed: " + e);
        }
    }

    private ClipDescription queryPrimaryClipDescription() {
        if (iClipboard == null || getPrimaryClipDescriptionMethod == null) {
            return null;
        }
        try {
            return (ClipDescription) invokeClipboardMethod(getPrimaryClipDescriptionMethod, null, false);
        } catch (Exception e) {
            return null;
        }
    }

    private void registerPrimaryClipListener(Class<?> listenerInterface) {
        if (addListenerMethod == null) {
            return;
        }
        try {
            final Binder callbackBinder = new Binder() {
                @Override
                public String getInterfaceDescriptor() {
                    return LISTENER_DESCRIPTOR;
                }

                @Override
                protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
                    if (code == IBinder.FIRST_CALL_TRANSACTION) {
                        data.enforceInterface(LISTENER_DESCRIPTOR);
                        scheduleImmediateCheck();
                        return true;
                    }
                    return super.onTransact(code, data, reply, flags);
                }
            };

            Object proxy = Proxy.newProxyInstance(
                    listenerInterface.getClassLoader(),
                    new Class<?>[] { listenerInterface },
                    (p, method, args) -> {
                        String mName = method.getName();
                        if ("asBinder".equals(mName)) {
                            return callbackBinder;
                        }
                        if ("dispatchPrimaryClipChanged".equals(mName)) {
                            scheduleImmediateCheck();
                            return null;
                        }
                        if ("equals".equals(mName) && args != null && args.length == 1) {
                            return p == args[0];
                        }
                        if ("hashCode".equals(mName)) {
                            return System.identityHashCode(p);
                        }
                        if ("toString".equals(mName)) {
                            return "SeamOnPrimaryClipChangedListenerProxy";
                        }
                        return null;
                    }
            );
            invokeClipboardMethod(addListenerMethod, proxy, true);
            registeredListenerProxy = proxy;
        } catch (Exception e) {
            System.err.println("[Clipboard] Could not register IOnPrimaryClipChangedListener (using silent polling): " + e);
        }
    }

    private static Method resolveClipboardMethod(Class<?> iface, String name, Class<?> leadingParam)
            throws NoSuchMethodException {
        Class<?>[][] trailingCandidates = new Class<?>[][] {
                { String.class, String.class, int.class, int.class }, // Android 14–15 (pkg, attrTag, userId, deviceId)
                { String.class, String.class, int.class },            // Android 12–13 (pkg, attrTag, userId)
                { String.class, int.class },                          // Android 10–11 (pkg, userId)
                { String.class }                                      // Legacy (pkg)
        };
        for (Class<?>[] trailing : trailingCandidates) {
            Class<?>[] fullParams;
            if (leadingParam != null) {
                fullParams = new Class<?>[1 + trailing.length];
                fullParams[0] = leadingParam;
                System.arraycopy(trailing, 0, fullParams, 1, trailing.length);
            } else {
                fullParams = trailing;
            }
            try {
                Method m = iface.getMethod(name, fullParams);
                m.setAccessible(true);
                return m;
            } catch (NoSuchMethodException ignored) {
            }
        }
        throw new NoSuchMethodException(iface.getName() + "." + name);
    }

    private Object invokeClipboardMethod(Method method, Object leadingArg, boolean hasLeadingArg) throws Exception {
        int totalParams = method.getParameterCount();
        int trailingCount = totalParams - (hasLeadingArg ? 1 : 0);
        Object[] args = new Object[totalParams];
        int idx = 0;
        if (hasLeadingArg) {
            args[idx++] = leadingArg;
        }
        switch (trailingCount) {
            case 4 -> {
                args[idx++] = SHELL_PACKAGE;
                args[idx++] = null;
                args[idx++] = USER_ID;
                args[idx] = DEVICE_ID_DEFAULT;
            }
            case 3 -> {
                args[idx++] = SHELL_PACKAGE;
                args[idx++] = null;
                args[idx] = USER_ID;
            }
            case 2 -> {
                args[idx++] = SHELL_PACKAGE;
                args[idx] = USER_ID;
            }
            case 1 -> args[idx] = SHELL_PACKAGE;
            default -> throw new IllegalStateException("Unsupported IClipboard trailing parameter count: " + trailingCount);
        }
        return method.invoke(iClipboard, args);
    }

    @Override
    public synchronized void close() {
        running = false;
        if (registeredListenerProxy != null && removeListenerMethod != null && iClipboard != null) {
            try {
                invokeClipboardMethod(removeListenerMethod, registeredListenerProxy, true);
            } catch (Exception ignored) {
            }
            registeredListenerProxy = null;
        }
        if (executor != null) {
            executor.shutdownNow();
            executor = null;
        }
        iClipboard = null;
    }
}
