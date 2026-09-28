import 'dart:math' as math;

import '../models.dart';
import '../protocol.dart';
import '../time/local_clock.dart';
import 'clock_filter.dart';

const int _minimumClusterSurvivors = 3;

class NtpEstimate {
  const NtpEstimate({
    required this.offset,
    required this.leap,
    required this.rootDistance,
  });

  final double offset;
  final LeapIndicator leap;
  final double rootDistance;
}

typedef _Edge = ({double value, int type});

List<PeerEstimate> selectTruechimers(List<PeerEstimate> peers) {
  final candidates =
      peers.where((peer) => peer.rootDistance < maximumDistance).toList();
  final edges = [
    for (final peer in candidates) ...[
      (value: peer.offset - peer.rootDistance, type: -1),
      (value: peer.offset, type: 0),
      (value: peer.offset + peer.rootDistance, type: 1),
    ],
  ]..sort(
    (a, b) => a.value == b.value ? a.type - b.type : a.value.compareTo(b.value),
  );
  final count = candidates.length;
  for (var allowed = 0; 2 * allowed < count; allowed++) {
    final low = _intersectionEdge(edges, count - allowed, sign: -1);
    final high = _intersectionEdge(edges.reversed, count - allowed, sign: 1);
    if (low.found + high.found > allowed || low.value >= high.value) continue;
    return candidates
        .where((peer) => peer.offset >= low.value && peer.offset <= high.value)
        .toList();
  }
  return [];
}

({double value, int found}) _intersectionEdge(
  Iterable<_Edge> edges,
  int needed, {
  required int sign,
}) {
  var chime = 0;
  var found = 0;
  for (final edge in edges) {
    chime += sign * edge.type;
    if (chime >= needed) return (value: edge.value, found: found);
    if (edge.type == 0) found++;
  }
  return (
    value: sign < 0 ? double.infinity : double.negativeInfinity,
    found: found,
  );
}

List<PeerEstimate> clusterSurvivors(List<PeerEstimate> peers) {
  final survivors = [...peers]..sort((a, b) => a.merit.compareTo(b.merit));
  while (survivors.length > _minimumClusterSurvivors) {
    // Σ(x − a)² = Σ(x − μ)² + n(a − μ)², so the peer farthest from the mean
    // has the worst selection jitter. Offsets are taken relative to the first
    // survivor to keep microsecond spreads exact around large offsets.
    final count = survivors.length;
    final pivot = survivors.first.offset;
    final mean =
        survivors.fold(0.0, (sum, peer) => sum + (peer.offset - pivot)) / count;
    var spread = 0.0;
    var worst = 0;
    var worstDeviation = -1.0;
    for (final (index, peer) in survivors.indexed) {
      final deviation = peer.offset - pivot - mean;
      final squared = deviation * deviation;
      spread += squared;
      if (squared <= worstDeviation) continue;
      worst = index;
      worstDeviation = squared;
    }
    final worstJitter = math.sqrt(
      (spread + count * worstDeviation) / (count - 1),
    );
    final bestPeerJitter = survivors
        .map((peer) => peer.jitter)
        .reduce(math.min);
    if (worstJitter < bestPeerJitter) break;
    survivors.removeAt(worst);
  }
  return survivors;
}

double combineOffsets(List<PeerEstimate> survivors) {
  final sum = survivors.fold<(double, double)>(
    (0, 0),
    (sum, peer) => (
      sum.$1 + peer.offset / peer.rootDistance,
      sum.$2 + 1 / peer.rootDistance,
    ),
  );
  return sum.$1 / sum.$2;
}

NtpEstimate? estimateSystem(Iterable<List<NtpPacket>> responses, double now) {
  final peers =
      responses
          .map((samples) => PeerEstimate.fromSamples(samples, now))
          .toList();
  final survivors = clusterSurvivors(selectTruechimers(peers));
  if (survivors.isEmpty) return null;
  return NtpEstimate(
    offset: combineOffsets(survivors),
    leap: survivors.first.leap,
    rootDistance: survivors.first.rootDistance,
  );
}
