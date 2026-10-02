import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import '../models.dart';
import '../storage.dart';
import '../time/local_clock.dart';
import '../time/stable_time.dart';
import 'synchronized_clock.dart';

/// Main-isolate side of [SynchronizedClock.share]: sends the calibration and
/// the current anchor to every follower, then a new anchor on every change.
class ClockPublisher {
  ClockPublisher(this._anchor);

  final Map<String, Object?>? Function() _anchor;
  final Set<SendPort> _followers = {};
  RawReceivePort? _port;

  SendPort get sendPort =>
      (_port ??= RawReceivePort(_receive, 'kronos share')
            ..keepIsolateAlive = false)
          .sendPort;

  /// Followers subscribe with `[port]` and leave with `port`, which is also
  /// the response of the exit listener they register on themselves.
  void _receive(Object? message) {
    switch (message) {
      case [final SendPort follower]:
        _followers.add(follower);
        follower.send(_message());
      case final SendPort follower:
        _followers.remove(follower);
    }
  }

  void publish() {
    if (_followers.isEmpty) return;
    final message = _message();
    for (final follower in _followers) {
      follower.send(message);
    }
  }

  Map<String, Object?> _message() {
    final anchor = _anchor();
    final (:uptime, :timestamp) = processSample();
    return {
      'Calibration': clockCalibration.toMap(),
      'Anchor': anchor,
      'Uptime': uptime,
      'Timestamp': timestamp,
    };
  }
}

/// Read-only [SynchronizedClock] fed by the main isolate's clock.
///
/// It reuses the main isolate's calibration, boot identifier and anchor, so it
/// never calibrates or queries NTP. Each read is one monotonic clock read.
class FollowerClock implements SynchronizedClock {
  FollowerClock._(this._main);

  final SendPort _main;
  final RawReceivePort _port = RawReceivePort(null, 'kronos follow');
  StableTime? _state;

  static Future<SynchronizedClock> follow(SendPort main) async {
    final clock = FollowerClock._(main);
    final first = Completer<void>();
    clock._port.handler = (Object? message) {
      try {
        clock._receive(message);
        if (!first.isCompleted) first.complete();
      } on Object catch (error, stack) {
        if (first.isCompleted) rethrow;
        clock._port.close();
        first.completeError(error, stack);
      }
    };
    Isolate.current.addOnExitListener(main, response: clock._port.sendPort);
    main.send([clock._port.sendPort]);
    try {
      await first.future;
    } finally {
      clock._port.keepIsolateAlive = false;
    }
    return clock;
  }

  void _receive(Object? message) {
    if (message is! Map) return;
    adoptCalibration(
      ClockCalibration.fromMap(message['Calibration'] as Map<Object?, Object?>),
    );
    final anchor = message['Anchor'];
    _state =
        anchor is Map
            ? _restore(
              Map<String, Object?>.from(anchor),
              message['Uptime'] as double,
              message['Timestamp'] as double,
            )
            : null;
  }

  /// Kernel mode shares the monotonic clock, so the anchor is used as is. In
  /// portable mode each isolate has its own `Stopwatch`, so the anchor is
  /// moved onto this isolate's one, using the system clock as the bridge.
  StableTime? _restore(
    Map<String, Object?> anchor,
    double mainUptime,
    double mainTimestamp,
  ) {
    try {
      if (clockCalibration.mode == ClockMode.kernel) {
        return StableTime.fromMap(anchor);
      }
      final here = processSample();
      final delta = here.uptime - (mainUptime + here.timestamp - mainTimestamp);
      final now = defaultMonotonicTime();
      double shift(Object? value) =>
          math.min(now, (value as num).toDouble() + delta);
      return StableTime.fromMap({
        ...anchor,
        'Uptime': shift(anchor['Uptime']),
        'ReferenceUptime': shift(anchor['ReferenceUptime']),
      });
    } on FormatException {
      return null;
    }
  }

  @override
  double? get timestamp =>
      _state?.adjustedTimestamp(atUptime: defaultMonotonicTime());
  @override
  AnnotatedTime? get annotatedNow =>
      _state?.annotated(atUptime: defaultMonotonicTime());
  @override
  DateTime? get now => annotatedNow?.date;

  @override
  ClockSource get source => ClockSource.process;
  @override
  set source(ClockSource value) => throw UnsupportedError(_readOnly);
  @override
  TimeStorage get storage => throw UnsupportedError(_readOnly);
  @override
  set storage(TimeStorage value) => throw UnsupportedError(_readOnly);

  @override
  Future<SyncResult> sync({
    NtpConfiguration configuration = NtpConfiguration.standard,
  }) => Future.error(StateError(_readOnly));

  @override
  Stream<SyncSample> syncing({
    NtpConfiguration configuration = NtpConfiguration.standard,
  }) => Stream.error(StateError(_readOnly));

  @override
  SendPort share() => throw UnsupportedError(_readOnly);

  /// Stops following. The clock then reports no time.
  @override
  void reset() {
    _main.send(_port.sendPort);
    _port.close();
    _state = null;
  }
}

const _readOnly =
    'A follower clock is read-only; the main isolate syncs and owns state.';
