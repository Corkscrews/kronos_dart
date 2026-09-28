import 'dart:async';

import 'package:kronos_dart/kronos_dart.dart';
import 'package:test/test.dart';

@Tags(['network'])
void main() {
  setUp(() {
    Clock.reset();
    Clock.storage.clear();
  });

  tearDown(Clock.reset);

  test('async sync returns the last usable date and offset', () async {
    final result = await Clock.sync(
      configuration: const NtpConfiguration(
        pools: [NtpPool('time.apple.com', samples: 1)],
      ),
    );
    expect(result.date, isNotNull);
    expect(result.offset, isNotNull);
    expect(Clock.now, isNotNull);
  });

  test('syncing yields ordered samples with selected measurements', () async {
    final samples =
        await Clock.syncing(
          configuration: const NtpConfiguration(
            pools: [NtpPool('time.apple.com', samples: 1)],
          ),
        ).toList();

    expect(samples, isNotEmpty);
    final completed = samples.map((sample) => sample.completed).toList();
    expect(completed, orderedEquals([...completed]..sort()));
    final measurements = samples.last.measurements;
    expect(measurements, isNotEmpty);
    expect(measurements.any((measurement) => measurement.selected), isTrue);
    expect(
      measurements.every(
        (measurement) =>
            measurement.stratum > 0 && measurement.server.isNotEmpty,
      ),
      isTrue,
    );
  });

  test('reset finishes an active stream and clears the clock', () async {
    final completed = Completer<void>();
    final subscription = Clock.syncing(
      configuration: const NtpConfiguration(
        pools: [NtpPool('time.apple.com', samples: 4)],
      ),
    ).listen((_) {}, onDone: () => completed.complete());

    Clock.reset();
    await completed.future.timeout(const Duration(seconds: 2));
    await subscription.cancel();
    expect(Clock.now, isNull);
  });

  test('reset resolves an awaiting sync with no result', () async {
    final sync = Clock.sync(
      configuration: const NtpConfiguration(
        pools: [NtpPool('time.apple.com', samples: 4)],
      ),
    );
    Clock.reset();

    final result = await sync.timeout(const Duration(seconds: 2));
    expect(result.date, isNull);
    expect(result.offset, isNull);
    expect(Clock.now, isNull);
  });
}
