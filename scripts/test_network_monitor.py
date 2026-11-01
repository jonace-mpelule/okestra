#!/usr/bin/env python3
"""Exercise the real helper against old/new Android API fixtures without a device."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
JAVA = os.environ.get('OKESTRA_JAVA', '/opt/homebrew/opt/openjdk@17/bin/java')
JAVAC = os.environ.get('OKESTRA_JAVAC', '/opt/homebrew/opt/openjdk@17/bin/javac')


@unittest.skipUnless(Path(JAVA).is_file() and Path(JAVAC).is_file(), 'OpenJDK 17 is required')
class NetworkMonitorTests(unittest.TestCase):
    def run_helper(self, mode):
        with tempfile.TemporaryDirectory(prefix='okestra-network-test-') as directory:
            root = Path(directory)
            sources = {
                'android/content/Context.java': 'package android.content; public class Context {}',
                'android/os/Looper.java': '''package android.os;
                    public class Looper {
                        public static boolean prepared;
                        public static Looper myLooper() { return prepared ? new Looper() : null; }
                        public static void prepareMainLooper() { prepared = true; }
                    }''',
                'android/os/SystemClock.java': '''package android.os;
                    public class SystemClock {
                        private static long now;
                        public static long elapsedRealtime() { return now += 1000; }
                        public static void sleep(long ignored) {
                            try { Thread.sleep(60); } catch (InterruptedException e) {}
                        }
                    }''',
                'android/app/ActivityThread.java': '''package android.app;
                    import android.content.Context;
                    import android.os.Looper;
                    public class ActivityThread {
                        public static boolean started;
                        public static ActivityThread systemMain() {
                            if (!Looper.prepared) { throw new IllegalStateException("Missing looper"); }
                            started = true; return new ActivityThread();
                        }
                        public Context getSystemContext() { return new Context(); }
                    }''',
            }
            if mode in ('legacy', 'unsupported'):
                rx = '-1' if mode == 'unsupported' else '(rx += 1000)'
                sources['android/net/TrafficStats.java'] = '''package android.net;
                    public class TrafficStats {
                        public static final int UNSUPPORTED = -1;
                        private static long rx, tx;
                        // Deliberately no init(Context) method on this older API.
                        public static long getTotalRxBytes() { return %s; }
                        public static long getTotalTxBytes() { return tx += 2000; }
                    }''' % rx
            else:
                init = 'throw new SecurityException("Fixture initialization denied");' if mode == 'denied' else 'ready = true;'
                sources['android/net/TrafficStats.java'] = '''package android.net;
                    import android.content.Context;
                    import android.app.ActivityThread;
                    public class TrafficStats {
                        public static final int UNSUPPORTED = -1;
                        private static boolean ready;
                        private static long rx, tx;
                        public static void init(Context context) {
                            if (context == null || !ActivityThread.started) {
                                throw new IllegalStateException("Missing context");
                            }
                            %s
                        }
                        public static long getTotalRxBytes() {
                            if (!ready) { throw new IllegalStateException("TrafficStats not initialized"); }
                            return rx += 1000;
                        }
                        public static long getTotalTxBytes() { return tx += 2000; }
                    }''' % init
            files = []
            for relative, source in sources.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source)
                files.append(str(path))
            real = root / 'NetworkMonitor.java'
            shutil.copyfile(ROOT / 'apps/okestra-device/Android/NetworkMonitor.java', real)
            subprocess.run([JAVAC, '--release', '8', '-d', str(root), *files, str(real)],
                           check=True, capture_output=True)
            process = subprocess.Popen([JAVA, '-cp', str(root), 'dev.okestra.device.NetworkMonitor'],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            timer = threading.Timer(1, process.stdin.close)
            timer.start()
            try:
                process.wait(timeout=8)
                output = process.stdout.read().decode()
                diagnostics = process.stderr.read().decode()
                self.assertEqual(process.returncode, 0, diagnostics)
                return [json.loads(line) for line in output.splitlines()], diagnostics
            finally:
                timer.cancel()
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stdin.close()
                process.stdout.close()
                process.stderr.close()

    def test_older_android_without_init_method_still_streams(self):
        samples, diagnostics = self.run_helper('legacy')
        self.assertGreaterEqual(len(samples), 2)
        self.assertGreater(samples[-1]['received_bytes'], samples[0]['received_bytes'])
        self.assertFalse(diagnostics)

    def test_context_dependent_android_bootstraps_and_streams(self):
        samples, diagnostics = self.run_helper('modern')
        self.assertGreaterEqual(len(samples), 2)
        self.assertGreater(samples[-1]['elapsed_ms'], samples[0]['elapsed_ms'])
        self.assertGreater(samples[-1]['transmitted_bytes'], samples[0]['transmitted_bytes'])
        self.assertFalse(diagnostics)

    def test_unsupported_counters_report_error_instead_of_zero(self):
        samples, _ = self.run_helper('unsupported')
        self.assertEqual(len(samples), 1)
        self.assertIn('error', samples[0])
        self.assertNotIn('received_bytes', samples[0])

    def test_initialization_failure_keeps_diagnostics_and_reports_error(self):
        samples, diagnostics = self.run_helper('denied')
        self.assertEqual(len(samples), 1)
        self.assertIn('error', samples[0])
        self.assertIn('Fixture initialization denied', diagnostics)


if __name__ == '__main__':
    unittest.main()
