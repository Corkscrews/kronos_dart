import 'dart:async';

import 'package:kronos_dart/kronos_dart.dart';
import 'package:kronos_dart/src/time/local_clock.dart' show currentTime;
import 'package:test/test.dart';

import 'test_helpers.dart';

NtpProgress _progress(double offset, int completed, int total) => NtpProgress(
  estimate: NtpEstimate(
    offset: offset,
    leap: LeapIndicator.noWarning,
    rootDistance: 0.01,
  ),
  completed: completed,
  total: total,
  measurements: const [],
);

void main() {
  test('sync returns the last usable sample', () async {
    final clock = SynchronizedClock(
      query:
          (_) => Stream.fromIterable([
            _progress(0.01, 1, 2),
            _progress(0.02, 2, 2),
          ]),
      source: fixedSource(5000),
      storage: TimeStorage(backend: MemoryTimeStorageBackend()),
    );
    final result = await clock.sync();
    expect(result.date, isNotNull);
    expect(result.offset, 0.02);
    clock.reset();
  });

  test('updates in one pass use the state from before that pass', () async {
    final backend = MemoryTimeStorageBackend();
    var uptime = 10000.0;
    final source = ClockSource(
      monotonicTime: () => uptime,
      bootIdentifier: () => testBootIdentifier,
    );
    final storage = TimeStorage(backend: backend, source: source);
    final now = currentTime();
    storage.stableTime = restoredTime(
      uptime: 8000,
      timestamp: now - 2000,
      monotonicNow: 10000,
    );
    final clock = SynchronizedClock(
      storage: storage,
      source: source,
      query: (_) async* {
        yield _progress(5, 1, 2);
        uptime = 10000.1;
        yield _progress(0, 2, 2);
      },
    );
    await clock.sync();
    final map = storage.stableTime!.toMap();
    expect(map['ReferenceUptime'], 10000.1);
    expect(map['Frequency'], lessThan(-5e-6));
    clock.reset();
  });

  test('reset closes an active pass and keeps now empty', () async {
    final updates = StreamController<NtpProgress>();
    final finished = Completer<void>();
    final clock = SynchronizedClock(
      query: (_) => updates.stream,
      source: fixedSource(5000),
      storage: TimeStorage(backend: MemoryTimeStorageBackend()),
    );
    final subscription = clock.syncing().listen(
      (_) {},
      onDone: finished.complete,
    );
    clock.reset();
    await finished.future;
    expect(clock.now, isNull);
    await subscription.cancel();
    await updates.close();
  });

  test('changing the source or storage reloads saved state', () {
    final backend = MemoryTimeStorageBackend();
    final first = TimeStorage(backend: backend, source: fixedSource(5000));
    first.stableTime = restoredTime(
      uptime: 4000,
      timestamp: currentTime() - 1000,
    );
    final clock = SynchronizedClock(storage: first, source: fixedSource(5000));
    expect(clock.now, isNotNull);

    clock.source = fixedSource(5000, 'another-boot');
    expect(clock.now, isNull);

    final replacement = TimeStorage(
      backend: MemoryTimeStorageBackend(),
      source: fixedSource(5000),
    );
    replacement.stableTime = restoredTime(
      uptime: 4900,
      timestamp: currentTime() - 100,
    );
    clock.storage = replacement;
    clock.source = fixedSource(5000);
    expect(clock.now, isNotNull);
    clock.reset();
  });

  test('completed passes schedule one poll', () async {
    var calls = 0;
    final second = Completer<void>();
    final clock = SynchronizedClock(
      source: fixedSource(5000),
      storage: TimeStorage(backend: MemoryTimeStorageBackend()),
      pollInterval: const Duration(milliseconds: 20),
      query: (_) {
        calls++;
        if (calls == 2) second.complete();
        return Stream.value(_progress(0, 1, 1));
      },
    );
    await clock.sync();
    await second.future.timeout(const Duration(seconds: 1));
    clock.reset();
    expect(calls, 2);
  });
}
