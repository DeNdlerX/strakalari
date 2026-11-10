import '../l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

export '../tutorial/tours.dart';
export '../tutorial/tutorial_ui.dart';

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
