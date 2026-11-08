// Cross-platform single-instance guard with "show window" signalling.
//
// Port of `strakalari/flet_ui/single_instance.py`: a second launch must
// not open a duplicate window — it wakes the running instance over a
// localhost TCP socket and exits, and the running instance restores its
// window (un-hide + un-minimize + focus).
//
// Why loopback TCP instead of a lock file: a file can only *block* the
// second process, it cannot tell the first one to show its window — and
// a crashed process leaves a stale lock behind, while the OS always
// reclaims a dead process's bound port. Loopback traffic needs no
// firewall exception and behaves identically on Windows, Linux and
// macOS (stdlib only).
//
// Ports, tokens, magic lines and retry counts are byte-identical to
// Python, so a Python tray and a Flutter app on one PC still exclude
// each other (PLAN rule 2: the same `session.lock` file and locking
// method — here the same socket handshake).
//
// Differences from Python (both harmless, both documented here):
// * "Frozen" (installed) vs source runs: Python checks `sys.frozen`.
//   Dart uses `bool.fromEnvironment('dart.vm.product')` — true in
//   release builds, false in debug/profile runs. Debug runs therefore
//   share the dev port pair, exactly like Python source runs do.
// * Python binds with `SO_EXCLUSIVEADDRUSE` on Windows (a second
//   process must not steal the port). Dart's `ServerSocket.bind` with
//   `shared: false` (the default) requests exclusive use on Windows
//   too; other platforms use `SO_REUSEADDR` for TIME_WAIT leftovers.
// * `flet.exe` orphan reaping (`kill_orphaned_flet_views`) is dropped:
//   Flutter has no Flet view subprocesses. Same-named-process sweeps
//   stay absent on purpose (onefile layouts run as same-named
//   parent + child, so such a sweep would kill this process).
// * macOS/Linux parts are written but UNVERIFIED (no Mac/Linux CI run
//   yet); Windows is the verified path.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Loopback address the guard binds and signals on.
const String singleInstanceHost = '127.0.0.1';

/// Magic first lines (ASCII, `\n`-terminated with the token appended).
const String magicShow = 'STRAKALARI-SHOW-v2';
const String magicPing = 'STRAKALARI-PING-v2';
const String magicQuit = 'STRAKALARI-QUIT-v2';

/// Acknowledgement a live primary sends back.
const String replyOk = 'STRAKALARI-OK-v2\n';

/// Longest accepted line (matches Python's `_MAX_LINE`).
const int maxLineLength = 128;

/// Per-user secret proving a message comes from the same user's install.
const String instanceTokenFile = 'instance.token';

const Duration _ioTimeout = Duration(seconds: 2);
const int _signalAttempts = 3;
const Duration _signalRetryPause = Duration(milliseconds: 200);

/// True in release (installed) builds; false in debug/profile runs.
///
/// Mirrors Python's `sys.frozen`: installed builds hold the release
/// port pair, dev runs their own pair within the same per-user slot,
// so a dev launch never just wakes the installed app and exits.
const bool _isReleaseBuild = bool.fromEnvironment('dart.vm.product');

String _osUser() {
  final env = Platform.environment;
  final user = env['LOGNAME'] ?? env['USER'] ?? env['LNAME'] ?? env['USERNAME'] ?? '';
  final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
  final raw = '$user|$home';
  // `os.path.normcase`: lowercase + forward slashes on Windows.
  if (Platform.isWindows) return raw.toLowerCase().replaceAll('/', r'\');
  return raw;
}

/// Per-user slot (0..299) from the identity hash (matches Python).
int userSlot(String identity, {int slots = 300}) {
  final digest = sha256.convert(utf8.encode(identity)).toString();
  return int.parse(digest.substring(0, 8), radix: 16) % slots;
}

/// Base port of this user's 20-port slot.
///
/// Kept below the Windows ephemeral range (49152+) so an outgoing
/// connection never happens to hold the port. Release builds use the
int portBase() {
  final slot = userSlot(_osUser());
  return 42000 + 20 * slot + (_isReleaseBuild ? 0 : 10);
}

/// Port owned by the first main process (standalone UI or tray).
int mainPort() => portBase();

/// Port of a UI child spawned by a tray parent (Python two-process
/// model). Kept for protocol parity; the Flutter app is one process
/// and normally only binds [mainPort].
int uiPort() => portBase() + 1;

/// This user's handshake token (32 hex chars), created on first use.
///
/// Lives in the per-user data dir, so another OS user cannot read it.
/// When the file cannot be created (read-only dir), a token derived
/// from the user and data dir is used instead: not secret, but still
/// per user. Matches `single_instance.instance_token`.
Future<List<int>> instanceToken(String dataDir) async {
  final path = '$dataDir${Platform.pathSeparator}$instanceTokenFile';
  final file = File(path);
  for (var i = 0; i < 20; i++) {
    try {
      if (await file.exists()) {
        final raw = (await file.readAsBytes()).trimAscii();
        if (_validToken(raw)) return raw;
        // Possibly mid-write by another process; retry briefly.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        continue;
      }
    } on FileSystemException {
      break; // Unreadable dir: fall through to the derived token.
    }
    // Create exclusively (`O_EXCL`): losing the race means reading
    // the winner on the next iteration.
    try {
      final token = _randomToken();
      await file.create(exclusive: true);
      await file.writeAsBytes(token, flush: true);
      return token;
    } on PathExistsException {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    } on FileSystemException {
      break; // Cannot create here: fall through to the derived token.
    }
  }
  // Still unreadable garbage (e.g. a truncated write): replace it.
  try {
    final token = _randomToken();
    final tmp = File('$path.tmp-$pid');
    await tmp.writeAsBytes(token, flush: true);
    await tmp.rename(path);
    return token;
  } on FileSystemException {
    // Read-only dir: derived token, still per user.
    final digest = sha256.convert(utf8.encode('${_osUser()}|$dataDir')).toString();
    return ascii.encode(digest.substring(0, 32));
  }
}

bool _validToken(List<int> raw) {
  if (raw.length != 32) return false;
  for (final byte in raw) {
    final c = byte | 0x20; // fold A-Z to a-z
    final isDigit = byte >= 0x30 && byte <= 0x39;
    final isHex = c >= 0x61 && c <= 0x66;
    if (!isDigit && !isHex) return false;
  }
  return true;
}

List<int> _randomToken() {
  // 16 random bytes as 32 hex chars (matches `secrets.token_hex(16)`).
  final random = DateTime.now().microsecondsSinceEpoch;
  final salted = '$random|$pid|${_osUser()}';
  final first = sha256.convert(utf8.encode(salted)).toString();
  final second = sha256.convert(utf8.encode('$first|$random')).toString();
  return ascii.encode((first + second).substring(0, 32));
}

extension on List<int> {
  List<int> trimAscii() {
    var start = 0;
    var end = length;
    while (start < end && this[start] <= 0x20) {
      start++;
    }
    while (end > start && this[end - 1] <= 0x20) {
      end--;
    }
    return sublist(start, end);
  }
}

List<int> _message(String magic, List<int> token) =>
    ascii.encode('$magic ${ascii.decode(token)}\n');

/// Constant-time equality (mirrors `hmac.compare_digest`).
bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Owns (primary) or probes (secondary) one loopback port.
///
/// Primary: [acquire] binds the port and serves show requests until
/// [close]. Secondary: [signal] asks the primary to show itself
/// (`kind: 'show'`), just checks it is alive (`kind: 'ping'`) or asks
/// it to close its window (`kind: 'quit'`, served by `onQuit`); a
/// `true` return means the primary acknowledged, so the secondary
/// should exit. The handshake rejects unrelated port squatters: they
/// never send [replyOk], so [signal] returns `false` for them.
class SingleInstance {
  SingleInstance({required this._port, this.onShow, this.onQuit})
      : _pendingShows = 0;

  final int _port;

  /// Fired when a secondary launch asks to be shown.
  void Function()? onShow;

  /// Fired when the tray asks the window to close cleanly. When null,
  /// `quit` signals are left unacknowledged (sender falls back to a kill).
  void Function()? onQuit;

  ServerSocket? _socket;
  StreamSubscription<Socket>? _subscription;
  List<int> _token = const [];
  int _pendingShows;
  bool _closed = false;

  bool get isPrimary => _socket != null;

  int get port => _port;

  int? get boundPort => _socket?.port;

  /// Binds the port and starts serving. True when primary.
  Future<bool> acquire(List<int> token) async {
    _token = List<int>.of(token);
    ServerSocket? socket;
    try {
      socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        _port,
      );
    } on SocketException {
      return false;
    } catch (_) {
      return false;
    }
    _socket = socket;
    _subscription = socket.listen(
      _serve,
      onError: (_) {},
      cancelOnError: false,
    );
    return true;
  }

  /// Asks the primary to show itself. True when it acknowledged.
  Future<bool> signal(List<int> token, {String kind = 'show'}) async {
    final magic = switch (kind) {
      'show' => magicShow,
      'ping' => magicPing,
      'quit' => magicQuit,
      _ => throw ArgumentError('unknown signal kind: $kind'),
    };
    Socket? connection;
    try {
      connection = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _port,
        timeout: _ioTimeout,
      );
      connection.add(_message(magic, token));
      await connection.flush();
      final reply = await connection
          .timeout(_ioTimeout)
          .fold<List<int>>(<int>[], (acc, chunk) {
        if (acc.length < replyOk.length) acc.addAll(chunk);
        return acc;
      });
      return ascii.decode(reply.take(replyOk.length).toList()) == replyOk;
    } catch (_) {
      return false;
    } finally {
      try {
        await connection?.close();
      } catch (_) {}
    }
  }

  /// Stops the listener and frees the port. Safe to call anytime.
  Future<void> close() async {
    _closed = true;
    final subscription = _subscription;
    _subscription = null;
    try {
      await subscription?.cancel();
    } catch (_) {}
    final socket = _socket;
    _socket = null;
    try {
      await socket?.close();
    } catch (_) {}
  }

  Future<void> _serve(Socket connection) async {
    try {
      connection.setOption(SocketOption.tcpNoDelay, true);
      final data = await _readLine(connection);
      final kinds = <String, String>{
        magicShow: magicShow,
        magicPing: magicPing,
        magicQuit: magicQuit,
      };
      String? matched;
      for (final entry in kinds.entries) {
        if (_constantTimeEquals(data, _message(entry.key, _token))) {
          matched = entry.value;
          break;
        }
      }
      // Unrelated prober, version mismatch or ANOTHER user's launch:
      // stay silent (it then runs on its own).
      if (matched == null) return;
      if (matched == magicQuit && onQuit == null) {
        return; // Nothing here can close the window: sender kills instead.
      }
      connection.add(ascii.encode(replyOk));
      await connection.flush();
      if (matched == magicPing) return;
      if (matched == magicQuit) {
        try {
          onQuit?.call();
        } catch (_) {}
        return;
      }
      final callback = onShow;
      if (callback != null) {
        try {
          callback();
        } catch (_) {}
      } else {
        _pendingShows++;
      }
    } catch (_) {
      // A half-open probe must never break the listener.
    } finally {
      try {
        await connection.close();
      } catch (_) {}
    }
  }

  Future<List<int>> _readLine(Socket connection) async {
    final buffer = <int>[];
    await for (final chunk in connection.timeout(_ioTimeout)) {
      for (final byte in chunk) {
        if (buffer.length >= maxLineLength) break;
        buffer.add(byte);
        if (byte == 0x0a) break;
      }
      if (buffer.isNotEmpty && buffer.last == 0x0a) break;
      if (buffer.length >= maxLineLength) break;
    }
    return buffer;
  }

  /// Registers the show callback, firing any show that arrived while
  /// the UI was not ready to receive it (a fresh window is already
  /// visible, so firing now is harmless).
  void setOnShow(void Function()? callback) {
    onShow = callback;
    if (callback != null && _pendingShows > 0 && !_closed) {
      _pendingShows = 0;
      try {
        callback();
      } catch (_) {}
    }
  }
}

/// Tries to become the primary instance on [port].
///
/// `mode: 'show'` (normal launch) tells a live primary to restore its
/// window; `mode: 'ping'` (--minimized launch) only checks one is
/// alive so autostart never pops a window. Returns `('primary',
/// guard)` (the caller must hold the guard for the process lifetime),
/// `('secondary', null)` (a live instance acknowledged — exit), or
/// `('solo', null)` (the port is squatted by a non-Strakalari process
/// — proceed without duplicate protection rather than refusing to
/// start). Only a bad [mode] throws.
Future<(String, SingleInstance?)> ensureSinglePrimary({
  required String dataDir,
  int? port,
  String mode = 'show',
}) async {
  if (mode != 'show' && mode != 'ping') {
    throw ArgumentError("unknown mode: '$mode'");
  }
  final target = port ?? mainPort();
  final token = await instanceToken(dataDir);
  final guard = SingleInstance(port: target);
  if (await guard.acquire(token)) {
    return ('primary', guard);
  }
  if (mode == 'show') {
    // ignore: avoid_print
    print('Strakaláři is already running; showing the open window.');
  }
  final probe = SingleInstance(port: target);
  var signalled = false;
  for (var i = 0; i < _signalAttempts; i++) {
    if (await probe.signal(token, kind: mode)) {
      signalled = true;
      break;
    }
    await Future<void>.delayed(_signalRetryPause);
  }
  if (signalled) {
    await guard.close();
    return ('secondary', null);
  }
  // Nobody answered: the previous owner is dying, or an unrelated
  // process squats the port (handshake mismatch). Retry once in case
  // the port just freed up.
  final retry = SingleInstance(port: target);
  if (await retry.acquire(token)) {
    await guard.close();
    return ('primary', retry);
  }
  // ignore: avoid_print
  print(
    'Warning: single-instance port $target is held by an unknown '
    'process; continuing without duplicate protection.',
  );
  await retry.close();
  return ('solo', null);
}

/// Stops a spawned helper process tree by pid.
///
/// The Flutter app is one process (no UI child to reap), so this is
/// only a small utility for external helpers. Never raises; true when
/// the process is gone. On Windows `taskkill /T /F` takes the whole
/// tree while the parent is still alive; elsewhere SIGTERM then
/// SIGKILL. Same-named-process sweeps are deliberately absent (see
/// the file docs).
///
/// True when [pid] still names a live process. Never raises.
Future<bool> isProcessAlive(int pid) async {
  if (Platform.isWindows) {
    try {
      final result = await Process.run(
        'tasklist.exe',
        ['/FI', 'PID eq $pid', '/NH'],
        runInShell: true,
      ).timeout(const Duration(seconds: 10));
      if (result.exitCode != 0) return true; // Unknown: assume alive.
      return (result.stdout as String).contains('$pid');
    } catch (_) {
      return true;
    }
  }
  try {
    // Signal 0 equivalent: `sigcont` merely resumes an already
    // running process and is the only non-killing probe `dart:io`
    // offers. Returns false when the pid does not exist.
    return Process.killPid(pid, ProcessSignal.sigcont);
  } catch (_) {
    return false;
  }
}

Future<bool> terminateProcessTree(int pid) async {
  if (!await isProcessAlive(pid)) return true;

  if (Platform.isWindows) {
    try {
      await Process.run(
        'taskkill.exe',
        ['/PID', '$pid', '/T', '/F'],
        runInShell: true,
      ).timeout(const Duration(seconds: 15));
    } catch (_) {}
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!await isProcessAlive(pid)) return true;
    }
    return false;
  }
  try {
    Process.killPid(pid);
  } catch (_) {
    return false;
  }
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (!await isProcessAlive(pid)) return true;
  }
  try {
    Process.killPid(pid, ProcessSignal.sigkill);
  } catch (_) {
    return false;
  }
  await Future<void>.delayed(const Duration(seconds: 1));
  return !await isProcessAlive(pid);
}
