import '../l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SnackLog {
  static String? last;
  static final List<String> all = [];

  static void record(String text) {
    last = text;
    all.add(text);
  }

  static void clear() {
    last = null;
    all.clear();
  }
}

/// Shows a snackbar and records it for tests. Never throws.
void appSnack(BuildContext context, String text) {
  SnackLog.record(text);
  try {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  } catch (_) {}
}

/// Copies [text] to the clipboard. Returns true when dispatched.
Future<bool> copyAppText(String text) async {
  if (text.isEmpty) return false;
  try {
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  } catch (_) {
    return false;
  }
}

/// Error popup with a copy-logs button. Port of overlays.show_error_dialog.
///
/// [userMessage] set → friendly fix-it text on screen, full bundle one
/// copy-tap away. Otherwise the summary + hint + traceback dump show.
class ErrorDialog extends StatefulWidget {
  final String title;
  final String summary;
  final String reportText;
  final String userMessage;
  final VoidCallback? onClose;

  const ErrorDialog({
    super.key,
    required this.title,
    required this.summary,
    required this.reportText,
    this.userMessage = '',
    this.onClose,
  });

  @override
  State<ErrorDialog> createState() => _ErrorDialogState();
}

class _ErrorDialogState extends State<ErrorDialog> {
  bool _copied = false;

  Future<void> _copy() async {
    final ok = await copyAppText(widget.reportText);
    if (!mounted) return;
    setState(() => _copied = ok);
    if (context.mounted) {
      appSnack(context,
          Strings.get(ok ? 'error_copied' : 'error_copy_failed'));
    }
  }

  void _dismiss() {
    Navigator.of(context).maybePop();
    widget.onClose?.call();
  }

  @override
  Widget build(BuildContext context) {
    final body = widget.reportText.trim().isEmpty
        ? '(no details captured)'
        : widget.reportText.trim();
    final friendly = widget.userMessage.trim();
    final List<Widget> message;
    if (friendly.isNotEmpty) {
      message = [
        SelectableText(friendly),
        SelectableText(Strings.get('error_not_yours'),
            style: Theme.of(context).textTheme.bodySmall),
      ];
    } else {
      message = [
        SelectableText(widget.summary),
        SelectableText(Strings.get('error_hint'),
            style: Theme.of(context).textTheme.bodySmall),
        Container(
          height: 220,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SingleChildScrollView(
            child: SelectableText(body,
                style: const TextStyle(
                    fontFamily: 'Consolas', fontSize: 12)),
          ),
        ),
      ];
    }
    return AlertDialog(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline),
          const SizedBox(width: 8),
          Flexible(
              child: Text(widget.title.isEmpty
                  ? Strings.get('error_title')
                  : widget.title)),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < message.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              message[i],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: _dismiss, child: Text(Strings.get('error_close'))),
        TextButton.icon(
          onPressed: _copy,
          icon: const Icon(Icons.content_copy),
          label: Text(_copied
              ? Strings.get('error_copied')
              : Strings.get('error_copy_logs')),
        ),
      ],
    );
  }
}

/// Shows the error dialog. Never throws.
Future<void> showErrorDialog(
  BuildContext context, {
  required String title,
  required String summary,
  required String reportText,
  String userMessage = '',
  VoidCallback? onClose,
}) async {
  try {
    await showDialog<void>(
      context: context,
      builder: (_) => ErrorDialog(
        title: title,
        summary: summary,
        reportText: reportText,
        userMessage: userMessage,
        onClose: onClose,
      ),
    );
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// Tutorial tours (port of flet_ui/tutorial.py).
// ---------------------------------------------------------------------------

/// Where a step's bubble goes.
enum TourPlace { inline, center, left, topLeft, topRight, headerRight, bottomRight, bottom }

/// One step of a tour.
class TourStep {
  final String key;
  final String anchor;
  final TourPlace place;
  final String until;
  final IconData icon;
  final bool welcome;

  const TourStep(
    this.key, {
    this.anchor = '',
    this.place = TourPlace.inline,
    this.until = '',
    this.icon = Icons.lightbulb_outline,
    this.welcome = false,
  });
}

/// One guided tour.
class Tour {
  final String id;
  final String? route;
  final List<TourStep> steps;

  const Tour(this.id, this.route, this.steps);
}

/// All tours, mirroring TOURS in tutorial.py.
const Map<String, Tour> kTours = {
  'intro': Tour('intro', null, [
    TourStep('intro_welcome',
        place: TourPlace.center,
        icon: Icons.waving_hand_outlined,
        welcome: true),
    TourStep('intro_nav', place: TourPlace.left, icon: Icons.menu_outlined),
    TourStep('intro_refresh',
        anchor: 'refresh',
        place: TourPlace.topRight,
        icon: Icons.refresh),
    TourStep('intro_status',
        anchor: 'status',
        place: TourPlace.topLeft,
        icon: Icons.monitor_heart_outlined),
    TourStep('intro_done',
        place: TourPlace.bottomRight, icon: Icons.school_outlined),
  ]),
  'excuse': Tour('excuse', 'today', [
    TourStep('excuse_pick',
        anchor: 'excuse_card', icon: Icons.event_busy_outlined),
    TourStep('excuse_send',
        anchor: 'excuse_card',
        until: 'excuse_done',
        icon: Icons.send_outlined),
    TourStep('excuse_done',
        place: TourPlace.bottomRight, icon: Icons.task_alt),
  ]),
  'timetable': Tour('timetable', 'timetable', [
    TourStep('tt_weeks',
        anchor: 'tt_nav', icon: Icons.date_range_outlined),
    TourStep('tt_colors',
        anchor: 'tt_legend', icon: Icons.palette_outlined),
  ]),
  'absences': Tour('absences', 'absences', [
    TourStep('abs_stats',
        anchor: 'abs_stats', icon: Icons.pie_chart_outline),
    TourStep('abs_subject',
        anchor: 'abs_first', icon: Icons.percent),
  ]),
  'planner': Tour('planner', 'planner', [
    TourStep('plan_strip',
        anchor: 'plan_strip', icon: Icons.calendar_view_month_outlined),
    TourStep('plan_pick',
        anchor: 'plan_first',
        until: 'day_planned',
        icon: Icons.beach_access_outlined),
    TourStep('plan_budget',
        anchor: 'plan_budget', icon: Icons.stacked_bar_chart),
  ]),
  'lunches': Tour('lunches', 'lunches', [
    TourStep('lunch_pick',
        anchor: 'lunch_day',
        until: 'lunch_picked',
        icon: Icons.restaurant_outlined),
    TourStep('lunch_send',
        anchor: 'lunch_send',
        until: 'orders_sent',
        icon: Icons.send_outlined),
    TourStep('lunch_tools',
        anchor: 'lunch_tools',
        place: TourPlace.headerRight,
        icon: Icons.tune_outlined),
  ]),
  'marks': Tour('marks', 'marks', [
    TourStep('marks_stats',
        anchor: 'marks_stats', icon: Icons.grade_outlined),
    TourStep('marks_subject',
        anchor: 'marks_subject',
        until: 'marks_subject_opened',
        icon: Icons.touch_app_outlined),
    TourStep('marks_need',
        anchor: 'marks_need', icon: Icons.flag_outlined),
    TourStep('marks_predict',
        anchor: 'marks_predict',
        until: 'marks_predicted',
        icon: Icons.science_outlined),
    TourStep('marks_scale',
        anchor: 'marks_scale',
        place: TourPlace.headerRight,
        icon: Icons.percent),
  ]),
  'settings': Tour('settings', 'settings', [
    TourStep('settings_intro',
        place: TourPlace.bottomRight, icon: Icons.settings_outlined),
  ]),
  'activity': Tour('activity', 'activity', [
    TourStep('activity_intro',
        place: TourPlace.bottomRight, icon: Icons.history_outlined),
  ]),
};

const String kFirstTour = 'intro';

/// Progress tracker for the tours. Port of state_tutorial.TutorialMixin.
///
/// Backed by a plain config map (`tutorials_enabled`, `tutorials_done`)
/// plus an optional [persist] hook; UI-agnostic so tests run headless.
class TutorialController {
  final Map<String, dynamic> config;
  final bool Function(Map<String, dynamic> updates)? persist;

  /// Active `(tourId, stepIndex)` in memory, or null.
  List<dynamic>? active;

  TutorialController(this.config, {this.persist});

  bool enabled() {
    try {
      return (config['tutorials_enabled'] as bool?) ?? true;
    } catch (_) {
      return true;
    }
  }

  Set<String> done() {
    final out = <String>{};
    final stored = config['tutorials_done'];
    if (stored is List) {
      for (final t in stored) {
        final s = '$t'.trim();
        if (s.isNotEmpty) out.add(s);
      }
    }
    return out;
  }

  void _rememberDone(String tourId) {
    final stored = done()..add(tourId);
    final updates = {'tutorials_done': stored.toList()..sort()};
    try {
      if (persist != null) {
        persist!(updates);
      } else {
        config.addAll(updates);
      }
    } catch (_) {}
  }

  bool setEnabled(bool value) {
    if (!value) active = null;
    try {
      final updates = {'tutorials_enabled': value};
      if (persist != null) {
        return persist!(updates) != false;
      }
      config.addAll(updates);
      return true;
    } catch (_) {
      return false;
    }
  }

  bool reset() {
    active = null;
    try {
      final updates = {
        'tutorials_done': <String>[],
        'tutorials_enabled': true
      };
      if (persist != null) {
        return persist!(updates) != false;
      }
      config.addAll(updates);
      return true;
    } catch (_) {
      return false;
    }
  }

  List<dynamic>? current() {
    if (active == null) return null;
    final tour = kTours[active![0]];
    if (tour == null) {
      active = null;
      return null;
    }
    final index = active![1] as int;
    if (index < 0 || index >= tour.steps.length) {
      active = null;
      return null;
    }
    return [tour, index, tour.steps[index]];
  }

  /// Starts [tourId] if nothing runs and it was never done.
  bool offer(String tourId) {
    if (active != null) return active![0] == tourId;
    if (!enabled()) return false;
    if (done().contains(tourId) || !kTours.containsKey(tourId)) return false;
    if (tourId != kFirstTour && !done().contains(kFirstTour)) return false;
    active = [tourId, 0];
    return true;
  }

  void suspend() {
    active = null;
  }

  void _goto(int index) {
    final cur = current();
    if (cur == null) return;
    final Tour tour = cur[0];
    if (index >= tour.steps.length) {
      active = null;
      _rememberDone(tour.id);
      return;
    }
    active = [tour.id, index < 0 ? 0 : index];
  }

  void next() {
    final cur = current();
    if (cur != null) _goto((cur[1] as int) + 1);
  }

  void back() {
    final cur = current();
    if (cur != null && (cur[1] as int) > 0) {
      _goto((cur[1] as int) - 1);
    }
  }

  void skip() {
    final cur = current();
    if (cur == null) return;
    active = null;
    _rememberDone((cur[0] as Tour).id);
  }

  /// The user just did [name]: advance past the first waiting step.
  void event(String name) {
    List<dynamic>? cur;
    try {
      cur = current();
    } catch (_) {
      return;
    }
    if (cur == null) return;
    final Tour tour = cur[0];
    final int index = cur[1];
    for (var later = index; later < tour.steps.length; later++) {
      if (tour.steps[later].until == name) {
        _gotoQuiet(later + 1);
        return;
      }
    }
  }

  void _gotoQuiet(int index) {
    final cur = current();
    if (cur == null) return;
    final Tour tour = cur[0];
    if (index >= tour.steps.length) {
      active = null;
      _rememberDone(tour.id);
      return;
    }
    active = [tour.id, index];
  }
}

/// The callout bubble for one step.
class TutorialBubble extends StatelessWidget {
  final TutorialController controller;
  final Tour tour;
  final int index;
  final TourStep step;

  const TutorialBubble({
    super.key,
    required this.controller,
    required this.tour,
    required this.index,
    required this.step,
  });

  @override
  Widget build(BuildContext context) {
    final total = tour.steps.length;
    final last = index == total - 1;
    final List<Widget> body = [
      Row(
        children: [
          Icon(step.icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(Strings.get('tut_${step.key}_title'),
                style: Theme.of(context).textTheme.titleSmall),
          ),
          IconButton(
            tooltip: Strings.get('tut_skip_tour'),
            icon: const Icon(Icons.close, size: 16),
            onPressed: controller.skip,
          ),
        ],
      ),
      Text(Strings.get('tut_${step.key}_body')),
    ];
    if (step.until.isNotEmpty) {
      body.add(
        Text(Strings.get('tut_${step.key}_try'),
            style: TextStyle(
                color: Theme.of(context).colorScheme.primary)),
      );
    }
    if (step.welcome) {
      body.add(Row(
        children: [
          FilledButton(
              onPressed: controller.next,
              child: Text(Strings.get('tut_start'))),
          const SizedBox(width: 8),
          TextButton(
              onPressed: controller.skip,
              child: Text(Strings.get('tut_not_now'))),
        ],
      ));
      body.add(Row(
        children: [
          Expanded(child: Text(Strings.get('tut_off_note'))),
          TextButton(
            onPressed: () => controller.setEnabled(false),
            child: Text(Strings.get('tut_turn_off')),
          ),
        ],
      ));
    } else {
      final List<Widget> nav = [
        Row(
          children: [
            for (var i = 0; i < total; i++)
              Container(
                width: i == index ? 14 : 6,
                height: 6,
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  color: i <= index
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
          ],
        ),
        const Spacer(),
      ];
      if (index > 0 && !tour.steps[index - 1].until.isNotEmpty) {
        nav.add(TextButton(
            onPressed: controller.back,
            child: Text(Strings.get('tut_back'))));
      }
      if (step.until.isNotEmpty) {
        nav.add(TextButton(
          onPressed: controller.next,
          child: Text(Strings.get(last ? 'tut_later' : 'tut_skip_step')),
        ));
      } else {
        nav.add(FilledButton(
          onPressed: controller.next,
          child: Text(Strings.get(last ? 'tut_done' : 'tut_next')),
        ));
      }
      body.add(Row(children: nav));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < body.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              body[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// Wraps [child] with an accent ring when the active step points at [key].
/// Returns [child] untouched otherwise. Only the first match highlights.
class TutorialAnchor extends StatelessWidget {
  final TutorialController controller;
  final String anchorKey;
  final Widget child;
  final bool narrow;

  const TutorialAnchor({
    super.key,
    required this.controller,
    required this.anchorKey,
    required this.child,
    this.narrow = false,
  });

  @override
  Widget build(BuildContext context) {
    final cur = controller.current();
    if (cur == null || (cur[2] as TourStep).anchor != anchorKey) {
      return child;
    }
    final ring = Container(
      decoration: BoxDecoration(
        border:
            Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
        borderRadius: BorderRadius.circular(11),
      ),
      padding: const EdgeInsets.all(3),
      child: child,
    );
    final Tour tour = cur[0];
    final int index = cur[1];
    final TourStep step = cur[2];
    if (narrow || step.place == TourPlace.inline) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ring,
          TutorialBubble(
              controller: controller,
              tour: tour,
              index: index,
              step: step),
        ],
      );
    }
    return ring;
  }
}
