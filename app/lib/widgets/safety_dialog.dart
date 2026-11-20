import 'dart:math';

import 'package:flutter/material.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import '../l10n/strings.dart';

const Map<String, String> modeKeys = {
  'excuse_mode': 'excuse',
  'strava_order_mode': 'lunch',
};

/// Dialog widget for confirming the switch to automatic sending/ordering mode.
/// Port of `confirm_auto_mode` in `strakalari/flet_ui/safety.py`.
class AutoConfirmDialog extends StatelessWidget {
  final String modeKey;
  final VoidCallback? onConfirm;
  final VoidCallback? onDryRun;
  final VoidCallback? onCancel;
  final bool unsigned;
  final bool? hasDryRunOverride;
  final String? dataDir;

  const AutoConfirmDialog({
    super.key,
    required this.modeKey,
    this.onConfirm,
    this.onDryRun,
    this.onCancel,
    this.unsigned = false,
    this.hasDryRunOverride,
    this.dataDir,
  });

  @override
  Widget build(BuildContext context) {
    final kind = modeKeys[modeKey] ?? 'excuse';
    bool tried;
    if (hasDryRunOverride != null) {
      tried = hasDryRunOverride!;
    } else {
      try {
        tried = core.hasDryRun(kind, dataDir: dataDir);
      } catch (exc) {
        // ignore: avoid_print
        print('Warning: could not read the automation history: $exc');
        tried = false;
      }
    }

    final width = MediaQuery.sizeOf(context).width;
    final contentWidth =
        max(240.0, min(440.0, width > 0 ? width - 64.0 : 440.0));

    return AlertDialog(
      title: Text(Strings.get('auto_confirm_title')),
      content: SizedBox(
        width: contentWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(Strings.get(kind == 'excuse'
                  ? 'auto_confirm_excuse'
                  : 'auto_confirm_lunch')),
              if (!tried) ...[
                const SizedBox(height: 10),
                Text(
                  Strings.get('auto_confirm_no_dry_run'),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
              if (unsigned && kind == 'excuse') ...[
                const SizedBox(height: 10),
                Text(
                  Strings.get('auto_confirm_unsigned'),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                Strings.get('auto_confirm_pause_hint'),
                style: const TextStyle(fontSize: 12),
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
        TextButton(
          onPressed: () {
            Navigator.of(context, rootNavigator: true).pop('dry_run');
            onDryRun?.call();
          },
          child: Text(Strings.get('auto_confirm_dry')),
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
/// Exactly one of the callbacks runs: [onConfirm] (keep `auto`),
/// [onDryRun] (switch to `dry_run` instead) or [onCancel]
/// (dialog dismissed — revert the picker). [unsigned] (no signature
/// configured) adds a warning to the excuse dialog.
Future<void> confirmAutoMode(
  BuildContext context,
  String modeKey, {
  required VoidCallback onConfirm,
  required VoidCallback onDryRun,
  required VoidCallback onCancel,
  bool unsigned = false,
  bool? hasDryRunOverride,
  String? dataDir,
}) async {
  final result = await showDialog<String>(
    context: context,
    barrierDismissible: false, // modal=True in safety.py
    builder: (dialogCtx) => AutoConfirmDialog(
      modeKey: modeKey,
      unsigned: unsigned,
      hasDryRunOverride: hasDryRunOverride,
      dataDir: dataDir,
    ),
  );

  switch (result) {
    case 'confirm':
      onConfirm();
      break;
    case 'dry_run':
      onDryRun();
      break;
    case 'cancel':
    default:
      onCancel();
      break;
  }
}
