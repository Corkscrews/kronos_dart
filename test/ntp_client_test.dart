import 'package:universal_io/io.dart';

import 'package:kronos_dart/kronos_dart.dart';
import 'package:kronos_dart/src/ntp/clock_filter.dart'
    show PeerEstimate, ReceivedSample, measurementsOf;
import 'package:kronos_dart/src/ntp/kiss_of_death.dart'
    show KissOfDeathRegistry;
import 'package:kronos_dart/src/ntp/selection.dart'
    show selectTruechimers, clusterSurvivors, combineOffsets;
import 'package:kronos_dart/src/time/local_clock.dart' show currentTime;
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('NTP client', () {
    test('queries a resolved server IP', () async {
      final addresses = await NtpDnsResolver.resolve('time.apple.com');
      expect(addresses, isNotEmpty);

      NtpSampleResult? successfulResult;
      for (final address in addresses) {
        final result = await NtpClient().sample(
          ip: address,
          version: 3,
          timeout: 2,
        );
        if (result.packet != null) {
          successfulResult = result;
          break;
        }
      }

      expect(successfulResult, isNotNull);
      expect(successfulResult!.blocked, isFalse);
      expect(successfulResult.packet!.version, greaterThanOrEqualTo(3));
      expect(successfulResult.packet!.isValidResponse(), isTrue);
    });

    test('queries a pool consistently', () async {
      final first = await lastEstimate(['0.pool.ntp.org']);
      expect(first, isNotNull);
      final second = await lastEstimate(['0.pool.ntp.org']);
      expect(second, isNotNull);
      expect((first!.offset - second!.offset).abs(), lessThan(0.10));
    });

    test('queries an IPv6 pool', () async {
      final estimate = await lastEstimate(['2.pool.ntp.org']);
      expect(estimate, isNotNull);
    });

    test('reports progress through the requested sample count', () async {
      final updates =
          await NtpClient()
              .query(
                pools: [NtpPool('time.apple.com', samples: 2)],
                maximumServers: 1,
              )
              .toList();
      expect(updates.map((update) => update.completed), [1, 2]);
      expect(updates.last.total, 2);
    });

    test('finishes with an empty estimate when no servers resolve', () async {
      final updates = await NtpClient().query(pools: [NtpPool('')]).toList();
      expect(updates, hasLength(1));
      expect(updates.first.estimate, isNull);
      expect(updates.first.total, 0);
    });

    test('deduplicates repeated pool names before sampling', () async {
      final client = NtpClient();
      final updates =
          await client
              .query(
                pools: [
                  NtpPool('127.0.0.1', samples: 1),
                  NtpPool('127.0.0.1', samples: 1),
                ],
                port: 9,
                timeout: 0.01,
              )
              .toList();
      expect(updates.last.total, 1);
    });
  }, tags: ['network']);

  group('RFC 5905 algorithms', () {
    test('selection drops a falseticker', () {
      final truechimers = [
        0.010,
        0.012,
        0.011,
      ].map((offset) => peer(offset: offset, distance: 0.02));
      final falseticker = peer(offset: 5, distance: 0.02);
      final survivors = selectTruechimers([...truechimers, falseticker]);
      final offsets = survivors.map((value) => value.offset).toList()..sort();
      expect(offsets, [0.010, 0.011, 0.012]);
    });

    test('selection fails without a majority', () {
      final peers = [
        peer(offset: 0, distance: 0.01),
        peer(offset: 1, distance: 0.01),
      ];
      expect(selectTruechimers(peers), isEmpty);
    });

    test('selection rejects distant servers', () {
      expect(selectTruechimers([peer(offset: 0, distance: 2)]), isEmpty);
    });

    test('cluster prunes an outlier down to the minimum survivor count', () {
      final peers = [
        0.0,
        0.001,
        0.002,
        0.003,
        0.05,
      ].map((offset) => peer(offset: offset, distance: 0.1, jitter: 0.0001));
      final survivors = clusterSurvivors(peers.toList());
      expect(survivors, hasLength(3));
      expect(survivors.any((item) => item.offset == 0.05), isFalse);
    });

    test('combine weights by root distance', () {
      final near = peer(offset: 0, distance: 0.01);
      final far = peer(offset: 0.3, distance: 0.02);
      expect(combineOffsets([near, far]), closeTo(0.1, 1e-9));
    });

    test('estimate takes the system peer leap indicator', () {
      final leaping = peer(
        offset: 0,
        distance: 0.01,
        stratum: 1,
        leap: LeapIndicator.sixtyOneSeconds,
      );
      final other = peer(offset: 0.001, distance: 0.01, stratum: 2);
      expect(
        clusterSurvivors([other, leaping]).first.leap,
        LeapIndicator.sixtyOneSeconds,
      );
    });

    test('measurements mark the lowest-delay sample per server', () {
      final now = currentTime();
      final first = InternetAddress('192.0.2.10');
      final second = InternetAddress('192.0.2.11');
      final samples = <ReceivedSample>[
        (
          address: first,
          packet: serverReply(now: now, offset: 0.200, delay: 0.410),
        ),
        (
          address: first,
          packet: serverReply(now: now, offset: 0.013, delay: 0.035),
        ),
        (
          address: first,
          packet: serverReply(now: now, offset: 0.015, delay: 0.038),
        ),
        (
          address: second,
          packet: serverReply(now: now, offset: 0.040, delay: 0.090),
        ),
        (
          address: second,
          packet: serverReply(now: now, offset: 0.011, delay: 0.030),
        ),
      ];
      final measurements = measurementsOf(samples);

      expect(measurements.map((item) => item.server), [
        '192.0.2.10',
        '192.0.2.10',
        '192.0.2.10',
        '192.0.2.11',
        '192.0.2.11',
      ]);
      expect(measurements.map((item) => item.stratum), [2, 2, 2, 2, 2]);
      expect(measurements.map((item) => item.selected), [
        false,
        true,
        false,
        false,
        true,
      ]);
      expect(measurements[0].offset, closeTo(0.200, 1e-4));
      expect(measurements[0].roundTripDelay, closeTo(0.410, 1e-4));
      expect(measurements[1].offset, closeTo(0.013, 1e-4));
      expect(measurements[1].roundTripDelay, closeTo(0.035, 1e-4));
      expect(measurements[0].dispersion, greaterThan(0));
    });

    test('clock filter picks the lowest-delay sample', () {
      final now = currentTime();
      final estimate = PeerEstimate.fromSamples([
        serverReply(now: now, offset: 0.5, delay: 0.2),
        serverReply(now: now, offset: 0.1, delay: 0.02),
        serverReply(now: now, offset: 0.3, delay: 0.1),
      ], now);
      expect(estimate.offset, closeTo(0.1, 1e-6));
      expect(estimate.delay, closeTo(0.02, 1e-6));
      expect(estimate.jitter, greaterThan(0.2));
    });
  });

  group('kiss-o-death', () {
    final denied = InternetAddress('192.0.2.1');
    final limited = InternetAddress('192.0.2.2');
    final other = InternetAddress('192.0.2.3');

    late KissOfDeathRegistry registry;
    setUp(() => registry = KissOfDeathRegistry());

    test('records denied, rate-limited, and informational servers', () {
      registry.record(KissCode.deny, denied);
      registry.record(KissCode.rateExceeded, limited);
      registry.record(KissCode.other, other);

      expect(registry.isBlocked(denied), isTrue);
      expect(registry.isBlocked(limited), isTrue);
      expect(registry.isBlocked(other), isFalse);
    });

    test('blocked server is skipped without sending', () async {
      registry.record(KissCode.restricted, denied);
      final result = await NtpClient(registry: registry).sample(ip: denied);
      expect(result.packet, isNull);
      expect(result.blocked, isTrue);
    });

    test('blocked server is not selected', () async {
      registry.record(KissCode.deny, denied);
      final updates =
          await NtpClient(
            registry: registry,
          ).query(pools: [NtpPool('192.0.2.1')]).toList();
      expect(updates.map((item) => item.total), [0]);
    });

    test('rate hold expires on the injected monotonic clock', () {
      var uptime = 0.0;
      final local = KissOfDeathRegistry(monotonicTime: () => uptime);
      local.record(KissCode.rateExceeded, limited);
      expect(local.isBlocked(limited), isTrue);
      uptime = 65;
      expect(local.isBlocked(limited), isFalse);
    });
  });
}

Future<NtpEstimate?> lastEstimate(List<String> pools) async {
  NtpEstimate? estimate;
  await for (final update in NtpClient().query(
    pools: [for (final pool in pools) NtpPool(pool, samples: 1)],
  )) {
    estimate = update.estimate;
  }
  return estimate;
}

PeerEstimate peer({
  required double offset,
  required double distance,
  double jitter = 0,
  int stratum = 2,
  LeapIndicator leap = LeapIndicator.noWarning,
}) => PeerEstimate(
  offset: offset,
  delay: 0,
  dispersion: 0,
  jitter: jitter,
  rootDelay: 0,
  rootDispersion: distance - 0.0025 - jitter,
  stratum: stratum,
  leap: leap,
);
