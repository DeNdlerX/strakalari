// Cross-process session lock: one refresh or submit at a time.
//
// Port of the `session_lock` context manager in
// strakalari/core/refresh.py. It lives here (not in the refresh pipeline
// module) so the tray and window schedulers can share it without
// importing the pipeline.
//
// Serializes whole refreshes and order submits across processes: callers
// that do not get the lock must skip, not run in parallel — two runs
// would both log in, both auto-send and race each other's cache writes.
// The OS releases the lock when a holder dies, so a killed process never
// blocks the next run.
import '../storage/helpers.dart';

/// Lock file shared by every process that drives the school sites (the
/// tray and the window are separate processes, each with a scheduler).
const String sessionLockFile = './session.lock';

/// An acquired cross-process session lock (release with [release]).
class SessionLock {
  final InterProcessLock _inner;

  SessionLock._(this._inner);

  /// Acquires the lock; null when another refresh or submit (this or
  /// another process) kept it for [timeoutS].
  static SessionLock? acquire(
      {double timeoutS = 0.0, String lockFile = sessionLockFile}) {
    final inner = InterProcessLock(resolvePath(lockFile));
    if (!inner.acquire(timeoutS: timeoutS)) return null;
    return SessionLock._(inner);
  }

  /// Releases a lock acquired with [acquire].
  void release() => _inner.release();

  /// Whether this object currently holds the lock.
  bool get held => _inner.held;
}

/// Runs [body] with the session lock held.
///
/// [body] receives true when the lock is held, false when another
/// refresh or submit (this or another process) kept it — callers must
/// then skip, not run in parallel. The `session.lock` file is shared with
/// the Python app, so a Python and a Dart app on one PC still exclude
/// each other.
///
/// [body] must be synchronous: returning a [Future] would release the lock
/// as soon as the body returns it, before the async work runs (asserted in
/// debug builds). Use [withSessionLockAsync] for async work.
T withSessionLock<T>(T Function(bool held) body,
    {double timeoutS = 0.0, String lockFile = sessionLockFile}) {
  final lock = SessionLock.acquire(timeoutS: timeoutS, lockFile: lockFile);
  try {
    final result = body(lock != null);
    assert(result is! Future,
        'withSessionLock body returned a Future: the lock is released when '
        'the body returns, so async work would run unlocked; use '
        'withSessionLockAsync instead.');
    return result;
  } finally {
    lock?.release();
  }
}

/// Async variant of [withSessionLock]: awaits [body] inside the
/// try/finally, so the lock stays held for the whole async work.
Future<T> withSessionLockAsync<T>(Future<T> Function(bool held) body,
    {double timeoutS = 0.0, String lockFile = sessionLockFile}) async {
  final lock = SessionLock.acquire(timeoutS: timeoutS, lockFile: lockFile);
  try {
    return await body(lock != null);
  } finally {
    lock?.release();
  }
}
