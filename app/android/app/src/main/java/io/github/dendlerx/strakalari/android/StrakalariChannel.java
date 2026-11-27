package io.github.dendlerx.strakalari.android;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.provider.AlarmClock;
import android.provider.Settings;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

import java.security.KeyStore;
import java.util.ArrayList;
import java.util.Map;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.spec.GCMParameterSpec;

/**
 * The MethodChannel behind {@code app/lib/platform/android/}:
 * {@code strakalari/android}.
 *
 * <p>One method per function in {@code strakalari/core/android.py} (same names,
 * same argument names, same behavior), so the Dart port maps one-to-one:
 *
 * <ul>
 *   <li>notifications: {@code notify}, {@code notificationsEnabled},
 *       {@code requestNotificationPermission}, {@code openNotificationSettings}
 *   <li>background service: {@code startBackground}, {@code stopBackground},
 *       {@code updateBackgroundNotification}, {@code batteryUnrestricted},
 *       {@code openBatterySettings}
 *   <li>refresh wake: {@code scheduleWake}, {@code cancelWake}
 *   <li>CPU awake during a refresh: {@code keepAwake}, {@code releaseAwake}
 *   <li>wake-up alarm: {@code setWakeupAlarms}, {@code exactAlarmsAllowed},
 *       {@code openExactAlarmSettings}, {@code openSystemAlarm}
 *   <li>morning brief: {@code setMorningBriefs}
 *   <li>widget: {@code updateTimetableWidget}
 *   <li>Keystore: {@code keystoreWrap}, {@code keystoreUnwrap}
 *   <li>misc: {@code available}, {@code sdkInt}
 *   <li>headless: {@code registerBackgroundCallback}, {@code backgroundDone}
 * </ul>
 *
 * <p>Where Python went through pyjnius with process-aborting lookups, this
 * runs plain framework calls on the engine's thread. The app's own classes
 * are named directly (no lookup problem: this <em>is</em> one of them).
 */
public class StrakalariChannel implements FlutterPlugin, ActivityAware,
        MethodChannel.MethodCallHandler,
        PluginRegistry.RequestPermissionsResultListener {
    static final String CHANNEL = "strakalari/android";
    static final String ACTION_UPDATE_STATUS =
            "io.github.dendlerx.strakalari.android.ACTION_UPDATE_STATUS";
    static final String ACTION_REFRESH_WIDGET =
            "io.github.dendlerx.strakalari.android.ACTION_REFRESH_WIDGET";
    static final String EVENTS_CHANNEL = "strakalari_events";
    static final int NOTIFICATION_PERMISSION_REQUEST = 7301;
    /** The Keystore alias; identical to {@code core/android.py}. */
    static final String KEYSTORE_ALIAS = "strakalari-secret-key";

    /** Reason the current headless run started ({@code "boot"} or
     * {@code "alarm"}); read once by Dart through
     * {@code takeHeadlessReason}. Same process, so a static is enough. */
    static volatile String headlessReason = "";
    @Nullable
    private Runnable releaseHook;

    /** Runs when Dart reports {@code backgroundDone} (drops the engine). */
    void setReleaseHook(@Nullable Runnable hook) {
        releaseHook = hook;
    }

    private static int nextId = 1000;

    @Nullable
    private Context appContext;
    @Nullable
    private android.app.Activity activity;
    @Nullable
    private MethodChannel channel;
    @Nullable
    private MethodChannel.Result pendingPermissionResult;
    private String pendingLaunchRoute = "";
    private boolean launchRouteTaken = false;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        attach(binding.getApplicationContext(), binding.getBinaryMessenger());
    }

    /** Attaches to an engine (also a headless one: no activity there). */
    public void attach(@NonNull Context context, @NonNull BinaryMessenger messenger) {
        appContext = context.getApplicationContext();
        channel = new MethodChannel(messenger, CHANNEL);
        channel.setMethodCallHandler(this);
    }

    public void detach() {
        launchRouteTaken = false;
        if (pendingPermissionResult != null) {
            pendingPermissionResult.success(null);
            pendingPermissionResult = null;
        }
        if (channel != null) {
            channel.setMethodCallHandler(null);
            channel = null;
        }
        appContext = null;
    }

    /**
     * Reads a notification/widget target route from an activity launch or
     * {@code onNewIntent}, clears the extra so recreation never replays it,
     * and either invokes {@code openRoute} on Dart (warm start) or stores it
     * for {@code takeLaunchRoute} (cold start).
     */
    public void handleIntent(@Nullable Intent intent) {
        if (intent == null) {
            return;
        }
        String route = intent.getStringExtra(Notifications.EXTRA_ROUTE);
        if (route == null || route.isEmpty()) {
            return;
        }
        intent.removeExtra(Notifications.EXTRA_ROUTE);
        MethodChannel ch = channel;
        if (launchRouteTaken && ch != null) {
            ch.invokeMethod("openRoute", route);
        } else {
            pendingLaunchRoute = route;
        }
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        detach();
    }

    // -- ActivityAware: only the permission prompt needs the screen --------

    /**
     * The screen for the permission prompt. {@code MainActivity} attaches
     * this channel by hand (not through the plugin registry), so the
     * {@link ActivityAware} callbacks below never run for it.
     */
    public void setActivity(@Nullable android.app.Activity screen) {
        activity = screen;
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activity = binding.getActivity();
        binding.addRequestPermissionsResultListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        activity = null;
    }

    @Override
    public void onReattachedToActivityForConfigChanges(
            @NonNull ActivityPluginBinding binding) {
        activity = binding.getActivity();
    }

    @Override
    public void onDetachedFromActivity() {
        activity = null;
    }

    // -- dispatch ----------------------------------------------------------

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        try {
            switch (call.method) {
                case "available":
                    result.success(true);
                    return;
                case "sdkInt":
                    result.success(Build.VERSION.SDK_INT);
                    return;
                case "networkKind":
                    result.success(networkKind());
                    return;
                case "notify":
                    result.success(notify(
                            stringArg(call, "title"),
                            stringArg(call, "text"),
                            stringArg(call, "channelName"),
                            stringArg(call, "route")));
                    return;
                case "notificationsEnabled":
                    result.success(notificationsEnabled());
                    return;
                case "requestNotificationPermission":
                    requestNotificationPermission(result);
                    return;
                case "openNotificationSettings":
                    openNotificationSettings();
                    result.success(null);
                    return;
                case "startBackground":
                    result.success(startBackground(mapArg(call, "texts")));
                    return;
                case "stopBackground":
                    stopBackground();
                    result.success(null);
                    return;
                case "updateBackgroundNotification":
                    result.success(updateBackgroundNotification(
                            stringArg(call, "title"),
                            stringArg(call, "text"),
                            stringArg(call, "sub"),
                            stringArg(call, "rows")));
                    return;
                case "batteryUnrestricted":
                    result.success(batteryUnrestricted());
                    return;
                case "openBatterySettings":
                    openBatterySettings();
                    result.success(null);
                    return;
                case "scheduleWake":
                    result.success(scheduleWake(doubleArg(call, "epochSeconds")));
                    return;
                case "cancelWake":
                    cancelWake();
                    result.success(null);
                    return;
                case "keepAwake":
                    result.success(keepAwake(doubleArg(call, "minutes")));
                    return;
                case "releaseAwake":
                    releaseAwake(intArg(call, "id"));
                    result.success(null);
                    return;
                case "setWakeupAlarms":
                    result.success(setWakeupAlarms(
                            stringArg(call, "queueJson"),
                            stringArg(call, "channelName"),
                            stringArg(call, "dismissLabel")));
                    return;
                case "setMorningBriefs":
                    result.success(setMorningBriefs(
                            stringArg(call, "queueJson"),
                            stringArg(call, "channelName")));
                    return;
                case "exactAlarmsAllowed":
                    result.success(exactAlarmsAllowed());
                    return;
                case "openExactAlarmSettings":
                    openExactAlarmSettings();
                    result.success(null);
                    return;
                case "openSystemAlarm": {
                    Object weekday = call.argument("weekday");
                    result.success(openSystemAlarm(
                            intArg(call, "hour"),
                            intArg(call, "minute"),
                            stringArg(call, "message"),
                            weekday instanceof Number ? ((Number) weekday).intValue() : null));
                    return;
                }
                case "updateTimetableWidget":
                    result.success(updateTimetableWidget(stringArg(call, "payloadJson")));
                    return;
                case "keystoreWrap":
                    result.success(keystoreWrap(bytesArg(call, "data")));
                    return;
                case "keystoreUnwrap":
                    try {
                        result.success(keystoreUnwrap(bytesArg(call, "blob")));
                    } catch (IllegalArgumentException e) {
                        result.error("BAD_BLOB", e.getMessage(), null);
                    } catch (Exception e) {
                        result.error("UNWRAP_FAILED", e.toString(), null);
                    }
                    return;
                case "registerBackgroundCallback":
                    RefreshReceiver.storeCallback(requireContext(),
                            longArg(call, "handle"));
                    result.success(null);
                    return;
                case "backgroundDone": {
                    Runnable hook = releaseHook;
                    releaseHook = null;
                    if (hook != null) {
                        hook.run();
                    } else {
                        RefreshReceiver.release(requireContext());
                    }
                    result.success(null);
                    return;
                }
                case "takeHeadlessReason": {
                    String reason = headlessReason;
                    headlessReason = "";
                    result.success(reason);
                    return;
                }
                case "takeLaunchRoute": {
                    launchRouteTaken = true;
                    String route = pendingLaunchRoute;
                    pendingLaunchRoute = "";
                    result.success(route);
                    return;
                }
                default:
                    result.notImplemented();
            }
        } catch (Exception e) {
            result.error("ANDROID_FAILED", e.toString(), null);
        }
    }

    // -- arguments ----------------------------------------------------------

    private Context requireContext() throws IllegalStateException {
        if (appContext == null) {
            throw new IllegalStateException("channel not attached");
        }
        return appContext;
    }

    private static String stringArg(MethodCall call, String name) {
        Object value = call.argument(name);
        return value != null ? String.valueOf(value) : "";
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> mapArg(MethodCall call, String name) {
        Object value = call.argument(name);
        return value instanceof Map ? (Map<String, Object>) value : null;
    }

    private static double doubleArg(MethodCall call, String name) {
        Object value = call.argument(name);
        return value instanceof Number ? ((Number) value).doubleValue() : 0;
    }

    private static int intArg(MethodCall call, String name) {
        Object value = call.argument(name);
        return value instanceof Number ? ((Number) value).intValue() : 0;
    }

    private static long longArg(MethodCall call, String name) {
        Object value = call.argument(name);
        return value instanceof Number ? ((Number) value).longValue() : 0L;
    }

    private static byte[] bytesArg(MethodCall call, String name) {
        Object value = call.argument(name);
        if (value instanceof byte[]) {
            return (byte[]) value;
        }
        throw new IllegalArgumentException(name + " must be bytes");
    }

    // -- notifications -------------------------------------------------------

    private boolean notify(String title, String text, String channelName, String route) {
        Context ctx = requireContext();
        synchronized (StrakalariChannel.class) {
            nextId = 1000 + (nextId - 1000 + 1) % 5000;
        }
        Notifications.show(ctx, EVENTS_CHANNEL,
                channelName.isEmpty() ? "Strakaláři" : channelName,
                title, text, nextId,
                route.isEmpty() ? "today" : route);
        return notificationsEnabled();
    }

    private boolean notificationsEnabled() {
        return Notifications.enabled(requireContext());
    }

    private void requestNotificationPermission(@NonNull MethodChannel.Result result) {
        // Android 13+ asks once; after two declines only the settings help.
        if (Build.VERSION.SDK_INT < 33 || notificationsEnabled() || activity == null) {
            result.success(null);
            return;
        }
        if (pendingPermissionResult != null) {
            pendingPermissionResult.success(null);
        }
        pendingPermissionResult = result;
        activity.requestPermissions(
                new String[]{"android.permission.POST_NOTIFICATIONS"},
                NOTIFICATION_PERMISSION_REQUEST);
    }

    @Override
    public boolean onRequestPermissionsResult(
            int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) {
            return false;
        }
        MethodChannel.Result pending = pendingPermissionResult;
        pendingPermissionResult = null;
        if (pending != null) {
            pending.success(null);
        }
        return true;
    }

    private void openNotificationSettings() {
        Context ctx = requireContext();
        Intent intent = new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS);
        intent.putExtra(Settings.EXTRA_APP_PACKAGE, ctx.getPackageName());
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        ctx.startActivity(intent);
    }

    // -- background service ----------------------------------------------------

    private boolean startBackground(@Nullable Map<String, Object> texts) {
        Context ctx = requireContext();
        Intent intent = new Intent(ctx, KeepAliveService.class);
        if (texts != null) {
            for (Map.Entry<String, Object> entry : texts.entrySet()) {
                if (entry.getValue() != null) {
                    intent.putExtra(entry.getKey(), String.valueOf(entry.getValue()));
                }
            }
        }
        if (Build.VERSION.SDK_INT >= 26) {
            ctx.startForegroundService(intent);
        } else {
            ctx.startService(intent);
        }
        return true;
    }

    private void stopBackground() {
        Context ctx = requireContext();
        ctx.stopService(new Intent(ctx, KeepAliveService.class));
        cancelWake();
    }

    private boolean updateBackgroundNotification(
            String title, String text, String sub, String rows) {
        Context ctx = requireContext();
        Intent intent = new Intent(ACTION_UPDATE_STATUS);
        intent.setClassName(ctx.getPackageName(), StatusReceiver.class.getName());
        intent.putExtra("title", title);
        intent.putExtra("text", text);
        intent.putExtra("sub", sub);
        intent.putExtra("rows", rows);
        ctx.sendBroadcast(intent);
        return true;
    }

    /**
     * True when the user lets the app use the battery without restriction
     * (on the battery-optimization allowlist): Doze and the standby buckets
     * then no longer hold back the refresh wake or its network.
     */
    private boolean batteryUnrestricted() {
        Context ctx = requireContext();
        PowerManager power = ctx.getSystemService(PowerManager.class);
        return power == null || power.isIgnoringBatteryOptimizations(ctx.getPackageName());
    }

    /**
     * Opens the app's info page, where its battery use can be set to
     * unrestricted (no direct request: Google Play limits that permission);
     * the system's battery-optimization list where that page is missing.
     */
    private void openBatterySettings() {
        Context ctx = requireContext();
        Intent intent = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:" + ctx.getPackageName()));
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            ctx.startActivity(intent);
        } catch (RuntimeException e) {
            Intent list = new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
            list.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ctx.startActivity(list);
        }
    }

    // -- refresh wake ----------------------------------------------------------

    private boolean scheduleWake(double epochSeconds) {
        Context ctx = requireContext();
        AlarmManager alarms = ctx.getSystemService(AlarmManager.class);
        if (alarms == null) {
            return false;
        }
        long atMs = (long) (Math.max(epochSeconds,
                System.currentTimeMillis() / 1000.0 + 5) * 1000);
        RefreshReceiver.armWake(ctx, alarms, atMs);
        return true;
    }

    private void cancelWake() {
        Context ctx = requireContext();
        AlarmManager alarms = ctx.getSystemService(AlarmManager.class);
        if (alarms != null) {
            alarms.cancel(RefreshReceiver.wakeIntent(ctx));
        }
    }

    // -- CPU awake while a refresh runs (core/android.py KeepAwake) ---------------

    /** Held locks by id: like Python, every {@code KeepAwake} has its own. */
    private static final Map<Integer, PowerManager.WakeLock> awakeLocks =
            new java.util.HashMap<>();
    private static int nextAwakeId = 1;

    /**
     * A new partial wakelock {@code strakalari:refresh} held for at most
     * {@code minutes} (the timeout is a safety net). Returns its id for
     * {@code releaseAwake}, or -1 when no lock could be taken.
     */
    private int keepAwake(double minutes) {
        PowerManager power = requireContext().getSystemService(PowerManager.class);
        if (power == null) {
            return -1;
        }
        PowerManager.WakeLock lock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,
                "strakalari:refresh");
        lock.setReferenceCounted(false);
        lock.acquire((long) (minutes * 60 * 1000));
        synchronized (StrakalariChannel.class) {
            int id = nextAwakeId++;
            awakeLocks.put(id, lock);
            return id;
        }
    }

    private void releaseAwake(int id) {
        PowerManager.WakeLock lock;
        synchronized (StrakalariChannel.class) {
            lock = awakeLocks.remove(id);
        }
        if (lock != null && lock.isHeld()) {
            lock.release();
        }
    }

    // -- wake-up alarm before the first lesson -----------------------------------

    private boolean setWakeupAlarms(String queueJson, String channelName, String dismissLabel) {
        Context ctx = requireContext();
        SharedPreferences prefs = ctx.getSharedPreferences(
                AlarmReceiver.PREFS, Context.MODE_PRIVATE);
        prefs.edit()
                .putString("queue", queueJson)
                .putString("channel", channelName)
                .putString("dismiss", dismissLabel)
                .commit();
        Intent intent = new Intent(AlarmReceiver.ACTION_RESCHEDULE);
        intent.setClassName(ctx.getPackageName(), AlarmReceiver.class.getName());
        ctx.sendBroadcast(intent);
        return true;
    }

    // -- morning brief ------------------------------------------------------------

    private boolean setMorningBriefs(String queueJson, String channelName) {
        Context ctx = requireContext();
        SharedPreferences prefs = ctx.getSharedPreferences(
                BriefReceiver.PREFS, Context.MODE_PRIVATE);
        prefs.edit()
                .putString("queue", queueJson)
                .putString("channel", channelName)
                .commit();
        Intent intent = new Intent(BriefReceiver.ACTION_RESCHEDULE);
        intent.setClassName(ctx.getPackageName(), BriefReceiver.class.getName());
        ctx.sendBroadcast(intent);
        return true;
    }

    private boolean exactAlarmsAllowed() {
        if (Build.VERSION.SDK_INT < 31) {
            return true;
        }
        AlarmManager alarms = requireContext().getSystemService(AlarmManager.class);
        return alarms == null || alarms.canScheduleExactAlarms();
    }

    private void openExactAlarmSettings() {
        if (Build.VERSION.SDK_INT < 31) {
            return;
        }
        Context ctx = requireContext();
        Intent intent = new Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                Uri.parse("package:" + ctx.getPackageName()));
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        ctx.startActivity(intent);
    }

    // Python's weekday (Monday = 0) -> java.util.Calendar's (Sunday = 1).
    private static final int[] CALENDAR_DAYS = {2, 3, 4, 5, 6, 7, 1};

    private boolean openSystemAlarm(
            int hour, int minute, String message, @Nullable Integer weekday) {
        Context ctx = requireContext();
        Bundle extras = new Bundle();
        extras.putInt(AlarmClock.EXTRA_HOUR, hour);
        extras.putInt(AlarmClock.EXTRA_MINUTES, minute);
        extras.putString(AlarmClock.EXTRA_MESSAGE, message);
        extras.putBoolean(AlarmClock.EXTRA_SKIP_UI, false);
        if (weekday != null) {
            ArrayList<Integer> days = new ArrayList<>(1);
            days.add(CALENDAR_DAYS[weekday % 7]);
            extras.putIntegerArrayList(AlarmClock.EXTRA_DAYS, days);
        }
        Intent setAlarm = new Intent(AlarmClock.ACTION_SET_ALARM);
        setAlarm.putExtras(extras);
        setAlarm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            ctx.startActivity(setAlarm);
            return true;
        } catch (RuntimeException e) {
            // No Clock app takes a new alarm: at least show the alarm list.
            try {
                Intent show = new Intent(AlarmClock.ACTION_SHOW_ALARMS);
                show.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                ctx.startActivity(show);
                return true;
            } catch (RuntimeException ignored) {
                return false;
            }
        }
    }

    // -- home-screen timetable widget ----------------------------------------------

    private boolean updateTimetableWidget(String payloadJson) {
        Context ctx = requireContext();
        ctx.getSharedPreferences(TimetableWidgetProvider.PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString("payload", payloadJson)
                .commit();
        Intent intent = new Intent(ACTION_REFRESH_WIDGET);
        intent.setClassName(ctx.getPackageName(),
                TimetableWidgetProvider.class.getName());
        ctx.sendBroadcast(intent);
        return true;
    }

    // -- Android Keystore (protects the password key) ------------------------------
    //
    // Identical to core/android.py: alias "strakalari-secret-key",
    // AES/GCM/NoPadding, a 12-byte IV prefix. The key never leaves the
    // secure hardware and is lost when the app is uninstalled (then the
    // Dart side quarantines the wrapped blob and starts over, like Python).

    private javax.crypto.SecretKey keystoreKey() throws Exception {
        KeyStore keystore = KeyStore.getInstance("AndroidKeyStore");
        keystore.load(null);
        if (keystore.containsAlias(KEYSTORE_ALIAS)) {
            KeyStore.Entry entry = keystore.getEntry(KEYSTORE_ALIAS, null);
            if (entry instanceof KeyStore.SecretKeyEntry) {
                return ((KeyStore.SecretKeyEntry) entry).getSecretKey();
            }
        }
        KeyGenerator generator = KeyGenerator.getInstance(
                "AES", "AndroidKeyStore");
        android.security.keystore.KeyGenParameterSpec spec =
                new android.security.keystore.KeyGenParameterSpec.Builder(
                        KEYSTORE_ALIAS,
                        android.security.keystore.KeyProperties.PURPOSE_ENCRYPT
                                | android.security.keystore.KeyProperties.PURPOSE_DECRYPT)
                        .setBlockModes(android.security.keystore.KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(
                                android.security.keystore.KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setKeySize(256)
                        .build();
        generator.init(spec);
        return generator.generateKey();
    }

    private byte[] keystoreWrap(byte[] data) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, keystoreKey());
        byte[] iv = cipher.getIV();
        byte[] out = cipher.doFinal(data);
        byte[] blob = new byte[iv.length + out.length];
        System.arraycopy(iv, 0, blob, 0, iv.length);
        System.arraycopy(out, 0, blob, iv.length, out.length);
        return blob;
    }

    private byte[] keystoreUnwrap(byte[] blob) throws Exception {
        if (blob.length < 12 + 16) {
            throw new IllegalArgumentException("wrapped key too short");
        }
        byte[] iv = new byte[12];
        byte[] cipherText = new byte[blob.length - 12];
        System.arraycopy(blob, 0, iv, 0, 12);
        System.arraycopy(blob, 12, cipherText, 0, cipherText.length);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, keystoreKey(),
                new GCMParameterSpec(128, iv));
        return cipher.doFinal(cipherText);
    }

    /**
     * Classifies the active network as {@code "unmetered"} (Wi-Fi / unmetered
     * Ethernet), {@code "metered"} (mobile data / metered hotspot), or
     * {@code "unknown"} (F6 §7.1). Used only for polling cadence, never to
     * block a refresh.
     */
    private String networkKind() {
        try {
            ConnectivityManager cm = (ConnectivityManager) requireContext()
                    .getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm == null) {
                return "unknown";
            }
            Network net = cm.getActiveNetwork();
            if (net == null) {
                return "unknown";
            }
            NetworkCapabilities caps = cm.getNetworkCapabilities(net);
            if (caps == null) {
                return "unknown";
            }
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                return "unknown";
            }
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) {
                return "unmetered";
            }
            return "metered";
        } catch (Exception e) {
            return "unknown";
        }
    }
}
