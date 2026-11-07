package io.github.dendlerx.strakalari.android;

import android.app.Notification;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

/**
 * Background running: while this foreground service runs, Android neither
 * freezes nor kills the app's process, so the embedded Python and its
 * refresh scheduler keep working after the user leaves (or swipes away)
 * the app, with network access even in Doze. WakeReceiver wakes the CPU
 * when a refresh is due.
 *
 * Started and stopped from Python; the start intent carries the texts in
 * the app's language: the ongoing notification ("title", "text", "sub",
 * "rows", "channel") and the reminder BootReceiver shows after a reboot or
 * an update ("boot_title", "boot_text", "events_channel").
 *
 * The ongoing notification doubles as an overview (the next lesson, today's
 * lunch, …: strakalari/core/status_notification.py), its rows drawn by
 * {@link StatusViews}. Python keeps it current through {@link StatusReceiver},
 * which redraws it in place with {@link #update}; the texts are kept, so a
 * restart shows the latest ones.
 */
public class KeepAliveService extends Service {
    static final String CHANNEL_ID = "strakalari_background";
    static final int NOTIFICATION_ID = 7301;
    static final String PREFS = "strakalari_background";
    private static final String[] NOTIFICATION_KEYS = {"title", "text", "sub", "rows", "channel"};
    private static final String[] BOOT_KEYS = {"boot_title", "boot_text", "events_channel"};

    /** True between the start and the end of this service (in this process). */
    private static volatile boolean running;

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        SharedPreferences.Editor prefs = getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                .putBoolean("enabled", true);
        for (String[] keys : new String[][] {NOTIFICATION_KEYS, BOOT_KEYS}) {
            for (String key : keys) {
                String value = intent != null ? intent.getStringExtra(key) : null;
                if (value != null) {
                    prefs.putString(key, value);
                }
            }
        }
        prefs.commit(); // the notification below is built from it
        Notification notification = notification(this);
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }
        running = true;
        // The process now stays: the widget can catch a missed day change on screen-on.
        TimetableWidgetProvider.watchScreen(this);
        // Not sticky: recreated without the app, no Python would run behind
        // the notification. After a kill the user reopens the app instead.
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        running = false;
        // Stopped on purpose (switched off in the app): no reboot reminder.
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putBoolean("enabled", false).apply();
        super.onDestroy();
    }

    @Override
    public void onTimeout(int startId, int fgsType) {
        // Android 15+ time limits (none apply to specialUse): stop cleanly.
        stopSelf();
    }

    /**
     * Saves new notification texts and, while the service runs, redraws its
     * notification in place (posting under the service's id updates it; no
     * new start, which Android 12+ may refuse from the background).
     */
    static void update(Context ctx, String title, String text, String sub, String rows) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("title", title != null ? title : "")
                .putString("text", text != null ? text : "")
                .putString("sub", sub != null ? sub : "")
                .putString("rows", rows != null ? rows : "")
                .commit();
        if (!running) {
            return; // shown with these texts at the next start
        }
        NotificationManager nm = ctx.getSystemService(NotificationManager.class);
        if (nm != null) {
            nm.notify(NOTIFICATION_ID, notification(ctx));
        }
    }

    /**
     * The ongoing notification with the saved texts: the overview's rows in
     * the app's own layout, the plain title and text without rows.
     */
    static Notification notification(Context ctx) {
        SharedPreferences prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        String title = prefs.getString("title", "");
        Notification.Builder b = Notifications.builder(
                ctx, CHANNEL_ID, prefs.getString("channel", "Background"),
                NotificationManager.IMPORTANCE_LOW,
                title.isEmpty() ? "Strakaláři" : title,
                prefs.getString("text", ""), prefs.getString("sub", ""), true);
        StatusViews.apply(ctx, b, prefs.getString("rows", ""));
        return b.build();
    }
}
