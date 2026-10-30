package io.github.dendlerx.strakalari.android;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

/**
 * Notifications with the app's status bar icon; a tap opens the app.
 * Called from Python through pyjnius (strakalari/core/android.py) and by
 * the background service and the boot receiver.
 */
public final class Notifications {
    private Notifications() {}

    /** Posts (or replaces) notification {@code id} on {@code channelId}. */
    public static void show(Context ctx, String channelId, String channelName,
                            String title, String text, int id) {
        NotificationManager nm = ctx.getSystemService(NotificationManager.class);
        if (nm == null) {
            return;
        }
        nm.notify(id, build(ctx, channelId, channelName,
                NotificationManager.IMPORTANCE_DEFAULT, title, text, false));
    }

    /** False when the user turned the app's notifications off (or never allowed them). */
    public static boolean enabled(Context ctx) {
        NotificationManager nm = ctx.getSystemService(NotificationManager.class);
        return nm != null && nm.areNotificationsEnabled();
    }

    static Notification build(Context ctx, String channelId, String channelName,
                              int importance, String title, String text, boolean ongoing) {
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager nm = ctx.getSystemService(NotificationManager.class);
            if (nm != null) {
                nm.createNotificationChannel(
                        new NotificationChannel(channelId, channelName, importance));
            }
        }
        Notification.Builder b = Build.VERSION.SDK_INT >= 26
                ? new Notification.Builder(ctx, channelId)
                : new Notification.Builder(ctx);
        b.setSmallIcon(R.drawable.ic_stat_strakalari)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(new Notification.BigTextStyle().bigText(text))
                .setOngoing(ongoing)
                .setAutoCancel(!ongoing)
                .setShowWhen(!ongoing);
        PendingIntent open = openApp(ctx);
        if (open != null) {
            b.setContentIntent(open);
        }
        if (Build.VERSION.SDK_INT < 26) {
            b.setPriority(ongoing ? Notification.PRIORITY_MIN : Notification.PRIORITY_DEFAULT);
        }
        return b.build();
    }

    /** Opens the app (a notification tap, the alarm clock icon). */
    static PendingIntent openApp(Context ctx) {
        Intent launch = ctx.getPackageManager().getLaunchIntentForPackage(ctx.getPackageName());
        if (launch == null) {
            return null;
        }
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        return PendingIntent.getActivity(ctx, 0, launch,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }
}
