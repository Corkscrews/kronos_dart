import 'dart:math' as math;

import 'kernel_clock_stub.dart' if (dart.library.ffi) 'kernel_clock_ffi.dart';

const double frequencyTolerance = 15e-6;
const double maximumDistance = 1.5;
const int _microsPerSecond = 1000000;
const int _nanosPerSecond = 1000000000;
const int _calibrationSnapshots = 64;
const int _kernelEdgeAttempts = 10000;
const int _portableEdgeAttempts = 2000;
const int _doubleMantissaBits = 52;

final Stopwatch _monotonicWatch = Stopwatch()..start();

double secondsFromMicros(int micros) => micros / _microsPerSecond;
Duration durationFromSeconds(double seconds) =>
    Duration(microseconds: (seconds * _microsPerSecond).round());
DateTime utcFromSeconds(double seconds) => DateTime.fromMicrosecondsSinceEpoch(
  (seconds * _microsPerSecond).round(),
  isUtc: true,
);

/// Which clocks back [currentTime] and [defaultMonotonicTime].
enum ClockMode {
  /// `DateTime.now()` and a per-isolate `Stopwatch`. Needs no declaration.
  portable,

  /// A kernel clock that counts sleep (Darwin `CLOCK_MONOTONIC_RAW`, Linux and
  /// Android `CLOCK_BOOTTIME`) and the kernel boot ID. Opt-in, because Apple
  /// lists boot-time reads as a privacy-manifest "required reason" API.
  kernel,
}

/// Process-wide clock facts, measured once by the main isolate and handed to
/// follower isolates so they never measure them again.
class ClockCalibration {
  const ClockCalibration({
    required this.mode,
    required this.bootIdentifier,
    required this.precision,
    this.offsetNanoseconds = 0,
    this.windowMinimumNanoseconds = 0,
    this.windowMedianNanoseconds = 0,
    this.windowP99Nanoseconds = 0,
  });

  factory ClockCalibration.fromMap(Map<Object?, Object?> map) {
    final mode = map['Mode'];
    final bootIdentifier = map['BootIdentifier'];
    final precision = map['Precision'];
    int read(String key) => switch (map[key]) {
      final int value => value,
      _ => 0,
    };
    if (mode is! String || bootIdentifier is! String || precision is! int) {
      throw const FormatException('Invalid clock calibration.');
    }
    return ClockCalibration(
      mode: ClockMode.values.byName(mode),
      bootIdentifier: bootIdentifier,
      precision: precision,
      offsetNanoseconds: read('OffsetNanoseconds'),
      windowMinimumNanoseconds: read('WindowMinimumNanoseconds'),
      windowMedianNanoseconds: read('WindowMedianNanoseconds'),
      windowP99Nanoseconds: read('WindowP99Nanoseconds'),
    );
  }

  final ClockMode mode;
  final String bootIdentifier;

  /// RFC 5905 precision: log2 of the local clock resolution in seconds.
  final int precision;

  /// `C` in `currentTime = monotonic + C`. Zero in portable mode.
  final int offsetNanoseconds;

  /// Width of the window that brackets one wall-clock edge, over the
  /// calibration snapshots. The pairing error is about half the minimum.
  final int windowMinimumNanoseconds;
  final int windowMedianNanoseconds;
  final int windowP99Nanoseconds;

  Map<String, Object?> toMap() => {
    'Mode': mode.name,
    'BootIdentifier': bootIdentifier,
    'Precision': precision,
    'OffsetNanoseconds': offsetNanoseconds,
    'WindowMinimumNanoseconds': windowMinimumNanoseconds,
    'WindowMedianNanoseconds': windowMedianNanoseconds,
    'WindowP99Nanoseconds': windowP99Nanoseconds,
  };
}

bool _kernelRequested = false;
ClockCalibration? _calibration;

/// The calibration in use. The first read fixes the mode for this isolate.
ClockCalibration get clockCalibration =>
    _calibration ??=
        _kernelRequested ? _calibrateKernel() : _calibratePortable();

/// Switches this isolate to the kernel clock. Returns false where the kernel
/// clock is unavailable, leaving the portable clock in place.
bool useKernelClock() {
  if (!kernelClockSupported) return false;
  final current = _calibration;
  if (current != null && current.mode != ClockMode.kernel) {
    throw StateError(
      'useKernelClock() must be called before the first clock read.',
    );
  }
  _kernelRequested = true;
  return true;
}

/// Uses the main isolate's calibration instead of measuring one here.
void adoptCalibration(ClockCalibration calibration) {
  final current = _calibration;
  if (current != null && current.mode != calibration.mode) {
    throw StateError(
      'This isolate already reads the ${current.mode.name} clock. Follow the '
      'main isolate before reading the clock.',
    );
  }
  _calibration = calibration;
}

bool get _isKernel => clockCalibration.mode == ClockMode.kernel;

/// Current time in seconds since the Unix epoch.
///
/// In kernel mode this is `kernel monotonic + C`, which ignores system clock
/// steps; [systemClockCorrection] relates it back to the system clock.
double currentTime() {
  final calibration = clockCalibration;
  return calibration.mode == ClockMode.kernel
      ? (kernelMonotonicNanoseconds() + calibration.offsetNanoseconds) /
          _nanosPerSecond
      : _systemSeconds();
}

double defaultMonotonicTime() =>
    _isKernel
        ? kernelMonotonicNanoseconds() / _nanosPerSecond
        : _monotonicWatch.elapsedTicks / _monotonicWatch.frequency;

String processBootIdentifier() => clockCalibration.bootIdentifier;

int get localPrecision => clockCalibration.precision;
double get precisionFloor => math.pow(2, localPrecision).toDouble();

/// Seconds to add to an offset measured against [currentTime] so that it is
/// relative to the system clock instead.
double systemClockCorrection() =>
    _isKernel ? currentTime() - _systemSeconds() : 0;

typedef ClockSample = ({double uptime, double timestamp});

/// [defaultMonotonicTime] and [currentTime] for one instant.
ClockSample processSample() {
  final calibration = clockCalibration;
  if (calibration.mode == ClockMode.kernel) {
    final monotonic = kernelMonotonicNanoseconds();
    return (
      uptime: monotonic / _nanosPerSecond,
      timestamp: (monotonic + calibration.offsetNanoseconds) / _nanosPerSecond,
    );
  }
  final watch = _monotonicWatch;
  final edge = _edge(
    () => watch.elapsedTicks,
    () => DateTime.now().microsecondsSinceEpoch,
    _portableEdgeAttempts,
  );
  if (edge == null) {
    return (uptime: defaultMonotonicTime(), timestamp: _systemSeconds());
  }
  return (
    uptime: edge.middle / watch.frequency,
    timestamp: secondsFromMicros(edge.wall),
  );
}

double _systemSeconds() =>
    secondsFromMicros(DateTime.now().microsecondsSinceEpoch);

typedef _Edge = ({int middle, int window, int wall});

/// Spins until [wall] ticks over. At that instant the true wall time equals the
/// new value, and it lies between the monotonic reads around the last old and
/// first new wall reads.
_Edge? _edge(int Function() monotonic, int Function() wall, int attempts) {
  var previousStart = monotonic();
  var previousWall = wall();
  for (var attempt = 0; attempt < attempts; attempt++) {
    final start = monotonic();
    final value = wall();
    final end = monotonic();
    if (value != previousWall) {
      final window = end - previousStart;
      return (middle: previousStart + window ~/ 2, window: window, wall: value);
    }
    previousStart = start;
    previousWall = value;
  }
  return null;
}

List<_Edge> _edges(int Function() monotonic, int Function() wall, int tries) {
  final edges = <_Edge>[
    for (var i = 0; i < _calibrationSnapshots; i++)
      if (_edge(monotonic, wall, tries) case final edge?) edge,
  ];
  return edges..sort((a, b) => a.window.compareTo(b.window));
}

ClockCalibration _calibrateKernel() {
  final edges = _edges(
    kernelMonotonicNanoseconds,
    kernelWallNanoseconds,
    _kernelEdgeAttempts,
  );
  final monotonic = kernelMonotonicNanoseconds();
  final best =
      edges.isEmpty
          ? (middle: monotonic, window: 0, wall: kernelWallNanoseconds())
          : edges.first;
  return ClockCalibration(
    mode: ClockMode.kernel,
    bootIdentifier: kernelBootIdentifier() ?? _newProcessBootIdentifier(),
    precision: _kernelPrecision(best.wall / _nanosPerSecond),
    offsetNanoseconds: best.wall - best.middle,
    windowMinimumNanoseconds: _windowAt(edges, 0),
    windowMedianNanoseconds: _windowAt(edges, 50),
    windowP99Nanoseconds: _windowAt(edges, 99),
  );
}

ClockCalibration _calibratePortable() {
  final watch = _monotonicWatch;
  final nanosPerTick = _nanosPerSecond / watch.frequency;
  final edges = _edges(
    () => watch.elapsedTicks,
    () => DateTime.now().microsecondsSinceEpoch,
    _portableEdgeAttempts,
  );
  int windowAt(int percentile) =>
      (_windowAt(edges, percentile) * nanosPerTick).round();
  return ClockCalibration(
    mode: ClockMode.portable,
    bootIdentifier: _newProcessBootIdentifier(),
    precision: _measurePortablePrecision(),
    windowMinimumNanoseconds: windowAt(0),
    windowMedianNanoseconds: windowAt(50),
    windowP99Nanoseconds: windowAt(99),
  );
}

int _windowAt(List<_Edge> sorted, int percentile) =>
    sorted.isEmpty ? 0 : sorted[(sorted.length - 1) * percentile ~/ 100].window;

/// Rounds up, so the precision is never better than the coarser of the
/// monotonic tick and the ULP of epoch seconds stored as a double.
int _kernelPrecision(double epochSeconds) {
  final ulpExponent =
      (math.log(epochSeconds) / math.ln2).floor() - _doubleMantissaBits;
  final tick = _kernelTickNanoseconds() / _nanosPerSecond;
  if (tick <= math.pow(2, ulpExponent)) return ulpExponent;
  return (math.log(tick) / math.ln2).ceil();
}

int _kernelTickNanoseconds() {
  var tick = 1000;
  var previous = kernelMonotonicNanoseconds();
  for (var i = 0; i < 10000; i++) {
    final next = kernelMonotonicNanoseconds();
    if (next > previous) tick = math.min(tick, next - previous);
    previous = next;
  }
  return tick;
}

int _measurePortablePrecision() {
  var tick = 1.0;
  for (var sample = 0; sample < 32; sample++) {
    final start = _systemSeconds();
    var next = start;
    for (var attempt = 0; attempt < 100000 && next == start; attempt++) {
      next = _systemSeconds();
    }
    if (next > start) tick = math.min(tick, next - start);
  }
  return (math.log(tick) / math.ln2).floor().clamp(-32, 0).toInt();
}

String _newProcessBootIdentifier() =>
    'process:${DateTime.now().microsecondsSinceEpoch}:${_monotonicWatch.elapsedMicroseconds}';

class ClockSource {
  const ClockSource({
    this.monotonicTime = defaultMonotonicTime,
    this.bootIdentifier = processBootIdentifier,
  });

  static const process = ClockSource();
  final double Function() monotonicTime;
  final String Function() bootIdentifier;

  /// Whether both clocks are this process's own, so state can be shared
  /// with other isolates.
  bool get isProcess =>
      monotonicTime == defaultMonotonicTime &&
      bootIdentifier == processBootIdentifier;

  /// Monotonic time and [currentTime] for one instant. The process clocks are
  /// paired by edge detection; injected clocks are read one after the other.
  ClockSample sample() =>
      monotonicTime == defaultMonotonicTime
          ? processSample()
          : (uptime: monotonicTime(), timestamp: currentTime());

  ClockSource copyWith({
    double Function()? monotonicTime,
    String Function()? bootIdentifier,
  }) => ClockSource(
    monotonicTime: monotonicTime ?? this.monotonicTime,
    bootIdentifier: bootIdentifier ?? this.bootIdentifier,
  );
}
