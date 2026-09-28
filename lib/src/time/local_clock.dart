import 'dart:math' as math;

const double frequencyTolerance = 15e-6;
const double maximumDistance = 1.5;
const int _microsPerSecond = 1000000;

final Stopwatch _monotonicWatch = Stopwatch()..start();

double secondsFromMicros(int micros) => micros / _microsPerSecond;
Duration durationFromSeconds(double seconds) =>
    Duration(microseconds: (seconds * _microsPerSecond).round());
DateTime utcFromSeconds(double seconds) => DateTime.fromMicrosecondsSinceEpoch(
  (seconds * _microsPerSecond).round(),
  isUtc: true,
);

/// Current wall-clock time in seconds since the Unix epoch.
double currentTime() =>
    secondsFromMicros(DateTime.now().microsecondsSinceEpoch);
double defaultMonotonicTime() =>
    secondsFromMicros(_monotonicWatch.elapsedMicroseconds);

final int localPrecision = _measureLocalPrecision();
final double precisionFloor = math.pow(2, localPrecision).toDouble();

int _measureLocalPrecision() {
  var tick = 1.0;
  for (var sample = 0; sample < 32; sample++) {
    final start = currentTime();
    var next = start;
    for (var attempt = 0; attempt < 100000 && next == start; attempt++) {
      next = currentTime();
    }
    if (next > start) tick = math.min(tick, next - start);
  }
  return (math.log(tick) / math.ln2).floor().clamp(-32, 0).toInt();
}

final String _processBootId =
    'process:${DateTime.now().microsecondsSinceEpoch}:${_monotonicWatch.elapsedMicroseconds}';
String processBootIdentifier() => _processBootId;

class ClockSource {
  const ClockSource({
    this.monotonicTime = defaultMonotonicTime,
    this.bootIdentifier = processBootIdentifier,
  });

  static const process = ClockSource();
  final double Function() monotonicTime;
  final String Function() bootIdentifier;

  ClockSource copyWith({
    double Function()? monotonicTime,
    String Function()? bootIdentifier,
  }) => ClockSource(
    monotonicTime: monotonicTime ?? this.monotonicTime,
    bootIdentifier: bootIdentifier ?? this.bootIdentifier,
  );
}
