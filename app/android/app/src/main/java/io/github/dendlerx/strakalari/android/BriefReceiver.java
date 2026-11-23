package io.github.dendlerx.strakalari.android;

import android.app.AlarmManager;
import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/**
 * The morning brief: on every school day at the time the user set, a
 * regular notification with the day's overview, drawn like the background
 * notification's ({@link StatusViews}).
 *
 * <p>Dart (strakalari_core/lib/src/morning_brief.dart) saves the briefs of
 * the next two weeks as a JSON queue ({@code at}, {@code until},
 * {@code title}, {@code text}, {@code sub}, {@code rows}) and sends
 * {@link #ACTION_RESCHEDULE}. From then on this receiver runs them by
 * itself, like {@link AlarmReceiver}: it arms the earliest brief, and each
 * one posted (and a reboot or app update, see {@link BootReceiver}) arms
 * the next.
 *
 * <p>Each brief is posted once. One the phone delivers past its
 * {@code until} (it was off) is dropped. A new queue never arms a brief
 * that was due before it came, except the one already armed (a delivery
 * running late must not drop out because a refresh handed over a new
 * queue meanwhile).
 */
public class BriefReceiver extends BroadcastReceiver {
    static final String PREFS = "strakalari_brief";
    static final String ACTION_FIRE =
            "io.github.dendlerx.strakalari.android.ACTION_MORNING_BRIEF";
    static final String ACTION_RESCHEDULE =
            "io.github.dendlerx.strakalari.android.ACTION_RESCHEDULE_BRIEF";
    static final String CHANNEL_ID = "strakalari_morning_brief";
    static final int NOTIFICATION_ID = 7320;
    static final int REQUEST_FIRE = 7320;

    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent != null ? intent.getAction() : null;
        if (ACTION_FIRE.equals(action)) {
            fire(context, intent.getLongExtra("at", 0L));
            scheduleNext(context);
        } else if (ACTION_RESCHEDULE.equals(action)) {
            scheduleNext(context);
        }
    }

    private static void fire(Context ctx, long at) {
        SharedPreferences prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        if (at <= 0 || at <= prefs.getLong("fired", 0L)) {
            return; // posted already
        }
        prefs.edit().putLong("fired", at).putLong("armed", 0L).commit();
        JSONObject entry = entryAt(prefs, at);
        if (entry == null || System.currentTimeMillis() >= entry.optLong("until", at)) {
            return; // taken out of the queue meanwhile, or too late
        }
        post(ctx, prefs.getString("channel", "Morning brief"), entry);
    }

    private static void post(Context ctx, String channelName, JSONObject entry) {
        NotificationManager nm = ctx.getSystemService(NotificationManager.class);
        if (nm == null) {
            return;
        }
        Notification.Builder b = Notifications.builder(ctx, CHANNEL_ID, channelName,
                NotificationManager.IMPORTANCE_DEFAULT,
                entry.optString("title", "Strakaláři"), entry.optString("text", ""),
                entry.optString("sub", ""), false, "today");
        StatusViews.apply(ctx, b, entry.optString("rows", ""));
        nm.notify(NOTIFICATION_ID, b.build());
    }

    /** Arms the next brief to post; cancels the pending one when none is left. */
    static void scheduleNext(Context ctx) {
        AlarmManager alarms = ctx.getSystemService(AlarmManager.class);
        if (alarms == null) {
            return;
        }
        SharedPreferences prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        JSONObject next = nextEntry(prefs, System.currentTimeMillis());
        Intent fire = new Intent(ACTION_FIRE);
        fire.setClassName(ctx.getPackageName(), BriefReceiver.class.getName());
        if (next == null) {
            alarms.cancel(PendingIntent.getBroadcast(ctx, REQUEST_FIRE, fire,
                    PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT));
            prefs.edit().putLong("armed", 0L).commit();
            return;
        }
        long at = next.optLong("at", 0L);
        fire.putExtra("at", at);
        PendingIntent op = PendingIntent.getBroadcast(ctx, REQUEST_FIRE, fire,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        prefs.edit().putLong("armed", at).commit();
        if (AlarmReceiver.exactAllowed(alarms)) {
            try {
                alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, op);
                return;
            } catch (SecurityException ignored) {
                // Permission withdrawn meanwhile: the inexact alarm below.
            }
        }
        alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, op);
    }

    /**
     * The earliest brief not posted yet and not stale: still ahead, or the
     * armed one running late.
     */
    private static JSONObject nextEntry(SharedPreferences prefs, long now) {
        long fired = prefs.getLong("fired", 0L);
        long armed = prefs.getLong("armed", 0L);
        JSONObject best = null;
        for (JSONObject entry : queue(prefs)) {
            long at = entry.optLong("at", 0L);
            if (at <= fired || now >= entry.optLong("until", at)) {
                continue;
            }
            if (at <= now && at != armed) {
                continue;
            }
            if (best == null || at < best.optLong("at", 0L)) {
                best = entry;
            }
        }
        return best;
    }

    private static JSONObject entryAt(SharedPreferences prefs, long at) {
        for (JSONObject entry : queue(prefs)) {
            if (entry.optLong("at", 0L) == at) {
                return entry;
            }
        }
        return null;
    }

    private static List<JSONObject> queue(SharedPreferences prefs) {
        List<JSONObject> out = new ArrayList<>();
        String raw = prefs.getString("queue", null);
        if (raw == null || raw.isEmpty()) {
            return out;
        }
        try {
            JSONArray array = new JSONArray(raw);
            for (int i = 0; i < array.length(); i++) {
                JSONObject entry = array.optJSONObject(i);
                if (entry != null) {
                    out.add(entry);
                }
            }
        } catch (Exception ignored) {
            out.clear();
        }
        return out;
    }
}
