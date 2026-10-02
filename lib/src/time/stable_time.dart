import 'dart:math' as math;

import '../models.dart';
import 'local_clock.dart';

const double _minimumFrequencyInterval = 1024;
const double _maximumFrequency = 500e-6;
const double _frequencyGain = 0.25;

/// Internal state used to extrapolate synchronized time between NTP samples.
class StableTime {
  StableTime._({
    required this.uptime,
    required this.timestamp,
    required this.offset,
    required this.bootIdentifier,
    required this.frequency,
    required this.referenceUptime,
    required this.referenceTime,
    required this.leapTime,
    required this.leapStep,
    required this.rootDistance,
  });

  factory StableTime.synchronized({
    required double offset,
    LeapIndicator leap = LeapIndicator.noWarning,
    double rootDistance = 0,
    StableTime? previous,
    ClockSource source = ClockSource.process,
  }) {
    final (:uptime, :timestamp) = source.sample();
    final time = offset + timestamp;
    final discipline = _discipline(previous, uptime, time);
    final (leapTime, leapStep) = _leapSchedule(leap, time);
    return StableTime._(
      uptime: uptime,
      timestamp: timestamp,
      offset: offset,
      bootIdentifier: source.bootIdentifier(),
      frequency: discipline.frequency,
      referenceUptime: discipline.referenceUptime,
      referenceTime: discipline.referenceTime,
      leapTime: leapTime,
      leapStep: leapStep,
      rootDistance: rootDistance,
    );
  }

  static ({double frequency, double referenceUptime, double referenceTime})
  _discipline(StableTime? previous, double uptime, double time) {
    if (previous == null) {
      return (frequency: 0, referenceUptime: uptime, referenceTime: time);
    }
    final elapsed = uptime - previous.referenceUptime;
    if (elapsed < _minimumFrequencyInterval) {
      return (
        frequency: previous.frequency,
        referenceUptime: previous.referenceUptime,
        referenceTime: previous.referenceTime,
      );
    }
    final predicted =
        previous.referenceTime + elapsed * (1 + previous.frequency);
    final error = (time - predicted) / elapsed;
    final frequency =
        error.abs() < _maximumFrequency
            ? (previous.frequency + _frequencyGain * error)
                .clamp(-_maximumFrequency, _maximumFrequency)
                .toDouble()
            : previous.frequency;
    return (frequency: frequency, referenceUptime: uptime, referenceTime: time);
  }

  static (double, double) _leapSchedule(LeapIndicator leap, double time) =>
      switch (leap) {
        LeapIndicator.sixtyOneSeconds => (startOfNextMonth(time), -1),
        LeapIndicator.fiftyNineSeconds => (startOfNextMonth(time), 1),
        _ => (0, 0),
      };

  factory StableTime.fromMap(
    Map<String, Object?> map, {
    ClockSource source = ClockSource.process,
  }) {
    double? read(String key) => _storedDouble(map[key]);
    final uptime = read('Uptime');
    final timestamp = read('Timestamp');
    final offset = read('Offset');
    final storedBootIdentifier = map['BootIdentifier'];
    if (uptime == null ||
        timestamp == null ||
        offset == null ||
        storedBootIdentifier is! String ||
        uptime > source.monotonicTime() ||
        storedBootIdentifier != source.bootIdentifier()) {
      throw const FormatException(
        'Stored Kronos time is not valid for this boot.',
      );
    }
    return StableTime._(
      uptime: uptime,
      timestamp: timestamp,
      offset: offset,
      bootIdentifier: storedBootIdentifier,
      frequency: read('Frequency') ?? 0,
      referenceUptime: read('ReferenceUptime') ?? uptime,
      referenceTime: read('ReferenceTime') ?? offset + timestamp,
      leapTime: read('LeapTime') ?? 0,
      leapStep: read('LeapStep') ?? 0,
      rootDistance: read('RootDistance') ?? 0,
    );
  }

  final double uptime;
  final double timestamp;
  final double offset;
  final String bootIdentifier;
  final double frequency;
  final double referenceUptime;
  final double referenceTime;
  final double leapTime;
  final double leapStep;
  final double rootDistance;

  double adjustedTimestamp({required double atUptime}) {
    final time = offset + timestamp + (atUptime - uptime) * (1 + frequency);
    final stepAt = leapStep > 0 ? leapTime - 1 : leapTime;
    return leapStep != 0 && time >= stepAt ? time + leapStep : time;
  }

  double uncertainty({required double atUptime}) =>
      rootDistance + frequencyTolerance * math.max(0.0, atUptime - uptime);

  bool isSynchronized({required double atUptime}) =>
      uncertainty(atUptime: atUptime) <= maximumDistance;

  AnnotatedTime? annotated({required double atUptime}) {
    if (!isSynchronized(atUptime: atUptime)) return null;
    return AnnotatedTime(
      date: utcFromSeconds(adjustedTimestamp(atUptime: atUptime)),
      timeSinceLastNtpSync: atUptime - uptime,
      uncertainty: uncertainty(atUptime: atUptime),
    );
  }

  Map<String, Object?> toMap() => {
    'Uptime': uptime,
    'Timestamp': timestamp,
    'Offset': offset,
    'BootIdentifier': bootIdentifier,
    'Frequency': frequency,
    'ReferenceUptime': referenceUptime,
    'ReferenceTime': referenceTime,
    'LeapTime': leapTime,
    'LeapStep': leapStep,
    'RootDistance': rootDistance,
  };
}

double? _storedDouble(Object? value) => value is num ? value.toDouble() : null;

double startOfNextMonth(double time) {
  final date = DateTime.fromMillisecondsSinceEpoch(
    (time * 1000).round(),
    isUtc: true,
  );
  final year = date.month == 12 ? date.year + 1 : date.year;
  final month = date.month == 12 ? 1 : date.month + 1;
  return DateTime.utc(year, month).millisecondsSinceEpoch / 1000;
}
