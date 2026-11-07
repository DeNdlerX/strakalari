package io.github.dendlerx.strakalari.android;

import android.app.Notification;
import android.content.Context;
import android.graphics.Typeface;
import android.text.SpannableStringBuilder;
import android.text.Spanned;
import android.text.style.StyleSpan;
import android.view.View;
import android.widget.RemoteViews;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/**
 * The background notification's overview in the app's own layout: a row per
 * item the user picked, each with its icon (the rows come from Python:
 * strakalari/core/status_notification.py, StatusContent.rows_json).
 *
 * Collapsed, where Android 12+ leaves a custom view only 48 dp (and about
 * 250 dp across), every row still shows: the first on its own line, the
 * others side by side on a second one with their short values (a count or
 * a time next to the icon); the long ones shorten so the short ones always
 * fit. Expanded, each row has its own
 * line, "label: value" with the label bold. The system draws the app icon,
 * its name and the header's small text around both
 * ({@link Notification.DecoratedCustomViewStyle}).
 */
final class StatusViews {
    private StatusViews() {}

    static final class Row {
        final String kind;
        final String label;
        final String value;
        final String shortValue;

        Row(String kind, String label, String value, String shortValue) {
            this.kind = kind;
            this.label = label;
            this.value = value;
            this.shortValue = shortValue.isEmpty() ? value : shortValue;
        }
    }

    /** Draws the rows into {@code b}; without (readable) rows its plain style stays. */
    static void apply(Context ctx, Notification.Builder b, String rowsJson) {
        List<Row> rows = parse(rowsJson);
        if (rows.isEmpty()) {
            return;
        }
        try {
            RemoteViews collapsed = collapsed(ctx, rows);
            RemoteViews expanded = expanded(ctx, rows);
            b.setStyle(new Notification.DecoratedCustomViewStyle())
                    .setCustomContentView(collapsed)
                    .setCustomBigContentView(expanded);
        } catch (RuntimeException e) {
            // The plain title and text still say it all.
        }
    }

    static List<Row> parse(String json) {
        List<Row> rows = new ArrayList<>();
        if (json == null || json.isEmpty()) {
            return rows;
        }
        try {
            JSONArray array = new JSONArray(json);
            for (int i = 0; i < array.length(); i++) {
                JSONObject o = array.optJSONObject(i);
                String value = o != null ? o.optString("value", "") : "";
                if (value.isEmpty()) {
                    continue;
                }
                rows.add(new Row(o.optString("kind", ""), o.optString("label", ""), value,
                        o.optString("short", "")));
            }
        } catch (JSONException e) {
            rows.clear();
        }
        return rows;
    }

    private static RemoteViews collapsed(Context ctx, List<Row> rows) {
        String pkg = ctx.getPackageName();
        RemoteViews views = new RemoteViews(pkg, R.layout.strakalari_status_collapsed);
        Row first = rows.get(0);
        views.setTextViewText(R.id.strakalari_status_first, first.shortValue);
        views.setTextViewCompoundDrawablesRelative(
                R.id.strakalari_status_first, icon(first.kind), 0, 0, 0);
        if (rows.size() == 1) {
            views.setViewVisibility(R.id.strakalari_status_rest, View.GONE);
        }
        int gap = Math.round(12 * ctx.getResources().getDisplayMetrics().density);
        for (int i = 1; i < rows.size(); i++) {
            Row row = rows.get(i);
            // Counts and a time stay whole; the rest share what is left of the line.
            boolean whole = "excuses".equals(row.kind) || "wakeup".equals(row.kind)
                    || "lunch_orders".equals(row.kind);
            RemoteViews chip = new RemoteViews(pkg, whole
                    ? R.layout.strakalari_status_chip_wrap : R.layout.strakalari_status_chip_fill);
            chip.setTextViewText(R.id.strakalari_status_chip, row.shortValue);
            chip.setTextViewCompoundDrawablesRelative(
                    R.id.strakalari_status_chip, icon(row.kind), 0, 0, 0);
            if (i > 1) {
                chip.setViewPadding(R.id.strakalari_status_chip, gap, 0, 0, 0); // between chips
            }
            views.addView(R.id.strakalari_status_rest, chip);
        }
        return views;
    }

    private static RemoteViews expanded(Context ctx, List<Row> rows) {
        String pkg = ctx.getPackageName();
        RemoteViews views = new RemoteViews(pkg, R.layout.strakalari_status_expanded);
        for (Row row : rows) {
            RemoteViews line = new RemoteViews(pkg, R.layout.strakalari_status_row);
            int icon = icon(row.kind);
            if (icon != 0) {
                line.setImageViewResource(R.id.strakalari_status_row_icon, icon);
            } else {
                line.setViewVisibility(R.id.strakalari_status_row_icon, View.INVISIBLE);
            }
            line.setTextViewText(R.id.strakalari_status_row_text, labelled(row));
            views.addView(R.id.strakalari_status_rows, line);
        }
        return views;
    }

    /** "<b>Další hodina:</b> 1. Matematika · 8:00 · 214". */
    private static CharSequence labelled(Row row) {
        if (row.label.isEmpty()) {
            return row.value;
        }
        SpannableStringBuilder text = new SpannableStringBuilder(row.label).append(": ");
        text.setSpan(new StyleSpan(Typeface.BOLD), 0, text.length(),
                Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        return text.append(row.value);
    }

    /** The row's icon (status_notification.ITEMS), 0 for none. */
    private static int icon(String kind) {
        switch (kind) {
            case "next_lesson":
                return R.drawable.strakalari_status_lesson;
            case "lunch":
                return R.drawable.strakalari_status_lunch;
            case "lunch_orders":
                return R.drawable.strakalari_status_orders;
            case "excuses":
                return R.drawable.strakalari_status_excuses;
            case "wakeup":
                return R.drawable.strakalari_status_wakeup;
            default:
                return 0;
        }
    }
}
