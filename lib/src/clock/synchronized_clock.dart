import 'dart:async';

import '../models.dart';
import '../ntp/client.dart';
import '../ntp/kiss_of_death.dart';
import '../storage.dart';
import '../time/local_clock.dart';
import '../time/stable_time.dart';

typedef NtpQuery = Stream<NtpProgress> Function(NtpConfiguration configuration);

/// A stable clock that can be read and synchronized.
///
/// Implement this to supply a fake in tests. [SynchronizedClock.new] builds the
/// NTP-backed clock.
abstract interface class SynchronizedClock {
  factory SynchronizedClock({
    NtpQuery? query,
    TimeStorage? storage,
    ClockSource source,
    Duration pollInterval,
  }) = _NtpSynchronizedClock;

  TimeStorage get storage;
  set storage(TimeStorage value);

  ClockSource get source;
  set source(ClockSource value);

  double? get timestamp;
  AnnotatedTime? get annotatedNow;
  DateTime? get now;

  Future<SyncResult> sync({
    NtpConfiguration configuration = NtpConfiguration.standard,
  });

  Stream<SyncSample> syncing({
    NtpConfiguration configuration = NtpConfiguration.standard,
  });

  void reset();
}

/// NTP-backed [SynchronizedClock] with injectable query and clock sources.
class _NtpSynchronizedClock implements SynchronizedClock {
  _NtpSynchronizedClock({
    NtpQuery? query,
    TimeStorage? storage,
    ClockSource source = ClockSource.process,
    this.pollInterval = const Duration(seconds: 1024),
  }) : _queryOverride = query,
       _storage = storage ?? TimeStorage(),
       _source = source,
       _registry =
           identical(source, ClockSource.process)
               ? KissOfDeathRegistry.shared
               : KissOfDeathRegistry(monotonicTime: source.monotonicTime);

  final NtpQuery? _queryOverride;
  final Duration pollInterval;
  TimeStorage _storage;
  ClockSource _source;
  KissOfDeathRegistry _registry;
  StableTime? _state;
  bool _loaded = false;
  Timer? _pollTimer;
  final Set<_SyncPass> _activePasses = {};

  NtpQuery get query => _queryOverride ?? _defaultQuery;
  @override
  TimeStorage get storage => _storage;
  @override
  set storage(TimeStorage value) => _reconfigure(() => _storage = value);
  @override
  ClockSource get source => _source;
  @override
  set source(ClockSource value) => _reconfigure(() {
    _source = value;
    _registry =
        identical(value, ClockSource.process)
            ? KissOfDeathRegistry.shared
            : KissOfDeathRegistry(monotonicTime: value.monotonicTime);
  });

  @override
  double? get timestamp =>
      _current?.adjustedTimestamp(atUptime: _source.monotonicTime());
  @override
  AnnotatedTime? get annotatedNow =>
      _current?.annotated(atUptime: _source.monotonicTime());
  @override
  DateTime? get now => annotatedNow?.date;

  @override
  Future<SyncResult> sync({
    NtpConfiguration configuration = NtpConfiguration.standard,
  }) async {
    SyncSample? last;
    await for (final sample in syncing(configuration: configuration)) {
      last = sample;
    }
    return SyncResult(date: last?.date, offset: last?.offset);
  }

  @override
  Stream<SyncSample> syncing({
    NtpConfiguration configuration = NtpConfiguration.standard,
  }) {
    final controller = StreamController<SyncSample>();
    _SyncPass? pass;
    controller.onListen = () {
      pass = _beginPass(configuration, controller);
    };
    controller.onCancel = () {
      pass?.sink = null;
    };
    return controller.stream;
  }

  @override
  void reset() {
    _stop();
    _state = null;
    _loaded = true;
  }

  void _reconfigure(void Function() change) {
    _stop();
    change();
    _state = null;
    _loaded = false;
  }

  StableTime? get _current {
    if (!_loaded) {
      _state = _storage.restore(_source);
      _loaded = true;
    }
    return _state;
  }

  Stream<NtpProgress> _defaultQuery(NtpConfiguration configuration) =>
      NtpClient(
        registry: _registry,
      ).query(pools: configuration.pools, key: configuration.key);

  _SyncPass _beginPass(
    NtpConfiguration configuration,
    StreamController<SyncSample>? sink,
  ) {
    final previous = _current;
    _cancelPoll();
    final pass = _SyncPass(StreamIterator(query(configuration)), sink);
    _activePasses.add(pass);
    unawaited(_consumePass(pass, configuration, previous));
    return pass;
  }

  Future<void> _consumePass(
    _SyncPass pass,
    NtpConfiguration configuration,
    StableTime? previous,
  ) async {
    try {
      while (await pass.updates.moveNext()) {
        if (pass.stopped) return;
        _apply(pass, pass.updates.current, previous);
        if (pass.updates.current.isComplete) _schedulePoll(configuration);
      }
    } catch (_) {
      // A failed pass leaves the previous synchronized time available.
    } finally {
      _activePasses.remove(pass);
      await pass.close();
    }
  }

  void _apply(_SyncPass pass, NtpProgress update, StableTime? previous) {
    final estimate = update.estimate;
    if (estimate == null) return;
    final freeze = StableTime.synchronized(
      offset: estimate.offset,
      leap: estimate.leap,
      rootDistance: estimate.rootDistance,
      previous: previous,
      source: _source,
    );
    _state = freeze;
    _storage.stableTime = freeze;
    final annotated = freeze.annotated(atUptime: _source.monotonicTime());
    if (annotated == null) return;
    pass.emit(
      SyncSample(
        date: annotated.date,
        offset: estimate.offset,
        completed: update.completed,
        total: update.total,
        measurements: update.measurements,
      ),
    );
  }

  void _schedulePoll(NtpConfiguration configuration) {
    _cancelPoll();
    _pollTimer = Timer(pollInterval, () => _beginPass(configuration, null));
  }

  void _cancelPoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _stop() {
    _cancelPoll();
    final active = _activePasses.toList();
    _activePasses.clear();
    for (final pass in active) {
      pass.stopped = true;
      unawaited(pass.close());
    }
  }
}

class _SyncPass {
  _SyncPass(this.updates, this.sink);

  final StreamIterator<NtpProgress> updates;
  StreamController<SyncSample>? sink;
  bool stopped = false;
  bool _closed = false;

  void emit(SyncSample sample) {
    final target = sink;
    if (!stopped && target != null && !target.isClosed) target.add(sample);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final target = sink;
    sink = null;
    if (target != null && !target.isClosed) unawaited(target.close());
    await updates.cancel();
  }
}
