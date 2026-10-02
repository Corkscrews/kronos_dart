@TestOn('vm')
library;

import 'dart:isolate';

import 'package:kronos_dart/kronos_dart.dart';
import 'package:kronos_dart/src/time/kernel_clock_ffi.dart';
import 'package:kronos_dart/src/time/local_clock.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('portable clock', () {
    test('is the default', () {
      expect(clockCalibration.mode, ClockMode.portable);
      expect(clockCalibration.offsetNanoseconds, 0);
      expect(systemClockCorrection(), 0);
    });

    test('pairs monotonic and wall time from one instant', () {
      final sample = processSample();
      expect(currentTime() - sample.timestamp, inInclusiveRange(-1e-6, 1e-3));
      expect(defaultMonotonicTime() - sample.uptime, inInclusiveRange(0, 1e-3));
    });

    test('calibration round-trips through a map', () {
      final copy = ClockCalibration.fromMap(clockCalibration.toMap());
      expect(copy.toMap(), clockCalibration.toMap());
      expect(
        () => ClockCalibration.fromMap(const {'Mode': 'kernel'}),
        throwsFormatException,
      );
    });
  });

  group(
    'kernel clock',
    skip: kernelClockSupported ? false : 'Kernel clock only',
    () {
      test('opting in switches the isolate to the kernel clocks', () async {
        final facts = await Isolate.run(_kernelFacts);
        expect(facts['enabled'], isTrue);
        expect(facts['mode'], 'kernel');
        expect(facts['precision'], inInclusiveRange(-25, -20));
        expect(facts['drift'] as double, lessThan(1e-3));
        expect(facts['boot'], isNotNull);
        expect(facts['boot'], facts['kernelBoot']);
        expect(facts['window'] as int, lessThan(1000));
      });

      test('opting in after a portable read throws', () async {
        expect(await Isolate.run(_optInAfterRead), 'StateError');
      });

      test('monotonic time never decreases', () {
        var previous = kernelMonotonicNanoseconds();
        for (var i = 0; i < 100000; i++) {
          final next = kernelMonotonicNanoseconds();
          expect(next >= previous, isTrue);
          previous = next;
        }
      });

      test('isolates read the same monotonic clock and boot', () async {
        final before = kernelMonotonicNanoseconds();
        final inside = await Isolate.run(kernelMonotonicNanoseconds);
        final after = kernelMonotonicNanoseconds();
        expect(inside, inInclusiveRange(before, after));
        expect(await Isolate.run(kernelBootIdentifier), kernelBootIdentifier());
      });

      test('reported offsets stay relative to the system clock', () async {
        expect(await Isolate.run(_kernelSyncOffset), closeTo(0.02, 1e-3));
      });
    },
  );
}

Map<String, Object?> _kernelFacts() {
  final enabled = useKernelClock();
  final calibration = clockCalibration;
  final system = DateTime.now().microsecondsSinceEpoch / 1e6;
  return {
    'enabled': enabled,
    'mode': calibration.mode.name,
    'precision': localPrecision,
    'drift': (currentTime() - system).abs(),
    'boot': processBootIdentifier(),
    'kernelBoot': kernelBootIdentifier(),
    'window': calibration.windowMinimumNanoseconds,
  };
}

String _optInAfterRead() {
  currentTime();
  try {
    useKernelClock();
    return 'no error';
  } on StateError {
    return 'StateError';
  }
}

Future<double?> _kernelSyncOffset() async {
  KronosClock.useKernelClock();
  final clock = SynchronizedClock(
    query: (_) => Stream.value(progressWith(0.02)),
    storage: TimeStorage(backend: MemoryTimeStorageBackend()),
  );
  final result = await clock.sync();
  clock.reset();
  return result.offset;
}
