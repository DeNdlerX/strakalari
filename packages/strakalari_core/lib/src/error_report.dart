// Structured error reports with secrets redacted.
//
// Port of strakalari/core/error_report.py. Phase 2 lands the foundation
// the HTTP session needs ([UserError], [timeoutUserMessage]); phase 4
// ports the redaction and report builders with their tests.
import 'i18n.dart';

/// A failure the user can fix themselves (missing URL, bad login, ...).
class UserError implements Exception {
  final String message;

  /// The transport error that caused this failure, if any (lets the
  /// excuse post tell "certainly never sent" from "maybe sent").
  final Object? cause;

  const UserError(this.message, [this.cause]);

  @override
  String toString() => 'UserError: $message';
}

/// Friendly fix-it text for timeouts (slow/unstable connection).
String timeoutUserMessage() => t('error_timeout');
