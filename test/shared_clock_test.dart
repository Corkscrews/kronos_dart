@TestOn('vm')
library;

import 'dart:isolate';

import 'package:kronos_dart/kronos_dart.dart';
import 'package:kronos_dart/src/time/kernel_clock_ffi.dart';
import 'package:kronos_dart/src/time/local_clock.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

/// A main-isolate clock whose every pass estimates [offset()].
SynchronizedClock _mainClock(double Function() offset) => SynchronizedClock(
  query: (_) => Stream.value(progressWith(offset())),
  storage: TimeStorage(backend: MemoryTimeStorageBackend()),
  pollInterval: const Duration(hours: 1),
);

double _offsetOf(SynchronizedClock clock) => clock.timestamp! - currentTime();

void main() {
  test('a follower mirrors syncs and resets of the main clock', () async {
    var offset = 5.0;
    final main = _mainClock(() => offset);
    await main.sync();
    final follower = await SynchronizedClock.follow(main.share());
    expect(_offsetOf(follower), closeTo(5, 1e-3));

    offset = 7;
    await main.sync();
    await pumpEventQueue();
    expect(_offsetOf(follower), closeTo(7, 1e-3));

    main.reset();
    await pumpEventQueue();
    expect(follower.now, isNull);
    follower.reset();
  });

  test('a follower in another isolate agrees with the main clock', () async {
    final main = _mainClock(() => 5);
    await main.sync();
    final followerOffset = await _followInIsolate(main.share());
    expect(followerOffset - _offsetOf(main), closeTo(0, 1e-4));
    main.reset();
  });

  test('a follower is read-only', () async {
    final main = _mainClock(() => 1);
    final follower = await SynchronizedClock.follow(main.share());
    expect(follower.now, isNull);
    expect(follower.sync(), throwsStateError);
    expect(() => follower.storage, throwsUnsupportedError);
    expect(follower.share, throwsUnsupportedError);
    follower.reset();
    main.reset();
  });

  test('only a clock on the process source can be shared', () {
    final clock = SynchronizedClock(source: fixedSource(1));
    expect(clock.share, throwsStateError);
  });

  test(
    'a follower adopts the main isolate kernel calibration',
    skip: kernelClockSupported ? false : 'Kernel clock only',
    () async {
      final facts = await Isolate.run(_kernelMainWithFollower);
      expect(facts['followerMode'], 'kernel');
      expect(
        facts['followerOffsetNanoseconds'],
        facts['mainOffsetNanoseconds'],
      );
      expect(facts['followerBoot'], facts['mainBoot']);
      expect(facts['difference'] as double, closeTo(0, 1e-5));
    },
  );
}

Future<double> _followInIsolate(SendPort port) => Isolate.run(() async {
  final follower = await SynchronizedClock.follow(port);
  final offset = _offsetOf(follower);
  follower.reset();
  return offset;
});

/// Runs in a fresh isolate: opts in, syncs, then lets a second isolate follow
/// without opting in itself.
Future<Map<String, Object?>> _kernelMainWithFollower() async {
  KronosClock.useKernelClock();
  final main = _mainClock(() => 5);
  await main.sync();
  final follower = await _kernelFollowerFacts(main.share());
  final facts = {
    ...follower,
    'mainOffsetNanoseconds': clockCalibration.offsetNanoseconds,
    'mainBoot': clockCalibration.bootIdentifier,
    'difference': (follower['offset'] as double) - _offsetOf(main),
  };
  main.reset();
  return facts;
}

Future<Map<String, Object?>> _kernelFollowerFacts(SendPort port) =>
    Isolate.run(() async {
      final follower = await SynchronizedClock.follow(port);
      final facts = {
        'followerMode': clockCalibration.mode.name,
        'followerOffsetNanoseconds': clockCalibration.offsetNanoseconds,
        'followerBoot': processBootIdentifier(),
        'offset': _offsetOf(follower),
      };
      follower.reset();
      return facts;
    });
