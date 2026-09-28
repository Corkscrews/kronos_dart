import 'package:kronos_dart/src/storage.dart';
import 'package:kronos_dart/src/models.dart' show LeapIndicator;
import 'package:kronos_dart/src/time/local_clock.dart';
import 'package:kronos_dart/src/time/stable_time.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('TimeStoragePolicy', () {
    test('app group policy retains its group identifier', () {
      const policy = TimeStoragePolicy.appGroup(
        'com.test.something.mygreatapp',
      );
      expect(policy.groupId, 'com.test.something.mygreatapp');
    });

    test('standard policy has no group identifier', () {
      expect(TimeStoragePolicy.standard.groupId, isNull);
    });
  });

  group('TimeStorage', () {
    test('stores and retrieves a stable time', () {
      final backend = MemoryTimeStorageBackend();
      const uptime = 5000.0;
      final storage = TimeStorage(
        backend: backend,
        source: fixedSource(uptime),
      );
      final sample = StableTime.synchronized(
        offset: 5000.32423,
        source: fixedSource(uptime),
      );
      storage.stableTime = sample;

      final restored = storage.stableTime;
      expect(restored, isNotNull);
      expect(restored!.toMap(), sample.toMap());
    });

    test('assigning null clears a saved stable time', () {
      final storage = TimeStorage(
        backend: MemoryTimeStorageBackend(),
        source: fixedSource(5000),
      );
      storage.stableTime = restoredTime(uptime: 4000, timestamp: currentTime());
      storage.stableTime = null;
      expect(storage.stableTime, isNull);
    });

    test('rejects a saved timestamp from another boot', () {
      final backend = MemoryTimeStorageBackend();
      final oldStorage = TimeStorage(
        backend: backend,
        source: fixedSource(5000, 'old-boot'),
      );
      oldStorage.stableTime = StableTime.synchronized(
        offset: 1,
        source: fixedSource(5000, 'old-boot'),
      );
      final newStorage = TimeStorage(
        backend: backend,
        source: fixedSource(5000, 'new-boot'),
      );
      expect(newStorage.stableTime, isNull);
    });

    test('rejects stored state without a boot identifier', () {
      final backend =
          MemoryTimeStorageBackend()..write('KronosStableTime', {
            'Uptime': 1.0,
            'Timestamp': 1.0,
            'Offset': 0.0,
          });
      final storage = TimeStorage(backend: backend, source: fixedSource(2));
      expect(storage.stableTime, isNull);
    });
  });

  group('StableTime', () {
    test('keeps sub-second offsets', () {
      const uptime = 5000.0;
      final freeze = StableTime.synchronized(
        offset: 0.25,
        source: fixedSource(uptime),
      );
      expect(
        freeze.adjustedTimestamp(atUptime: uptime) - currentTime(),
        closeTo(0.25, 0.01),
      );
    });

    test('measures frequency between synchronizations', () {
      const uptime = 10000.0;
      final now = currentTime();
      final previous = restoredTime(
        uptime: uptime - 2000,
        timestamp: now - 2000,
        monotonicNow: uptime,
      );
      final freeze = StableTime.synchronized(
        offset: -0.02,
        previous: previous,
        source: fixedSource(uptime),
      );
      final values = freeze.toMap();
      expect(values['Frequency'], closeTo(-2.5e-6, 1e-6));
      expect(values['ReferenceUptime'], values['Uptime']);
    });

    test('keeps the frequency for close synchronizations', () {
      const uptime = 10000.0;
      final now = currentTime();
      final previous = restoredTime(
        uptime: uptime - 10,
        timestamp: now - 10,
        monotonicNow: uptime,
        extra: {
          'Frequency': 3e-6,
          'ReferenceUptime': uptime - 10,
          'ReferenceTime': now - 10,
        },
      );
      final values =
          StableTime.synchronized(
            offset: 0.5,
            previous: previous,
            source: fixedSource(uptime),
          ).toMap();
      expect(values['Frequency'], 3e-6);
      expect(values['ReferenceUptime'], uptime - 10);
    });

    test('ignores steps when measuring frequency', () {
      const uptime = 10000.0;
      final now = currentTime();
      final previous = restoredTime(
        uptime: uptime - 2000,
        timestamp: now - 2000,
        monotonicNow: uptime,
      );
      final values =
          StableTime.synchronized(
            offset: 2,
            previous: previous,
            source: fixedSource(uptime),
          ).toMap();
      expect(values['Frequency'], 0);
    });

    test('steps back after an inserted leap second', () {
      final now = currentTime();
      const uptime = 5000.0;
      final pending = restoredTime(
        uptime: uptime,
        timestamp: now,
        monotonicNow: uptime,
        extra: {'LeapTime': now + 100, 'LeapStep': -1},
      );
      final passed = restoredTime(
        uptime: uptime,
        timestamp: now,
        monotonicNow: uptime,
        extra: {'LeapTime': now - 100, 'LeapStep': -1},
      );
      expect(
        pending.adjustedTimestamp(atUptime: uptime) - currentTime(),
        closeTo(0, 0.01),
      );
      expect(
        passed.adjustedTimestamp(atUptime: uptime) - currentTime(),
        closeTo(-1, 0.01),
      );
    });

    test('schedules an announced leap second at the next month', () {
      const uptime = 5000.0;
      final freeze =
          StableTime.synchronized(
            offset: 0,
            leap: LeapIndicator.fiftyNineSeconds,
            source: fixedSource(uptime),
          ).toMap();
      expect(freeze['LeapStep'], 1);
      expect(
        freeze['LeapTime'],
        closeTo(startOfNextMonth(currentTime()), 0.01),
      );
      expect(startOfNextMonth(1483185600), 1483228800);
    });

    test('uncertainty grows at the configured frequency tolerance', () {
      const uptime = 10000.0;
      final now = currentTime();
      final freeze = restoredTime(
        uptime: uptime - 1000,
        timestamp: now - 1000,
        monotonicNow: uptime,
        extra: {'RootDistance': 0.01},
      );
      expect(
        freeze.uncertainty(atUptime: uptime),
        closeTo(0.01 + 1000 * frequencyTolerance, 1e-9),
      );
      expect(freeze.isSynchronized(atUptime: uptime), isTrue);
    });

    test('old synchronization exceeds maximum distance', () {
      const uptime = 300000.0;
      final now = currentTime();
      final freeze = restoredTime(
        uptime: uptime - 200000,
        timestamp: now - 200000,
        monotonicNow: uptime,
      );
      expect(
        freeze.uncertainty(atUptime: uptime),
        greaterThan(maximumDistance),
      );
      expect(freeze.isSynchronized(atUptime: uptime), isFalse);
    });
  });
}
