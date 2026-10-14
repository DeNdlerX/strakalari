package io.github.dendlerx.strakalari.android;

import android.app.NotificationManager;
import android.app.Service;
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
 * the app's language: the ongoing notification ("title", "text",
 * "channel") and the reminder BootReceiver shows after a reboot or an
 * update ("boot_title", "boot_text", "events_channel").
 */
public class KeepAliveService extends Service {
    static final String CHANNEL_ID = "strakalari_background";
    static final int NOTIFICATION_ID = 7301;
    static final String PREFS = "strakalari_background";

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String title = extra(intent, "title", "Strakaláři");
        String text = extra(intent, "text", "");
        android.app.Notification notification = Notifications.build(
                this, CHANNEL_ID, extra(intent, "channel", "Background"),
                NotificationManager.IMPORTANCE_LOW, title, text, true);
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }
        SharedPreferences.Editor prefs = getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                .putBoolean("enabled", true);
        for (String key : new String[] {"boot_title", "boot_text", "events_channel"}) {
            String value = intent != null ? intent.getStringExtra(key) : null;
            if (value != null) {
                prefs.putString(key, value);
            }
        }
        prefs.apply();
        // Not sticky: recreated without the app, no Python would run behind
        // the notification. After a kill the user reopens the app instead.
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        // Stopped on purpose (switched off in the app): no reboot reminder.
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putBoolean("enabled", false).apply();
        super.onDestroy();
    }

    @Override
    public void onTimeout(int startId, int fgsType) {
        // Android 15+ time limits (none apply to specialUse): stop cleanly.
        stopSelf();
    }

    private static String extra(Intent intent, String key, String fallback) {
        String value = intent != null ? intent.getStringExtra(key) : null;
        return value != null ? value : fallback;
    }
}
