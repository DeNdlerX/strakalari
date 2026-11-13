package io.github.dendlerx.strakalari.android;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;

import androidx.annotation.NonNull;

import io.flutter.FlutterInjector;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.dart.DartExecutor;
import io.flutter.embedding.engine.dart.DartExecutor.DartCallback;
import io.flutter.view.FlutterCallbackInformation;

/**
 * Runs one headless refresh without the screen.
 *
 * <p>{@link WakeReceiver} (unchanged) only holds a wakelock for the Python
 * scheduler that no longer exists. This receiver is what the Dart side arms
 * through {@code scheduleWake}: it boots a headless {@link FlutterEngine}
 * running the background callback the UI isolate registered
 * ({@code registerBackgroundCallback}), which runs one {@code runRefresh},
 * updates the status notification and the widget through the channel, re-arms
 * the next wake, and exits.
 *
 * <p>On a reboot or an app update it runs the same entry with reason
 * {@code "boot"}: that re-arms the refresh wake (the one intended behavior
 * change of PLAN.md §3.4 — the old build only reminded the user to open the
 * app). The wake-up alarms and the widget are still re-armed by the
 * unchanged {@link BootReceiver}.
 *
 * <p>Only one run at a time: a second wake while one runs is dropped (the
 * next armed wake retries). The CPU is held until Dart reports
 * {@code backgroundDone}, or a 32-minute timeout releases everything (covering
 * the 30-minute job wait plus the 60-second update check) and arms a 5-minute
 * retry wake.
 */
public class RefreshReceiver extends BroadcastReceiver {
    static final String ACTION_WAKE =
            "io.github.dendlerx.strakalari.android.ACTION_REFRESH_RUN";
    private static final String PREFS = "strakalari_background";
    private static final String KEY_CALLBACK = "bg_callback";
    // Longest allowed run: 30 min refresh job wait + 60 s update wait + margin.
    private static final long HOLD_MS = 32 * 60 * 1000L;
    private static final long RETRY_MS = 5 * 60 * 1000L;
    private static final int REQUEST_WAKE = 7305;

    private static Context appContext;
    private static FlutterEngine engine;
    private static StrakalariChannel headlessChannel;
    private static PowerManager.WakeLock lock;
    private static final Handler handler = new Handler(Looper.getMainLooper());
    private static final Runnable timeout = RefreshReceiver::giveUp;

    /** The wake alarm the Dart side arms (also used to cancel it). */
    static PendingIntent wakeIntent(@NonNull Context ctx) {
        Intent intent = new Intent(ACTION_WAKE);
        intent.setClassName(ctx.getPackageName(), RefreshReceiver.class.getName());
        return PendingIntent.getBroadcast(ctx, REQUEST_WAKE, intent,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    /** Persists the UI isolate's background-callback handle for headless runs. */
    static void storeCallback(@NonNull Context ctx, long handle) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putLong(KEY_CALLBACK, handle)
                .apply();
    }

    /** Dart's end-of-run signal: releases the wakelock and the engine. */
    static void release(@NonNull Context ctx) {
        synchronized (RefreshReceiver.class) {
            releaseStatic();
        }
    }

    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent != null ? intent.getAction() : null;
        if (Intent.ACTION_BOOT_COMPLETED.equals(action)
                || Intent.ACTION_MY_PACKAGE_REPLACED.equals(action)) {
            runHeadless(context.getApplicationContext(), "boot");
        } else if (ACTION_WAKE.equals(action)) {
            runHeadless(context.getApplicationContext(), "alarm");
        }
    }

    private static void runHeadless(@NonNull Context appCtx, @NonNull String reason) {
        synchronized (RefreshReceiver.class) {
            if (engine != null) {
                return; // one run at a time; the next armed wake retries
            }
            PowerManager pm = appCtx.getSystemService(PowerManager.class);
            if (pm == null) {
                return;
            }
            appContext = appCtx;
            lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,
                    "strakalari:headless-refresh");
            lock.setReferenceCounted(false);
            lock.acquire(HOLD_MS);

            SharedPreferences prefs = appCtx.getSharedPreferences(
                    PREFS, Context.MODE_PRIVATE);
            long handle = prefs.getLong(KEY_CALLBACK, 0L);

            FlutterEngine created = new FlutterEngine(appCtx);
            try {
                io.flutter.plugins.GeneratedPluginRegistrant.registerWith(created);
            } catch (Exception | Error ignored) {
                // No plugins to register in this build flavor; the channel
                // below is attached by hand either way.
            }
            headlessChannel = new StrakalariChannel();
            headlessChannel.attach(appCtx,
                    created.getDartExecutor().getBinaryMessenger());
            StrakalariChannel.headlessReason = reason;
            headlessChannel.setReleaseHook(() -> release(appCtx));
            try {
                // A handle this build does not know (possible after an app
                // update) looks up as null: use the named entry point then.
                FlutterCallbackInformation info = handle != 0L
                        ? FlutterCallbackInformation.lookupCallbackInformation(handle)
                        : null;
                if (info != null) {
                    DartCallback callback = new DartCallback(
                            appCtx.getAssets(),
                            FlutterInjector.instance().flutterLoader()
                                    .findAppBundlePath(),
                            info);
                    created.getDartExecutor().executeDartCallback(callback);
                } else {
                    // Never registered (fresh install, never opened): the
                    // named entry point in the main library. Missing there
                    // too: give up until the app runs once.
                    created.getDartExecutor().executeDartEntrypoint(
                            new DartExecutor.DartEntrypoint(
                                    FlutterInjector.instance().flutterLoader()
                                            .findAppBundlePath(),
                                    "backgroundMain"));
                }
            } catch (Exception | Error e) {
                // Dart never ran, so nothing armed the next wake: retry.
                release(appCtx);
                Log.w("strakalari",
                        "Warning: headless refresh could not start ("
                                + e + "); retrying in 5 min.");
                armRetry(appCtx);
                return;
            }
            engine = created;
            handler.removeCallbacks(timeout);
            handler.postDelayed(timeout, HOLD_MS);
        }
    }

    private static void giveUp() {
        Context ctx;
        synchronized (RefreshReceiver.class) {
            if (engine == null) {
                return;
            }
            ctx = appContext;
            releaseStatic();
        }
        // Dart never reported back; drop the run and arm a 5-minute retry.
        Log.w("strakalari",
                "Warning: headless refresh timed out; retrying in 5 min.");
        if (ctx != null) {
            armRetry(ctx);
        }
    }

    /** Arms the wake alarm {@code RETRY_MS} ahead (a run that never finished). */
    private static void armRetry(@NonNull Context ctx) {
        AlarmManager alarms = ctx.getSystemService(AlarmManager.class);
        if (alarms != null) {
            long atMs = System.currentTimeMillis() + RETRY_MS;
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs,
                    wakeIntent(ctx));
        }
    }

    private static void releaseStatic() {
        handler.removeCallbacks(timeout);
        if (lock != null) {
            try {
                if (lock.isHeld()) {
                    lock.release();
                }
            } catch (RuntimeException ignored) {
            }
            lock = null;
        }
        if (headlessChannel != null) {
            headlessChannel.detach();
            headlessChannel = null;
        }
        if (engine != null) {
            engine.destroy();
            engine = null;
        }
        appContext = null;
    }

    /** AlarmManager clock check shared with the widget's tick (unused here). */
    static boolean exactAllowed(@NonNull Context ctx) {
        AlarmManager alarms = ctx.getSystemService(AlarmManager.class);
        return Build.VERSION.SDK_INT < 31
                || alarms == null
                || alarms.canScheduleExactAlarms();
    }
}
