package io.github.dendlerx.strakalari.android;

import android.annotation.TargetApi;
import android.appwidget.AppWidgetManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Paint;
import android.view.View;
import android.widget.RemoteViews;
import android.widget.RemoteViewsService;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/**
 * The list rows of {@link TimetableWidgetProvider}: lessons and empty slots
 * for free periods. On today's day the running lesson (else the next one)
 * is highlighted, from the clock at the last refresh.
 *
 * <p>Android 12+ gets the rows inside the widget's own RemoteViews
 * ({@link #items}), so the day title and its lessons always arrive in one
 * update. This service only serves older versions: with it, newer Android
 * re-sent the widget's previous views after the list changed, and the title
 * jumped back to the day shown before.
 */
public class TimetableWidgetService extends RemoteViewsService {
    @Override
    public RemoteViewsFactory onGetViewFactory(Intent intent) {
        int widgetId = intent != null
                ? intent.getIntExtra(
                        AppWidgetManager.EXTRA_APPWIDGET_ID,
                        AppWidgetManager.INVALID_APPWIDGET_ID)
                : AppWidgetManager.INVALID_APPWIDGET_ID;
        return new Factory(getApplicationContext(), widgetId);
    }

    private static final class Factory implements RemoteViewsFactory {
        private final Context context;
        private final int widgetId;
        private final List<JSONObject> rows = new ArrayList<>();
        private int focus = -1;

        Factory(Context context, int widgetId) {
            this.context = context;
            this.widgetId = widgetId;
        }

        @Override
        public void onCreate() {
            loadRows();
        }

        @Override
        public void onDataSetChanged() {
            loadRows();
        }

        @Override
        public void onDestroy() {
            rows.clear();
        }

        @Override
        public int getCount() {
            return rows.size();
        }

        @Override
        public int getViewTypeCount() {
            return 2; // lesson and pause layouts
        }

        @Override
        public RemoteViews getViewAt(int position) {
            if (position < 0 || position >= rows.size()) {
                return null;
            }
            return rowView(context, rows.get(position), position == focus);
        }

        @Override
        public RemoteViews getLoadingView() {
            return null;
        }

        @Override
        public long getItemId(int position) {
            return position;
        }

        @Override
        public boolean hasStableIds() {
            return false; // positions mean other lessons on another day
        }

        private void loadRows() {
            rows.clear();
            SharedPreferences prefs = TimetableWidgetProvider.prefs(context);
            JSONObject payload = TimetableWidgetProvider.parsePayload(prefs);
            JSONObject day = payload != null
                    ? TimetableWidgetProvider.shownDay(prefs, payload, widgetId) : null;
            rows.addAll(rowsOf(day));
            focus = focusOf(rows, day);
        }
    }

    /** Android 12+: the day's rows for {@code RemoteViews.setRemoteAdapter}. */
    @TargetApi(31)
    static RemoteViews.RemoteCollectionItems items(Context context, JSONObject day) {
        List<JSONObject> rows = rowsOf(day);
        int focus = focusOf(rows, day);
        RemoteViews.RemoteCollectionItems.Builder b =
                new RemoteViews.RemoteCollectionItems.Builder()
                        .setHasStableIds(false)
                        .setViewTypeCount(2); // lesson and pause layouts
        for (int i = 0; i < rows.size(); i++) {
            b.addItem(i, rowView(context, rows.get(i), i == focus));
        }
        return b.build();
    }

    /** The rows of {@code day} (lessons and free periods); none without a day. */
    static List<JSONObject> rowsOf(JSONObject day) {
        List<JSONObject> rows = new ArrayList<>();
        JSONArray arr = day != null ? day.optJSONArray("rows") : null;
        for (int i = 0; arr != null && i < arr.length(); i++) {
            JSONObject row = arr.optJSONObject(i);
            if (row != null) {
                rows.add(row);
            }
        }
        return rows;
    }

    /** The row to highlight: on today's day the running (else next) lesson, else -1. */
    static int focusOf(List<JSONObject> rows, JSONObject day) {
        if (day == null || !TimetableWidgetProvider.isoDay(0).equals(day.optString("iso"))) {
            return -1;
        }
        return focusRow(rows, TimetableWidgetProvider.minuteOfDay());
    }

    /** The lesson running at {@code nowMin}, else the next one today (-1: none). */
    private static int focusRow(List<JSONObject> rows, int nowMin) {
        int next = -1;
        for (int i = 0; i < rows.size(); i++) {
            JSONObject row = rows.get(i);
            if (!"lesson".equals(row.optString("kind"))
                    || "cancelled".equals(row.optString("status"))) {
                continue;
            }
            int start = row.optInt("start", -1);
            int end = row.optInt("end", -1);
            if (start < 0 || end < 0) {
                continue;
            }
            if (start <= nowMin && nowMin < end) {
                return i;
            }
            if (start > nowMin && (next < 0 || start < rows.get(next).optInt("start", -1))) {
                next = i;
            }
        }
        return next;
    }

    /** One list row: a lesson, or an empty slot for a free period. */
    static RemoteViews rowView(Context context, JSONObject item, boolean focused) {
        if ("pause".equals(item.optString("kind"))) {
            RemoteViews rv = new RemoteViews(
                    context.getPackageName(), R.layout.timetable_widget_pause_item);
            rv.setTextViewText(R.id.widget_item_period, item.optString("period", ""));
            rv.setTextViewText(R.id.widget_item_time, item.optString("time", ""));
            rv.setOnClickFillInIntent(R.id.widget_pause_root, new Intent());
            return rv;
        }

        RemoteViews rv = new RemoteViews(
                context.getPackageName(), R.layout.timetable_widget_item);
        String status = item.optString("status", "normal");
        String meta = item.optString("meta", "");
        String badge = item.optString("badge", "");
        boolean cancelled = "cancelled".equals(status);

        rv.setInt(R.id.widget_item_root, "setBackgroundResource",
                focused ? R.drawable.widget_item_focus_bg : R.drawable.widget_item_bg);
        rv.setTextViewText(R.id.widget_item_period, item.optString("period", ""));
        rv.setTextColor(R.id.widget_item_period,
                focused ? Color.parseColor("#5B9BFF") : Color.parseColor("#B5BDCE"));
        rv.setTextViewText(R.id.widget_item_time, item.optString("time", ""));

        rv.setTextViewText(R.id.widget_item_subject, item.optString("subject", "?"));
        rv.setInt(R.id.widget_item_subject, "setPaintFlags",
                cancelled ? (Paint.ANTI_ALIAS_FLAG | Paint.STRIKE_THRU_TEXT_FLAG)
                        : Paint.ANTI_ALIAS_FLAG);
        if (cancelled) {
            rv.setTextColor(R.id.widget_item_subject, Color.parseColor("#6E768A"));
        } else if ("change".equals(status)) {
            rv.setTextColor(R.id.widget_item_subject, Color.parseColor("#7AB0FF"));
        } else {
            rv.setTextColor(R.id.widget_item_subject, Color.parseColor("#F0F4FC"));
        }

        if (!meta.isEmpty()) {
            rv.setTextViewText(R.id.widget_item_meta, meta);
            rv.setViewVisibility(R.id.widget_item_meta, View.VISIBLE);
        } else {
            rv.setViewVisibility(R.id.widget_item_meta, View.GONE);
        }

        rv.setInt(R.id.widget_item_bar, "setBackgroundColor", barColorFor(status, focused));

        if (!badge.isEmpty()) {
            rv.setTextViewText(R.id.widget_item_badge, badge);
            rv.setTextColor(R.id.widget_item_badge, badgeColorFor(status));
            rv.setViewVisibility(R.id.widget_item_badge, View.VISIBLE);
        } else {
            rv.setViewVisibility(R.id.widget_item_badge, View.GONE);
        }

        rv.setOnClickFillInIntent(R.id.widget_item_root, new Intent());
        return rv;
    }

    private static int barColorFor(String status, boolean focused) {
        if ("absent".equals(status)) {
            return Color.parseColor("#F05454");
        }
        if ("excused".equals(status)) {
            return Color.parseColor("#34C759");
        }
        if ("late".equals(status)) {
            return Color.parseColor("#FF9F0A");
        }
        if ("change".equals(status) || focused) {
            return Color.parseColor("#4C8DFF");
        }
        if ("cancelled".equals(status)) {
            return Color.parseColor("#4A5162");
        }
        return Color.parseColor("#2E3546");
    }

    private static int badgeColorFor(String status) {
        if ("absent".equals(status)) {
            return Color.parseColor("#FF7A7A");
        }
        if ("excused".equals(status)) {
            return Color.parseColor("#5CE07D");
        }
        if ("late".equals(status)) {
            return Color.parseColor("#FFB84D");
        }
        if ("change".equals(status)) {
            return Color.parseColor("#7AB0FF");
        }
        return Color.parseColor("#8C95A8");
    }
}
