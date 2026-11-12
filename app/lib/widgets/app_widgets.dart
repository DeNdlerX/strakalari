// Shared components: cards, rows, badges, buttons, fields.
//
// Port of strakalari/flet_ui/components.py. Every screen reads colors
// only from [Tokens]; nothing here hardcodes a color, radius or spacing.
import 'package:flutter/material.dart';
import 'package:strakalari_core/strakalari_core.dart';

import '../l10n/strings.dart';
import '../shell/theme.dart';

// -- date / language helpers -------------------------------------------------

/// Czech short date: '7. 9.' — accepts a [DateTime] or `DD.MM.YYYY`.
/// Port of `cz_day()`.
String czDay(Object? value) {
  final day = value is DateTime ? value : parseCzDate('$value');
  if (day == null) return '${value ?? '?'}';
  return '${day.day}. ${day.month}.';
}

/// `'7. 9. 2026'` variant. Port of `cz_day_year()`.
String czDayYear(Object? value) {
  final day = value is DateTime ? value : parseCzDate('$value');
  if (day == null) return '${value ?? '?'}';
  return '${day.day}. ${day.month}. ${day.year}';
}

/// `'1 hodina' / '3 hodiny' / '5 hodin'` (Czech plural rules).
/// Port of `lessons_text()`.
String lessonsText(int n) {
  if (n == 1) return Strings.format('lessons_one', {'n': n});
  if (n >= 2 && n <= 4) return Strings.format('lessons_few', {'n': n});
  return Strings.format('lessons_many', {'n': n});
}

const List<String> czechDayNames = [
  'Pondělí',
  'Úterý',
  'Středa',
  'Čtvrtek',
  'Pátek',
  'Sobota',
  'Neděle',
];
const List<String> englishDayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const List<String> czechDayNamesShort = [
  'Po',
  'Út',
  'St',
  'Čt',
  'Pá',
  'So',
  'Ne',
];
const List<String> englishDayNamesShort = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

/// Weekday name in the app language (never the OS locale).
/// Port of `day_name()` (Python Monday=0 == Dart Monday=1 minus one).
String dayName(Object? value, [bool short = false]) {
  final day = value is DateTime ? value : parseCzDate('$value');
  if (day == null) return '${value ?? '?'}';
  final idx = day.weekday - 1;
  final en = Strings.lang == 'en';
  if (short) return (en ? englishDayNamesShort : czechDayNamesShort)[idx];
  return (en ? englishDayNames : czechDayNames)[idx];
}

/// Maps a normalized lesson status to a badge kind. Port of
/// `lesson_kind()`.
String lessonKind(String status) {
  switch (status.toLowerCase()) {
    case '':
      return 'ok';
    case 'late':
    case 'early':
    case 'soon':
      return 'late';
    case 'absent':
      return 'critical';
    case 'cancelled':
      return 'cancelled';
    case 'excused':
      return 'sent';
    default:
      return 'info';
  }
}

/// Dialog width clamped to the screen. Port of `dialog_width()`.
double dialogWidth(BuildContext context, double preferred) {
  final w = MediaQuery.sizeOf(context).width;
  if (w <= 0) return preferred;
  // Python: int(max(240, min(preferred, width - 64))).
  final fit = w - 64 < preferred ? w - 64 : preferred;
  return (fit < 240 ? 240 : fit).truncateToDouble();
}

// -- text --------------------------------------------------------------------

/// Section heading. Port of `section_header()`.
class SectionHeader extends StatelessWidget {
  final String text;
  final Tokens tok;
  const SectionHeader(this.text, {super.key, required this.tok});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.zero,
      child: Text(text.toUpperCase(),
          style: TextStyle(
              color: tok.faint,
              fontSize: tok.fsSmall,
              fontWeight: FontWeight.w700)),
    );
  }
}

/// Muted hint line. Port of `hint_text()`.
class HintText extends StatelessWidget {
  final String text;
  final Tokens tok;
  const HintText(this.text, {super.key, required this.tok});

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: TextStyle(color: tok.muted, fontSize: tok.fsSmall));
  }
}

/// One activity-log line. Port of `log_line()`.
class LogLineText extends StatelessWidget {
  final String text;
  final Tokens tok;
  const LogLineText(this.text, {super.key, required this.tok});

  @override
  Widget build(BuildContext context) {
    return SelectableText(text,
        style: TextStyle(
            color: tok.muted, fontSize: tok.fsSmall, fontFamily: 'Consolas'));
  }
}

// -- cards -------------------------------------------------------------------

/// Default content card. Port of `card()`.
class AppCard extends StatelessWidget {
  final Tokens tok;
  final double? padding;
  final List<Widget> children;
  const AppCard({super.key, required this.tok, this.padding, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(padding ?? tok.pad),
      decoration: BoxDecoration(
        color: tok.card,
        borderRadius: BorderRadius.circular(tok.radiusMd),
        border: Border.all(color: tok.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: tok.gap / 2,
        children: children,
      ),
    );
  }
}

/// Settings form card. Port of `form_card()`.
class FormCard extends StatelessWidget {
  final List<Widget> children;
  final Tokens tok;
  const FormCard({super.key, required this.children, required this.tok});

  @override
  Widget build(BuildContext context) => AppCard(tok: tok, children: children);
}

/// Empty-state placeholder with an optional action. Port of
/// `empty_state()`.
class EmptyState extends StatelessWidget {
  final String text;
  final Tokens tok;
  final Widget? action;
  const EmptyState({super.key, required this.text, required this.tok, this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: tok.gap,
        children: [
          Icon(Icons.inbox_outlined, size: 40, color: tok.faint),
          Text(text, style: TextStyle(color: tok.faint, fontSize: tok.fsBody)),
          ?action,
        ],
      ),
    );
  }
}

/// Title + "updated" line + optional actions. Port of `header_row()`.
class HeaderRow extends StatelessWidget {
  final String heading;
  final String updated;
  final Tokens tok;
  final List<Widget> actions;
  const HeaderRow(
      {super.key,
      required this.heading,
      required this.updated,
      required this.tok,
      this.actions = const []});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      spacing: 8,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              Text(heading,
                  style: TextStyle(
                      color: tok.text,
                      fontSize: tok.fsTitle,
                      fontWeight: FontWeight.w700)),
              if (updated.isNotEmpty)
                Text(updated,
                    style:
                        TextStyle(color: tok.faint, fontSize: tok.fsSmall)),
            ],
          ),
        ),
        ...actions,
      ],
    );
  }
}

// -- badges / meters / dots --------------------------------------------------

/// Pill badge. Port of `badge()`.
class Badge extends StatelessWidget {
  final String text;
  final Tokens tok;
  final String kind;
  const Badge({super.key, required this.text, required this.tok, this.kind = 'info'});

  Color get color => statusColor(
      {'info': 'pending', 'ok': 'ok'}[kind] ?? kind, tok);

  @override
  Widget build(BuildContext context) {
    final c = kind == 'info' ? tok.accent : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: c),
        borderRadius: BorderRadius.circular(tok.radiusSm),
      ),
      child: Text(text,
          style: TextStyle(
              color: c, fontSize: tok.fsTiny, fontWeight: FontWeight.w600)),
    );
  }
}

/// Badge for an excuse-task kind (late/soon/early/short/long).
/// Port of `kind_badge()`.
class KindBadge extends StatelessWidget {
  final String kind;
  final Tokens tok;
  const KindBadge({super.key, required this.kind, required this.tok});

  @override
  Widget build(BuildContext context) {
    const labels = {
      'late': 'kind_late',
      'soon': 'kind_soon',
      'early': 'kind_early',
      'short': 'kind_short',
      'long': 'kind_long',
    };
    final k = kind.toLowerCase();
    final color = (k == 'late' || k == 'soon' || k == 'early')
        ? tok.yellow
        : tok.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(tok.radiusSm),
      ),
      child: Text(Strings.get(labels[k] ?? 'kind_short'),
          style: TextStyle(
              color: color,
              fontSize: tok.fsTiny,
              fontWeight: FontWeight.w600)),
    );
  }
}

/// Horizontal value bar. Port of `meter()`.
class Meter extends StatelessWidget {
  final double valuePct;
  final Tokens tok;
  final String kind;
  final double width;
  const Meter(
      {super.key,
      required this.valuePct,
      required this.tok,
      this.kind = 'ok',
      this.width = 140});

  @override
  Widget build(BuildContext context) {
    final v = valuePct.clamp(0.0, 100.0) / 100.0;
    // Port of `components.meter`: a fixed-width track and a fixed-width,
    // right-aligned label ("100.0 %" fits), so the track stays put
    // whatever the number's width.
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        SizedBox(
          width: width,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: v,
              minHeight: 8,
              backgroundColor: tok.overlay,
              valueColor:
                  AlwaysStoppedAnimation<Color>(statusColor(kind, tok)),
            ),
          ),
        ),
        SizedBox(
          width: tok.fsSmall * 4.5,
          child: Text('${valuePct.toStringAsFixed(1)} %',
              textAlign: TextAlign.end,
              style: TextStyle(color: tok.muted, fontSize: tok.fsSmall)),
        ),
      ],
    );
  }
}

/// Colored status dot. Port of `status_dot()`.
class StatusDot extends StatelessWidget {
  final Tokens tok;
  final String kind;
  final double size;
  const StatusDot({super.key, required this.tok, this.kind = 'idle', this.size = 10});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: statusColor(kind, tok),
        shape: BoxShape.circle,
      ),
    );
  }
}

/// Small "changed" dot. Port of `change_badge()` / `note_dot()`.
class ChangeDot extends StatelessWidget {
  final Tokens tok;
  final String tooltip;
  const ChangeDot({super.key, required this.tok, this.tooltip = ''});

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: tok.yellow, shape: BoxShape.circle),
    );
    if (tooltip.isEmpty) return dot;
    return Tooltip(message: tooltip, child: dot);
  }
}

/// Radio dot (settings options). Port of `radio_dot()`.
class RadioDot extends StatelessWidget {
  final Tokens tok;
  final bool selected;
  final double size;
  const RadioDot(
      {super.key, required this.tok, required this.selected, this.size = 20});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
            color: selected ? tok.accent : tok.muted, width: 2),
      ),
      child: selected
          ? Center(
              child: Container(
                width: size / 2,
                height: size / 2,
                decoration: BoxDecoration(
                    color: tok.accent, shape: BoxShape.circle),
              ),
            )
          : null,
    );
  }
}

// -- stats -------------------------------------------------------------------

/// Label + value stat tile. Port of `stat_card()`.
class StatCard extends StatelessWidget {
  final String label;
  final String value;
  final Tokens tok;
  final String kind;
  final bool singleLine;
  const StatCard(
      {super.key,
      required this.label,
      required this.value,
      required this.tok,
      this.kind = 'info',
      this.singleLine = false});

  @override
  Widget build(BuildContext context) {
    final color = const {
      'ok', 'warning', 'critical', 'late', 'cancelled', 'pending', 'sent',
      'failed'
    }.contains(kind)
        ? statusColor(kind, tok)
        : tok.accent;
    return Expanded(
      child: Container(
        padding: EdgeInsets.all(tok.pad),
        decoration: BoxDecoration(
          color: tok.card,
          borderRadius: BorderRadius.circular(tok.radiusMd),
          border: Border.all(color: tok.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: 2,
          children: [
            Text(label,
                style: TextStyle(color: tok.muted, fontSize: tok.fsBody)),
            Tooltip(
              message: singleLine ? value : '',
              child: Text(value,
                  maxLines: singleLine ? 1 : null,
                  overflow: singleLine ? TextOverflow.ellipsis : null,
                  style: TextStyle(
                      color: color,
                      fontSize: tok.fsTitle,
                      fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Key/value row. Port of `kv_row()`.
class KvRow extends StatelessWidget {
  final Tokens tok;
  final String label;
  final String value;
  final Color? valueColor;
  const KvRow(
      {super.key,
      required this.tok,
      required this.label,
      required this.value,
      this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: tok.muted, fontSize: tok.fsBody)),
        Flexible(
          child: Text(value,
              textAlign: TextAlign.end,
              style: TextStyle(
                  color: valueColor ?? tok.text, fontSize: tok.fsBody)),
        ),
      ],
    );
  }
}

// -- buttons -----------------------------------------------------------------

/// Filled primary button. Port of `primary_button()`.
class PrimaryButton extends StatelessWidget {
  final String label;
  final Tokens tok;
  final VoidCallback? onPressed;
  const PrimaryButton(
      {super.key, required this.label, required this.tok, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: onPressed == null ? tok.overlay : tok.accent,
        foregroundColor: onPressed == null ? tok.faint : tok.accentText,
        disabledBackgroundColor: tok.overlay,
        disabledForegroundColor: tok.faint,
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// Text button. Port of `ghost_button()`.
class GhostButton extends StatelessWidget {
  final String label;
  final Tokens tok;
  final VoidCallback? onPressed;
  const GhostButton(
      {super.key, required this.label, required this.tok, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(foregroundColor: tok.text),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// Destructive button. Port of `danger_button()`.
class DangerButton extends StatelessWidget {
  final String label;
  final Tokens tok;
  final VoidCallback? onPressed;
  const DangerButton(
      {super.key, required this.label, required this.tok, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: TextButton.styleFrom(foregroundColor: tok.red),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

// -- fields ------------------------------------------------------------------

/// Single-line text field. Port of `field()`.
class AppField extends StatelessWidget {
  final Tokens tok;
  final String? initialValue;
  final String? hint;
  final bool obscure;
  final ValueChanged<String>? onChanged;
  final TextEditingController? controller;
  const AppField(
      {super.key,
      required this.tok,
      this.initialValue,
      this.hint,
      this.obscure = false,
      this.onChanged,
      this.controller});

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      initialValue: controller == null ? initialValue : null,
      obscureText: obscure,
      onChanged: onChanged,
      style: TextStyle(color: tok.text, fontSize: tok.fsBody),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: tok.faint),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(tok.radiusSm),
          borderSide: BorderSide(color: tok.border),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }
}

/// Label + field pair. Port of `labeled_field()`.
class LabeledField extends StatelessWidget {
  final Tokens tok;
  final String label;
  final Widget field;
  const LabeledField(
      {super.key, required this.tok, required this.label, required this.field});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Text(label,
            style: TextStyle(color: tok.muted, fontSize: tok.fsSmall)),
        field,
      ],
    );
  }
}

/// Dropdown. Port of `dropdown()`.
class AppDropdown<T> extends StatelessWidget {
  final Tokens tok;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T?> onChanged;
  const AppDropdown(
      {super.key,
      required this.tok,
      required this.value,
      required this.options,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      onChanged: onChanged,
      style: TextStyle(color: tok.text, fontSize: tok.fsBody),
      dropdownColor: tok.card,
      decoration: InputDecoration(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(tok.radiusSm),
          borderSide: BorderSide(color: tok.border),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      items: [
        for (final (v, label) in options)
          DropdownMenuItem<T>(value: v, child: Text(label)),
      ],
    );
  }
}

/// Switch row. Port of `toggle()`.
class AppToggle extends StatelessWidget {
  final Tokens tok;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const AppToggle(
      {super.key,
      required this.tok,
      required this.label,
      required this.value,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
            child: Text(label,
                style: TextStyle(color: tok.text, fontSize: tok.fsBody))),
        Switch(value: value, onChanged: onChanged, activeThumbColor: tok.accent),
      ],
    );
  }
}

/// Collapsible section. Port of `collapsed()`.
class Collapsed extends StatelessWidget {
  final Tokens tok;
  final String title;
  final bool initiallyExpanded;
  final List<Widget> children;
  const Collapsed(
      {super.key,
      required this.tok,
      required this.title,
      required this.children,
      this.initiallyExpanded = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: tok.card,
        borderRadius: BorderRadius.circular(tok.radiusMd),
        border: Border.all(color: tok.border),
      ),
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        collapsedIconColor: tok.muted,
        iconColor: tok.accent,
        title: Text(title,
            style: TextStyle(
                color: tok.text,
                fontSize: tok.fsBody,
                fontWeight: FontWeight.w600)),
        childrenPadding: EdgeInsets.fromLTRB(
            tok.pad / 2, 0, tok.pad / 2, tok.pad / 2),
        children: children,
      ),
    );
  }
}

// -- misc --------------------------------------------------------------------

/// Thin divider. Port of `divider()`.
class AppDivider extends StatelessWidget {
  final Tokens tok;
  const AppDivider({super.key, required this.tok});

  @override
  Widget build(BuildContext context) => Divider(color: tok.border, height: 1);
}

/// Bottom scroll padding. Port of `bottom_spacer()`.
class BottomSpacer extends StatelessWidget {
  final Tokens tok;
  const BottomSpacer({super.key, required this.tok});

  @override
  Widget build(BuildContext context) => const SizedBox(height: 96);
}

/// Indeterminate progress bar. Port of `progress_bar()`.
class AppProgressBar extends StatelessWidget {
  final Tokens tok;
  const AppProgressBar({super.key, required this.tok});

  @override
  Widget build(BuildContext context) {
    return LinearProgressIndicator(
      backgroundColor: tok.overlay,
      valueColor: AlwaysStoppedAnimation<Color>(tok.accent),
    );
  }
}
