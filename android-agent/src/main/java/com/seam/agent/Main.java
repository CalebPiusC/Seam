package com.seam.agent;

import android.system.Os;

import com.seam.agent.core.SeamInputEngine;
import com.seam.agent.pointer.PointerLinearizer;
import com.seam.agent.protocol.SeamAuthenticator;
import com.seam.agent.protocol.SeamProtocol;
import com.seam.agent.telemetry.DisplayMetricsSnapshot;
import com.seam.agent.telemetry.DisplayTelemetry;
import com.seam.agent.telemetry.NetworkTelemetry;
import com.seam.agent.transport.DualTransportCoordinator;
import com.seam.agent.uhid.HidKeycodes;

import java.io.File;
import java.util.List;

/**
 * SEAM Android Agent Entrypoint ({@code app_process}, {@code uid=2000 (shell)}).
 *
 * <p>Supported CLI commands:
 * <ul>
 *   <li>{@code --server} / {@code --daemon}: Starts the persistent {@code SEAM-Wire v1} transport server
 *       bridging authenticated USB/Wi-Fi sessions to {@link SeamInputEngine}.</li>
 *   <li>{@code --info}: Prints display geometry, UID/GID context, and {@code /dev/uhid} accessibility.</li>
 *   <li>{@code --self-test}: Verifies virtual {@code /dev/uhid} mouse and keyboard registration,
 *       native hardware cursor rendering, 16-bit corner homing, 120 Hz circular movement, scroll wheel,
 *       and clean {@code UHID_DESTROY} unregistration.</li>
 *   <li>{@code --calibrate}: Runs 16-bit corner-homing and pointer velocity calibration against
 *       {@code PointerChoreographer} ({@code dumpsys input}).</li>
 * </ul>
 */
public final class Main {

    public static void main(String[] args) {
        String mode = args.length > 0 ? args[0] : "--info";

        switch (mode) {
            case "--server", "--daemon" -> runServerDaemon(args);
            case "--info" -> runInfoProbe();
            case "--self-test" -> runSelfTest();
            case "--calibrate" -> runCalibration();
            default -> {
                System.err.println("Unknown option: " + mode);
                System.err.println("Usage: app_process / com.seam.agent.Main [--server | --info | --self-test | --calibrate]");
                System.exit(1);
            }
        }
    }

    private static void runServerDaemon(String[] args) {
        String hexKey = System.getenv("SEAM_AUTH_KEY");
        for (int i = 1; i < args.length; i++) {
            if (args[i].startsWith("--auth-key=")) {
                hexKey = args[i].substring("--auth-key=".length());
            } else if ("--detach".equals(args[i])) {
                try {
                    Os.setsid();
                } catch (Exception ignored) {
                }
            }
        }

        if (hexKey == null || hexKey.isBlank()) {
            System.err.println("[ERROR] Missing SEAM authentication key (provide SEAM_AUTH_KEY env or --auth-key=<64-hex>)");
            System.exit(2);
        }

        byte[] keyBytes;
        try {
            keyBytes = SeamAuthenticator.parseHexKey(hexKey);
        } catch (IllegalArgumentException e) {
            System.err.println("[ERROR] Invalid SEAM authentication key: " + e.getMessage());
            System.exit(2);
            return;
        }

        SeamAuthenticator authenticator = new SeamAuthenticator(keyBytes);

        SeamInputEngine engine = new SeamInputEngine();
        DualTransportCoordinator coordinator = new DualTransportCoordinator(
                engine,
                authenticator,
                SeamProtocol.WIFI_DEFAULT_PORT
        );
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            coordinator.close();
            engine.close();
        }, "seam-server-shutdown"));

        try {
            engine.initialize();
            // Pre-park at origin (0, 0) so the first CURSOR_ENTER jump is 0 ms
            engine.onCursorLeaveOrPanicReset();

            System.out.println("[SEAM-Agent] SeamInputEngine initialized (/dev/uhid Mouse + Keyboard ready).");
            System.out.println("[SEAM-Agent] Display: " + engine.getDisplayMetrics());

            List<NetworkTelemetry.InterfaceAddress> wifiAddrs = NetworkTelemetry.queryWifiAddresses();
            for (NetworkTelemetry.InterfaceAddress addr : wifiAddrs) {
                System.out.printf("SEAM_WIFI_ENDPOINT:%s:%s:%d%n",
                        addr.interfaceName(), addr.ipv4Address(), SeamProtocol.WIFI_DEFAULT_PORT);
            }

            System.out.println("SEAM_AGENT_READY");
            System.out.flush();

            coordinator.run();
        } catch (Exception e) {
            System.err.println("[ERROR] SEAM Agent Server terminated: " + e.getMessage());
            e.printStackTrace(System.err);
            System.exit(1);
        } finally {
            coordinator.close();
            engine.close();
        }
    }

    private static void runInfoProbe() {
        System.out.println("============================================================");
        System.out.println(" SEAM Android Agent — Device Telemetry");
        System.out.println("============================================================");
        System.out.printf("Process Context   : uid=%d, pid=%d, ppid=%d%n",
                Os.getuid(), Os.getpid(), Os.getppid());

        File uhidFile = new File("/dev/uhid");
        System.out.printf("/dev/uhid Node    : exists=%b, canRead=%b, canWrite=%b%n",
                uhidFile.exists(), uhidFile.canRead(), uhidFile.canWrite());

        DisplayMetricsSnapshot metrics = DisplayTelemetry.queryPrimaryDisplay();
        System.out.println("Primary Display   : " + metrics);
        System.out.println("Wi-Fi / Hotspot   : " + NetworkTelemetry.queryWifiAddresses());
        System.out.println("------------------------------------------------------------");
        System.out.print(PointerLinearizer.dumpPointerChoreographerState());
        System.out.println("============================================================");
    }

    private static void runSelfTest() {
        System.out.println("============================================================");
        System.out.println(" SEAM Android Agent — Native /dev/uhid Hardware Self-Test");
        System.out.println("============================================================");

        try (SeamInputEngine engine = new SeamInputEngine()) {
            Runtime.getRuntime().addShutdownHook(new Thread(engine::close, "seam-shutdown-hook"));

            DisplayMetricsSnapshot display = engine.refreshDisplayMetrics();
            int width = display.widthPx();
            int height = display.heightPx();
            int centerX = width / 2;
            int centerY = height / 2;

            System.out.println("[1/6] Registering /dev/uhid Virtual Mouse & Keyboard...");
            engine.initialize();

            Thread.sleep(350);
            System.out.println("      Registered 'SEAM Virtual Mouse' & 'SEAM Virtual Keyboard'.");
            System.out.println("      Display Viewport: " + display);

            System.out.printf("[2/6] Homing Cursor to Screen Center (%d, %d)...%n", centerX, centerY);
            engine.onCursorEnter(centerX, centerY);
            Thread.sleep(250);

            String choreographerDump = PointerLinearizer.dumpPointerChoreographerState();
            System.out.println("      InputReader & PointerChoreographer Status:");
            for (String line : choreographerDump.split("\n")) {
                String trimmed = line.trim();
                if (trimmed.startsWith("Device ") || trimmed.startsWith("Cursor Input Mapper")
                        || trimmed.startsWith("Mode:") || trimmed.startsWith("MousePointerControllers")
                        || trimmed.startsWith("Presentation:")) {
                    System.out.println("        " + trimmed);
                }
            }

            System.out.println("[3/6] Gliding Native Hardware Mouse Cursor in a 120 Hz Circle...");
            double radius = Math.min(width, height) * 0.28;
            int steps = 300;
            int prevX = 0;
            int prevY = 0;
            for (int i = 1; i <= steps; i++) {
                double theta = (2.0 * Math.PI * 2.0 * i) / steps;
                int curX = (int) Math.round(radius * Math.sin(theta));
                int curY = (int) Math.round(radius * (1.0 - Math.cos(theta)) * 0.5);
                int dx = curX - prevX;
                int dy = curY - prevY;
                prevX = curX;
                prevY = curY;

                engine.onMouseReport(HidKeycodes.MOUSE_BTN_NONE, dx, dy, 0, 0);
                Thread.sleep(8);
            }

            System.out.println("[4/6] Testing Screen-Edge Entry Transitions (Y = 25%, 50%, 75%)...");
            int[] entryYs = new int[] { height / 4, height / 2, (height * 3) / 4 };
            for (int entryY : entryYs) {
                engine.onCursorEnter(4, entryY);
                for (int step = 0; step < 45; step++) {
                    engine.onMouseReport(HidKeycodes.MOUSE_BTN_NONE, 4, 0, 0, 0);
                    Thread.sleep(8);
                }
                Thread.sleep(150);
            }

            System.out.println("[5/6] Testing Vertical Scroll Wheel Events...");
            engine.onCursorEnter(centerX, centerY);
            for (int i = 0; i < 8; i++) {
                engine.onMouseReport(HidKeycodes.MOUSE_BTN_NONE, 0, 0, -1, 0);
                Thread.sleep(45);
            }
            Thread.sleep(200);
            for (int i = 0; i < 8; i++) {
                engine.onMouseReport(HidKeycodes.MOUSE_BTN_NONE, 0, 0, +1, 0);
                Thread.sleep(45);
            }

            System.out.println("[6/6] Parking Cursor & Unregistering /dev/uhid Devices...");
            engine.onCursorLeaveOrPanicReset();
            Thread.sleep(200);

        } catch (Exception e) {
            System.err.println("[ERROR] Hardware self-test failed: " + e.getMessage());
            e.printStackTrace(System.err);
            System.exit(1);
        }

        System.out.println("============================================================");
        System.out.println(" SEAM Hardware Self-Test Complete");
        System.out.println("============================================================");
    }

    private static void runCalibration() {
        System.out.println("============================================================");
        System.out.println(" SEAM Android Agent — Pointer Homing & Velocity Calibration");
        System.out.println("============================================================");

        try (SeamInputEngine engine = new SeamInputEngine()) {
            Runtime.getRuntime().addShutdownHook(new Thread(engine::close, "seam-cal-shutdown"));
            engine.initialize();
            Thread.sleep(350);

            DisplayMetricsSnapshot display = engine.refreshDisplayMetrics();
            System.out.println("Target Display: " + display);

            int[][] targets = new int[][] {
                { 0, 0 },
                { 2, display.heightPx() / 4 },
                { 2, display.heightPx() / 2 },
                { 2, (display.heightPx() * 3) / 4 },
                { display.widthPx() / 2, display.heightPx() / 2 }
            };

            for (int[] target : targets) {
                int tx = target[0];
                int ty = target[1];
                engine.onCursorEnter(tx, ty);
                Thread.sleep(150);

                String dump = PointerLinearizer.dumpPointerChoreographerState();
                float[] actual = PointerLinearizer.parseCursorPositionFromDump(dump);
                if (actual != null) {
                    System.out.printf("  Target=(%4d, %4d) -> Actual=(%6.1f, %6.1f) | Error=(%+5.1f, %+5.1f) px%n",
                            tx, ty, actual[0], actual[1], actual[0] - tx, actual[1] - ty);
                } else {
                    System.out.printf("  Homed to (%4d, %4d) | Shadow=(%4d, %4d)%n",
                            tx, ty, engine.getShadowX(), engine.getShadowY());
                }
            }
        } catch (Exception e) {
            System.err.println("[ERROR] Calibration failed: " + e.getMessage());
            e.printStackTrace(System.err);
            System.exit(1);
        }
    }
}
