import 'package:clock/clock.dart';
import 'package:app/l10n/strings.dart';
import 'package:flutter/material.dart';

import 'package:app/features/lunches/lunches_format.dart';
import 'package:app/features/lunches/lunches_controller.dart';
import '../common/format.dart';
import 'package:app/widgets/overlays.dart';

/// Obědy: weekly menu with a radio picker + AI/blacklist side panel.
/// Port of views/lunches.py.
class LunchesView extends StatelessWidget {
  final LunchController controller;
  final bool narrow;
  final String updatedLabel;
  final VoidCallback? onOpenSettings;
  final Future<void> Function()? onRecommend;
  final Future<bool> Function(Map<String, String> payload)? onSubmit;
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
    if (!c.stravaOn) {
      return ListView(
        children: [
          ListTile(
              title: Text(Strings.get('lunch_title')),
              subtitle: Text(updatedLabel)),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(Strings.get('strava_disabled_title')),
                  Text(Strings.get('strava_disabled_msg')),
                  TextButton(
                      onPressed: onOpenSettings,
                      child: Text(Strings.get('go_to_settings'))),
                ],
              ),
            ),
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
    final menu = <Widget>[
      Padding(
        padding: const EdgeInsets.all(12),
        child: Text(Strings.get('pick_hint')),
      ),
      TutorialAnchor(
        anchorKey: 'lunch_send',
        child: _sendRow(context),
      ),
      if (past.isNotEmpty)
        TextButton(
          onPressed: () {
            final next = !c.showPastLunches;
            c.showPastLunches = next;
            c.setShowPastLunchesHook?.call(next);
          },
          child: Text(c.showPastLunches
              ? Strings.get('lunch_hide_past')
              : Strings.format('lunch_show_past', {'n': past.length})),
        ),
      if (c.showPastLunches)
        for (final day in past) _dayCard(context, day, c.food[day] ?? {}),
      for (var i = 0; i < upcoming.length; i++)
        if (i == 0)
          TutorialAnchor(
            anchorKey: 'lunch_day',
            child: _dayCard(context, upcoming[i], c.food[upcoming[i]] ?? {}),
          )
        else
          _dayCard(context, upcoming[i], c.food[upcoming[i]] ?? {}),
    ];
    if (c.food.isEmpty) {
      // Why the last refresh brought no menu (STRAVA_STATUS_KEY).
      final reason = {
        'no_login': 'lunch_empty_no_login',
        'empty': 'lunch_empty_no_menu',
      }['${c.get('strava_status', '')}'] ??
          'need_credentials';
      menu.add(Padding(
        padding: const EdgeInsets.all(12),
        child: Text(Strings.get('no_data')),
      ));
      menu.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(Strings.get(reason)),
      ));
    }
    final header = ListTile(
      title: Text(Strings.get('lunch_title')),
      subtitle: Text(updatedLabel),
      trailing: TutorialAnchor(
        anchorKey: 'lunch_tools',
        child: IconButton(
          tooltip: sidebarOpen
              ? Strings.get('hide_sidebar')
              : Strings.get('show_sidebar'),
          icon: const Icon(Icons.tune_outlined),
          onPressed: () {
            if (narrow) {
              final next = !c.lunchToolsOpen;
              c.lunchToolsOpen = next;
              c.setLunchToolsHook?.call(next);
            } else {
              final next = !c.sidebarOpen;
              c.sidebarOpen = next;
              c.setSidebarHook?.call(next);
            }
          },
        ),
      ),
    );
    if (narrow && !sidebarOpen) {
      return ListView(children: [header, ...menu]);
    }
    if (narrow) {
      return ListView(children: [header, ..._sideChildren(context)]);
    }
    return Column(
      children: [
        header,
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: ListView(children: menu)),
              if (sidebarOpen)
                SizedBox(width: 360, child: _sidebar(context)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sendRow(BuildContext context) {
    final c = controller;
    var pending = 0;
    for (final e in c.orders.entries) {
      if (e.value.isEmpty ||
          !c.pendingOrders.contains(e.key) ||
          !c.lunchIsChange(e.key)) {
        continue;
      }
      if (c.isOrderOpen != null) {
        try {
          if (!c.isOrderOpen!(e.key)) continue;
        } catch (_) {
          continue;
        }
      }
      pending++;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: FilledButton.icon(
        onPressed: () async {
          final payload = {
            for (final e in c.orders.entries)
              if (e.value.isNotEmpty &&
                  c.pendingOrders.contains(e.key) &&
                  c.lunchIsChange(e.key))
                e.key: e.value,
          };
          if (onSubmit != null) {
            final ok = await onSubmit!(payload);
            if (!context.mounted) return;
            appSnack(context,
                ok ? Strings.get('orders_sent') : Strings.get('orders_failed'));
          } else if (payload.isEmpty) {
            appSnack(context, Strings.get('no_changes'));
          }
        },
        icon: const Icon(Icons.send_outlined),
        label: Text('${Strings.get('send_orders')}'
            '${pending > 0 ? ' ($pending)' : ''}'),
      ),
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
      if ((c.webOrders[day] ?? '').isNotEmpty) {
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
      BuildContext context, String day, Map<String, String> meals) {
    final c = controller;
    var orderOpen = true;
    if (c.isOrderOpen != null) {
      try {
        orderOpen = c.isOrderOpen!(day);
      } catch (_) {
        orderOpen = true;
      }
    }
    final ordered = c.orders[day] ?? c.webOrders[day];
    final isCancelled = c.cancelledLunches.contains(day);
    final status = dayStatus(day);
    final soup = sharedSoup(meals);
    String? deorderId;
    for (final e in meals.entries) {
      if (e.key.contains('&-1&')) deorderId = e.key;
    }
    var hidden = 0;
    final rows = <Widget>[];
    if (!orderOpen) {
      rows.add(Text(Strings.get('lunch_order_closed')));
    }
    if (soup.isNotEmpty) {
      rows.add(Text('${Strings.get('lunch_soup')}: $soup'));
    }
    for (final e in meals.entries) {
      if (e.key.contains('&-1&')) continue;
      if (c.lunchHidden.contains(e.key)) {
        hidden++;
        continue;
      }
      final selected = ordered == e.key && !isCancelled;
      rows.add(_mealRow(context, day, e.key, e.value, selected,
          disabled: !orderOpen, sharedSoup: soup));
    }
    final noLunchSelected =
        isCancelled || (ordered != null && ordered == deorderId);
    rows.add(_pickRow(
      context,
      selected: noLunchSelected,
      disabled: !orderOpen,
      label: Strings.get('no_order_option'),
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
    ));
    if (hidden > 0) {
      rows.add(Text(Strings.format('hidden_meals', {'n': hidden})));
    }
    final parsed = parseCzDate(day);
    final now = nowFor?.call() ?? clock.now();
    final today = DateTime(now.year, now.month, now.day);
    final isPast = parsed != null && parsed.isBefore(today);
    final expKey = 'lunch:$day';
    final expanded = c.isDayExpanded(expKey, defaultValue: !isPast);

    return Card(
      child: ExpansionTile(
        key: ValueKey('tile_$day'),
        title: Row(
          children: [
            Expanded(child: Text(day)),
            if (status != null) Chip(label: Text(status)),
            if (!orderOpen) Chip(label: Text(Strings.get('lunch_closed_badge'))),
          ],
        ),
        initiallyExpanded: expanded,
        onExpansionChanged: (v) => c.setDayExpanded(expKey, v),
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: rows),
          ),
        ],
      ),
    );
  }

  Widget _mealRow(BuildContext context, String day, String mid,
      String name, bool selected,
      {bool disabled = false, String sharedSoup = ''}) {
    final (soup, main, allergens) = splitMeal(name);
    final label =
        sharedSoup.isNotEmpty && soup == sharedSoup ? main : (soup.isEmpty ? main : '$soup; $main');
    return Opacity(
      opacity: disabled ? 0.55 : 1.0,
      child: ListTile(
        leading: Icon(selected
            ? Icons.radio_button_checked
            : Icons.radio_button_unchecked),
        title: Text(label.isEmpty ? displayMealName(name) : label),
        subtitle: allergens.isEmpty
            ? null
            : Text('${Strings.get('allergens')}: $allergens'),
        selected: selected,
        onTap: disabled
            ? null
            : () {
                if (!controller.orderLunch(day, mid)) {
                  appSnack(context, Strings.get('lunch_order_closed'));
                }
              },
      ),
    );
  }

  Widget _pickRow(BuildContext context,
      {required bool selected,
      required bool disabled,
      required String label,
      required VoidCallback onTap}) {
    return Opacity(
      opacity: disabled ? 0.55 : 1.0,
      child: ListTile(
        leading: Icon(selected
            ? Icons.radio_button_checked
            : Icons.radio_button_unchecked),
        title: Text(label),
        selected: selected,
        onTap: disabled ? null : onTap,
      ),
    );
  }

  List<Widget> _sideChildren(BuildContext context) => [
        ListTile(title: Text(Strings.get('ai_tools'))),
        _aiCard(context),
        _blacklistCard(context),
      ];

  Widget _sidebar(BuildContext context) => ListView(
        children: _sideChildren(context),
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

  Widget _aiCard(BuildContext context) {
    final c = controller;
    final hasKey = (c.get('gemini_api_key') ?? '').toString().isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(Strings.get('ai_section')),
            TextField(
              decoration: InputDecoration(
                  labelText: Strings.get('ai_prefs'),
                  hintText: Strings.get('ai_prefs_hint')),
              controller: TextEditingController(text: c.lunchPrefs),
              maxLines: 2,
              onChanged: (v) {
                c.lunchPrefs = v;
                c.setLunchPrefsHook?.call(v);
              },
            ),
            if (!hasKey) Text(Strings.get('ai_no_key')),
            if (!hasKey)
              Row(
                children: [
                  TextButton(
                      onPressed: onOpenSettings,
                      child: Text(Strings.get('go_to_settings'))),
                ],
              ),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: !hasKey || c.aiRunning
                      ? null
                      : () async {
                          await recommend(context);
                        },
                  child: Text(Strings.get('recommend')),
                ),
                OutlinedButton(
                  onPressed: () => c.applyFoodFilter(c.lunchPrefs),
                  child: Text(Strings.get('apply_filter_long')),
                ),
              ],
            ),
            Text(Strings.get('filter_hint')),
            if (c.aiRunning) const LinearProgressIndicator(),
            if (c.lunchHidden.isNotEmpty)
              Text(Strings.format('hidden_meals', {'n': c.lunchHidden.length})),
          ],
        ),
      ),
    );
  }

  Widget _blacklistCard(BuildContext context) {
    final c = controller;
    final words = c.blacklistWords();
    final draft = TextEditingController();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(Strings.get('blacklist_section'))),
                Chip(label: Text('${words.length}')),
              ],
            ),
            Text(Strings.get('blacklist_hint')),
            if (words.isEmpty) Text(Strings.get('no_blacklist')),
            for (final w in words)
              ListTile(
                title: Text(w),
                trailing: IconButton(
                  tooltip: Strings.get('delete'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => c.removeBlacklistWord(w),
                ),
              ),
            Row(
              children: [
                Expanded(
                    child: TextField(
                        controller: draft,
                        decoration: InputDecoration(
                            labelText: Strings.get('add_word')))),
                FilledButton(
                  onPressed: () {
                    if (!c.addBlacklistWord(draft.text)) {
                      appSnack(
                          context,
                          c.blacklistEditError.isNotEmpty
                              ? c.blacklistEditError
                              : Strings.get('save_failed'));
                    } else {
                      draft.clear();
                    }
                  },
                  child: Text(Strings.get('add')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static DateTime? _parseCz(String day) {
    final m =
        RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$').firstMatch(day);
    if (m == null) return null;
    try {
      return DateTime(
          int.parse(m.group(3)!), int.parse(m.group(2)!), int.parse(m.group(1)!));
    } catch (_) {
      return null;
    }
  }
}
