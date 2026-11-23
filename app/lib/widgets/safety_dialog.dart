import 'package:flutter/material.dart';

import '../features/common/app_tokens.dart';
import '../l10n/strings.dart';
import 'app_widgets.dart' show dialogWidth;

const Map<String, String> modeKeys = {
  'excuse_mode': 'excuse',
  'strava_order_mode': 'lunch',
};

/// Dialog widget for confirming the switch to automatic sending/ordering mode.
/// Port of `confirm_auto_mode` in `strakalari/flet_ui/safety.py`.
class AutoConfirmDialog extends StatelessWidget {
  final String modeKey;
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;
  final bool unsigned;

  const AutoConfirmDialog({
    super.key,
    required this.modeKey,
    this.onConfirm,
    this.onCancel,
    this.unsigned = false,
  });

  @override
  Widget build(BuildContext context) {
    final excuse = (modeKeys[modeKey] ?? 'excuse') == 'excuse';
    final tok = tokensOf(context);

    Widget point(IconData icon, String text, {Color? color, bool bold = false}) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          Icon(icon, size: 18, color: color ?? tok.muted),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    color: tok.text,
                    fontSize: tok.fsBody,
                    fontWeight: bold ? FontWeight.w600 : null)),
          ),
        ],
      );
    }

    return AlertDialog(
      title: Text(Strings.get(excuse
          ? 'auto_confirm_title_excuse'
          : 'auto_confirm_title_lunch')),
      content: SizedBox(
        width: dialogWidth(context, 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              Text(
                  Strings.get(
                      excuse ? 'auto_confirm_excuse' : 'auto_confirm_lunch'),
                  style: TextStyle(color: tok.text, fontSize: tok.fsBody)),
              point(
                  Icons.warning_amber_rounded,
                  Strings.get(excuse
                      ? 'auto_confirm_excuse_risk'
                      : 'auto_confirm_lunch_risk'),
                  color: tok.orange,
                  bold: true),
              point(Icons.pause_circle_outline,
                  Strings.get('auto_confirm_pause_hint')),
              point(Icons.history, Strings.get('auto_confirm_history')),
              if (unsigned && excuse)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: tintColor(tok.yellow, 0.12),
                    border: Border.all(color: tintColor(tok.yellow, 0.5)),
                    borderRadius: BorderRadius.circular(tok.radiusSm),
                  ),
                  child: point(Icons.draw_outlined,
                      Strings.get('auto_confirm_unsigned'),
                      color: tok.yellow),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context, rootNavigator: true).pop('cancel');
            onCancel?.call();
          },
          child: Text(Strings.get('cancel')),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context, rootNavigator: true).pop('confirm');
            onConfirm?.call();
          },
          child: Text(Strings.get('auto_confirm_ok')),
        ),
      ],
    );
  }
}

/// Shows the "turn on automatic mode?" dialog for [modeKey].
///
/// Exactly one of the callbacks runs: [onConfirm] (keep `auto`) or
/// [onCancel] (dialog dismissed — revert the picker). [unsigned] (no
/// signature configured) adds a warning to the excuse dialog.
Future<void> confirmAutoMode(
  BuildContext context,
  String modeKey, {
  required VoidCallback onConfirm,
  required VoidCallback onCancel,
  bool unsigned = false,
}) async {
  final result = await showDialog<String>(
    context: context,
    barrierDismissible: false, // modal=True in safety.py
    builder: (dialogCtx) => AutoConfirmDialog(
      modeKey: modeKey,
      unsigned: unsigned,
    ),
  );

  if (result == 'confirm') {
    onConfirm();
  } else {
    onCancel();
  }
}
