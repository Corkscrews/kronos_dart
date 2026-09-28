import '../models.dart';
import '../storage.dart';
import 'synchronized_clock.dart';

/// Static compatibility API backed by one synchronized clock.
abstract final class KronosClock {
  /// Process-wide clock. Tests replace this with a [SynchronizedClock] fake.
  static SynchronizedClock instance = SynchronizedClock();

  static TimeStorage get storage => instance.storage;
  static set storage(TimeStorage value) => instance.storage = value;

  static double Function() get monotonicTimeProvider =>
      instance.source.monotonicTime;
  static set monotonicTimeProvider(double Function() value) =>
      instance.source = instance.source.copyWith(monotonicTime: value);

  static String Function() get bootIdentifierProvider =>
      instance.source.bootIdentifier;
  static set bootIdentifierProvider(String Function() value) =>
      instance.source = instance.source.copyWith(bootIdentifier: value);

  static double? get timestamp => instance.timestamp;
  static DateTime? get now => instance.now;
  static AnnotatedTime? get annotatedNow => instance.annotatedNow;

  static Future<SyncResult> sync({
    NtpConfiguration configuration = NtpConfiguration.standard,
  }) => instance.sync(configuration: configuration);

  static Stream<SyncSample> syncing({
    NtpConfiguration configuration = NtpConfiguration.standard,
  }) => instance.syncing(configuration: configuration);

  static void reset() => instance.reset();
}

typedef Clock = KronosClock;
