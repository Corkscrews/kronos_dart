import 'dart:isolate';

import '../models.dart';
import '../storage.dart';
import '../time/local_clock.dart' as local_clock;
import '../time/local_clock.dart' show ClockCalibration;
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

  /// Reads the kernel clocks instead of `DateTime.now()` and `Stopwatch`:
  /// `CLOCK_MONOTONIC_RAW` and `kern.bootsessionuuid` on iOS and macOS,
  /// `CLOCK_BOOTTIME` and the kernel `boot_id` on Android and Linux.
  ///
  /// Call it once, before the first Kronos read. On iOS, only call it after
  /// declaring `NSPrivacyAccessedAPICategorySystemBootTime` (reason `35F9.1`)
  /// in the app's privacy manifest; Android needs no declaration. Returns false where the kernel clock is
  /// unavailable; the portable clock stays in use. Throws [StateError] once
  /// this isolate has read the clock in portable mode.
  static bool useKernelClock() => local_clock.useKernelClock();

  /// The clock calibration this isolate uses.
  static ClockCalibration get calibration => local_clock.clockCalibration;

  /// See [SynchronizedClock.share].
  static SendPort share() => instance.share();

  /// Makes [instance] a follower of the clock behind [main]; see
  /// [SynchronizedClock.follow].
  static Future<void> follow(SendPort main) async {
    instance = await SynchronizedClock.follow(main);
  }
}

typedef Clock = KronosClock;
