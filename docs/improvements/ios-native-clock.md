# Kronos: native high-precision clock on iOS

Scope: `lib/src/time/local_clock.dart` and the callers that read it. Goal: replace the Dart-level
clock reads with kernel clocks on iOS, keep the synchronized state in memory, and make that state
usable from every isolate.

**Status:** phases 1–3 are implemented (`kernel_clock_ffi.dart`, `local_clock.dart`,
`shared_clock.dart`). Phase 0 (a release-mode run on an iPhone) and phase 4 are still open.

## 1. Decision

1. **Read the kernel clocks via `dart:ffi` straight from libSystem (`DynamicLibrary.process()`).**
   Ship no Swift, Objective-C, C, podspec or plugin, and keep it a pure Dart package. Leaf FFI calls
   measure as tight as C (§3).
2. **Use `CLOCK_MONOTONIC_RAW` as the monotonic source.** It is `mach_continuous_time`. It ticks
   every 41.67 ns, keeps counting during sleep, is never slewed or stepped, and is the same clock
   in every isolate and process.
3. **Use `kern.bootsessionuuid` as the boot identifier.** With (2), a stored anchor stays valid
   across isolates, processes and app launches, so the README caveat about needing a platform
   monotonic source and boot ID goes away for apps that opt in (6).
4. **Put NTP and stable-clock math on one timescale derived from the monotonic clock,**
   `L(m) = m + C`, where `C` is computed once by the main isolate and handed to every other
   isolate. The system wall clock is read only to compute `C` and to report the offset against it.
5. **Share state between isolates by message passing.** The main isolate is the authority: it
   runs NTP, calibrates and reads the boot ID. The other isolates follow read-only and compute
   `now` locally. There is no shared memory and no locks.
6. **(2)–(4) are opt-in.** They read time since boot, which Apple puts under the "System boot time"
   privacy-manifest category. A host that hasn't declared that reason gets the **portable clock**:
   today's `DateTime.now()` and `Stopwatch`, with the improvements in §4.4. The library never
   requires the declaration (§8).

## 2. What is wrong today

[local_clock.dart](../../lib/src/time/local_clock.dart):

| Code | Problem |
|---|---|
| `currentTime()` → `DateTime.now()` (line 18) | 1 µs resolution. It is the wall clock, so it jumps when the user or `timed` sets the clock, including between the T1 and T4 of an NTP exchange. |
| `_monotonicWatch` `Stopwatch` (line 7) | Its epoch is when the isolate first touches it, so readings from two isolates or two launches can't be compared. The Dart API doesn't document whether it counts device sleep. |
| `_processBootId` (line 39) | Changes per isolate and per launch, so every restore across isolates or launches is rejected. That is safe, but it means state can never be shared. |
| `_measureLocalPrecision` (line 26) | Measures the 1 µs `DateTime.now` tick, which gives precision −20. |
| `StableTime.synchronized` ([stable_time.dart:32-33](../../lib/src/time/stable_time.dart#L32-L33)) | Reads uptime and wall time in two separate calls, so the pair has an unbounded, unmeasured gap. |
| Epoch seconds stored as `double` | At today's epoch (~1.79e9 s) one ULP is 2⁻²² s = **238 ns**. That floor applies whatever the clock source. |

## 3. Measured facts

These numbers come from macOS 15 (Darwin 24.6) on Apple Silicon, which uses the same XNU kernel,
libc and 24 MHz timebase as iOS. `dart compile exe` (AOT, like iOS release builds) used leaf FFI
calls. Section 9, phase 0 repeats the run on a device.

| Clock | `clock_getres` | Smallest observed step | Notes |
|---|---:|---:|---|
| `CLOCK_REALTIME` | 1000 ns | 1000 ns | Every value is a multiple of 1 µs. **A native read does not raise wall-clock resolution over `DateTime.now()`.** |
| `CLOCK_MONOTONIC` | 1000 ns | 1000 ns | Also 1 µs, so it is ruled out. |
| `CLOCK_MONOTONIC_RAW` | 42 ns | 41 ns | Equals `mach_continuous_time × 125/3` (checked). Counts sleep. |
| `CLOCK_UPTIME_RAW` | 42 ns | 41 ns | `mach_absolute_time`. **Stops during sleep**, so it's wrong for extrapolation. |

| Measurement (200k samples) | min | p50 | p99 | p99.99 | max |
|---|---:|---:|---:|---:|---:|
| C: `M1, W, M2` window | 0 | 41 | 42 | 208 | 9167 ns |
| Dart AOT leaf FFI: `M1, W, M2` window | 0 | 0 | 42 | 292 | 263916 ns |
| Dart AOT: `DateTime.now()` bracketed by mono | 0 | 41 | 42 | 167 | 6708 ns |

Takeaways:

- **Calling `DateTime.now()` costs about 41 ns, so latency isn't the problem.** Its 1 µs
  quantization is, and so is the fact that it reads a clock that can be stepped.
- FFI leaf calls are as tight as C at p99. The rare outliers, up to 264 µs, are thread preemption,
  and a native function would not prevent them. Throw them out by keeping the best of N samples.
- `mach_get_times()`, the kernel's atomic wall+mono pair, is not in the public iOS 18.4 SDK header.
  Treat it as SPI and don't use it.

### 3.1 The `M1/W/M2` window understates the error on Darwin

The draft proposed `uncertainty ≈ (M2 − M1) / 2`. On Darwin the window is 0–42 ns, but `W` is
truncated to the microsecond, so the real uncertainty of the wall↔mono pairing is about ±500 ns.
Measured over 20k snapshots, the spread of `C = W − mid(M1, M2)` between p1 and p99 was
**979 ns**.

**Edge detection** fixes it. Spin until the wall clock's microsecond changes. At that moment the
true wall time is exactly `W`, and the edge falls between the `M1` of the last old read and the
`M2` of the first new read:

```
prev = read(M1, W, M2)
loop (bounded):
  cur = read(M1, W, M2)
  if cur.W != prev.W:  mono_at_edge ∈ [prev.M1, cur.M2];  C = cur.W − mid
  prev = cur
```

Measured: C spread p1..p99 = **125 ns**, window p50 42 ns and p99 125 ns, at about **1 µs per
snapshot**. Keeping the narrowest window out of a handful of snapshots gives about ±60 ns.

## 4. Design

### 4.1 FFI bindings (Darwin only)

```dart
// sketch — symbols resolved from the process image; libSystem is always loaded
final _nsec = DynamicLibrary.process()
    .lookupFunction<Uint64 Function(Int32), int Function(int)>(
        'clock_gettime_nsec_np', isLeaf: true);
const _realtime = 0, _monotonicRaw = 4; // <_time.h>, iOS 10+
```

- Use a conditional import, `if (dart.library.ffi)`, so web builds keep compiling. That matters
  because the package uses `universal_io`.
- Gate it on `Platform.isIOS || Platform.isMacOS`. Every other platform keeps today's code until it
  gets its own doc (Android/Linux would use `CLOCK_BOOTTIME`).
- The boot ID comes from `sysctlbyname("kern.bootsessionuuid")` into a 37-byte buffer. Look up
  `malloc`/`free` from the process image the same way, so no `package:ffi` dependency is needed.
  If the call fails, fall back to today's per-process ID, which rejects restores safely.
- The `int` returned for ns since boot stays far below 2⁶³, so there is no overflow concern.

### 4.2 One timescale: `L(m) = m + C`

`C` is computed once, lazily, by the main isolate from an edge-detected snapshot (§3.1). Other
isolates receive it and never measure it themselves (§6.3).
`currentTime()` returns `L(now)` in seconds and `defaultMonotonicTime()` returns `m` in seconds.
Both come from **the same kernel counter**, which has these effects:

- NTP T1/T4 ([transport.dart:67](../../lib/src/ntp/transport.dart#L67),
  [:103](../../lib/src/ntp/transport.dart#L103)) and the `uptime`/`timestamp` pair in
  `StableTime.synchronized` become step-immune and consistent with each other. The pairing gap in
  §2 disappears, because `timestamp = uptime + C` exactly.
- Every caller of `currentTime()` stays unchanged: protocol, transport, client pacing and tests.
  It still returns seconds since the epoch, just from a better source.
- **`C` cancels out of the synchronized time.** `offset = NTP − L` and `timestamp = L`, so
  `offset + timestamp + Δm` doesn't depend on `C`. An error in `C` affects only the offset reported
  against the system clock.

The draft's `TimeAnchor { wallTimeNs, monotonicTimeNs, ntpOffsetNs }` reduces to the same
constant, since `UTC = M_now + (W_anchor − M_anchor + offset)`. Measuring T1/T4 on the monotonic
scale removes the wall terms entirely instead of pairing them.

Two consequences need explicit handling:

- **The public offset.** `SyncResult.offset` and `SyncSample.offset`
  ([synchronized_clock.dart:196](../../lib/src/clock/synchronized_clock.dart#L196)) promise
  "NTP − device clock". To keep that promise, report `estimate.offset + (L_now − W_now)`, with
  `W_now` taken from one wall read at report time.
- **`C` is never refreshed.** The main isolate fixes it for the life of the process. Refreshing it
  would mix two scales in a pass that's in flight, and would split the timescale between the
  main isolate and its followers. If the user steps the device clock, `L` correctly ignores the
  step, and the public offset picks it up at the next report.

### 4.3 Precision

`localPrecision = ceil(log2(max(tick, representation ULP)))`:

| Stage | Limiting term | Precision | `precisionFloor` |
|---|---|---:|---:|
| Today | `DateTime.now` 1 µs tick | −20 | 954 ns |
| Phases 1–2 (double epoch seconds) | 238 ns double ULP | −22 | 238 ns |
| Phase 4 (int ns timescale) | 41.67 ns tick | −24 | 60 ns |

Round up rather than floor so the value is never better than reality. The existing test range,
−32..0, still holds. The portable clock stays at −20.

### 4.4 Mode selection and the portable fallback

| | Portable (default) | Kernel (opt-in) |
|---|---|---|
| Wall / `currentTime()` | `DateTime.now()` | `L(m) = m + C` |
| Monotonic | Per-isolate `Stopwatch` | `CLOCK_MONOTONIC_RAW` |
| Boot ID | Per process (today) | `kern.bootsessionuuid` |
| Privacy manifest entry | None | `NSPrivacyAccessedAPICategorySystemBootTime`, reason 35F9.1 |

- **Opt-in is explicit.** The host calls `KronosClock.useKernelClock()` once, before the first
  Kronos read or sync, and only after adding the manifest entry. A call after the clock has been
  read throws `StateError`, because switching timescales mid-life would mix scales inside a pass.
  On platforms without the kernel path the call does nothing, and the clock stays portable.
- **There is no runtime detection.** The manifest is merged into the app bundle at build time and
  is checked by Apple at upload. The library can't see it reliably, and guessing wrong would either
  break the App Store submission or silently lower precision.
- **The portable fallback still improves.** `StableTime.synchronized` pairs `Stopwatch` and
  `DateTime.now()` using the edge detection from §3.1 (bracketing with `Stopwatch.elapsedTicks`),
  instead of two unrelated reads. The pairing error drops from unbounded to about ±100 ns.
  Everything else stays at today's 1 µs and keeps today's step and sleep behavior.
- **The fallback uses only public Dart APIs whose purpose is in-app elapsed time.** It must not
  read a since-boot value through another route (for example `Timeline.now`) to dodge the
  declaration. That would defeat the point of the manifest.

## 5. What lives in memory

| Data | Where | Lifetime | Shared across isolates? |
|---|---|---|---|
| `ClockCalibration`: `tickNs`, `wallResolutionNs`, `C`, edge window min/p50/p99, `localPrecision` | One immutable value in `local_clock.dart`; it replaces `_measureLocalPrecision` | Measured once by the main isolate from ~64 edge snapshots (~64 µs), and fixed for the process | **Yes.** Followers receive it from the main isolate and never calibrate (§6.3). |
| Anchor (`StableTime`) | The clock's `_state` plus the `TimeStorage` backend, which already exist | Until `reset()` or a new boot | **Yes**, via §6 |
| NTP raw samples | `NtpProgress.measurements`, which already exists | Per pass | No |

No new storage type is needed. `StableTime.toMap()` already serializes to a sendable
`Map<String, Object?>`, and `StableTime.fromMap` already rejects an anchor that comes from another
boot or from the future.

## 6. Isolates

### 6.1 Today

Every static is per isolate: `KronosClock.instance`
([kronos_clock.dart:8](../../lib/src/clock/kronos_clock.dart#L8)), `_monotonicWatch`,
`_processBootId`, `localPrecision`, `KissOfDeathRegistry.shared`
([kiss_of_death.dart:15](../../lib/src/ntp/kiss_of_death.dart#L15)) and `_defaultBackends`
([storage.dart:42](../../lib/src/storage.dart#L42)). Each isolate is unsynchronized until it runs
its own NTP passes. That multiplies traffic to public servers (see
[public_ntp_polling.md](../known_issues/public_ntp_polling.md)) and splits the Kiss-o'-Death
state. An anchor copied between isolates is rejected, because both the monotonic epoch and the boot
ID differ.

### 6.2 After §4

The monotonic clock and the boot ID are kernel facts, identical in every isolate. An anchor
produced anywhere in the process can be used everywhere. Synchronizing isolates therefore means
**copying a handful of numbers**, not synchronizing clocks.

### 6.3 The main isolate is the authority

The main isolate is the only one that makes the expensive or privileged calls. Every other isolate
reuses its results.

| Done only by the main isolate | Sent to followers |
|---|---|
| NTP queries, polling and the Kiss-o'-Death registry | The anchor (`StableTime.toMap()`) |
| Calibration: edge snapshots, `C`, tick, precision (§5) | The `ClockCalibration` values |
| Boot ID (`sysctlbyname`) | The boot ID string |
| Mode choice (`useKernelClock()`) | The mode |

- **Followers subscribe** by sending their `SendPort`. The main isolate replies with
  `{mode, calibration, bootId, anchor}`. After that it sends a new anchor on every `_apply`, and
  `null` on `reset()`. Calibration, boot ID and mode never change for the process, so they're sent
  once.
- **A follower builds its `ClockSource` from what it received.** The boot ID is the string the
  main isolate sent, and `currentTime()` uses the main isolate's `C`. The follower makes **no
  calibration, no `sysctl` and no NTP calls**. `sync()` on a follower is an error.
- **The only clock read a follower makes is one monotonic read per `now`:** a single leaf FFI call
  in kernel mode, or a `Stopwatch` read in portable mode. No current time can be produced without
  it. A follower then calls `annotated(atUptime: mono)` on its copy of the anchor, and **reads
  never send a message.**
- **In kernel mode the timescale is identical in every isolate.** The monotonic counter is shared,
  and `C` comes from one place, so `currentTime()` returns the same value everywhere.
- For **short-lived isolates** (`Isolate.run`, Flutter `compute`), pass the current map as an
  argument. No subscription is needed.
- **Discovery** stays outside the package. A Flutter app can register the main isolate's port with
  `IsolateNameServer`, and `kronos_dart` remains pure Dart.

Semantics:

- **Staleness is harmless.** Until an update arrives, a follower uses the previous anchor, which
  is still valid and reports honestly larger uncertainty (`rootDistance + 15 ppm × elapsed`).
- **When the main isolate dies,** followers keep extrapolating until the uncertainty exceeds 1.5 s, which
  takes about 27.8 h at `rootDistance` 0. After that `now` returns `null`, as it does today.
- **Cross-process (iOS extensions, widgets):** the same map in a durable App Group
  `TimeStorageBackend` becomes valid in the other process too. This is out of scope here. Note
  that `TimeStoragePolicy.appGroup` is still in-memory only.

Because the mode comes from the main isolate, a follower switches itself to the kernel clock when
the main isolate uses it. The host doesn't have to opt in again in every isolate.

### 6.4 Followers in portable mode

Without a shared monotonic clock, a follower can't use the main isolate's `uptime` as it is.
Instead, the follower **rebases on receipt** using the wall clock as a bridge. The follower takes
its boot ID from the main isolate, as in §6.3, so the restore check passes:

- The main isolate sends each anchor together with `(monoA, wallA)`, read as one edge-detected
  pair just before sending.
- The follower makes one `Stopwatch` read and one `DateTime.now()` read on receipt, giving
  `(monoB, wallB)`, and computes `Δ = monoB − (monoA + wallB − wallA)`.
- It then stores the anchor with `Uptime += Δ` and `ReferenceUptime += Δ`.

The rebase error is about ±2 µs: one edge-detected pair on the main side, and one plain 1 µs read
on the follower side. It goes wrong only if the device clock is stepped while the message is in
flight. That window is microseconds to milliseconds long, and the next update corrects it. The
main isolate keeps the original anchor, so the error never feeds back into NTP discipline.

### 6.5 Why not shared memory

A `malloc`'d anchor read through `Pointer` would need a seqlock. Stable `dart:ffi` exposes no
atomic loads or fences to build one, and someone would have to own `free`. The anchor changes
every ~1024 s, so messaging costs nothing measurable. Revisit only for a reader that can't receive
messages.

## 7. Error budget: what this fixes and what it doesn't

| Term | Today | Portable (default) | Kernel (opt-in) |
|---|---|---|---|
| Local clock resolution | 1 µs | 1 µs | 238 ns (41.67 ns after phase 4) |
| Wall-clock step during an exchange or between syncs | Corrupts T1/T4 or the extrapolation | Same as today | Immune |
| Device sleep between syncs | Depends on undocumented `Stopwatch` behavior | Same as today | Counted (`CLOCK_MONOTONIC_RAW`) |
| uptime/timestamp pairing in `StableTime` | Unbounded and unmeasured | ±100 ns (edge detection) | 0 (same counter) |
| Anchor reuse across isolates | Rejected | Rebased, ±2 µs (§6.4) | Exact |
| Anchor restore across launches | Rejected | Rejected | Valid on the same boot |
| T4 receive timestamp (event-loop dispatch of `RawDatagramSocket`) | Unmeasured; expected µs–ms | Unchanged | **Unchanged.** This is the largest local term left. |
| Network path asymmetry | Up to delay/2 (ms on the internet) | Unchanged | Unchanged |

The native clock takes the local clock out of the error budget. It does not make internet NTP
accurate to nanoseconds. The next lever is kernel receive timestamps (`SO_TIMESTAMP` via
`recvmsg` over FFI), which the README already mentions. That belongs in a separate doc.

## 8. Platform and App Store

- Use only public symbols: `clock_gettime_nsec_np` and `sysctlbyname` on iOS 10+. Resolving them
  with `dlsym` is not private API.
- **Privacy manifest: optional, and it unlocks the kernel clock.** Apple's "System boot time
  APIs" category names `mach_absolute_time` and `systemUptime`.
  `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)` and `kern.bootsessionuuid` read the same family, so
  the library only touches them after `useKernelClock()`. A pure Dart package can't ship its own
  `PrivacyInfo.xcprivacy`, so the app declares the reason in `ios/Runner/PrivacyInfo.xcprivacy`:

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

  Reason 35F9.1 covers elapsed time between in-app events, and the derived values must not leave
  the device. Apps that skip it keep working on the portable clock, with the precision in §7.

  The README needs a short "Precision on iOS" section that says three things: the default is
  portable, how to opt in (manifest entry plus `useKernelClock()`), and what the portable clock
  loses (§7).
- **`kern.bootsessionuuid` is identical for every app on the device during one boot.** It must
  only be compared locally, and never logged, sent or used as an identifier, to stay clear of
  Apple's fingerprinting rules.

## 9. Phases

Each phase is one reviewable diff that leaves `make test` green.

0. **Device spike, throwaway and not committed.** Run the §3 probes in `example/` on a real iPhone
   in release mode. Confirm the symbol lookup, the resolutions, the window percentiles and the
   edge-detection spread. Confirm that `kern.bootsessionuuid` is readable inside the sandbox, and
   that `CLOCK_MONOTONIC_RAW` advances across a 10-minute screen lock (compare its delta with the
   wall clock's).
1. **Native monotonic clock and boot ID behind `useKernelClock()`.** Change `local_clock.dart`
   plus the one opt-in entry point on `KronosClock`. With the switch off, behavior is exactly
   today's. Gains when on: anchors that survive across isolates and launches, counting of sleep,
   and 41.67 ns uptime.
2. **Timescale `L` and calibration.** Change `currentTime()`, replace `_measureLocalPrecision`
   with `ClockCalibration`, and correct the public offset in `_apply`. In the same phase, add
   edge-detected pairing for the portable clock (§4.4). Gains: step-immune T1/T4 and timestamp at
   238 ns in kernel mode, and a bounded pairing error in portable mode. Add the README's
   "Precision on iOS" section here.
3. **Main isolate as authority, with followers** (§6.3), including the portable-mode rebase (§6.4).
4. **Deferred: an int-ns internal timescale,** which takes the floor from 238 ns to 41.67 ns.
   It's only worth doing once kernel receive timestamps exist. Until then the T4 jitter is far
   larger than 238 ns.

## 10. Verification

- **Add one test file** that runs only on a Darwin host. `dart test` on a Mac exercises the real
  native path. It should check:
  - Monotonic readings never decrease across 100k reads.
  - A reading taken in `Isolate.run` falls between two reads in the root isolate.
  - The boot ID is equal across isolates.
  - `localPrecision` is in −25..−20.
  - `currentTime()` is within 1 ms of `DateTime.now()`.
  - Calling `useKernelClock()` after the first read throws `StateError`.
- **Portable mode runs on every host,** since it's the default:
  - The whole existing suite must pass without opting in.
  - A follower rebased in `Isolate.run` reports a `now` within 100 µs of the main isolate's.
    Measured on macOS in JIT: median 0.48 µs and max 20 µs in portable mode, median 0.48 µs and
    max 1.4 µs in kernel mode.
- **Existing tests stay unchanged.** They inject fake `ClockSource`s.
- **The window and spread benchmark is a script, not a test.** It reports min, p50, p99 and max,
  and is run on a device in phase 0 and before each release.
- **Long-running drift check.** After a sync, compare `KronosClock.now` with fresh NTP passes over
  hours, including a device sleep.
