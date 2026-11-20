// Phone menu: the screens that don't fit the bottom bar.
//
// Port of strakalari/flet_ui/views/more.py.

import 'package:flutter/material.dart';

import '../controllers/app_state.dart';
import '../features/common/app_tokens.dart';
import '../l10n/strings.dart';
import '../widgets/account_switcher.dart' show accountInitial;

/// Phone menu: the screens that don't fit the bottom bar.
/// Port of `strakalari/flet_ui/views/more.py`.
class MorePage extends StatelessWidget {
  final void Function(String route) onOpen;
  final bool isAndroid;
  final AppTokens? tokens;

  /// Multi-account header card (§10.1); omitted when single-account / degraded.
  final String? activeAccountLabel;
  final String? activeAccountSubtitle;
  final VoidCallback? onSwitchAccount;

  const MorePage({
    super.key,
    required this.onOpen,
    this.isAndroid = false,
    this.tokens,
    this.activeAccountLabel,
    this.activeAccountSubtitle,
    this.onSwitchAccount,
  });

  static const List<(String, IconData, String)> entries = [
    ('absences', Icons.event_busy_outlined, 'nav_absences'),
    ('activity', Icons.history_outlined, 'nav_activity'),
    ('settings', Icons.settings_outlined, 'nav_settings'),
  ];

  static const (String, IconData, String) alarmEntry =
      ('alarm', Icons.alarm, 'sec_alarm');

  List<(String, IconData, String)> visibleEntries() {
    if (!isAndroid) return entries;
    // Android inserts the alarm shortcut before settings.
    return [
      ...entries.take(entries.length - 1),
      alarmEntry,
      entries.last,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = tokens ?? AppTokens.of(Theme.of(context).brightness);
    final items = visibleEntries();
    // No padding of its own: the shell already gives the page its gutters
    // (views/more.py has none either).
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Padding(
          padding: EdgeInsets.only(bottom: t.gap / 2 + 2),
          child: Text(
            Strings.get('nav_more'),
            style: TextStyle(
              color: t.text,
              fontSize: t.fsTitle,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        if (onSwitchAccount != null &&
            (activeAccountLabel ?? '').isNotEmpty) ...[
          Material(
            key: const Key('more:account_card'),
            color: t.card,
            borderRadius: BorderRadius.circular(t.radiusMd),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: CircleAvatar(
                radius: 18,
                backgroundColor: tintColor(t.accent, 0.18),
                foregroundColor: t.accent,
                child: Text(
                  accountInitial(activeAccountLabel!),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              title: Text(
                activeAccountLabel!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: t.text,
                  fontSize: t.fsSection,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: (activeAccountSubtitle ?? '').isNotEmpty
                  ? Text(
                      activeAccountSubtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: t.muted,
                        fontSize: t.fsSmall,
                      ),
                    )
                  : null,
              trailing: Icon(Icons.swap_horiz, color: t.accent),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(t.radiusMd),
              ),
              onTap: onSwitchAccount,
            ),
          ),
          SizedBox(height: t.gap / 2 + 2),
        ],
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) SizedBox(height: t.gap / 2 + 2),
          Material(
            color: t.card,
            borderRadius: BorderRadius.circular(t.radiusMd),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: Icon(items[i].$2, color: t.accent),
              title: Text(
                Strings.get(items[i].$3),
                style: TextStyle(
                  color: t.text,
                  fontSize: t.fsSection,
                ),
              ),
              trailing: Icon(Icons.chevron_right, color: t.faint),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(t.radiusMd),
              ),
              onTap: () => onOpen(items[i].$1),
            ),
          ),
        ],
      ],
    );
  }
}

/// Navigates from the More menu into a destination screen.
/// Port of `_open(state, route)` in strakalari/flet_ui/views/more.py.
void openMoreRoute(AppState state, String route, void Function(String) go) {
  if (route == 'alarm') {
    state.settingsSection = 'alarm';
    state.settingsOpen = true; // Straight into the section, not the list.
    go('settings');
  } else if (route == 'settings') {
    state.settingsOpen = false; // From the menu, Settings opens on its list.
    go('settings');
  } else {
    go(route);
  }
}
