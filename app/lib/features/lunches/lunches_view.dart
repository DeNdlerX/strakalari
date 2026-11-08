import 'package:flutter/material.dart';

import 'package:app/features/lunches/lunch_filter.dart';
import 'package:app/features/lunches/lunches_controller.dart';
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
              title: Text(Str.t('lunch_title')),
              subtitle: Text(updatedLabel)),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(Str.t('strava_disabled_title')),
                  Text(Str.t('strava_disabled_msg')),
                  TextButton(
                      onPressed: onOpenSettings,
                      child: Text(Str.t('go_to_settings'))),
                ],
              ),
            ),
          ),
        ],
      );
    }
    final now = (nowFor?.call() ?? DateTime.now());
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
        child: Text(Str.t('pick_hint')),
      ),
      _sendRow(context),
      if (past.isNotEmpty)
        TextButton(
          onPressed: () {
            c.showPastLunches = !c.showPastLunches;
          },
          child: Text(c.showPastLunches
              ? Str.t('lunch_hide_past')
              : Str.t('lunch_show_past', {'n': past.length})),
        ),
      for (final day in [if (c.showPastLunches) ...past, ...upcoming])
        _dayCard(context, day, c.food[day] ?? {}),
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
        child: Text(Str.t('no_data')),
      ));
      menu.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(Str.t(reason)),
      ));
    }
    final header = ListTile(
      title: Text(Str.t('lunch_title')),
      subtitle: Text(updatedLabel),
      trailing: IconButton(
        tooltip: sidebarOpen
            ? Str.t('hide_sidebar')
            : Str.t('show_sidebar'),
        icon: const Icon(Icons.tune_outlined),
        onPressed: () {
          if (narrow) {
            c.lunchToolsOpen = !c.lunchToolsOpen;
          } else {
            c.sidebarOpen = !c.sidebarOpen;
          }
        },
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
                ok ? Str.t('orders_sent') : Str.t('orders_failed'));
          } else if (payload.isEmpty) {
            appSnack(context, Str.t('no_changes'));
          }
        },
        icon: const Icon(Icons.send_outlined),
        label: Text('${Str.t('send_orders')}'
            '${pending > 0 ? ' ($pending)' : ''}'),
      ),
    );
  }

  /// Status badge for one day: cancelled / web-ordered / to-send / none.
  /// Port of LunchView._day_status.
  String? dayStatus(String day) {
    final c = controller;
    final ordered = c.orders[day] ?? c.webOrders[day];
    if (c.cancelledLunches.contains(day)) return Str.t('no_lunch');
    if (ordered == null || ordered.isEmpty) return null;
    if (!c.lunchIsChange(day)) {
      if ((c.webOrders[day] ?? '').isNotEmpty) {
        return Str.t('web_ordered');
      }
      return null;
    }
    if (c.isOrderOpen != null) {
      try {
        if (!c.isOrderOpen!(day)) return null;
      } catch (_) {}
    }
    return Str.t('to_send');
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
      rows.add(Text(Str.t('lunch_order_closed')));
    }
    if (soup.isNotEmpty) {
      rows.add(Text('${Str.t('lunch_soup')}: $soup'));
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
      label: Str.t('no_order_option'),
      onTap: () {
        if (!orderOpen) {
          appSnack(context, Str.t('lunch_order_closed'));
          return;
        }
        if (deorderId != null) {
          if (!c.orderLunch(day, deorderId)) {
            appSnack(context, Str.t('lunch_order_closed'));
          }
        } else {
          c.cancelLunchOrder(day);
        }
      },
    ));
    if (hidden > 0) {
      rows.add(Text(Str.t('hidden_meals', {'n': hidden})));
    }
    return Card(
      child: ExpansionTile(
        title: Row(
          children: [
            Expanded(child: Text(day)),
            if (status != null) Chip(label: Text(status)),
            if (!orderOpen) Chip(label: Text(Str.t('lunch_closed_badge'))),
          ],
        ),
        initiallyExpanded: true,
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
            : Text('${Str.t('allergens')}: $allergens'),
        selected: selected,
        onTap: disabled
            ? null
            : () {
                if (!controller.orderLunch(day, mid)) {
                  appSnack(context, Str.t('lunch_order_closed'));
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
        ListTile(title: Text(Str.t('ai_tools'))),
        _aiCard(context),
        _blacklistCard(context),
      ];

  Widget _sidebar(BuildContext context) => ListView(
        children: _sideChildren(context),
      );

  Widget _aiCard(BuildContext context) {
    final c = controller;
    final hasKey = (c.get('gemini_api_key') ?? '').toString().isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(Str.t('ai_section')),
            TextField(
              decoration: InputDecoration(
                  labelText: Str.t('ai_prefs'),
                  hintText: Str.t('ai_prefs_hint')),
              controller: TextEditingController(text: c.lunchPrefs),
              maxLines: 2,
              onChanged: (v) => c.lunchPrefs = v,
            ),
            if (!hasKey) Text(Str.t('ai_no_key')),
            if (!hasKey)
              Row(
                children: [
                  TextButton(
                      onPressed: onOpenSettings,
                      child: Text(Str.t('go_to_settings'))),
                ],
              ),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: !hasKey || c.aiRunning
                      ? null
                      : () async {
                          await onRecommend?.call();
                        },
                  child: Text(Str.t('recommend')),
                ),
                OutlinedButton(
                  onPressed: () => c.applyFoodFilter(c.lunchPrefs),
                  child: Text(Str.t('apply_filter_long')),
                ),
              ],
            ),
            Text(Str.t('filter_hint')),
            if (c.aiRunning) const LinearProgressIndicator(),
            if (c.lunchHidden.isNotEmpty)
              Text(Str.t('hidden_meals', {'n': c.lunchHidden.length})),
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
                Expanded(child: Text(Str.t('blacklist_section'))),
                Chip(label: Text('${words.length}')),
              ],
            ),
            Text(Str.t('blacklist_hint')),
            if (words.isEmpty) Text(Str.t('no_blacklist')),
            for (final w in words)
              ListTile(
                title: Text(w),
                trailing: IconButton(
                  tooltip: Str.t('delete'),
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
                            labelText: Str.t('add_word')))),
                FilledButton(
                  onPressed: () {
                    if (!c.addBlacklistWord(draft.text)) {
                      appSnack(
                          context,
                          c.blacklistEditError.isNotEmpty
                              ? c.blacklistEditError
                              : Str.t('save_failed'));
                    } else {
                      draft.clear();
                    }
                  },
                  child: Text(Str.t('add')),
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
