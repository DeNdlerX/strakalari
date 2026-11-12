// The headless wake's hand-off to a living UI isolate (C-M1): the UI
// acknowledges at once; a closed port (the engine dropped the UI isolate
// while the process lives on) is noticed, its stale name removed, and
// the headless side runs the job itself.
import 'dart:isolate';
import 'dart:ui';

import 'package:app/platform/android/background.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(unregisterUiRefreshPort);

  test('noUiIsolateRunsHere', () async {
    unregisterUiRefreshPort();
    expect(await handOffToUi('alarm'), isFalse);
  });

  test('aLivingUiAcknowledgesAtOnceThenDoesTheJob', () async {
    final port = ReceivePort();
    var handedOff = 0;
    final sub = await registerUiRefreshPort(port, onHandOff: () async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      handedOff++;
    });
    final sw = Stopwatch()..start();
    expect(await handOffToUi('alarm', ackTimeout: const Duration(seconds: 5)), isTrue);
    expect(sw.elapsed, lessThan(const Duration(seconds: 1)),
        reason: 'the acknowledgement comes before the job runs');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(handedOff, 1);
    await sub.cancel();
    port.close();
  });

  test('aClosedUiPortIsDroppedAndTheJobRunsHere', () async {
    final port = ReceivePort();
    IsolateNameServer.removePortNameMapping(uiIsolatePortName);
    IsolateNameServer.registerPortWithName(port.sendPort, uiIsolatePortName);
    port.close(); // the UI isolate died, its name stayed
    expect(await handOffToUi('alarm', ackTimeout: const Duration(milliseconds: 300)), isFalse);
    expect(IsolateNameServer.lookupPortByName(uiIsolatePortName), isNull);
    // The next wake does not wait again.
    expect(await handOffToUi('alarm'), isFalse);
  });

  test('aTornDownUiRemovesItsName', () async {
    final port = ReceivePort();
    final sub = await registerUiRefreshPort(port);
    expect(IsolateNameServer.lookupPortByName(uiIsolatePortName), isNotNull);
    unregisterUiRefreshPort(); // AppLifecycleState.detached
    expect(IsolateNameServer.lookupPortByName(uiIsolatePortName), isNull);
    await sub.cancel();
    port.close();
  });
}
