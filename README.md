# Kronos Dart

Kronos Dart is an NTP client library with sub-second precision and a stable
clock extrapolated from a monotonic timer.

## Install

```yaml
dependencies:
  kronos_dart: 0.0.1
```

## Synchronize

```dart
import 'package:kronos_dart/kronos_dart.dart';

Future<void> synchronize() async {
  final result = await KronosClock.sync(
    configuration: const NtpConfiguration(
      pools: [
        NtpPool('time.apple.com', samples: 4),
        NtpPool('pool.ntp.org', samples: 2),
      ],
    ),
  );

  print('date=${result.date}, offset=${result.offset}');
  print('clock=${KronosClock.now}');
}
```

Each `NtpPool` sets how many samples are taken from every server it resolves
to; `samples` defaults to 4. A host listed more than once keeps the first
entry's count, and a server shared by two pools is sampled once.

`KronosClock.syncing()` yields each valid estimate as samples arrive. The clock
continues polling every 1024 seconds after a completed synchronization until
`KronosClock.reset()` is called. `now` becomes `null` when the estimated error
bound grows beyond 1.5 seconds. Ending stream iteration early stops delivering
samples; the synchronization pass continues to update the clock.

Hosts that need a separate clock can create `SynchronizedClock`. Its `query`,
`storage`, `source`, and `pollInterval` constructor arguments allow each clock
to use its own NTP query, state backend, clock source, and polling interval.
`KronosClock` is the static facade over a default instance.

```dart
final clock = SynchronizedClock(
  source: ClockSource(
    monotonicTime: systemUptime,
    bootIdentifier: systemBootId,
  ),
  storage: TimeStorage(backend: myBackend),
);
final result = await clock.sync();
```

For direct NTP queries, `NtpClient` accepts an injected `NtpTransport`, DNS
resolver, and kiss-o'-death registry. The defaults use UDP, system DNS, and a
process-wide registry.

## Authenticated NTP

For servers configured with an RFC 5905 symmetric key, provide the same key in
the configuration:

```dart
final configuration = NtpConfiguration(
  pools: const [NtpPool('ntp.example.com')],
  key: NtpKey(id: 7, secret: [/* key bytes */], algorithm: NtpMacAlgorithm.sha1),
);
```

MD5 and SHA-1 NTP MACs are supported. Public NTP pools do not share a key and
should use the default unauthenticated configuration.

## Precision on iOS and Android

By default Kronos reads `DateTime.now()` and a `Stopwatch`. That needs no
privacy-manifest entry, resolves to 1 µs, follows system clock changes, and
cannot restore state across launches.

On iOS and macOS the app can opt in to the kernel clocks instead
(`CLOCK_MONOTONIC_RAW` and `kern.bootsessionuuid`). That gives a monotonic
clock that keeps counting during sleep, ignores system clock changes, and is
shared by every isolate and process on the same boot. Apple lists boot-time
reads as a "required reason" API, so first declare it in
`ios/Runner/PrivacyInfo.xcprivacy`:

```xml
<key>NSPrivacyAccessedAPITypes</key>
<array>
  <dict>
    <key>NSPrivacyAccessedAPIType</key>
    <string>NSPrivacyAccessedAPICategorySystemBootTime</string>
    <key>NSPrivacyAccessedAPITypeReasons</key>
    <array><string>35F9.1</string></array>
  </dict>
</array>
```

Then, before the first Kronos read:

```dart
KronosClock.useKernelClock(); // false where unsupported; the default clock stays
```

Without the declaration, leave it out: Kronos keeps the portable clock.

On Android (and Linux) the same call reads `CLOCK_BOOTTIME` and the kernel
`boot_id`, and needs no manifest change. It is the only mode that counts device
sleep there: the portable `Stopwatch` stops while the phone is suspended.
`KronosClock.calibration` reports the mode, precision and clock-pairing windows
measured at startup.

## Isolates

The main isolate is the authority: it alone queries NTP, calibrates and reads
the boot identifier. Other isolates follow it and reuse that data, so they make
no NTP or calibration calls of their own:

```dart
final port = KronosClock.share(); // main isolate
await Isolate.run(() async {
  await KronosClock.follow(port); // follower; inherits the kernel opt-in
  print(KronosClock.now);
});
```

A follower receives every update and reset. `sync()` on a follower is an
error. Call `follow` before the follower reads the clock.

## Storage and platforms

The default `TimeStorage` keeps the last stable timestamp in memory. A storage
adapter can be supplied for durable or shared storage. Restoring a timestamp
across process launches requires a platform monotonic-time source and boot ID;
set `KronosClock.monotonicTimeProvider` and
`KronosClock.bootIdentifierProvider` alongside a durable adapter when the host
platform provides them. `TimeStoragePolicy.appGroup` only selects an in-memory
namespace with the default backend; it does not access an Apple App Group.
`SynchronizedClock` passes its `ClockSource` to storage when restoring state,
so a shared `TimeStorage` is never reconfigured by the clock.

The NTP transport and DNS resolver use `universal_io`. On the Dart VM that
delegates to `dart:io`. In a browser those sockets are unavailable, so NTP
queries do not run there. `RawDatagramSocket` does not
expose the kernel receive timestamp control data used by the Darwin Swift
implementation, so the destination timestamp is taken when Dart receives the
datagram event; event-loop scheduling can add a small amount of receive-side
jitter.
