import 'time/local_clock.dart';
import 'time/stable_time.dart';

/// Selects a logical storage namespace for synchronized clock state.
class TimeStoragePolicy {
  const TimeStoragePolicy() : groupId = null;
  const TimeStoragePolicy.appGroup(String groupId) : groupId = groupId;

  static const standard = TimeStoragePolicy();

  final String? groupId;

  String get namespace => groupId == null ? 'standard' : 'group:$groupId';
}

/// Storage adapter for the serialized stable-clock state.
abstract interface class TimeStorageBackend {
  Map<String, Object?>? read(String key);
  void write(String key, Map<String, Object?> value);
  void remove(String key);
}

/// Simple process-local backend used when the host app does not provide storage.
class MemoryTimeStorageBackend implements TimeStorageBackend {
  final Map<String, Map<String, Object?>> _values = {};

  @override
  Map<String, Object?>? read(String key) {
    final value = _values[key];
    return value == null ? null : Map<String, Object?>.of(value);
  }

  @override
  void write(String key, Map<String, Object?> value) {
    _values[key] = Map<String, Object?>.of(value);
  }

  @override
  void remove(String key) => _values.remove(key);
}

final Map<String, MemoryTimeStorageBackend> _defaultBackends = {};

/// Reads and saves synchronized clock state.
class TimeStorage {
  TimeStorage({
    TimeStoragePolicy policy = TimeStoragePolicy.standard,
    TimeStorageBackend? backend,
    this.source = ClockSource.process,
  }) : _backend = backend ?? _defaultBackend(policy);

  static const String _key = 'KronosStableTime';
  final TimeStorageBackend _backend;
  final ClockSource source;

  StableTime? get stableTime => restore(source);

  StableTime? restore(ClockSource source) {
    final stored = _backend.read(_key);
    if (stored == null) return null;
    try {
      return StableTime.fromMap(stored, source: source);
    } on FormatException {
      return null;
    }
  }

  set stableTime(StableTime? value) {
    if (value == null) {
      clear();
      return;
    }
    _backend.write(_key, value.toMap());
  }

  void clear() => _backend.remove(_key);
}

MemoryTimeStorageBackend _defaultBackend(TimeStoragePolicy policy) =>
    _defaultBackends.putIfAbsent(
      policy.namespace,
      MemoryTimeStorageBackend.new,
    );
