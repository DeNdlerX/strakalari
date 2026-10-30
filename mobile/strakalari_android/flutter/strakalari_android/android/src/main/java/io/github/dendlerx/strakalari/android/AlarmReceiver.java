package io.github.dendlerx.strakalari.android;

import android.app.AlarmManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.media.AudioAttributes;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Build;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Wake-up alarm before the first lesson.
 *
 * <p>Python (strakalari/core/wakeup.py) saves the alarms of the next two
 * weeks as a JSON queue and sends {@link #ACTION_RESCHEDULE}. From then on
 * this receiver runs them by itself: it arms the earliest one, and each ring
 * (and a reboot or app update, see {@link BootReceiver}) arms the next, so
 * the alarm keeps ringing on days the app is never opened.
 *
 * <p>The ring is an insistent alarm notification: the system plays the
 * alarm sound on the alarm stream, repeating with the vibration, until the
 * notification is dismissed or opened (or {@link #RING_MS} passes). No app
 * process has to stay alive while it rings.
 */
public class AlarmReceiver extends BroadcastReceiver {
    static final String PREFS = "strakalari_alarm";
    static final String ACTION_FIRE =
            "io.github.dendlerx.strakalari.android.ACTION_WAKEUP_ALARM";
    static final String ACTION_DISMISS =
            "io.github.dendlerx.strakalari.android.ACTION_DISMISS_ALARM";
    static final String ACTION_RESCHEDULE =
            "io.github.dendlerx.strakalari.android.ACTION_RESCHEDULE_ALARM";
    // A channel's sound and vibration can't change once created, so a new
    // look gets a new id (test builds created "strakalari_wakeup").
    static final String CHANNEL_ID = "strakalari_wakeup_alarm";
    static final int NOTIFICATION_ID = 7303;
    static final int REQUEST_FIRE = 7303;
    static final int REQUEST_DISMISS = 7304;
    /** Rings at most this long, like a clock app's auto-silence. */
    static final long RING_MS = 10 * 60 * 1000L;
    private static final long[] VIBRATION = {0, 600, 400, 600, 400, 600, 1500};

    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent != null ? intent.getAction() : null;
        if (ACTION_DISMISS.equals(action)) {
            NotificationManager nm = context.getSystemService(NotificationManager.class);
            if (nm != null) {
                nm.cancel(NOTIFICATION_ID);
            }
            return;
        }
        long now = System.currentTimeMillis();
        if (ACTION_FIRE.equals(action)) {
            long lessonMs = intent.getLongExtra("lesson", 0L);
            // Delivered after the lesson began (phone was off, inexact
            // fallback): that is no wake-up any more, so stay quiet.
            if (lessonMs <= 0 || now < lessonMs) {
                ring(context, intent.getStringExtra("title"), intent.getStringExtra("text"));
            }
            // Never re-arm the alarm that just rang.
            now = Math.max(now, intent.getLongExtra("at", 0L));
            scheduleNext(context, now);
        } else if (ACTION_RESCHEDULE.equals(action)) {
            scheduleNext(context, now);
        }
    }

    /** Arms the earliest queued alarm still ahead; cancels the pending one when none is. */
    static void scheduleNext(Context ctx) {
        scheduleNext(ctx, System.currentTimeMillis());
    }

    private static void scheduleNext(Context ctx, long after) {
        AlarmManager alarms = ctx.getSystemService(AlarmManager.class);
        if (alarms == null) {
            return;
        }
        JSONObject next = nextEntry(ctx, after);
        Intent fire = new Intent(ACTION_FIRE);
        fire.setClassName(ctx.getPackageName(), AlarmReceiver.class.getName());
        if (next == null) {
            alarms.cancel(PendingIntent.getBroadcast(ctx, REQUEST_FIRE, fire,
                    PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT));
            return;
        }
        long at = next.optLong("at", 0L);
        fire.putExtra("at", at);
        fire.putExtra("lesson", next.optLong("lesson", 0L));
        fire.putExtra("title", next.optString("title", "Strakaláři"));
        fire.putExtra("text", next.optString("text", ""));
        PendingIntent op = PendingIntent.getBroadcast(ctx, REQUEST_FIRE, fire,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        if (exactAllowed(alarms)) {
            try {
                alarms.setAlarmClock(
                        new AlarmManager.AlarmClockInfo(at, Notifications.openApp(ctx)), op);
                return;
            } catch (SecurityException ignored) {
                // Permission withdrawn meanwhile: the inexact alarm below.
            }
        }
        alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, op);
    }

    /** Android 12+ lets the user withhold exact alarms ("Alarms & reminders"). */
    static boolean exactAllowed(AlarmManager alarms) {
        return Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms();
    }

    private static JSONObject nextEntry(Context ctx, long after) {
        SharedPreferences prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        String raw = prefs.getString("queue", null);
        if (raw == null || raw.isEmpty()) {
            return null;
        }
        JSONObject best = null;
        try {
            JSONArray queue = new JSONArray(raw);
            for (int i = 0; i < queue.length(); i++) {
                JSONObject entry = queue.optJSONObject(i);
                if (entry == null) {
                    continue;
                }
                long at = entry.optLong("at", 0L);
                if (at > after && (best == null || at < best.optLong("at", 0L))) {
                    best = entry;
                }
            }
        } catch (Exception ignored) {
            return null;
        }
        return best;
    }

    private static void ring(Context ctx, String title, String text) {
        NotificationManager nm = ctx.getSystemService(NotificationManager.class);
        if (nm == null) {
            return;
        }
        SharedPreferences prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        Uri sound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM);
        if (sound == null) {
            sound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE);
        }
        AudioAttributes alarmAudio = new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build();
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel ch = new NotificationChannel(CHANNEL_ID,
                    prefs.getString("channel", "Wake-up alarm"),
                    NotificationManager.IMPORTANCE_HIGH);
            ch.setSound(sound, alarmAudio);
            ch.enableVibration(true);
            ch.setVibrationPattern(VIBRATION);
            ch.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
            nm.createNotificationChannel(ch);
        }
        Intent dismissIntent = new Intent(ACTION_DISMISS);
        dismissIntent.setClassName(ctx.getPackageName(), AlarmReceiver.class.getName());
        PendingIntent dismiss = PendingIntent.getBroadcast(ctx, REQUEST_DISMISS, dismissIntent,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);

        Notification.Builder b = Build.VERSION.SDK_INT >= 26
                ? new Notification.Builder(ctx, CHANNEL_ID)
                : new Notification.Builder(ctx);
        String body = text != null ? text : "";
        b.setSmallIcon(R.drawable.ic_stat_strakalari)
                .setContentTitle(title != null ? title : "Strakaláři")
                .setContentText(body)
                .setStyle(new Notification.BigTextStyle().bigText(body))
                .setCategory(Notification.CATEGORY_ALARM)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setAutoCancel(true)
                .addAction(new Notification.Action.Builder(R.drawable.ic_stat_strakalari,
                        prefs.getString("dismiss", "Dismiss"), dismiss).build());
        PendingIntent open = Notifications.openApp(ctx);
        if (open != null) {
            b.setContentIntent(open);
        }
        if (Build.VERSION.SDK_INT >= 26) {
            b.setTimeoutAfter(RING_MS);
        } else {
            b.setPriority(Notification.PRIORITY_MAX)
                    .setSound(sound, alarmAudio)
                    .setVibrate(VIBRATION);
        }
        Notification n = b.build();
        // Repeat sound and vibration until the user reacts.
        n.flags |= Notification.FLAG_INSISTENT;
        nm.notify(NOTIFICATION_ID, n);
    }
}
