package io.github.dendlerx.strakalari.android;

import io.github.dendlerx.strakalari.R;

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
    static final String EXTRA_ROUTE = "strakalari_route";

    private Notifications() {}

    /** Posts (or replaces) notification {@code id} on {@code channelId}. */
    public static void show(Context ctx, String channelId, String channelName,
                            String title, String text, int id) {
        show(ctx, channelId, channelName, title, text, id, "today");
    }

    /** Posts (or replaces) notification {@code id} opening {@code route} on tap. */
    public static void show(Context ctx, String channelId, String channelName,
                            String title, String text, int id, String route) {
        NotificationManager nm = ctx.getSystemService(NotificationManager.class);
        if (nm == null) {
            return;
        }
        nm.notify(id, build(ctx, channelId, channelName,
                NotificationManager.IMPORTANCE_DEFAULT, title, text, "", false, route));
    }

    /** False when the user turned the app's notifications off (or never allowed them). */
    public static boolean enabled(Context ctx) {
        NotificationManager nm = ctx.getSystemService(NotificationManager.class);
        return nm != null && nm.areNotificationsEnabled();
    }

    static Notification build(Context ctx, String channelId, String channelName,
                              int importance, String title, String text, boolean ongoing) {
        return build(ctx, channelId, channelName, importance, title, text, "", ongoing, "today");
    }

    static Notification build(Context ctx, String channelId, String channelName, int importance,
                              String title, String text, String sub, boolean ongoing) {
        return build(ctx, channelId, channelName, importance, title, text, sub, ongoing, "today");
    }

    static Notification build(Context ctx, String channelId, String channelName, int importance,
                              String title, String text, String sub, boolean ongoing,
                              String route) {
        return builder(ctx, channelId, channelName, importance, title, text, sub, ongoing, route)
                .build();
    }

    /**
     * {@code sub}: the small text in the header next to the app name (none
     * when empty). An ongoing notification never alerts again on a redraw.
     * The text shows in full when expanded ({@code BigTextStyle}), unless the
     * caller sets another style.
     */
    static Notification.Builder builder(Context ctx, String channelId, String channelName,
                                        int importance, String title, String text, String sub,
                                        boolean ongoing) {
        return builder(ctx, channelId, channelName, importance, title, text, sub, ongoing, "today");
    }

    static Notification.Builder builder(Context ctx, String channelId, String channelName,
                                        int importance, String title, String text, String sub,
                                        boolean ongoing, String route) {
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
                .setOnlyAlertOnce(ongoing)
                .setAutoCancel(!ongoing)
                .setShowWhen(!ongoing);
        if (sub != null && !sub.isEmpty()) {
            b.setSubText(sub);
        }
        PendingIntent open = openApp(ctx, route);
        if (open != null) {
            b.setContentIntent(open);
        }
        if (Build.VERSION.SDK_INT < 26) {
            b.setPriority(ongoing ? Notification.PRIORITY_MIN : Notification.PRIORITY_DEFAULT);
        }
        return b;
    }

    /** Distinct deterministic requestCode per target route so PendingIntents never collide. */
    private static int requestCodeForRoute(String route) {
        switch (route) {
            case "today":
                return 101;
            case "timetable":
                return 102;
            case "absences":
                return 103;
            case "absences/plan":
                return 104;
            case "absences/limits":
                return 105;
            case "marks":
                return 106;
            case "lunches":
                return 107;
            case "activity":
                return 108;
            case "settings":
                return 109;
            case "alarm":
                return 110;
            default:
                return 1000 + (route.hashCode() & 0x7fff);
        }
    }

    /** Opens the app on Today (compatibility overload). */
    static PendingIntent openApp(Context ctx) {
        return openApp(ctx, "today");
    }

    /** Opens the app on {@code route} (notification tap, alarm clock icon, widget). */
    static PendingIntent openApp(Context ctx, String route) {
        Intent launch = ctx.getPackageManager().getLaunchIntentForPackage(ctx.getPackageName());
        if (launch == null) {
            return null;
        }
        String target = (route == null || route.isEmpty()) ? "today" : route;
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
                | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        launch.putExtra(EXTRA_ROUTE, target);
        return PendingIntent.getActivity(ctx, requestCodeForRoute(target), launch,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }
}
