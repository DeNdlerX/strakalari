import 'package:clock/clock.dart';
import 'package:app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import 'package:app/features/lunches/lunches_format.dart';
import 'package:app/features/lunches/lunches_controller.dart';
import '../common/app_tokens.dart';
import '../common/format.dart';
import '../common/open_url.dart';
import 'package:app/widgets/app_widgets.dart' as w;
import 'package:app/widgets/overlays.dart';

/// Obědy: weekly menu with a radio picker + AI/blacklist side panel.
/// Port of views/lunches.py.
class LunchesView extends StatelessWidget {
  final LunchController controller;
  final bool narrow;
  final String updatedLabel;
  final VoidCallback? onOpenSettings;
  final Future<void> Function()? onRecommend;
  /// Sends the picks. Returns what to tell the user right away (e.g.
  /// "already running"), null for nothing: a started send reports its
  /// outcome itself when it is done.
  final Future<String?> Function(Map<String, String> payload)? onSubmit;
  final DateTime Function()? nowFor;

  const LunchesView({
    super.key,
    required this.controller,
    this.narrow = false,
    this.updatedLabel = '',
    this.onOpenSettings,
    this.onRecommend,
    this.onSubmit,
    this.nowFor,
  });

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final tok = tokensOf(context);
    if (!c.stravaOn) {
      return ListView(
        padding: EdgeInsets.zero,
        children: [
          w.HeaderRow(
            heading: Strings.get('lunch_title'),
            updated: updatedLabel,
            tok: tok,
          ),
          SizedBox(height: tok.gap),
          w.AppCard(
            tok: tok,
            children: [
              Text(
                Strings.get('strava_disabled_title'),
                style: TextStyle(
                  color: tok.text,
                  fontSize: tok.fsBody,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                Strings.get('strava_disabled_msg'),
                style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: onOpenSettings,
                  child: Text(Strings.get('go_to_settings')),
                ),
              ),
            ],
          ),
        ],
      );
    }
    final now = (nowFor?.call() ?? clock.now());
    final today = DateTime(now.year, now.month, now.day);
    final past = <String>[];
    final upcoming = <String>[];
    for (final day in c.food.keys) {
      final parsed = _parseCz(day);
      if (parsed != null && parsed.isBefore(today)) {
        past.add(day);
      } else {
        upcoming.add(day);
      }
    }
    final sidebarOpen = narrow ? c.lunchToolsOpen : c.sidebarOpen;
    final menu = <Widget>[];
    final low = c.lowBalance['days'];
    if (low != null && low.isNotEmpty) {
      menu.add(
        w.AppCard(
          tok: tok,
          children: [
            Row(
              spacing: 8,
              children: [
                Icon(
                  Icons.account_balance_wallet_outlined,
                  color: tok.yellow,
                  size: 20,
                ),
                Text(
                  Strings.get('low_balance_title'),
                  style: TextStyle(
                    color: tok.yellow,
                    fontSize: tok.fsBody,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Text(
              Strings.format('low_balance_body', {
                'days': low.take(10).map(w.czDay).join(', '),
              }),
              style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
            ),
          ],
        ),
      );
    }
    if (c.food.isEmpty) {
      // Why the last refresh brought no menu (STRAVA_STATUS_KEY).
      final reason =
          {
            'no_login': 'lunch_empty_no_login',
            'empty': 'lunch_empty_no_menu',
          }['${c.get('strava_status', '')}'] ??
          'need_credentials';
      menu.add(w.EmptyState(text: Strings.get('no_data'), tok: tok));
      menu.add(
        Text(
          Strings.get(reason),
          style: TextStyle(color: tok.faint, fontSize: tok.fsSmall),
        ),
      );
    }
    if (past.isNotEmpty) {
      menu.add(
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () {
              final next = !c.showPastLunches;
              c.showPastLunches = next;
              c.setShowPastLunchesHook?.call(next);
            },
            icon: Icon(
              c.showPastLunches ? Icons.expand_less : Icons.history,
              size: 18,
            ),
            label: Text(
              c.showPastLunches
                  ? Strings.get('lunch_hide_past')
                  : Strings.format('lunch_show_past', {'n': past.length}),
            ),
          ),
        ),
      );
    }
    String? firstOpen;
    for (final day in upcoming) {
      if ((c.food[day] ?? {}).isNotEmpty && _isOpen(day)) {
        firstOpen = day;
        break;
      }
    }
    if (c.showPastLunches) {
      for (final day in past) {
        menu.add(_dayCard(context, tok, day, c.food[day] ?? {}));
      }
    }
    for (final day in upcoming) {
      final card = _dayCard(context, tok, day, c.food[day] ?? {});
      menu.add(
        day == firstOpen
            ? TutorialAnchor(anchorKey: 'lunch_day', child: card)
            : card,
      );
    }
    menu.add(SizedBox(height: tok.pad * 2));

    final toggle = TutorialAnchor(
      anchorKey: 'lunch_tools',
      child: IconButton(
        tooltip: sidebarOpen
            ? Strings.get('hide_sidebar')
            : Strings.get('show_sidebar'),
        iconSize: 22,
        color: sidebarOpen ? tok.accent : null,
        icon: const Icon(Icons.tune_outlined),
        onPressed: () => _setSidebar(!sidebarOpen),
      ),
    );
    final header = w.HeaderRow(
      heading: Strings.get('lunch_title'),
      updated: updatedLabel,
      tok: tok,
      actions: [toggle],
    );
    final hint = Text(
      Strings.get('pick_hint'),
      style: TextStyle(color: tok.faint, fontSize: tok.fsSmall),
    );
    final sendRow = TutorialAnchor(
      anchorKey: 'lunch_send',
      child: Align(
        alignment: Alignment.centerLeft,
        child: _sendButton(context),
      ),
    );
    Widget spaced(List<Widget> items) => ListView(
      padding: EdgeInsets.zero,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          items[i],
          if (i != items.length - 1) SizedBox(height: tok.gap),
        ],
      ],
    );
    if (narrow && !sidebarOpen) {
      // Phone: one scrolling page.
      return spaced([header, hint, sendRow, ...menu]);
    }
    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tok.gap,
        children: [
          header,
          Expanded(child: _sidebar(context, tok)),
        ],
      );
    }
    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tok.gap,
      children: [
        hint,
        sendRow,
        Expanded(child: spaced(menu)),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tok.gap,
      children: [
        header,
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: sidebarOpen ? tok.gap : 0,
            children: [
              Expanded(child: left),
              if (sidebarOpen)
                SizedBox(width: 360, child: _sidebar(context, tok)),
            ],
          ),
        ),
      ],
    );
  }

  bool _isOpen(String day) {
    final f = controller.isOrderOpen;
    if (f == null) return true;
    try {
      return f(day);
    } catch (_) {
      return true;
    }
  }

  void _setSidebar(bool open) {
    final c = controller;
    if (narrow) {
      c.lunchToolsOpen = open;
      c.setLunchToolsHook?.call(open);
    } else {
      c.sidebarOpen = open;
      c.setSidebarHook?.call(open);
    }
  }

  Widget _sendButton(BuildContext context) {
    final c = controller;
    final tok = tokensOf(context);
    var pending = 0;
    final counted = <String>{};
    for (final e in c.orders.entries) {
      if (e.value.isEmpty ||
          !c.pendingOrders.contains(e.key) ||
          !c.lunchIsChange(e.key)) {
        continue;
      }
      if (!_isOpen(e.key)) continue;
      counted.add(e.key);
      pending++;
    }
    // A planned day off still holding a web order goes out as its
    // cancellation (like the send payload).
    for (final day in c.cancelledLunches) {
      if (counted.contains(day)) continue;
      final web = c.webOrders[day] ?? '';
      if (web.isEmpty || web.contains('&-1&') || !_isOpen(day)) continue;
      if ((c.food[day] ?? const {}).keys.any((mid) => mid.contains('&-1&'))) {
        pending++;
      }
    }
    final notConfigured =
        !c.stravaConfigured || '${c.get('strava_status', '')}' == 'no_login';
    final button = ElevatedButton.icon(
      onPressed: notConfigured
          ? null
          : () async {
              final payload = {
                for (final e in c.orders.entries)
                  if (e.value.isNotEmpty &&
                      c.pendingOrders.contains(e.key) &&
                      c.lunchIsChange(e.key))
                    e.key: e.value,
              };
              if (onSubmit != null) {
                final msg = await onSubmit!(payload);
                if (msg != null && context.mounted) appSnack(context, msg);
              } else if (payload.isEmpty) {
                appSnack(context, Strings.get('no_changes'));
              }
            },
      icon: const Icon(Icons.send_outlined, size: 18),
      label: Text(
        '${Strings.get('send_orders')}'
        '${pending > 0 ? ' ($pending)' : ''}',
      ),
    );
    if (!notConfigured) return button;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        const SizedBox(height: 6),
        Text(
          Strings.get('strava_not_configured'),
          style: TextStyle(color: tok.faint, fontSize: tok.fsSmall),
        ),
      ],
    );
  }

  /// Status badge for one day: cancelled / web-ordered / to-send / none.
  /// Port of LunchView._day_status.
  String? dayStatus(String day) {
    final c = controller;
    final ordered = c.orders[day] ?? c.webOrders[day];
    if (c.cancelledLunches.contains(day)) return Strings.get('no_lunch');
    if (ordered == null || ordered.isEmpty) return null;
    if (!c.lunchIsChange(day)) {
      if (LunchController.realMeal(c.webOrders[day]).isNotEmpty) {
        return Strings.get('web_ordered');
      }
      return null;
    }
    if (c.isOrderOpen != null) {
      try {
        if (!c.isOrderOpen!(day)) return null;
      } catch (_) {}
    }
    return Strings.get('to_send');
  }

  Widget _dayCard(
    BuildContext context,
    Tokens tok,
    String day,
    Map<String, String> meals,
  ) {
    final c = controller;
    final orderOpen = _isOpen(day);
    final ordered = c.orders[day] ?? c.webOrders[day];
    final isCancelled = c.cancelledLunches.contains(day);
    final isFreeDay = c.freeDayLabels.containsKey(day);
    final freeLabel = (c.freeDayLabels[day] ?? '').trim();
    final status = dayStatus(day);
    final soup = sharedSoup(meals);
    String? deorderId;
    for (final e in meals.entries) {
      if (e.key.contains('&-1&')) deorderId = e.key;
    }
    var hidden = 0;
    final rows = <Widget>[];
    if (isFreeDay) {
      rows.add(
        Text(
          freeLabel.isNotEmpty
              ? Strings.format('lunch_no_school_named', {'label': freeLabel})
              : Strings.get('lunch_no_school_note'),
          style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
        ),
      );
    }
    if (!orderOpen) {
      final deadline = c.orderDeadline?.call(day);
      final detail = deadline == null
          ? ''
          : ' (${deadline.day.toString().padLeft(2, '0')}.${deadline.month.toString().padLeft(2, '0')}.${deadline.year} ${deadline.hour.toString().padLeft(2, '0')}:${deadline.minute.toString().padLeft(2, '0')})';
      rows.add(
        Text(
          '${Strings.get('lunch_order_closed')}$detail',
          style: TextStyle(color: tok.faint, fontSize: tok.fsSmall),
        ),
      );
    }
    final daySoup = c.soups[day] ?? '';
    if (daySoup.isNotEmpty) {
      rows.add(_soupRow(tok, daySoup));
    } else if (soup.isNotEmpty) {
      rows.add(
        Text(
          '${Strings.get('lunch_soup')}: $soup',
          style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
        ),
      );
    }
    for (final e in meals.entries) {
      if (e.key.contains('&-1&')) continue;
      if (c.lunchHidden.contains(e.key)) {
        hidden++;
        continue;
      }
      final selected = ordered == e.key && !isCancelled;
      rows.add(
        _mealRow(
          context,
          tok,
          day,
          e.key,
          e.value,
          selected,
          disabled: !orderOpen,
          sharedSoup: soup,
        ),
      );
    }
    final noLunchSelected =
        isCancelled || (ordered != null && ordered == deorderId);
    rows.add(
      _choiceBox(
        tok,
        selected: noLunchSelected,
        disabled: !orderOpen,
        onTap: () {
          if (!orderOpen) {
            appSnack(context, Strings.get('lunch_order_closed'));
            return;
          }
          if (deorderId != null) {
            if (!c.orderLunch(day, deorderId)) {
              appSnack(context, Strings.get('lunch_order_closed'));
            }
          } else {
            c.cancelLunchOrder(day);
          }
        },
        child: Text(
          Strings.get('no_order_option'),
          style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
        ),
      ),
    );
    if (hidden > 0) {
      rows.add(
        Text(
          Strings.format('hidden_meals', {'n': hidden}),
          style: TextStyle(color: tok.faint, fontSize: tok.fsSmall),
        ),
      );
    }
    final parsed = parseCzDate(day);
    final now = nowFor?.call() ?? clock.now();
    final today = DateTime(now.year, now.month, now.day);
    final isPast = parsed != null && parsed.isBefore(today);
    final expKey = 'lunch:$day';
    final expanded = c.isDayExpanded(expKey, defaultValue: !isPast);

    final title = Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '${w.dayName(day)} ${w.czDayYear(day)}',
          style: TextStyle(
            color: tok.text,
            fontSize: tok.fsBody,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (isFreeDay)
          w.Badge(
            text: Strings.get('lunch_no_school_badge'),
            tok: tok,
            kind: 'warning',
          ),
        if (status != null)
          w.Badge(
            text: status,
            tok: tok,
            kind: c.cancelledLunches.contains(day)
                ? 'warning'
                : (status == Strings.get('web_ordered') ? 'sent' : 'pending'),
          ),
        if (!orderOpen)
          w.Badge(
            text: Strings.get('lunch_closed_badge'),
            tok: tok,
            kind: 'warning',
          ),
      ],
    );
    return Container(
      decoration: BoxDecoration(
        color: tok.card,
        borderRadius: BorderRadius.circular(tok.radiusMd),
        border: Border.all(color: tok.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: ValueKey('tile_$day'),
        title: title,
        shape: const Border(),
        collapsedShape: const Border(),
        backgroundColor: tok.card,
        collapsedBackgroundColor: tok.card,
        iconColor: tok.accent,
        collapsedIconColor: tok.accent,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        childrenPadding: EdgeInsets.all(tok.pad),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        initiallyExpanded: expanded,
        onExpansionChanged: (v) => c.setDayExpanded(expKey, v),
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            rows[i],
            if (i != rows.length - 1) SizedBox(height: tok.gap / 2),
          ],
        ],
      ),
    );
  }

  /// A bordered, tappable pick row with a radio dot (meal / no lunch).
  Widget _choiceBox(
    Tokens tok, {
    required bool selected,
    required bool disabled,
    required VoidCallback onTap,
    required Widget child,
    String? tooltip,
    Widget? trailing,
  }) {
    final box = Opacity(
      opacity: disabled ? 0.55 : 1.0,
      child: Material(
        color: selected ? tintColor(tok.accent, 0.14) : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: selected ? tok.accent : tok.border),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: disabled ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
            child: Row(
              spacing: 10,
              children: [
                w.RadioDot(tok: tok, selected: selected),
                Expanded(child: child),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? box : Tooltip(message: tooltip, child: box);
  }

  Widget _mealRow(
    BuildContext context,
    Tokens tok,
    String day,
    String mid,
    String name,
    bool selected, {
    bool disabled = false,
    String sharedSoup = '',
  }) {
    final (soup, main, allergens) = splitMeal(name);
    final label = sharedSoup.isNotEmpty && soup == sharedSoup
        ? main
        : (soup.isEmpty ? main : '$soup; $main');
    return _choiceBox(
      tok,
      selected: selected,
      disabled: disabled,
      tooltip: _allergenTooltip(allergens),
      onTap: () {
        if (!controller.orderLunch(day, mid)) {
          appSnack(context, Strings.get('lunch_order_closed'));
        }
      },
      child: Text(
        label.isEmpty ? displayMealName(name) : label,
        style: TextStyle(
          color: selected ? tok.accent : (disabled ? tok.muted : tok.text),
          fontSize: tok.fsBody,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
      trailing: _allergenCodes(tok, allergens),
    );
  }

  /// The day's soup: not orderable, so a plain line where the meals have
  /// their radio dot.
  Widget _soupRow(Tokens tok, String text) {
    final (_, name, allergens) = splitMeal(text);
    final tooltip = _allergenTooltip(allergens);
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 12, 2),
      child: Row(
        spacing: 10,
        children: [
          Icon(Icons.soup_kitchen_outlined, size: 20, color: tok.muted),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${Strings.get('lunch_soup')}: ',
                    style: TextStyle(
                      color: tok.muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(
                    text: name,
                    style: TextStyle(color: tok.text),
                  ),
                ],
              ),
              style: TextStyle(fontSize: tok.fsBody),
            ),
          ),
          ?_allergenCodes(tok, allergens),
        ],
      ),
    );
    return tooltip == null ? row : Tooltip(message: tooltip, child: row);
  }

  /// Allergen codes (`01, 07`); the ones the diner avoids in red, with a
  /// warning sign. Null without codes.
  Widget? _allergenCodes(Tokens tok, String codes) {
    if (codes.isEmpty) return null;
    final avoided = controller.avoidedAllergens;
    final parts = codes.split(', ');
    var hit = false;
    final spans = <InlineSpan>[];
    for (var i = 0; i < parts.length; i++) {
      final bad = avoided.contains(allergenNumber(parts[i]));
      hit = hit || bad;
      if (i > 0) spans.add(const TextSpan(text: ', '));
      spans.add(
        TextSpan(
          text: parts[i],
          style: bad
              ? TextStyle(color: tok.red, fontWeight: FontWeight.w700)
              : null,
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        if (hit) Icon(Icons.warning_amber_rounded, size: 16, color: tok.red),
        Text.rich(
          TextSpan(children: spans),
          style: TextStyle(color: tok.faint, fontSize: tok.fsTiny),
        ),
      ],
    );
  }

  /// "Allergens:" plus one line per code with its name; a warning line
  /// when one is avoided. Null without codes.
  String? _allergenTooltip(String codes) {
    if (codes.isEmpty) return null;
    final lines = ['${Strings.get('allergens')}:'];
    var hit = false;
    for (final code in codes.split(', ')) {
      final n = allergenNumber(code);
      final known = n != null && n >= 1 && n <= 14;
      lines.add(known ? '$code – ${Strings.get('allergen_$n')}' : code);
      hit = hit || controller.avoidedAllergens.contains(n);
    }
    if (hit) lines.add('⚠ ${Strings.get('allergen_avoided')}');
    return lines.join('\n');
  }

  Widget _sidebar(BuildContext context, Tokens tok) => ListView(
    padding: EdgeInsets.zero,
    children: [
      Row(
        spacing: 4,
        children: [
          Expanded(
            child: Text(
              Strings.get('ai_tools'),
              style: TextStyle(
                color: tok.text,
                fontSize: tok.fsBody,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            tooltip: Strings.get('hide_sidebar'),
            iconSize: 18,
            icon: const Icon(Icons.close),
            onPressed: () => _setSidebar(false),
          ),
        ],
      ),
      SizedBox(height: tok.gap),
      _aiCard(context, tok),
      SizedBox(height: tok.gap),
      _blacklistCard(context, tok),
      SizedBox(height: tok.gap),
      _allergenCard(context, tok),
    ],
  );

  /// Tick the allergens to avoid; the chips double as the legend of
  /// what each number means.
  Widget _allergenCard(BuildContext context, Tokens tok) {
    final c = controller;
    return w.AppCard(
      tok: tok,
      children: [
        Row(
          spacing: 8,
          children: [
            Icon(Icons.health_and_safety_outlined, size: 18, color: tok.muted),
            Expanded(
              child: Text(
                Strings.get('allergens'),
                style: TextStyle(
                  color: tok.text,
                  fontSize: tok.fsBody,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            w.Badge(text: '${c.avoidedAllergens.length}', tok: tok),
          ],
        ),
        Text(
          Strings.get('allergens_hint'),
          style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final n in core.allergenNumbers)
              _allergenChip(context, tok, n, c.avoidedAllergens.contains(n)),
          ],
        ),
      ],
    );
  }

  Widget _allergenChip(BuildContext context, Tokens tok, int n, bool on) =>
      FilterChip(
        key: Key('allergen:$n'),
        selected: on,
        visualDensity: VisualDensity.compact,
        checkmarkColor: tok.red,
        selectedColor: tintColor(tok.red, 0.16),
        side: BorderSide(color: on ? tok.red : tok.border),
        label: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: n.toString().padLeft(2, '0'),
                style: TextStyle(
                  color: on ? tok.red : tok.muted,
                  fontWeight: FontWeight.w700,
                ),
              ),
              TextSpan(
                text: '  ${Strings.get('allergen_$n')}',
                style: TextStyle(color: tok.text),
              ),
            ],
          ),
          style: TextStyle(fontSize: tok.fsSmall),
        ),
        onSelected: (_) {
          if (!controller.toggleAllergen(n)) {
            appSnack(context, Strings.get('save_failed'));
          }
        },
      );

  /// Runs the AI recommendation flow (or snacks why it cannot run).
  /// Port of `LunchView.recommend`.
  Future<void> recommend([BuildContext? context]) async {
    final c = controller;
    final hasKey = (c.get('gemini_api_key') ?? '').toString().isNotEmpty;
    if (!hasKey) {
      if (context != null) appSnack(context, Strings.get('recommend_no_key'));
      return;
    }
    if (c.aiRunning) {
      if (context != null) appSnack(context, Strings.get('ai_already_running'));
      return;
    }
    await onRecommend?.call();
  }

  Widget _aiCard(BuildContext context, Tokens tok) {
    final c = controller;
    final hasKey = (c.get('gemini_api_key') ?? '').toString().isNotEmpty;
    final model = (c.get('gemini_model', '') ?? '').toString();
    return w.AppCard(
      tok: tok,
      children: [
        Row(
          spacing: 8,
          children: [
            Icon(Icons.auto_awesome_outlined, size: 18, color: tok.accent),
            Expanded(
              child: Text(
                Strings.get('ai_section'),
                style: TextStyle(
                  color: tok.text,
                  fontSize: tok.fsBody,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (model.isNotEmpty) w.Badge(text: model, tok: tok),
          ],
        ),
        _PrefsField(
          tok: tok,
          label: Strings.get('ai_prefs'),
          hint: Strings.get('ai_prefs_hint'),
          value: c.lunchPrefs,
          onChanged: (v) {
            c.lunchPrefs = v;
            c.setLunchPrefsHook?.call(v);
          },
        ),
        if (!hasKey) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Icon(Icons.info_outline, size: 16, color: tok.accent),
              Expanded(
                child: Text(
                  Strings.get('ai_no_key'),
                  style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => openUrl(aiStudioUrl),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text(Strings.get('ai_key_link')),
              ),
              OutlinedButton(
                onPressed: onOpenSettings,
                child: Text(Strings.get('go_to_settings')),
              ),
            ],
          ),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ElevatedButton.icon(
              onPressed: !hasKey || c.aiRunning
                  ? null
                  : () async {
                      await recommend(context);
                    },
              icon: const Icon(Icons.auto_awesome_outlined, size: 18),
              label: Text(Strings.get('recommend')),
            ),
            OutlinedButton(
              onPressed: () => c.applyFoodFilter(c.lunchPrefs),
              child: Text(Strings.get('apply_filter_long')),
            ),
          ],
        ),
        Text(
          Strings.get('filter_hint'),
          style: TextStyle(color: tok.faint, fontSize: tok.fsSmall),
        ),
        if (!hasKey)
          Text(
            Strings.get('recommend_no_key'),
            style: TextStyle(color: tok.yellow, fontSize: tok.fsSmall),
          ),
        if (c.aiRunning) ...[
          Row(
            spacing: 8,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: tok.accent,
                ),
              ),
              Text(
                Strings.get('ai_running'),
                style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
              ),
            ],
          ),
          LinearProgressIndicator(
            color: tok.accent,
            backgroundColor: tok.overlay,
          ),
        ],
        if (c.lunchHidden.isNotEmpty)
          Text(
            Strings.format('hidden_meals', {'n': c.lunchHidden.length}),
            style: TextStyle(color: tok.faint, fontSize: tok.fsSmall),
          ),
      ],
    );
  }

  Widget _blacklistCard(BuildContext context, Tokens tok) {
    final c = controller;
    final words = c.blacklistWords();
    return w.AppCard(
      tok: tok,
      children: [
        Row(
          spacing: 8,
          children: [
            Icon(Icons.block_outlined, size: 18, color: tok.muted),
            Expanded(
              child: Text(
                Strings.get('blacklist_section'),
                style: TextStyle(
                  color: tok.text,
                  fontSize: tok.fsBody,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            w.Badge(text: '${words.length}', tok: tok),
          ],
        ),
        Text(
          Strings.get('blacklist_hint'),
          style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
        ),
        if (words.isEmpty)
          Text(
            Strings.get('no_blacklist'),
            style: TextStyle(color: tok.faint, fontSize: tok.fsSmall),
          ),
        for (final word in words)
          Container(
            padding: const EdgeInsets.fromLTRB(10, 2, 4, 2),
            decoration: BoxDecoration(
              color: tok.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: tok.border),
            ),
            child: Row(
              spacing: 4,
              children: [
                Expanded(
                  child: Text(
                    word,
                    style: TextStyle(color: tok.text, fontSize: tok.fsSmall),
                  ),
                ),
                IconButton(
                  tooltip: Strings.get('delete'),
                  iconSize: 18,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => c.removeBlacklistWord(word),
                ),
              ],
            ),
          ),
        _BlacklistAdd(
          tok: tok,
          onAdd: (text) {
            if (!c.addBlacklistWord(text)) {
              appSnack(
                context,
                c.blacklistEditError.isNotEmpty
                    ? c.blacklistEditError
                    : Strings.get('blacklist_add_failed'),
              );
              return false;
            }
            return true;
          },
        ),
      ],
    );
  }

  static DateTime? _parseCz(String day) {
    final m = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$').firstMatch(day);
    if (m == null) return null;
    try {
      return DateTime(
        int.parse(m.group(3)!),
        int.parse(m.group(2)!),
        int.parse(m.group(1)!),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Caption above a multi-line box with a hint (Python `labeled_field`);
/// keeps its own controller so typing survives rebuilds.
class _PrefsField extends StatefulWidget {
  final Tokens tok;
  final String label;
  final String hint;
  final String value;
  final ValueChanged<String> onChanged;
  const _PrefsField({
    required this.tok,
    required this.label,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_PrefsField> createState() => _PrefsFieldState();
}

class _PrefsFieldState extends State<_PrefsField> {
  late final TextEditingController _c = TextEditingController(
    text: widget.value,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tok = widget.tok;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        Text(
          widget.label,
          style: TextStyle(
            color: tok.text,
            fontSize: tok.fsSmall,
            fontWeight: FontWeight.w700,
          ),
        ),
        TextField(
          controller: _c,
          minLines: 3,
          maxLines: null,
          style: TextStyle(color: tok.text, fontSize: tok.fsBody),
          decoration: InputDecoration(hintText: widget.hint),
          onChanged: widget.onChanged,
        ),
      ],
    );
  }
}

/// The blacklist's "add a word" row.
class _BlacklistAdd extends StatefulWidget {
  final Tokens tok;
  final bool Function(String text) onAdd;
  const _BlacklistAdd({required this.tok, required this.onAdd});

  @override
  State<_BlacklistAdd> createState() => _BlacklistAddState();
}

class _BlacklistAddState extends State<_BlacklistAdd> {
  final TextEditingController _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _add() {
    if (widget.onAdd(_c.text)) _c.clear();
  }

  @override
  Widget build(BuildContext context) {
    final tok = widget.tok;
    return Row(
      spacing: 8,
      children: [
        Expanded(
          child: TextField(
            controller: _c,
            style: TextStyle(color: tok.text, fontSize: tok.fsBody),
            decoration: InputDecoration(hintText: Strings.get('add_word')),
            onSubmitted: (_) => _add(),
          ),
        ),
        ElevatedButton(onPressed: _add, child: Text(Strings.get('add'))),
      ],
    );
  }
}
