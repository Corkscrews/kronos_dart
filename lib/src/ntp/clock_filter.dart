import 'package:universal_io/io.dart';
import 'dart:math' as math;

import '../models.dart';
import '../protocol.dart';
import '../time/local_clock.dart';
import 'servers.dart';

const int _filterStages = 8;
const double _minimumDispersion = 0.005;

typedef ReceivedSample = ({InternetAddress address, NtpPacket packet});

double filterDelay(NtpPacket packet) => math.max(packet.delay, precisionFloor);
List<T> filterWindow<T>(List<T> items) =>
    items.length <= _filterStages
        ? items
        : items.sublist(items.length - _filterStages);

double rmsDistance(double from, Iterable<double> values, int count) {
  if (count < 1) return 0;
  return math.sqrt(
    values.fold(0.0, (sum, value) => sum + (value - from) * (value - from)) /
        count,
  );
}

List<NtpMeasurement> measurementsOf(List<ReceivedSample> samples) {
  final byServer = <String, List<int>>{};
  for (final (index, sample) in samples.indexed) {
    byServer.putIfAbsent(sample.address.key, () => []).add(index);
  }
  int lower(int best, int index) =>
      filterDelay(samples[index].packet) < filterDelay(samples[best].packet)
          ? index
          : best;
  final selected =
      byServer.values
          .map((indices) => filterWindow(indices).reduce(lower))
          .toSet();
  return [
    for (final (index, sample) in samples.indexed)
      NtpMeasurement(
        server: sample.address.address,
        stratum: sample.packet.stratum,
        roundTripDelay: sample.packet.delay,
        offset: sample.packet.offset,
        dispersion: sample.packet.dispersion,
        selected: selected.contains(index),
      ),
  ];
}

class PeerEstimate {
  PeerEstimate({
    required this.offset,
    required this.delay,
    required this.dispersion,
    required this.jitter,
    required this.rootDelay,
    required this.rootDispersion,
    required this.stratum,
    required this.leap,
  }) : rootDistance =
           math.max(_minimumDispersion, rootDelay + delay) / 2 +
           rootDispersion +
           dispersion +
           jitter;

  factory PeerEstimate.fromSamples(List<NtpPacket> samples, double now) {
    if (samples.isEmpty) throw StateError('Peer requires at least one sample.');
    final recent = [...filterWindow(samples)]
      ..sort((a, b) => filterDelay(a).compareTo(filterDelay(b)));
    final best = recent.first;
    var dispersion = 0.0;
    for (final (index, sample) in recent.indexed) {
      final aged =
          sample.dispersion +
          frequencyTolerance * math.max(0.0, now - sample.destinationTime);
      dispersion += aged / math.pow(2, index + 1);
    }
    final jitter = rmsDistance(
      best.offset,
      recent.skip(1).map((sample) => sample.offset),
      recent.length - 1,
    );
    return PeerEstimate(
      offset: best.offset,
      delay: filterDelay(best),
      dispersion: dispersion,
      jitter: math.max(jitter, precisionFloor),
      rootDelay: best.rootDelay,
      rootDispersion: best.rootDispersion,
      stratum: best.stratum,
      leap: best.leap,
    );
  }

  final double offset;
  final double delay;
  final double dispersion;
  final double jitter;
  final double rootDelay;
  final double rootDispersion;
  final int stratum;
  final LeapIndicator leap;
  final double rootDistance;

  double get merit => stratum * maximumDistance + rootDistance;
}
