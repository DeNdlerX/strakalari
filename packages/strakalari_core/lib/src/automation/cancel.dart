// Cooperative cancellation.
//
// Port of strakalari/core/cancel.py. The GUI sets a flag when the user
// hits Zrušit; the Bakaláři and Strava clients check it before every
// request (and between fetch phases), so a cancel takes effect as soon
// as the request in flight returns. Callers treat [CancelledError] as
// "cancelled by user" (Python raises `InterruptedError` there).
bool isCancelled(bool Function()? predicate) {
  if (predicate == null) return false;
  try {
    return predicate();
  } on Object {
    return false;
  }
}

/// Raises [CancelledError] when the cancel predicate fires.
void raiseIfCancelled(bool Function()? predicate) {
  if (isCancelled(predicate)) {
    throw const CancelledError();
  }
}

/// User-initiated cancellation (Python: `InterruptedError`).
class CancelledError implements Exception {
  final String message;
  const CancelledError([this.message = 'Cancelled by user.']);

  @override
  String toString() => 'CancelledError: $message';
}
