// Error dialog with a Copy-log button.
//
// Port of `show_error_dialog()` in strakalari/flet_ui/overlays.py.
// `summary` is the one-line cause; `reportText` the full diagnostics
// bundle (also selectable in the dialog for manual copy). When
// `userMessage` is set the failure is user-fixable: the dialog shows the
// friendly fix-it text, with the full bundle one copy-tap away behind a
// secondary line. Never throws — a failing popup must not hide the
// error behind it.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/strings.dart';
import '../shell/theme.dart';
import 'app_widgets.dart' show dialogWidth;

/// Shows the error popup. Returns after dismissal; [onClose] runs after
/// the dialog closes. Never throws.
Future<void> showErrorDialog(
  BuildContext context, {
  required Tokens tok,
  required String title,
  required String summary,
  required String reportText,
  String userMessage = '',
  VoidCallback? onClose,
}) async {
  final body = reportText.trim().isEmpty
      ? '(no details captured)'
      : reportText.trim();
  var copied = false;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (stateContext, setState) {
            Future<void> copy() async {
              try {
                await Clipboard.setData(
                    ClipboardData(text: reportText));
                setState(() => copied = true);
                if (stateContext.mounted) {
                  ScaffoldMessenger.of(stateContext).showSnackBar(
                    SnackBar(content: Text(Strings.get('error_copied'))),
                  );
                }
              } catch (_) {
                if (stateContext.mounted) {
                  ScaffoldMessenger.of(stateContext).showSnackBar(
                    SnackBar(
                        content:
                            Text(Strings.get('error_copy_failed'))),
                  );
                }
              }
            }

            final friendly = userMessage.trim();
            final messageControls = <Widget>[
              if (friendly.isNotEmpty) ...[
                SelectableText(friendly,
                    style:
                        TextStyle(color: tok.text, fontSize: tok.fsBody)),
                SelectableText(Strings.get('error_not_yours'),
                    style: TextStyle(
                        color: Colors.grey, fontSize: tok.fsSmall)),
              ] else ...[
                if (summary.isNotEmpty)
                  SelectableText(summary,
                      style: TextStyle(
                          color: tok.text, fontSize: tok.fsBody)),
                SelectableText(Strings.get('error_hint'),
                    style: TextStyle(
                        color: Colors.grey, fontSize: tok.fsSmall)),
                Container(
                  height: 220,
                  width: dialogWidth(dialogContext, 560),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius:
                        BorderRadius.circular(tok.radiusSm),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(body,
                        style: const TextStyle(
                            fontFamily: 'Consolas', fontSize: 12)),
                  ),
                ),
              ],
            ];
            return AlertDialog(
              backgroundColor: tok.card,
              title: Row(
                spacing: 8,
                children: [
                  Icon(Icons.error_outline, color: tok.red),
                  Flexible(
                    child: Text(
                        title.isEmpty
                            ? Strings.get('error_title')
                            : title,
                        style: TextStyle(
                            color: tok.text, fontSize: tok.fsSection)),
                  ),
                ],
              ),
              content: SizedBox(
                width: dialogWidth(dialogContext, 560),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: messageControls,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () =>
                      Navigator.of(dialogContext).pop(),
                  child: Text(Strings.get('error_close')),
                ),
                FilledButton.icon(
                  onPressed: copy,
                  icon: const Icon(Icons.content_copy, size: 16),
                  label: Text(copied
                      ? Strings.get('error_copied')
                      : Strings.get('error_copy_logs')),
                ),
                IconButton(
                  tooltip: Strings.get('error_copy_logs'),
                  icon: const Icon(Icons.share_outlined, size: 20),
                  // Flet: the phone path used Share ("Share log").
                  // Phase 7 wires the share sheet wherever the dialog
                  // is shown; until then the copy button above carries
                  // the bundle.
                  onPressed: () async {
                    try {
                      await SharePlus.instance.share(ShareParams(
                        text: body,
                        subject: title.isEmpty
                            ? Strings.get('error_title')
                            : title,
                      ));
                    } catch (_) {
                      // Copy remains available.
                    }
                  },
                ),
              ],
            );
          },
        );
      },
    );
  } catch (_) {
    // A failing popup must not hide the error behind it.
  }
  try {
    onClose?.call();
  } catch (_) {
    // The dialog already closed; teardown must not throw.
  }
}
