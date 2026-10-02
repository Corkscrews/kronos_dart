# Kronos: native high-precision clock on Android

Scope: [kernel_clock_ffi.dart](../../lib/src/time/kernel_clock_ffi.dart) and the platform gate on
the kernel clock. Goal: give Android the same kernel mode that iOS has, so
`KronosClock.useKernelClock()` works on both platforms with one call.

This doc builds on [ios-native-clock.md](ios-native-clock.md). The timescale `L(m) = m + C`,
calibration, the authority/follower isolate model and the portable fallback are platform
independent and already implemented. This doc only covers what differs on Android: the
bindings, the clock choice, the boot ID and what the platform allows.

**Status:** phases 1–2 are implemented (`kernel_clock_ffi.dart`; the kernel tests now run wherever
`kernelClockSupported` is true). Phase 0 (a release-mode run on Android devices) and phase 3 are
still open, and the tests have not yet run on a Linux host.

## 1. Decision

1. **Read the kernel clocks via `dart:ffi` straight from bionic (`DynamicLibrary.open('libc.so')`).**
   Ship no Kotlin, Java, C, Gradle changes or plugin, and keep it a pure Dart package.
   `libc.so` is on the NDK's public library list, so any app can open it. Bionic has no
   `clock_gettime_nsec_np`, so the binding is `clock_gettime` plus one `struct timespec` buffer
   per isolate (§4.1).
2. **Use `CLOCK_BOOTTIME` as the monotonic source.** It is what
   `SystemClock.elapsedRealtimeNanos()` and `AlarmManager` use. It keeps counting during suspend
   and Doze, is never stepped, and is the same clock in every isolate and process. Linux has no
   clock that both counts suspend and is immune to frequency slewing, so this is the only correct
   choice (§3).
3. **Use `/proc/sys/kernel/random/boot_id` as the boot identifier.** It is a random UUID that
   the kernel regenerates on each boot. Read it with `dart:io`; no FFI is needed. If SELinux or
   the vendor blocks it, fall back to today's per-process ID, which rejects restores safely
   ([local_clock.dart:231](../../lib/src/time/local_clock.dart#L231) already does this).
4. **Keep everything else from the iOS design unchanged.** `L(m) = m + C`, the edge-detected
   calibration, `ClockCalibration`, `share`/`follow` and the portable rebase need no Android
   changes.
5. **Kernel mode stays opt-in through `useKernelClock()`,** as on iOS, so one call in the host
   covers both platforms. Android needs **no declaration** for it (§7). Whether Android should
   default to the kernel clock is an open question (§9, phase 3), because the portable clock is
   worse on Android than on iOS (§2).
6. **Linux comes along for free.** The bindings, clock IDs and boot ID path are the same; only the
   library differs (`DynamicLibrary.process()` on glibc). That lets a Linux host run the kernel
   path in `dart test` (§10).

## 2. What is wrong today on Android

The portable clock has the problems listed in the iOS doc, §2. Android adds two of its own:

| Code | Problem |
|---|---|
| `useKernelClock()` → `kernelClockSupported` ([kernel_clock_ffi.dart:10](../../lib/src/time/kernel_clock_ffi.dart#L10)) | False on Android, so the opt-in does nothing and the app always gets the portable clock. |
| `_monotonicWatch` `Stopwatch` ([local_clock.dart:14](../../lib/src/time/local_clock.dart#L14)) | The Dart VM on Android reads `CLOCK_MONOTONIC`, which **stops during suspend**. After the phone sleeps, `now` lags real time by the length of the sleep, and the reported uncertainty doesn't grow to cover it. The error is silent. Phase 0 confirms this. |
| Process death | Android kills background processes routinely. Every cold start loses the anchor and needs fresh NTP passes, which adds traffic to public servers ([public_ntp_polling.md](../known_issues/public_ntp_polling.md)). A boot-scoped anchor in durable storage would avoid that. |

## 3. Expected facts

Nothing in this section has been measured yet. It comes from the Linux `clock_gettime(2)` man
page and kernel sources. Phase 0 replaces it with device numbers, as §3 of the iOS doc did for
Darwin.

| Clock (Linux ID) | Counts suspend | Stepped | Slewed | Notes |
|---|---|---|---|---|
| `CLOCK_REALTIME` (0) | n/a | Yes | Yes | Full nanosecond resolution, unlike Darwin's 1 µs. Stepped by NITZ, network time sync and the user. |
| `CLOCK_MONOTONIC` (1) | **No** | No | Yes | What `Stopwatch` uses. Ruled out. |
| `CLOCK_MONOTONIC_RAW` (4) | **No** | No | No | The Darwin choice does not count sleep on Linux. Ruled out. |
| `CLOCK_BOOTTIME` (7) | Yes | No | Yes | `CLOCK_MONOTONIC` plus time in suspend. **Chosen.** |

- **Resolution.** `clock_getres` reports 1 ns for all four, but the real tick is the ARM generic
  timer, usually 19.2 MHz (52 ns) on Qualcomm and 24–26 MHz on others. `_kernelTickNanoseconds`
  ([local_clock.dart:273](../../lib/src/time/local_clock.dart#L273)) measures the step size
  directly, so it reports the true tick whatever `clock_getres` says.
- **Read cost.** On kernels 5.3 and later (every GKI kernel, Android 11+ launches), arm64 serves
  `CLOCK_BOOTTIME` from the vDSO, at about the cost of a Darwin read. Older arm64 kernels (4.14,
  4.19) serve only `REALTIME`, `MONOTONIC` and `MONOTONIC_RAW` from the vDSO, so `BOOTTIME`
  becomes a real syscall, expected to cost a few hundred ns. That widens the calibration window
  and raises the measured tick, but the result stays correct and the precision stays honest.
- **Slewing.** `CLOCK_BOOTTIME` follows `adjtimex` frequency corrections. Stock Android sets the
  wall clock by stepping (`SystemClock.setCurrentTimeMillis`) and doesn't run an `adjtimex`
  discipline, so the rate should be the raw oscillator. Phase 0 checks this by comparing the
  `BOOTTIME` and `MONOTONIC_RAW` rates while the device is awake: they should agree within a few
  ppm. A device that slews faster than `frequencyTolerance` (15 ppm) would break the uncertainty
  bound and needs a note in the README.
- **Wall pairing.** Because `CLOCK_REALTIME` isn't quantized on Linux, the iOS edge detection
  (§3.1 of the iOS doc) fires on the first read and brackets two reads instead of one. That is
  still correct, only about twice as wide as needed. `C` cancels out of the synchronized time
  anyway, so leave `_edge` ([local_clock.dart:193](../../lib/src/time/local_clock.dart#L193))
  as it is.

## 4. Design

### 4.1 FFI bindings (Android and Linux)

```dart
// sketch — lives next to the Darwin bindings in kernel_clock_ffi.dart
final class _Timespec extends Struct {
  @Long() external int seconds;     // 64-bit on arm64/x86_64, 32-bit on armv7
  @Long() external int nanoseconds;
}

final _libc = Platform.isAndroid ? DynamicLibrary.open('libc.so') : DynamicLibrary.process();
final _clockGettime = _libc.lookupFunction<
    Int32 Function(Int32, Pointer<_Timespec>),
    int Function(int, Pointer<_Timespec>)>('clock_gettime', isLeaf: true);

// ponytail: one 16-byte buffer per isolate, never freed; attach a NativeFinalizer if
// apps spawn isolates by the million.
final Pointer<_Timespec> _buffer = _malloc(sizeOf<_Timespec>()).cast();

int _read(int clock) {
  _clockGettime(clock, _buffer);
  final t = _buffer.ref;
  return t.seconds * 1000000000 + t.nanoseconds;
}

const _realtime = 0, _boottime = 7; // <linux/time.h>
```

- **One file, chosen at runtime.** A conditional import can't tell Android from iOS, so
  `kernel_clock_ffi.dart` picks its bindings with `Platform`. The lookups are lazy top-level
  finals, so iOS never resolves `clock_gettime` against bionic and Android never resolves
  `clock_gettime_nsec_np`.
- **Gate:** `kernelClockSupported = Platform.isIOS || Platform.isMacOS || Platform.isAndroid ||
  Platform.isLinux`.
- **`malloc`** is looked up from the same library, as the Darwin code already does for `sysctl`,
  so there is no `package:ffi` dependency.
- **armv7 (32-bit).** `@Long()` follows the ABI, so the struct is correct on every Flutter
  Android target. On armv7 bionic, `time_t` is 32-bit, so the `CLOCK_REALTIME` seconds overflow
  in 2038. Only calibration reads the wall clock, and `CLOCK_BOOTTIME` won't come near that range.
- **Boot ID:**

  ```dart
  String? kernelBootIdentifier() {
    try {
      final id = File('/proc/sys/kernel/random/boot_id').readAsStringSync().trim();
      return id.isEmpty ? null : id;
    } on Object {
      return null;
    }
  }
  ```

  The Darwin `sysctlbyname` path stays as it is for iOS and macOS.

### 4.2 What does not change

- `L(m) = m + C`, the public offset correction (`systemClockCorrection`) and "`C` is never
  refreshed" (iOS doc, §4.2).
- The precision formula (iOS doc, §4.3). With a 52 ns tick, the 238 ns double ULP still sets the
  limit, so kernel mode reports −22, the same as on iOS. On a syscall-path kernel the measured tick
  can exceed 238 ns, and the precision drops to −21 or −20 by itself.
- `ClockMode`, `ClockCalibration`, `share`/`follow` and the portable rebase (iOS doc, §5–6).
  Only the doc comments that say "Darwin" need updating
  ([local_clock.dart:31](../../lib/src/time/local_clock.dart#L31), `kernelWallNanoseconds`).

### 4.3 Mode selection

| | Portable (default) | Kernel (opt-in) |
|---|---|---|
| Wall / `currentTime()` | `DateTime.now()` | `L(m) = m + C` |
| Monotonic | Per-isolate `Stopwatch` (`CLOCK_MONOTONIC`, stops in suspend) | `CLOCK_BOOTTIME` |
| Boot ID | Per process | `/proc/sys/kernel/random/boot_id` |
| Declaration needed | None | None |

`useKernelClock()` keeps its contract: call it once before the first Kronos read, `StateError`
after, and `false` where unsupported.

## 5. Isolates and processes

The iOS doc's §6 applies unchanged. `CLOCK_BOOTTIME` and `boot_id` are kernel-wide, so an anchor
from any isolate is valid in every other isolate.

Android adds one case iOS doesn't have. Components declared with `android:process` (a separate
service process, for example) run their own Dart VM, and process death plus cold start is routine.
Both read the same `CLOCK_BOOTTIME` and `boot_id`, so an anchor written to a durable
`TimeStorageBackend` (for example `SharedPreferences`) stays valid across them for the whole boot.
`StableTime.fromMap` already rejects one from another boot. The durable backend itself is out of
scope here, as it is on iOS.

## 6. Error budget

| Term | Portable (default) | Kernel (opt-in) |
|---|---|---|
| Local clock resolution | 1 µs | 238 ns (the true tick after iOS phase 4) |
| Wall-clock step during an exchange or between syncs | Corrupts T1/T4 or the extrapolation | Immune |
| Device suspend / Doze between syncs | **Not counted. `now` lags silently by the sleep time.** | Counted |
| uptime/timestamp pairing in `StableTime` | ±100 ns (edge detection) | 0 (same counter) |
| Anchor reuse across isolates | Rebased, ±2 µs | Exact |
| Anchor restore across launches and processes | Rejected | Valid on the same boot |
| T4 receive timestamp, network asymmetry | Unchanged | Unchanged |

## 7. Platform and Play Store

- **Only public NDK symbols are used:** `clock_gettime` and `malloc` from `libc.so`. App seccomp
  filters allow `clock_gettime`.
- **Nothing to declare.** Android has no equivalent of Apple's required-reason APIs.
  `SystemClock.elapsedRealtime` and `CLOCK_BOOTTIME` are unrestricted.
- **`boot_id` is shared by every app on the device during one boot.** Like
  `kern.bootsessionuuid`, compare it only locally, and never log it, send it or use it as an
  identifier. Google Play's User Data policy restricts using device-wide values to link users
  across apps. Android 10 and later block most such values for apps, so `boot_id` may be blocked by
  SELinux on some builds (phase 0). The fallback is safe.
- **README.** Rename "Precision on iOS" to "Precision on iOS and Android" and add one paragraph:
  on Android, `useKernelClock()` needs no manifest change, and it is the only mode that counts
  device sleep.

## 8. Why not a platform channel

`SystemClock.elapsedRealtimeNanos()` and `Settings.Global.BOOT_COUNT` would give the same
clock and a boot counter that is readable without SELinux questions. But a method channel costs
tens of µs per call, so it can't serve the per-`now` monotonic read, and it would turn
`kronos_dart` into a Flutter plugin. The FFI read is the same kernel clock at a fraction of that
cost. Revisit `BOOT_COUNT` only if phase 0 finds `boot_id` blocked on a large share of devices.

## 9. Phases

Each phase is one reviewable diff that leaves `make test` green.

0. **Device spike, throwaway and not committed.** Run the iOS doc's §3 probes in `example/` with
   `flutter run --release` on two arm64 phones: one on a 4.14/4.19 kernel and one on GKI 5.10 or
   later. Confirm:
   - `libc.so` opens and `clock_gettime` resolves.
   - The tick, the read cost and the edge-window percentiles for `CLOCK_BOOTTIME`.
   - `boot_id` is readable by an app on Android 10, 13 and 15.
   - `CLOCK_BOOTTIME` advances across a 10-minute screen lock with forced Doze
     (`adb shell dumpsys deviceidle force-idle`), and `Stopwatch` does not. Compare both deltas
     with the wall clock's.
   - `BOOTTIME` and `MONOTONIC_RAW` agree in rate within 15 ppm over 10 minutes awake.
1. **Android and Linux bindings behind the existing `useKernelClock()`.** Change
   `kernel_clock_ffi.dart`, the platform gate, the "Darwin" doc comments and the README.
   Phases 2 and 3 of the iOS doc already cover everything above the bindings.
2. **Tests on a Linux host** (§10).
3. **Open question: default to kernel mode on Android.** It needs no declaration, and the
   portable clock miscounts sleep. The cost is a behavior change for existing Android users:
   `currentTime()` stops following wall-clock steps. Decide after phase 0.

## 10. Verification

- **Run the existing Darwin-only kernel tests on Linux too.** Widen the `_darwin` skip in
  [local_clock_test.dart](../../test/local_clock_test.dart) and
  [shared_clock_test.dart](../../test/shared_clock_test.dart) to "kernel clock supported". Linux
  shares the clock IDs and the boot ID path, so `dart test` on a Linux host covers the new bindings
  except for the `libc.so` name.
- **Add one Android-specific check to the phase 0 probe**, not to the suite. `dart test` doesn't
  run on a device, and the probes that matter (suspend, SELinux, the old-kernel syscall path) need
  real hardware anyway.
- **The whole existing suite passes without opting in,** as on iOS.
- **Long-running drift check,** as on iOS, with at least one forced Doze cycle between syncs.
