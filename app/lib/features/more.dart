import 'package:app/l10n/strings.dart';
import 'package:flutter/material.dart';


/// Phone menu: the screens that don't fit the bottom bar.
/// Port of views/more.py.
class MorePage extends StatelessWidget {
  final void Function(String route) onOpen;
  final bool isAndroid;

  const MorePage({
    super.key,
    required this.onOpen,
    this.isAndroid = false,
  });

  static const List<(String, IconData, String)> entries = [
    ('absences', Icons.event_busy_outlined, 'nav_absences'),
    ('planner', Icons.event_note_outlined, 'nav_planner'),
    ('activity', Icons.history_outlined, 'nav_activity'),
    ('settings', Icons.settings_outlined, 'nav_settings'),
  ];

  List<(String, IconData, String)> visibleEntries() {
    if (!isAndroid) return entries;
    // Android inserts the alarm shortcut before settings.
    return [
      ...entries.take(3),
      ('alarm', Icons.alarm, 'sec_alarm'),
      entries.last,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        ListTile(title: Text(Strings.get('nav_more'))),
        for (final (route, icon, label) in visibleEntries())
          Card(
            child: ListTile(
              leading: Icon(icon),
              title: Text(Strings.get(label)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onOpen(route),
            ),
          ),
      ],
    );
  }
}
