package io.github.dendlerx.strakalari.android;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.widget.RemoteViews;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.Calendar;
import java.util.Locale;

/**
 * Home-screen widget: one school day's lessons as a list, free periods as
 * empty slots, ‹ › to step through the days and a tap on the date to go
 * back to the default day.
 *
 * <p>Python (strakalari/core/wakeup.py) hands over dates and clock times
 * only. Which day is "today", the day to show and the running lesson are
 * worked out here from the clock, and a refresh is armed for today's next
 * lesson start / end and for midnight, so the widget stays right while the
 * app is closed. A day picked with ‹ › holds until the date changes.
 */
public class TimetableWidgetProvider extends AppWidgetProvider {
    static final String PREFS = "strakalari_widget";
    static final String ACTION_REFRESH =
            "io.github.dendlerx.strakalari.android.ACTION_REFRESH_WIDGET";
    static final String ACTION_PREV_DAY =
            "io.github.dendlerx.strakalari.android.ACTION_WIDGET_PREV_DAY";
    static final String ACTION_NEXT_DAY =
            "io.github.dendlerx.strakalari.android.ACTION_WIDGET_NEXT_DAY";
    static final String ACTION_TODAY =
            "io.github.dendlerx.strakalari.android.ACTION_WIDGET_TODAY";
    static final String EXTRA_WIDGET_ID = "app_widget_id";
    private static final int REQUEST_OPEN = 7310;
    private static final int REQUEST_TICK = 7311;

    @Override
    public void onReceive(Context context, Intent intent) {
        super.onReceive(context, intent);
        String action = intent != null ? intent.getAction() : null;
        if (ACTION_REFRESH.equals(action)
                || Intent.ACTION_TIME_CHANGED.equals(action)
                || Intent.ACTION_TIMEZONE_CHANGED.equals(action)) {
            refreshAll(context);
        } else if (ACTION_PREV_DAY.equals(action)
                || ACTION_NEXT_DAY.equals(action)
                || ACTION_TODAY.equals(action)) {
            int widgetId = intent.getIntExtra(
                    EXTRA_WIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID);
            if (widgetId != AppWidgetManager.INVALID_APPWIDGET_ID) {
                pickDay(context, widgetId, action);
            }
        }
    }

    @Override
    public void onUpdate(Context context, AppWidgetManager mgr, int[] appWidgetIds) {
        for (int widgetId : appWidgetIds) {
            updateWidget(context, mgr, widgetId);
        }
        mgr.notifyAppWidgetViewDataChanged(appWidgetIds, R.id.widget_list);
        scheduleTick(context);
    }

    @Override
    public void onDeleted(Context context, int[] appWidgetIds) {
        SharedPreferences.Editor ed = prefs(context).edit();
        for (int id : appWidgetIds) {
            ed.remove("pick_day_" + id).remove("pick_on_" + id);
        }
        ed.apply();
    }

    @Override
    public void onDisabled(Context context) {
        AlarmManager alarms = context.getSystemService(AlarmManager.class);
        if (alarms != null) {
            alarms.cancel(tickIntent(context));
        }
    }

    /** Redraws every placed widget and arms the next refresh. */
    public static void refreshAll(Context context) {
        AppWidgetManager mgr = AppWidgetManager.getInstance(context);
        if (mgr == null) {
            return;
        }
        int[] ids = mgr.getAppWidgetIds(new ComponentName(context, TimetableWidgetProvider.class));
        if (ids == null || ids.length == 0) {
            return;
        }
        for (int id : ids) {
            updateWidget(context, mgr, id);
        }
        mgr.notifyAppWidgetViewDataChanged(ids, R.id.widget_list);
        scheduleTick(context);
    }

    private static void pickDay(Context context, int widgetId, String action) {
        SharedPreferences prefs = prefs(context);
        SharedPreferences.Editor ed = prefs.edit();
        JSONObject payload = parsePayload(prefs);
        JSONArray days = payload != null ? payload.optJSONArray("days") : null;
        if (ACTION_TODAY.equals(action) || days == null || days.length() == 0) {
            ed.remove("pick_day_" + widgetId).remove("pick_on_" + widgetId);
        } else {
            int step = ACTION_PREV_DAY.equals(action) ? -1 : 1;
            int idx = clamp(dayIndex(prefs, days, widgetId) + step, 0, days.length() - 1);
            JSONObject day = days.optJSONObject(idx);
            ed.putString("pick_day_" + widgetId, day != null ? day.optString("iso") : "")
                    .putString("pick_on_" + widgetId, isoDay(0));
        }
        ed.commit(); // the list's factory reads it right below
        AppWidgetManager mgr = AppWidgetManager.getInstance(context);
        if (mgr != null) {
            updateWidget(context, mgr, widgetId);
            mgr.notifyAppWidgetViewDataChanged(widgetId, R.id.widget_list);
        }
    }

    static void updateWidget(Context context, AppWidgetManager mgr, int widgetId) {
        SharedPreferences prefs = prefs(context);
        JSONObject payload = parsePayload(prefs);
        RemoteViews views = new RemoteViews(context.getPackageName(), R.layout.timetable_widget);

        String title = "Strakaláři";
        String subtitle = "";
        String empty = context.getString(R.string.strakalari_widget_no_data);
        if (payload != null) {
            empty = payload.optString("empty", empty);
            JSONObject day = shownDay(prefs, payload, widgetId);
            if (day != null) {
                title = dayTitle(payload, day);
                subtitle = day.optString("subtitle", "");
            }
        }
        views.setTextViewText(R.id.widget_day_title, title);
        views.setTextViewText(R.id.widget_day_subtitle, subtitle);
        views.setTextViewText(R.id.widget_empty, empty);

        views.setOnClickPendingIntent(
                R.id.widget_prev_btn, navBroadcast(context, widgetId, ACTION_PREV_DAY, 1));
        views.setOnClickPendingIntent(
                R.id.widget_next_btn, navBroadcast(context, widgetId, ACTION_NEXT_DAY, 2));
        views.setOnClickPendingIntent(
                R.id.widget_day_title, navBroadcast(context, widgetId, ACTION_TODAY, 3));

        PendingIntent openApp = openAppIntent(context);
        if (openApp != null) {
            views.setOnClickPendingIntent(R.id.widget_day_subtitle, openApp);
            views.setOnClickPendingIntent(R.id.widget_empty, openApp);
            views.setPendingIntentTemplate(R.id.widget_list, openApp);
        }

        Intent svc = new Intent(context, TimetableWidgetService.class);
        svc.putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId);
        // A distinct data URI per widget: otherwise every widget shares one list factory.
        svc.setData(Uri.parse(svc.toUri(Intent.URI_INTENT_SCHEME)));
        views.setRemoteAdapter(R.id.widget_list, svc);
        views.setEmptyView(R.id.widget_list, R.id.widget_empty);

        mgr.updateAppWidget(widgetId, views);
    }

    static SharedPreferences prefs(Context ctx) {
        return ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    static JSONObject parsePayload(SharedPreferences prefs) {
        String raw = prefs.getString("payload", null);
        if (raw == null || raw.isEmpty()) {
            return null;
        }
        try {
            return new JSONObject(raw);
        } catch (Exception ignored) {
            return null;
        }
    }

    /** The day a widget shows: the one picked with ‹ › today, else the default day. */
    static JSONObject shownDay(SharedPreferences prefs, JSONObject payload, int widgetId) {
        JSONArray days = payload.optJSONArray("days");
        if (days == null || days.length() == 0) {
            return null;
        }
        return days.optJSONObject(dayIndex(prefs, days, widgetId));
    }

    static int dayIndex(SharedPreferences prefs, JSONArray days, int widgetId) {
        String today = isoDay(0);
        if (today.equals(prefs.getString("pick_on_" + widgetId, ""))) {
            String picked = prefs.getString("pick_day_" + widgetId, "");
            for (int i = 0; i < days.length(); i++) {
                JSONObject day = days.optJSONObject(i);
                if (day != null && picked.equals(day.optString("iso"))) {
                    return i;
                }
            }
        }
        return defaultIndex(days, today, minuteOfDay());
    }

    /**
     * The school day still ahead: today until its last lesson ends, else the
     * next day with lessons. Without one: today, else the first day after it,
     * else the last day.
     */
    static int defaultIndex(JSONArray days, String today, int nowMin) {
        int fallback = -1;
        for (int i = 0; i < days.length(); i++) {
            JSONObject day = days.optJSONObject(i);
            if (day == null) {
                continue;
            }
            int cmp = day.optString("iso").compareTo(today);
            if (cmp < 0) {
                continue;
            }
            if (fallback < 0) {
                fallback = i;
            }
            if (day.optInt("taught", 0) <= 0 || day.optBoolean("free", false)) {
                continue;
            }
            int end = day.optInt("end", -1);
            if (cmp > 0 || end < 0 || nowMin < end) {
                return i;
            }
        }
        return fallback >= 0 ? fallback : days.length() - 1;
    }

    static String dayTitle(JSONObject payload, JSONObject day) {
        String iso = day.optString("iso");
        String label = day.optString("label", iso);
        if (iso.equals(isoDay(0))) {
            return payload.optString("today", "Dnes") + " · " + label;
        }
        if (iso.equals(isoDay(1))) {
            return payload.optString("tomorrow", "Zítra") + " · " + label;
        }
        return label;
    }

    /** The local ISO date {@code offset} days from today. */
    static String isoDay(int offset) {
        Calendar cal = Calendar.getInstance();
        cal.add(Calendar.DAY_OF_YEAR, offset);
        return String.format(Locale.US, "%04d-%02d-%02d", cal.get(Calendar.YEAR),
                cal.get(Calendar.MONTH) + 1, cal.get(Calendar.DAY_OF_MONTH));
    }

    static int minuteOfDay() {
        Calendar cal = Calendar.getInstance();
        return cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE);
    }

    static int clamp(int val, int min, int max) {
        return Math.max(min, Math.min(max, val));
    }

    /**
     * Arms a refresh at today's next lesson start / end (the highlight moves)
     * or at midnight (the day moves), whichever comes first. It doesn't wake
     * the phone: a sleeping phone catches up as soon as it wakes.
     */
    static void scheduleTick(Context ctx) {
        AlarmManager alarms = ctx.getSystemService(AlarmManager.class);
        if (alarms == null) {
            return;
        }
        int nowMin = minuteOfDay();
        int nextMin = -1;
        JSONObject payload = parsePayload(prefs(ctx));
        JSONArray days = payload != null ? payload.optJSONArray("days") : null;
        String today = isoDay(0);
        for (int i = 0; days != null && i < days.length(); i++) {
            JSONObject day = days.optJSONObject(i);
            JSONArray rows = day != null && today.equals(day.optString("iso"))
                    ? day.optJSONArray("rows") : null;
            for (int j = 0; rows != null && j < rows.length(); j++) {
                JSONObject row = rows.optJSONObject(j);
                if (row == null) {
                    continue;
                }
                for (String key : new String[] {"start", "end"}) {
                    int min = row.optInt(key, -1);
                    if (min > nowMin && (nextMin < 0 || min < nextMin)) {
                        nextMin = min;
                    }
                }
            }
        }
        Calendar cal = Calendar.getInstance();
        cal.set(Calendar.SECOND, 0);
        cal.set(Calendar.MILLISECOND, 0);
        if (nextMin >= 0) {
            cal.set(Calendar.HOUR_OF_DAY, nextMin / 60);
            cal.set(Calendar.MINUTE, nextMin % 60);
        } else {
            cal.set(Calendar.HOUR_OF_DAY, 0);
            cal.set(Calendar.MINUTE, 0);
            cal.add(Calendar.DAY_OF_YEAR, 1);
        }
        long at = cal.getTimeInMillis() + 1000L; // just past the boundary
        PendingIntent op = tickIntent(ctx);
        if (AlarmReceiver.exactAllowed(alarms)) {
            try {
                alarms.setExact(AlarmManager.RTC, at, op);
                return;
            } catch (SecurityException ignored) {
                // Permission withdrawn meanwhile: the windowed alarm below.
            }
        }
        alarms.setWindow(AlarmManager.RTC, at, 5 * 60 * 1000L, op);
    }

    private static PendingIntent tickIntent(Context ctx) {
        Intent intent = new Intent(ACTION_REFRESH);
        intent.setClassName(ctx.getPackageName(), TimetableWidgetProvider.class.getName());
        return PendingIntent.getBroadcast(ctx, REQUEST_TICK, intent,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    private static PendingIntent navBroadcast(Context ctx, int widgetId, String action, int slot) {
        Intent intent = new Intent(action);
        intent.setClassName(ctx.getPackageName(), TimetableWidgetProvider.class.getName());
        intent.putExtra(EXTRA_WIDGET_ID, widgetId);
        return PendingIntent.getBroadcast(ctx, widgetId * 10 + slot, intent,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    private static PendingIntent openAppIntent(Context ctx) {
        Intent launch = ctx.getPackageManager().getLaunchIntentForPackage(ctx.getPackageName());
        if (launch == null) {
            return null;
        }
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        return PendingIntent.getActivity(ctx, REQUEST_OPEN, launch,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }
}
