import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/app_state.dart';
import '../l10n/strings.dart';
import '../shell/theme.dart';
import '../widgets/app_widgets.dart' show dialogWidth;
import 'tours.dart';

/// Where [step]'s bubble goes in the current layout.
/// Port of `_place()`.
TourPlace tutorialPlace(TourStep step, bool narrow, bool navSide) {
  if (!narrow) return step.place;
  if (step.place == TourPlace.left) {
    return navSide ? TourPlace.left : TourPlace.bottom;
  }
  if (step.anchor.isNotEmpty &&
      step.anchor != 'refresh' &&
      step.anchor != 'status') {
    return TourPlace.inline;
  }
  return step.place;
}

/// Small triangle pointer connecting the bubble to its target.
/// Port of `_caret()`.
class CaretWidget extends StatelessWidget {
  final String direction; // 'left' or 'up'
  final Color color;
  const CaretWidget({super.key, required this.direction, required this.color});

  @override
  Widget build(BuildContext context) {
    if (direction == 'left') {
      return ClipRect(
        child: SizedBox(
          width: 10,
          height: 20,
          child: Stack(
            children: [
              Positioned(
                left: 4,
                top: 4,
                child: Transform.rotate(
                  angle: 0.785398, // 45 degrees
                  child: Container(width: 12, height: 12, color: color),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ClipRect(
      child: SizedBox(
        width: 20,
        height: 10,
        child: Stack(
          children: [
            Positioned(
              left: 4,
              top: 4,
              child: Transform.rotate(
                angle: 0.785398,
                child: Container(width: 12, height: 12, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The callout bubble for one step.
/// Port of `_bubble()`.
class TutorialBubble extends StatelessWidget {
  final AppState state;
  final Tour tour;
  final int index;
  final TourStep step;
  final String caret;
  final Tokens tok;
  final bool narrow;
  final double? width;

  const TutorialBubble({
    super.key,
    required this.state,
    required this.tour,
    required this.index,
    required this.step,
    this.caret = '',
    required this.tok,
    this.narrow = false,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    final visible = state.tutorialVisibleStepIndices(tour);
    final visiblePos = visible.indexOf(index);
    final total = visible.isEmpty ? tour.steps.length : visible.length;
    final activeDot = visiblePos >= 0 ? visiblePos : index;
    final last = activeDot == total - 1;
    final edgeColor = tok.accent.withValues(alpha: 0.8);

    double bubbleW = width ??
        (step.welcome ? 440.0 : bubbleWidth);
    if (narrow) {
      bubbleW = dialogWidth(context, bubbleW);
    }

    var bodyKey = 'tut_${step.key}_body';
    if (narrow && Strings.hasKey('${bodyKey}_narrow')) {
      bodyKey = '${bodyKey}_narrow';
    }

    final close = IconButton(
      icon: Icon(Icons.close, size: 16, color: tok.faint),
      tooltip: Strings.get('tut_skip_tour'),
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(),
      onPressed: () => state.tutorialSkip(),
    );

    final head = Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: tok.accent.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(step.icon, color: tok.accent, size: 18),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            Strings.get('tut_${step.key}_title'),
            style: TextStyle(
              fontSize: tok.fsSection,
              fontWeight: FontWeight.bold,
              color: tok.text,
            ),
          ),
        ),
        close,
      ],
    );

    final List<Widget> body = [
      head,
      const SizedBox(height: 6),
      Text(
        Strings.get(bodyKey),
        style: TextStyle(fontSize: tok.fsBody, color: tok.muted),
      ),
    ];

    if (step.until.isNotEmpty) {
      body.addAll([
        const SizedBox(height: 6),
        Row(
          children: [
            Icon(Icons.touch_app_outlined, size: 16, color: tok.accent),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                Strings.get('tut_${step.key}_try'),
                style: TextStyle(
                  fontSize: tok.fsSmall,
                  color: tok.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ]);
    }

    if (step.welcome) {
      body.addAll([
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.arrow_forward, size: 18),
              label: Text(Strings.get('tut_start')),
              onPressed: () => state.tutorialNext(),
            ),
            OutlinedButton(
              onPressed: () => state.tutorialSkip(),
              child: Text(Strings.get('tut_not_now')),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Divider(color: tok.border, height: 1),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                Strings.get('tut_off_note'),
                style: TextStyle(fontSize: tok.fsSmall, color: tok.faint),
              ),
            ),
            TextButton(
              onPressed: () => state.setTutorialsEnabled(false),
              child: Text(
                Strings.get('tut_turn_off'),
                style: TextStyle(color: tok.red, fontSize: tok.fsSmall),
              ),
            ),
          ],
        ),
      ]);
    } else {
      final dots = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < total; i++)
            Container(
              width: i == activeDot ? 14 : 6,
              height: 6,
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: i <= activeDot ? tok.accent : tok.border,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
        ],
      );

      final buttons = <Widget>[];
      if (index > 0 && (tour.steps[index - 1].until.isEmpty)) {
        buttons.add(TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            minimumSize: Size.zero,
          ),
          onPressed: () => state.tutorialBack(),
          child: Text(
            Strings.get('tut_back'),
            style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
          ),
        ));
        buttons.add(const SizedBox(width: 4));
      }

      if (step.until.isNotEmpty) {
        buttons.add(TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            minimumSize: Size.zero,
          ),
          onPressed: () => state.tutorialNext(),
          child: Text(
            Strings.get(last ? 'tut_later' : 'tut_skip_step'),
            style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
          ),
        ));
      } else {
        buttons.add(FilledButton(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            minimumSize: Size.zero,
          ),
          onPressed: () => state.tutorialNext(),
          child: Text(
            Strings.get(last ? 'tut_done' : 'tut_next'),
            style: TextStyle(fontSize: tok.fsSmall),
          ),
        ));
      }

      body.addAll([
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            dots,
            Row(
              mainAxisSize: MainAxisSize.min,
              children: buttons,
            ),
          ],
        ),
      ]);
    }

    final card = Container(
      width: bubbleW,
      decoration: BoxDecoration(
        color: tok.card,
        border: Border.all(color: edgeColor, width: 1),
        borderRadius: BorderRadius.circular(tok.radiusLg),
        boxShadow: [
          BoxShadow(
            blurRadius: 24,
            offset: const Offset(0, 6),
            color: Colors.black.withValues(alpha: 0.28),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(
          tok.pad.toDouble(),
          (tok.pad - 4).toDouble(),
          (tok.pad - 6).toDouble(),
          (tok.pad - 6).toDouble()),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: body,
      ),
    );

    if (caret == 'left') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 18),
              CaretWidget(direction: 'left', color: edgeColor),
            ],
          ),
          card,
        ],
      );
    }

    if (caret == 'up') {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 18),
            child: CaretWidget(direction: 'up', color: edgeColor),
          ),
          card,
        ],
      );
    }

    if (caret == 'up_right') {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 18),
            child: CaretWidget(direction: 'up', color: edgeColor),
          ),
          card,
        ],
      );
    }

    return card;
  }
}

/// Wraps [child] when the active step points at [key].
/// Returns [child] untouched otherwise.
/// Only the first matching control per render is highlighted.
/// Port of `anchor()`.
Widget tutorialAnchor(
  AppState state,
  String key,
  Widget child, {
  Tokens? tok,
  bool narrow = false,
}) {
  final current = state.tutorialCurrent();
  if (current == null || current.$3.anchor != key) {
    return child;
  }
  if (state.tutorialAnchored) {
    return child;
  }
  state.tutorialAnchored = true;
  final (tour, index, step) = current;
  final effectiveTok = tok ?? state.tok;
  final place = tutorialPlace(step, narrow, state.navSide);

  final ring = Container(
    decoration: BoxDecoration(
      border: Border.all(color: effectiveTok.accent, width: 2),
      borderRadius: BorderRadius.circular(effectiveTok.radiusMd + 3),
      boxShadow: [
        BoxShadow(
          blurRadius: 18,
          spreadRadius: 1,
          color: effectiveTok.accent.withValues(alpha: 0.35),
        ),
      ],
    ),
    padding: const EdgeInsets.all(3),
    child: child,
  );

  if (place != TourPlace.inline) {
    return ring;
  }

  final bubble = TutorialBubble(
    state: state,
    tour: tour,
    index: index,
    step: step,
    caret: 'up',
    tok: effectiveTok,
    narrow: narrow,
  );

  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ring,
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(child: bubble),
        ],
      ),
    ],
  );
}

/// Declarative widget wrapping a control with tutorial highlighting.
class TutorialAnchor extends StatelessWidget {
  final String anchorKey;
  final Widget child;
  final AppState? state;

  const TutorialAnchor({
    super.key,
    required this.anchorKey,
    required this.child,
    this.state,
  });

  @override
  Widget build(BuildContext context) {
    if (state != null) {
      final appState = state!;
      final tok = appState.tok;
      return tutorialAnchor(appState, anchorKey, child,
          tok: tok, narrow: appState.narrow);
    }

    final hasScope =
        context.findAncestorWidgetOfExactType<ProviderScope>() != null ||
            context.findAncestorWidgetOfExactType<UncontrolledProviderScope>() !=
                null;
    if (!hasScope) {
      return child;
    }

    return Consumer(
      builder: (context, ref, _) {
        final appState = ref.watch(appStateProvider);
        final tok = appState.tok;
        return tutorialAnchor(appState, anchorKey, child,
            tok: tok, narrow: appState.narrow);
      },
    );
  }
}

/// The floating bubble for the active step, or null.
/// Stacks over the content area in [AppScaffold].
/// Port of `layer()`.
Widget? tutorialLayer(
    AppState state, BuildContext context, Tokens tok, bool narrow) {
  final current = state.tutorialCurrent();
  if (current == null) return null;
  final (tour, index, step) = current;
  var place = tutorialPlace(step, narrow, state.navSide);

  if (place == TourPlace.inline) {
    if (state.tutorialAnchored) {
      return null;
    }
    if (index == 0) {
      state.tutorialSuspend();
      return null;
    }
    place = TourPlace.bottomRight;
  }

  Widget wrapBubble({String caret = '', double? width}) {
    return TutorialBubble(
      state: state,
      tour: tour,
      index: index,
      step: step,
      caret: caret,
      tok: tok,
      narrow: narrow,
      width: width,
    );
  }

  switch (place) {
    case TourPlace.bottom:
      return Positioned(
        left: 0,
        right: 0,
        bottom: tok.gap.toDouble(),
        child: Center(child: wrapBubble()),
      );
    case TourPlace.center:
      return Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {}, // Absorbs clicks
          child: Container(
            color: tok.bg.withValues(alpha: 0.72),
            alignment: const Alignment(0, -0.2),
            child: SingleChildScrollView(
              child: wrapBubble(width: 440),
            ),
          ),
        ),
      );
    case TourPlace.left:
      return Positioned(
        left: 0,
        top: 96,
        child: wrapBubble(caret: 'left'),
      );
    case TourPlace.topLeft:
      return Positioned(
        left: tok.pad.toDouble(),
        top: 0,
        child: wrapBubble(caret: 'up'),
      );
    case TourPlace.topRight:
      return Positioned(
        right: tok.pad.toDouble(),
        top: 0,
        child: wrapBubble(caret: 'up_right'),
      );
    case TourPlace.headerRight:
      return Positioned(
        right: (tok.pad + 8).toDouble(),
        top: (tok.pad + 8 + headerHeight).toDouble(),
        child: wrapBubble(caret: 'up_right'),
      );
    case TourPlace.bottomRight:
    default:
      return Positioned(
        right: tok.pad.toDouble(),
        bottom: tok.pad.toDouble(),
        child: wrapBubble(),
      );
  }
}
