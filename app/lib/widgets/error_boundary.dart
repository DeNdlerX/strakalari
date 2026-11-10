import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/app_state.dart';
import '../l10n/strings.dart';
import '../shell/theme.dart';

/// Inherited scope providing the active route name to child widgets.
class ViewRouteScope extends InheritedWidget {
  final String route;
  const ViewRouteScope({super.key, required this.route, required super.child});

  static String? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ViewRouteScope>()?.route;

  @override
  bool updateShouldNotify(ViewRouteScope oldWidget) => route != oldWidget.route;
}

Widget Function(FlutterErrorDetails)? _originalErrorWidgetBuilder;

/// Replaces Flutter's default red box (debug) / grey box (release) with
/// the Python status_error fallback card and reports the failure to [AppState].
void installErrorWidgetBuilder() {
  _originalErrorWidgetBuilder ??= ErrorWidget.builder;
  ErrorWidget.builder =
      (FlutterErrorDetails details) => ViewErrorCard(details: details);
}

/// Restores the original [ErrorWidget.builder] (useful in tests).
void restoreErrorWidgetBuilder() {
  if (_originalErrorWidgetBuilder != null) {
    ErrorWidget.builder = _originalErrorWidgetBuilder!;
    _originalErrorWidgetBuilder = null;
  }
}

/// Fallback card rendered when a view throws during build.
/// Port of `C.card(C.txt(S("status_error"), self.state.tok, bold=True))`
/// in `strakalari/flet_ui/app.py:631-634`.
class ViewErrorCard extends ConsumerStatefulWidget {
  final FlutterErrorDetails details;
  const ViewErrorCard({super.key, required this.details});

  @override
  ConsumerState<ViewErrorCard> createState() => _ViewErrorCardState();
}

class _ViewErrorCardState extends ConsumerState<ViewErrorCard> {
  bool _reported = false;

  @override
  void initState() {
    super.initState();
    _reportOnce();
  }

  @override
  void didUpdateWidget(covariant ViewErrorCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reportOnce();
  }

  void _reportOnce() {
    if (_reported) return;
    _reported = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        final route = ViewRouteScope.of(context) ?? 'unknown';
        final state = ref.read(appStateProvider);
        state.reportError(
          'view ($route)',
          widget.details.exception,
          '',
          widget.details.stack?.toString() ?? '',
        );
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appStateProvider);
    final tok = tokensFor('${state.get('theme', 'dark')}');
    return Center(
      child: Card(
        key: const ValueKey('view_error_card'),
        color: tok.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tok.radiusMd),
        ),
        child: Padding(
          padding: EdgeInsets.all(tok.pad),
          child: Text(
            Strings.get('status_error'),
            style: TextStyle(
              color: tok.text,
              fontWeight: FontWeight.bold,
              fontSize: tok.fsBody,
            ),
          ),
        ),
      ),
    );
  }
}

/// Error boundary widget wrapping view content in [AppScaffold].
class ViewErrorBoundary extends StatelessWidget {
  final String route;
  final Widget child;

  const ViewErrorBoundary({
    super.key,
    required this.route,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return ViewRouteScope(
      route: route,
      child: child,
    );
  }
}
