package dev.okestra.device;

import android.content.Context;
import android.net.TrafficStats;
import android.os.Looper;
import android.os.SystemClock;

/** Device-wide counters, read on Android; no test downloads, permissions or app installation. */
public final class NetworkMonitor {
    private NetworkMonitor() {}

    /** app_process has no Application; newer Android releases require explicit initialization. */
    private static void initializeStats() throws Exception {
        try {
            TrafficStats.getTotalRxBytes();
            return;
        } catch (IllegalStateException uninitialized) {
            // Keep the older platform path untouched: only bootstrap if the API needs a context.
            java.lang.reflect.Method init = TrafficStats.class.getMethod("init", Context.class);
            if (Looper.myLooper() == null) { Looper.prepareMainLooper(); }
            Class<?> activityThread = Class.forName("android.app.ActivityThread");
            Object thread = activityThread.getMethod("systemMain").invoke(null);
            Context context = (Context) activityThread.getMethod("getSystemContext").invoke(thread);
            init.invoke(null, context);
        }
    }

    public static void main(String[] args) {
        // ADB closes stdin when this viewer's reader disconnects. Exit explicitly,
        // since Android's Binder threads can otherwise keep app_process alive.
        Thread lifetime = new Thread(new Runnable() {
            @Override public void run() {
                try { while (System.in.read() != -1) {} } catch (Exception ignored) {}
                System.exit(0);
            }
        }, "okestra-network-lifetime");
        lifetime.setDaemon(true);
        lifetime.start();
        try {
            initializeStats();
            while (true) {
                long rx = TrafficStats.getTotalRxBytes();
                long tx = TrafficStats.getTotalTxBytes();
                if (rx == TrafficStats.UNSUPPORTED || tx == TrafficStats.UNSUPPORTED || rx < 0 || tx < 0) {
                    System.out.println("{\"version\":1,\"error\":\"Network counters are unavailable on this device.\"}");
                    break;
                }
                System.out.println("{\"version\":1,\"elapsed_ms\":" + SystemClock.elapsedRealtime()
                        + ",\"received_bytes\":" + rx + ",\"transmitted_bytes\":" + tx + "}");
                if (System.out.checkError()) { break; }
                SystemClock.sleep(1000);
            }
        } catch (Throwable error) {
            error.printStackTrace(System.err);
            System.out.println("{\"version\":1,\"error\":\"Android could not read network counters.\"}");
        } finally {
            System.exit(0);
        }
    }
}
