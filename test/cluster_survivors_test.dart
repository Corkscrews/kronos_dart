import 'dart:math' as math;

import 'package:kronos_dart/src/models.dart' show LeapIndicator;
import 'package:kronos_dart/src/ntp/clock_filter.dart' show PeerEstimate;
import 'package:kronos_dart/src/ntp/selection.dart' show clusterSurvivors;
import 'package:test/test.dart';

void main() {
  group('clusterSurvivors', () {
    test('keeps every peer at or below the minimum survivor count', () {
      for (final count in [0, 1, 2, 3]) {
        final peers = [
          for (var index = 0; index < count; index++)
            peer(offset: index * 10.0, distance: 0.1),
        ];
        expect(clusterSurvivors(peers), unorderedEquals(peers));
      }
    });

    test('orders survivors by merit', () {
      final far = peer(offset: 0.001, distance: 0.3);
      final near = peer(offset: 0.002, distance: 0.1);
      final middle = peer(offset: 0.003, distance: 0.2);
      expect(clusterSurvivors([far, near, middle]), [near, middle, far]);
    });

    test('prunes outliers one at a time down to three', () {
      final core = [
        for (final offset in [0.0, 0.001, 0.002])
          peer(offset: offset, distance: 0.1, jitter: 0.0001),
      ];
      final outliers = [
        peer(offset: 0.5, distance: 0.1, jitter: 0.0001),
        peer(offset: -0.4, distance: 0.1, jitter: 0.0001),
      ];
      expect(clusterSurvivors([...outliers, ...core]), unorderedEquals(core));
    });

    test('stops once the worst selection jitter is below a peer jitter', () {
      final peers = [
        for (final offset in [0.0, 0.001, 0.002, 0.003])
          peer(offset: offset, distance: 0.1, jitter: 0.01),
      ];
      expect(clusterSurvivors(peers), unorderedEquals(peers));
    });

    test('prunes the first peer by merit on a jitter tie', () {
      final low = peer(offset: -1, distance: 0.1);
      final centre = peer(offset: 0, distance: 0.2);
      final centreTwin = peer(offset: 0, distance: 0.3);
      final high = peer(offset: 1, distance: 0.4);
      expect(clusterSurvivors([high, centreTwin, centre, low]), [
        centre,
        centreTwin,
        high,
      ]);
    });

    test('resolves microsecond spreads around a large offset', () {
      const base = 1.7e9;
      final core = [
        for (final delta in [0.0, 1e-6, 2e-6])
          peer(offset: base + delta, distance: 0.1, jitter: 1e-7),
      ];
      final outlier = peer(offset: base + 5e-5, distance: 0.1, jitter: 1e-7);
      expect(clusterSurvivors([...core, outlier]), unorderedEquals(core));
    });

    test('matches the reference algorithm on random peer sets', () {
      final random = math.Random(20260928);
      for (var round = 0; round < 2000; round++) {
        final base = const [0.0, -3.2, 1e3, 1.7e9][round % 4];
        final spread = const [1e-6, 1e-3, 0.1, 5.0][(round ~/ 4) % 4];
        // Offsets a few ulps apart tie exactly, and either tied peer is a
        // valid pick; the large-offset test above covers that range.
        if (base.abs() * 1e-15 > spread) continue;
        final peers = [
          for (
            var index = 0, count = random.nextInt(12);
            index < count;
            index++
          )
            peer(
              offset: base + spread * (random.nextDouble() * 2 - 1),
              distance: 0.01 + random.nextDouble(),
              jitter: spread * random.nextDouble() * 0.5,
              stratum: 1 + random.nextInt(3),
            ),
        ];
        expect(
          clusterSurvivors(peers),
          referenceClusterSurvivors(peers),
          reason: 'round $round, base $base, spread $spread',
        );
      }
    });

    test('does not modify the input list', () {
      final peers = [
        for (final offset in [0.5, 0.0, 0.001, 0.002])
          peer(offset: offset, distance: 0.1, jitter: 0.0001),
      ];
      final before = [...peers];
      clusterSurvivors(peers);
      expect(peers, before);
    });
  });
}

/// The RFC 5905 cluster algorithm as written before optimisation: each
/// round computes every peer's RMS offset distance to all survivors directly.
List<PeerEstimate> referenceClusterSurvivors(List<PeerEstimate> peers) {
  final survivors = [...peers]..sort((a, b) => a.merit.compareTo(b.merit));
  while (survivors.length > 3) {
    var worst = 0;
    var worstJitter = -1.0;
    for (final (index, peer) in survivors.indexed) {
      var sum = 0.0;
      for (final other in survivors) {
        final difference = other.offset - peer.offset;
        sum += difference * difference;
      }
      final jitter = math.sqrt(sum / (survivors.length - 1));
      if (jitter <= worstJitter) continue;
      worst = index;
      worstJitter = jitter;
    }
    final bestPeerJitter = survivors
        .map((peer) => peer.jitter)
        .reduce(math.min);
    if (worstJitter < bestPeerJitter) break;
    survivors.removeAt(worst);
  }
  return survivors;
}

PeerEstimate peer({
  required double offset,
  required double distance,
  double jitter = 0,
  int stratum = 2,
}) => PeerEstimate(
  offset: offset,
  delay: 0,
  dispersion: 0,
  jitter: jitter,
  rootDelay: 0,
  rootDispersion: distance - 0.0025 - jitter,
  stratum: stratum,
  leap: LeapIndicator.noWarning,
);
