# Kronos: SOLID and de-duplication plan

Scope: `packages/kronos/lib/src/`. Goal: split the code by responsibility, turn hidden globals into
injected dependencies, and remove the duplication, while every existing test assertion stays
unchanged. The package is unpublished (`publish_to: none`) and only `example/` uses it, so internal
APIs can change. What `kronos_dart.dart` exports cannot break, and neither can the static
`KronosClock`/`Clock` API that the README and example use.

## 1. Rules for the refactor

- **Tests are the spec.** No `expect(...)` in `test/` changes. Call sites in tests may change only
  where a phase below lists the edit (section 9 has the full table).
- **One phase, one reviewable diff.** Each phase leaves every test green and changes no behaviour
  unless it says so. Section 8 lists the behaviour changes that are allowed.
- **Characterise before moving.** When a phase adds a seam (transport, query function), first
  extract the current code as it is, add offline tests against the seam, then restructure.
- **Style target.** 100 columns, 5–20 lines per function, 50–150 lines per class, 100–300 lines per
  file, at most 2 indentation levels inside a function body, guard clauses, and expression bodies
  for trivial members. Exceptions: plain field-mapping code (`NtpPacket.fromBytes`,
  `StableTime.toMap`) may be longer.
- **Not gratuitous.** Add an interface only where a test needs a fake (the transport and the NTP
  query). Prefer a function type to a one-method interface. Keep a constant private next to its only
  user.
- **Running tests.** Run only the files each phase lists. `scripts/unit_test.sh` drives the Flutter
  app at the repo root, and kronos is a plain Dart package (`package:test`), so agree on the runner
  with the developer before the first run. Fakes added by this plan must be finite (see §7).

## 2. Current state

| File | Lines | Longest function | Deepest nesting in a body |
|---|---:|---|---:|
| `client.dart` | 627 | `_sample` 89, `_runQuery` 86, `_select` 43, `PeerEstimate.fromSamples` 37 | 5 |
| `clock.dart` | 227 | `_consumePass` 49 | 4 |
| `protocol.dart` | 266 | `fromBytes` 30 (field mapping) | 2 |
| `time.dart` | 214 | `StableTime.synchronized` 53 | 3 |
| `models.dart` | 125 | — | 1 |
| `storage.dart` | 91 | — | 1 |

### 2.1 Responsibility problems (SRP)

- `client.dart` holds five jobs: DNS lookup, UDP transport, the query loop and progress accounting,
  the RFC 5905 filter/select/cluster/combine math, and the kiss-o'-death registry. A 30-line
  `NtpClientTestHarness` exists only to reach its private statics.
- `NtpClient._sample` does ten things in one body: the KoD pre-check, socket bind, cancellation
  bookkeeping, encoding, datagram matching, the timeout, MAC verification, parsing, KoD recording and
  reply validation. None of the reply interpretation can be tested without a live server.
- `time.dart` mixes local-clock primitives (`currentTime`, precision, monotonic, boot ID) with the
  `StableTime` discipline model.
- `TimeStorage` persists state and also carries mutable clock-source providers that
  `KronosClock` pushes into it through `configureClockSources`. That is temporal coupling, and it
  mutates an object the caller passed in.

### 2.2 Hidden globals (DIP)

- `_KissOfDeathRegistry` is static mutable state. Tests reset it through the harness. It reads
  `defaultMonotonicTime()` directly and ignores `KronosClock.monotonicTimeProvider`.
- `KronosClock` is entirely static. It creates `NtpClient()` inline and owns timers, so
  `clock_test.dart` can only run against `time.apple.com`.
- `NtpClient` hard-codes `RawDatagramSocket` and `NtpDnsResolver.resolve`, so 4 of its 6 behaviour
  tests need the network.

### 2.3 Duplication inventory

| Pattern | Copies | Fix |
|---|---:|---|
| Seconds ↔ µs conversion (`* 1000000`, `/ 1000000`) | 7 | `durationFromSeconds`, `utcFromSeconds`, `secondsFromMicros` |
| `math.pow(2, localPrecision)` (two of them inside a comparison loop) | 4 | `final double precisionFloor` |
| "Last `filterStages` samples, lowest `max(delay, floor)` wins" (`_measurements` and `PeerEstimate.fromSamples`) | 2 | `filterWindow` + `filterDelay` |
| RMS jitter `sqrt(Σ(x − ref)² / (n − 1))` (`fromSamples` and `_cluster`) | 2 | `rmsDistance` |
| Low/high intersection scans in `_select` | 2 | `_intersectionEdge(edges, needed, sign:)` |
| `const NtpSampleResult(packet: null, blocked: …)` | 8 | `NtpSampleResult.noReply` / `.blockedServer` |
| `if (!response.isCompleted) response.complete((null, double.infinity))` | 3 | removed by the transport rewrite |
| Setter body: stop passes, set, `configureClockSources`, `_loaded = false`, `_stableTime = null` | 3 | `_reconfigure(change)` |
| `_pollTimer?.cancel(); _pollTimer = null;` | 3 | `_cancelPoll()` |
| "close controller if not closed" | 2 | `_SyncPass.close()` |
| `monotonicTime:` + `bootIdentifier:` parameter pair | 7 in lib, 12 in tests | `ClockSource` value |
| Uncertainty formula (`annotated` and `uncertainty`) | 2 | `annotated` calls `uncertainty` |
| Leap branches (`synchronized`, `adjustedTimestamp`) | 2 + 2 | `_leapSchedule` switch expression, one threshold |
| `_storedDouble(map['…'])` | 9 | local `read(key)` |
| Completed-count bump for a blocked server (before the sample and after it) | 2 | one `session.record(finished: remaining)` |
| Defaults `port 123`, `version 4`, `timeout 6` (`query`, `sample`, `_sample`) | 3 | one `NtpRequestOptions` |
| `samples = 4` (`NtpConfiguration` and `_defaultSamples`) | 2 | `NtpConfiguration.defaultSamples` |
| Magic `48` (header length) | 3 | `_headerLength` |
| `4 + key.digestLength` (MAC length) | 2 | `NtpKey.macLength` |
| Server-mode check (`kissCode`, `isValidResponse`) | 2 | `_fromServer` getter |
| BigInt 64-bit helpers `_readUint64` / `_writeUint64` | 2 lib + 1 test | `ByteData.getInt64` / `setInt64` |
| 16.16 interval helpers (4 functions) | 4 | `getInt32 / 65536`, `getUint32 / 65536` |
| `math.max(0, x)` followed by `.toDouble()` | 5 | `math.max(0.0, x)` |

### 2.4 Dead or redundant code

- `StableTime.stableTimestamp` has no callers. `StableTime.timeSinceLastNtpSync(fn)` is used only
  by `uncertainty`.
- `NtpPacket.stratumLevel` just aliases `stratum`.
- `NtpClient._resolve` wraps `NtpDnsResolver.resolve` and adds nothing.
- `NtpDnsResolver`'s `const` constructor exists, but every member is static.
- `if (recent.isEmpty) continue;` in `_measurements` can never be true.
- `PeerEstimate.fromSamples` throws on an empty list only after it has sorted that list.
- The `blockedBeforeSample` check in `runServer` repeats the one at the top of `_sample`. Both are
  kept, because the first one avoids a 2 s spacing wait, but they share one accounting path.
- `KronosClock._generation` repeats what a per-pass `stopped` flag would say. The poll timer is
  already cancelled on stop.

## 3. Target layout

```
lib/kronos_dart.dart               exports: same public names, plus SynchronizedClock
lib/src/
  models.dart                      public value types                                     ~110
  protocol.dart                    NtpMode, KissCode, NtpParsingException, NtpPacket, MAC ~200
  storage.dart                     policy, backend, memory backend, TimeStorage            ~80
  time/local_clock.dart            currentTime, monotonic, precision(+floor), boot ID,
                                   frequencyTolerance, maximumDistance, ClockSource,
                                   seconds helpers                                          ~80
  time/stable_time.dart            StableTime: discipline, leap, uncertainty, map          ~150
  ntp/servers.dart                 NtpDnsResolver, InternetAddress.key, selectServers        ~50
  ntp/kiss_of_death.dart           KissOfDeathRegistry (instance, injectable clock)          ~50
  ntp/clock_filter.dart            filterWindow, filterDelay, rmsDistance, PeerEstimate,
                                   ReceivedSample, measurementsOf                           ~110
  ntp/selection.dart               NtpEstimate, selectTruechimers, clusterSurvivors,
                                   combineOffsets, estimateSystem                           ~110
  ntp/transport.dart               NtpTransport, UdpNtpTransport, NtpReply, Cancellation    ~100
  ntp/client.dart                  NtpClient, NtpProgress, NtpSampleResult,
                                   NtpRequestOptions, _QuerySession                         ~200
  clock/synchronized_clock.dart    SynchronizedClock engine, _SyncPass                      ~180
  clock/kronos_clock.dart          static facade over one SynchronizedClock, Clock typedef   ~60
```

No `constants.dart`. Only `frequencyTolerance`, `maximumDistance`, `localPrecision` and
`precisionFloor` are shared across files, and they describe the local clock, so they live in
`local_clock.dart`. Every other tunable (`filterStages`, `_minimumDispersion`,
`_minimumClusterSurvivors`, `_minimumRateHold`, `_minimumSampleSpacing`, the frequency-discipline
constants, `_pollInterval`) becomes private next to its only user. `filterStages` stops being
public.

## 4. Phases

Each phase lists what changes, which principle it serves, the tests that guard it, and the edits
to tests. Commit each numbered step on its own.

### Phase 0: tooling baseline (no code changes)

1. Raise `environment.sdk` to `^3.7.0` (the pinned toolchain is Flutter 3.38.3 / Dart 3.10).
   Raise `lints` to the current major.
2. In `analysis_options.yaml`:
   ```yaml
   include: package:lints/recommended.yaml
   formatter:
     page_width: 100
   linter:
     rules: [prefer_final_locals, unnecessary_lambdas, avoid_positional_boolean_parameters,
             prefer_expression_function_bodies, unnecessary_breaks]
   ```
3. Run `dart format` on `lib/` and `test/`, and change `library kronos_dart;` to `library;`. Commit
   the formatting on its own so later diffs show only logic.

Guard: every offline test file (`ntp_packet_test`, `time_storage_test`, `ntp_client_test`).

### Phase 1: shared primitives and `protocol.dart`

**1a. `time/local_clock.dart`** (moved out of `time.dart`, which keeps `StableTime` until Phase 5):

```dart
const _microsPerSecond = 1000000;

double currentTime() => secondsFromMicros(DateTime.now().microsecondsSinceEpoch);
double defaultMonotonicTime() => secondsFromMicros(_monotonicWatch.elapsedMicroseconds);
double secondsFromMicros(int micros) => micros / _microsPerSecond;
Duration durationFromSeconds(double seconds) =>
    Duration(microseconds: (seconds * _microsPerSecond).round());
DateTime utcFromSeconds(double seconds) =>
    DateTime.fromMicrosecondsSinceEpoch((seconds * _microsPerSecond).round(), isUtc: true);

final int localPrecision = _measureLocalPrecision();
final double precisionFloor = math.pow(2, localPrecision).toDouble();
```

Replace all 7 conversions and all 4 `math.pow(2, localPrecision)` calls.

**1b. Collapse the protocol helpers.** kronos targets only `dart:io` (see the README), so it never
needs the web-safe `BigInt`.

- Keep NTP timestamps as a raw 64-bit `int` bit pattern: `data.getInt64(24)`, `setInt64`, and
  `timestamp >>> 32` for the seconds half. This deletes `_readUint64`, `_writeUint64` and every
  `BigInt.from`. Use `get/setInt64`, not the `Uint64` variants: the value is a bit pattern that is
  only compared for equality, so the signed accessors have no range ambiguity.
- Endian arguments: `ByteData` defaults to big-endian, so remove all 11 `Endian.big` arguments.
- Intervals: `rootDelay: data.getInt32(4) / 65536` and `rootDispersion: data.getUint32(8) / 65536`
  replace `_signedIntervalFromNtp` and `_intervalFromNtp`, because `(v >> 16) + (v & 0xffff) /
  65536 == v / 65536`. On write, clamp `rootDelay` into `setInt32` and keep the `& 0xffffffff`
  wrap for `setUint32`. Four helpers are deleted.
- Add `const _headerLength = 48`, `int get macLength => 4 + digestLength` on `NtpKey`, and
  `bool get _fromServer => mode == NtpMode.server || mode == NtpMode.symmetricPassive`.
- `isValidResponse({int? matchingTransmitTimestamp, double? now})`: inject the clock read and
  default it to `currentTime()`. This follows DIP and makes the 100 ms freshness check testable.
- Delete `stratumLevel`, and use `stratum` everywhere.

Test edits (mechanical): `test_helpers.dart` `writeUint64` becomes
`ByteData.sublistView(bytes).setInt64(offset, value)`, `originTimestamp` becomes `int?`, and
`ntp_packet_test.dart:179` `sent + BigInt.one` becomes `sent + 1`.

Guard: `ntp_packet_test.dart`. Its request-encoding test (`…dae2bc6e…`, top bit set) and its
2036-rollover test are exactly the cases where the bit-pattern change could break. Run this file
first.

### Phase 2: pull the RFC 5905 math out of `client.dart`

**2a. `ntp/clock_filter.dart`**: one clock filter, shared by measurements and peers.

```dart
const filterStages = 8;             // private to this file after Phase 7
const _minimumDispersion = 0.005;

typedef ReceivedSample = ({InternetAddress address, NtpPacket packet});

double filterDelay(NtpPacket packet) => math.max(packet.delay, precisionFloor);

List<T> filterWindow<T>(List<T> items) =>
    items.length <= filterStages ? items : items.sublist(items.length - filterStages);

/// Root-mean-square distance of [values] from [from], divided by [count] (RFC 5905 jitter).
double rmsDistance(double from, Iterable<double> values, int count) => count < 1
    ? 0
    : math.sqrt(values.fold(0.0, (sum, v) => sum + (v - from) * (v - from)) / count);

List<NtpMeasurement> measurementsOf(List<ReceivedSample> samples) {
  final byServer = <String, List<int>>{};
  for (final (index, sample) in samples.indexed) {
    byServer.putIfAbsent(sample.address.key, () => []).add(index);
  }
  int lower(int best, int i) =>
      filterDelay(samples[i].packet) < filterDelay(samples[best].packet) ? i : best;
  final selected = {for (final indices in byServer.values) filterWindow(indices).reduce(lower)};
  return [for (final (i, s) in samples.indexed) s.toMeasurement(selected: selected.contains(i))];
}
```

`PeerEstimate.fromSamples` moves its empty-list guard to the first line and uses `filterWindow`,
`filterDelay` and `rmsDistance(best.offset, window.skip(1).map(...), window.length - 1)`. In the
dispersion loop, use `math.max(0.0, …)`. Compute `rootDistance` once in the constructor
initializer instead of in a getter, because sort, select, combine and merit read it repeatedly. The
`PeerEstimate(...)` named constructor keeps its signature, since the test helper `peer()` uses it.

Keep tie-breaking the same: `measurementsOf` uses strict `<`, so the first minimum wins, and
`fromSamples` keeps `List.sort`. No test covers ties, so do not change either one here.

**2b. `ntp/selection.dart`**: plain top-level functions, no class.

```dart
typedef _Edge = ({double value, int type}); // -1 lower bound, 0 midpoint, +1 upper bound

List<PeerEstimate> selectTruechimers(List<PeerEstimate> peers) {
  final candidates = peers.where((p) => p.rootDistance < maximumDistance).toList();
  final edges = [
    for (final p in candidates) ...[
      (value: p.offset - p.rootDistance, type: -1),
      (value: p.offset, type: 0),
      (value: p.offset + p.rootDistance, type: 1),
    ],
  ]..sort((a, b) => a.value == b.value ? a.type - b.type : a.value.compareTo(b.value));
  final n = candidates.length;
  for (var allowed = 0; 2 * allowed < n; allowed++) {
    final low = _intersectionEdge(edges, n - allowed, sign: -1);
    final high = _intersectionEdge(edges.reversed, n - allowed, sign: 1);
    if (low.found + high.found > allowed || low.value >= high.value) continue;
    return candidates.where((p) => p.offset >= low.value && p.offset <= high.value).toList();
  }
  return [];
}

/// Walks [edges] until [needed] intervals overlap, counting midpoints passed on the way.
({double value, int found}) _intersectionEdge(Iterable<_Edge> edges, int needed,
    {required int sign}) {
  var chime = 0, found = 0;
  for (final edge in edges) {
    chime += sign * edge.type;
    if (chime >= needed) return (value: edge.value, found: found);
    if (edge.type == 0) found++;
  }
  return (value: sign < 0 ? double.infinity : double.negativeInfinity, found: found);
}
```

`clusterSurvivors` computes each survivor's jitter with `rmsDistance(p.offset, offsets,
survivors.length - 1)`. The peer's own zero term is included, as it is today. It picks the first
maximum with strict `>` and the best peer jitter with `reduce(math.min)`.
`combineOffsets` becomes a single `fold`. `estimateSystem(Iterable<List<NtpPacket>>, double now)`
replaces `_estimate`.

Remove the algorithm entries from `NtpClientTestHarness`. Test edits in `ntp_client_test.dart`:
the imports become `src/ntp/selection.dart` and `src/ntp/clock_filter.dart`, and the calls become
`NtpClientTestHarness.selectPeers` → `selectTruechimers`, `clusterPeers` → `clusterSurvivors`,
`combinePeers` → `combineOffsets`, and `measurements(samples)` → `measurementsOf(samples)`. The
record type the test already builds is `ReceivedSample`.

Guard: the `RFC 5905 algorithms` group in `ntp_client_test.dart` (7 tests, offline).

### Phase 3: the kiss-o'-death registry becomes an instance

```dart
class KissOfDeathRegistry {
  KissOfDeathRegistry({double Function() monotonicTime = defaultMonotonicTime})
      : _now = monotonicTime;

  /// Process-wide default, so that holds survive across queries and clock passes.
  static final shared = KissOfDeathRegistry();

  final double Function() _now;
  final _denied = <String>{};
  final _holdUntil = <String, double>{};

  void record(KissCode code, InternetAddress address, {int poll = 4}) {
    switch (code) {
      case KissCode.deny || KissCode.restricted:
        _denied.add(address.key);
      case KissCode.rateExceeded:
        final hold = math.max(_minimumRateHold, math.pow(2, poll.clamp(0, 17)).toDouble());
        _holdUntil[address.key] = _now() + hold;
      case KissCode.other:
        return;
    }
  }

  bool isBlocked(InternetAddress address) { /* unchanged logic, instance fields */ }
}
```

`String get key => '${type.name}:$address'` moves to an `extension on InternetAddress` in
`ntp/servers.dart`. Today the registry reaches into `NtpClient._addressKey`. `selectServers(pools,
perPool, registry)` moves next to it:

```dart
List<InternetAddress> selectServers(
    List<List<InternetAddress>> pools, int perPool, KissOfDeathRegistry registry) {
  final seen = <String>{};
  return [
    for (final addresses in pools)
      ...addresses.where((a) => !registry.isBlocked(a) && seen.add(a.key)).take(perPool),
  ];
}
```

`take` stops pulling after `perPool` matches, so `seen.add` runs for exactly the same addresses as
the current `break`.

`NtpClient` gets `const NtpClient({KissOfDeathRegistry? registry})` and reads
`registry ?? KissOfDeathRegistry.shared`.

Test edits: the `kiss-o-death` group builds a new registry in `setUp` (no more reset/tearDown),
uses `registry.record(...)` and `registry.isBlocked(...)`, and passes it with
`NtpClient(registry: registry)`. With that, `NtpClientTestHarness` has no members left, so delete
it.

Guard: the `kiss-o-death` group (3 tests, offline), plus `ntp_client_test.dart` as a whole.

### Phase 4: transport, cancellation, and the query session

This is the largest phase. Do it in four steps.

**4a. Extract the transport as it is today.**

```dart
typedef NtpReply = ({double sentAt, List<int> data, double receivedAt});

abstract interface class NtpTransport {
  /// Sends `encode(sentAt)` to [ip]:[port] and returns the first datagram from that endpoint, or
  /// `null` on timeout, socket error, or cancellation.
  Future<NtpReply?> exchange(InternetAddress ip, int port, Uint8List Function(double sentAt) encode,
      {required double timeout, Cancellation? cancellation});
}
```

The encoder callback keeps today's order: bind, then take `sentAt`, encode, listen, send. The
client can then rebuild the transmit timestamp as `ntpTimestampFromEpoch(reply.sentAt)`, which is
the same pure function `toBytes` applies. `UdpNtpTransport` is `_sample`'s socket half, with the
`Completer`/`Timer`/`!` code replaced:

```dart
final reply = _firstReplyFrom(socket, ip, port); // subscribes synchronously
socket.send(encode(sentAt), ip, port);
final datagram = await reply.timeout(durationFromSeconds(math.max(0.0, timeout)),
    onTimeout: () => null);
```

`_firstReplyFrom` is an `await for` over the socket with an inner
`for (var d = socket.receive(); d != null; d = socket.receive())`. A stream error or `onDone`
(socket closed on cancel) makes it return `null`. That deletes the three guarded `complete` calls.

**4b. Replace `_QueryCancellation` with a closed `Cancellation`.** Today its fields are public and
mutable, and `NtpClient` edits its `_sockets` set.

```dart
final class Cancellation {
  bool _cancelled = false;
  final _actions = <void Function()>{};
  bool get isCancelled => _cancelled;

  /// Runs [action] on cancel, or now if already cancelled. Returns an unregister callback.
  void Function() onCancel(void Function() action) { … }
  void cancel() { … }
}
```

The transport registers `socket.close` and unregisters it in `finally`. It no longer knows about a
socket set.

**4c. Separate interpretation from I/O.** `_sample` becomes a guard-clause pipeline, and the
reply logic becomes `_interpret`, a pure function testable with bytes built by `serverReply(...)`:

```dart
Future<NtpSampleResult> _sample(InternetAddress ip, NtpRequestOptions options,
    [Cancellation? cancellation]) async {
  if (_registry.isBlocked(ip)) return NtpSampleResult.blockedServer;
  final request = NtpPacket.request(version: options.version);
  final reply = await _transport.exchange(
      ip, options.port, (at) => request.toBytes(atTime: at, key: options.key),
      timeout: options.timeout, cancellation: cancellation);
  if (reply == null || (cancellation?.isCancelled ?? false)) return NtpSampleResult.noReply;
  return _interpret(reply, ip, options.key);
}

NtpSampleResult _interpret(NtpReply reply, InternetAddress ip, NtpKey? key) {
  if (key != null && !NtpPacket.isAuthentic(reply.data, key)) return NtpSampleResult.noReply;
  final packet = NtpPacket.tryParse(reply.data, destinationTime: reply.receivedAt);
  if (packet == null) return NtpSampleResult.noReply;
  final sent = ntpTimestampFromEpoch(reply.sentAt);
  final kiss = packet.originTimestamp == sent ? packet.kissCode : null;
  if (kiss != null) {
    _registry.record(kiss, ip, poll: packet.poll);
    if (_registry.isBlocked(ip)) return NtpSampleResult.blockedServer;
  }
  return packet.isValidResponse(matchingTransmitTimestamp: sent)
      ? NtpSampleResult(packet: packet, blocked: false)
      : NtpSampleResult.noReply;
}
```

`NtpSampleResult` gets `static const noReply` and `static const blockedServer`. They are static
constants, not named constructors, because a constructor named `blocked` would clash with the
field. `NtpPacket.tryParse` returns `null` on `NtpParsingException`, which narrows today's
`on Object`. The one remaining catch-all sits in the transport around bind/send, for
`SocketException` and `OSError`.

**4d. Query session.** Collect `version`, `port`, `key` and `timeout` into `NtpRequestOptions`,
whose defaults are defined once. The public `query(...)` and `sample(...)` signatures stay
unchanged, since the tests use them, and build that object. The shared mutable locals of
`_runQuery` (`packetsByServer`, `received`, `completed`, `total`) move into `_QuerySession`:

```dart
void record(InternetAddress address, NtpPacket? packet, {int finished = 1}) {
  if (packet != null) {
    _packetsByServer.putIfAbsent(address.key, () => []).add(packet);
    _received.add((address: address, packet: packet));
  }
  _completed += finished;
  if (_cancellation.isCancelled || _sink.isClosed) return;
  _sink.add(NtpProgress(
      estimate: estimateSystem(_packetsByServer.values, currentTime()),
      completed: _completed, total: _total, measurements: measurementsOf(_received)));
}
```

The per-server loop becomes a 15-line method. A server that is blocked before sampling, or that
sends a blocking KoD, calls `session.record(address, null, finished: remaining)`, which unifies the
two accounting paths. Deduplicating hosts becomes
`pools.where((p) => p.isNotEmpty).toSet()`, which keeps insertion order. The early-exit empty
update becomes `static const empty = NtpProgress(...)`. `NtpDnsResolver` becomes an
`abstract final class`, and the client takes `resolve` as a function (default
`NtpDnsResolver.resolve`, a const tear-off). The final constructor is
`const NtpClient({this.transport = const UdpNtpTransport(), this.resolve = NtpDnsResolver.resolve,
KissOfDeathRegistry? registry})`.

Keep exactly one swallow-all, at the session boundary (`_run`), with a comment. Removing it would
send stray errors to the zone as uncaught async errors.

New offline tests (added in 4a, before 4b–4d): see §7.

Guard: `ntp_client_test.dart` and the new `ntp_query_test.dart` / `udp_transport_test.dart`.
Network tests: `ntp_client_test` (4) and `dns_resolver_test`.

### Phase 5: `ClockSource`, `StableTime`, and storage

**5a. `ClockSource`** replaces the parameter pair everywhere:

```dart
class ClockSource {
  const ClockSource({
    this.monotonicTime = defaultMonotonicTime,
    this.bootIdentifier = processBootIdentifier,
  });
  static const process = ClockSource();
  final double Function() monotonicTime;
  final String Function() bootIdentifier;
  ClockSource copyWith({double Function()? monotonicTime, String Function()? bootIdentifier}) =>
      …;
}
```

**5b. `time/stable_time.dart`.** `synchronized` shrinks from 53 lines to about 12 by delegating to
two helpers:

```dart
static ({double frequency, double referenceUptime, double referenceTime}) _discipline(
    StableTime? previous, double uptime, double time) {
  if (previous == null) return (frequency: 0, referenceUptime: uptime, referenceTime: time);
  final elapsed = uptime - previous.referenceUptime;
  if (elapsed < _minimumFrequencyInterval) {
    return (frequency: previous.frequency, referenceUptime: previous.referenceUptime,
        referenceTime: previous.referenceTime);
  }
  final predicted = previous.referenceTime + elapsed * (1 + previous.frequency);
  final error = (time - predicted) / elapsed;
  final frequency = error.abs() < _maximumFrequency
      ? (previous.frequency + _frequencyGain * error).clamp(-_maximumFrequency, _maximumFrequency)
      : previous.frequency;
  return (frequency: frequency.toDouble(), referenceUptime: uptime, referenceTime: time);
}

static (double, double) _leapSchedule(LeapIndicator leap, double time) => switch (leap) {
      LeapIndicator.sixtyOneSeconds => (startOfNextMonth(time), -1),
      LeapIndicator.fiftyNineSeconds => (startOfNextMonth(time), 1),
      _ => (0, 0),
    };

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
      uncertainty: uncertainty(atUptime: atUptime));
}
```

Every time query now takes `atUptime`. Today some take `atUptime` and others take
`double Function()`. Delete `stableTimestamp` and `timeSinceLastNtpSync(fn)`. `fromMap` takes a
`ClockSource` and reads fields through a local `double? read(String key) => _storedDouble(map[key])`.
Keep the literal map keys: they are the persisted format, and the tests pin them.

Rejected: a separate `StableTimeCodec`. It would be one more class with one caller, and the tests
inspect `toMap()` directly.

**5c. `TimeStorage` stops holding mutable clock sources.**

```dart
TimeStorage({TimeStoragePolicy policy = TimeStoragePolicy.standard, TimeStorageBackend? backend,
    this.source = ClockSource.process});
final ClockSource source;

StableTime? get stableTime => restore(source);
set stableTime(StableTime? value) => value == null ? clear() : _backend.write(_key, value.toMap());
StableTime? restore(ClockSource source) { /* read, fromMap(source), FormatException → null */ }
```

Delete `configureClockSources`. The clock calls `storage.restore(itsSource)` and so never mutates a
storage object it did not create. `TimeStoragePolicy.appGroup(String this.groupId)` gets a
`namespace` getter, which replaces the string building in `_defaultBackend`.

Test edits (mechanical): `test_helpers.dart` adds `ClockSource fixedSource(double uptime,
[String boot = testBootIdentifier])`. `restoredTime` passes `source:`. `time_storage_test.dart`
changes 7 `StableTime.synchronized(... monotonicTime:, bootIdentifier:)` calls to `source:
fixedSource(uptime)` and 3 `TimeStorage(...)` calls to `source: fixedSource(5000, 'old-boot')` and
so on. `uncertainty(() => uptime)` becomes `uncertainty(atUptime: uptime)`, and the same for
`isSynchronized` (2 each). The test file drops about 25 lines.

Guard: `time_storage_test.dart` (13 tests, offline).

### Phase 6: `KronosClock` becomes a facade over an injectable engine

**6a. Extract `SynchronizedClock` as it is today** (instance fields in place of statics), and
add the fake-query tests from §7 before simplifying.

```dart
typedef NtpQuery = Stream<NtpProgress> Function(NtpConfiguration configuration);

class SynchronizedClock {
  SynchronizedClock({
    this.query = _defaultQuery,
    TimeStorage? storage,
    ClockSource source = ClockSource.process,
    this.pollInterval = const Duration(seconds: 1024),
  }) : _storage = storage ?? TimeStorage(), _source = source;

  set storage(TimeStorage value) => _reconfigure(() => _storage = value);
  set source(ClockSource value) => _reconfigure(() => _source = value);

  double? get timestamp => _current?.adjustedTimestamp(atUptime: _uptime);
  AnnotatedTime? get annotatedNow => _current?.annotated(atUptime: _uptime);
  DateTime? get now => annotatedNow?.date;

  Future<SyncResult> sync({NtpConfiguration configuration = NtpConfiguration.standard}) async {
    SyncSample? last;
    await for (final sample in syncing(configuration: configuration)) last = sample;
    return SyncResult(date: last?.date, offset: last?.offset);
  }

  void reset() { _stop(); _state = null; _loaded = true; }

  void _reconfigure(void Function() change) { _stop(); change(); _state = null; _loaded = false; }
  StableTime? get _current { … lazy _storage.restore(_source) … }
}
```

**6b. Simplify the pass lifecycle.**

- `_SyncPass` owns `updates`, the nullable `sink`, and a `stopped` flag, with `emit(sample)` and
  `close()`. `close()` closes the sink first and then cancels `updates`, the same order as
  `_stopPasses` today, which the two reset tests exercise.
- `pass.stopped` replaces `_generation`. `_stop()` marks and closes every pass and calls
  `_cancelPoll()`, the single place the poll timer is cancelled.
- `_consumePass` splits into a 10-line loop and `_apply(pass, update, previous)` (guard clauses:
  no estimate → return; not annotatable → return). `NtpProgress.isComplete` replaces the inline
  `completed == total`.

**6c. Facade.** `KronosClock` becomes an `abstract final class` over
`static SynchronizedClock _clock`. Each static member is a single delegating line, and
`monotonicTimeProvider = v` becomes `_clock.source = _clock.source.copyWith(monotonicTime: v)`.
`typedef Clock = KronosClock` stays. Export `SynchronizedClock` so hosts can inject their own
instance.

Guard: `clock_test.dart` (network), the new `synchronized_clock_test.dart` (offline), and a manual
check of `example/lib/example_model.dart`, which uses only `syncing`, `reset` and `annotatedNow`.

### Phase 7: cleanup

- Make private every constant that has a single user (see §3), and update the export list.
- README: document `SynchronizedClock` injection and `NtpClient(transport:, registry:)`, and drop
  the note that `configureClockSources` was an implicit side effect.
- Re-measure against the targets in §6.

## 5. Principle map

| Principle | Where it shows up |
|---|---|
| **S**ingle responsibility | `client.dart` split into five files; transport separated from interpretation; `StableTime` separated from local-clock primitives; storage no longer holds clock sources. |
| **O**pen/closed | New transports (TLS, an NTS test double) and new query sources plug in through `NtpTransport` and `NtpQuery` without edits to the client or the clock. |
| **L**iskov | `TimeStorage.stableTime = null` now clears storage instead of silently doing nothing, so the setter honours its nullable type. `Cancellation.onCancel` behaves the same before and after cancellation. |
| **I**nterface segregation | The test-only harness is gone. Tests import the narrow unit they check (`selection.dart`, `clock_filter.dart`, `KissOfDeathRegistry`). `NtpTransport` has one method. |
| **D**ependency inversion | The KoD registry, transport, resolver, clock source, NTP query and poll interval are all injected, with production defaults. Nothing reaches a global except through `.shared` or `.process` defaults. |

## 6. Targets after the refactor

| Metric | Now | Target |
|---|---:|---:|
| Largest file | 627 | ≤ 220 |
| Longest function (excluding field mapping) | 89 | ≤ 20 |
| Deepest nesting in a body | 5 | ≤ 2 |
| Mutable statics | 11 (`KronosClock` 8, KoD 2, backends 1) | 2 (facade `_clock`, `KissOfDeathRegistry.shared`) + backends map |
| Tests that need the network | ~10 of 51 | same ~10, tagged; new offline coverage for query, transport and clock |
| Test-only production code | `NtpClientTestHarness` (34 lines) | 0 |

## 7. New offline tests

Every fake must be finite. A fake transport returns one scripted reply per call from a fixed list
and `null` when the list runs out. A fake query yields a fixed list of `NtpProgress` values and
closes. Nothing may loop on microtasks, because that starves the test timeout. The poll test uses
a small real `pollInterval` and ends with `reset()`, so it is bounded by timers.

- `test/ntp_query_test.dart` (fake `NtpTransport` built from `serverReply` bytes):
  progress `[1..n]` for n samples on one server; the total across two servers; a mid-query `RATE`
  KoD records a hold and counts the remaining samples as completed; a MAC mismatch yields no packet;
  duplicate pool names collapse; an empty pool emits `NtpProgress.empty`; cancelling runs the
  registered `onCancel` actions.
- `test/udp_transport_test.dart`: a loopback `RawDatagramSocket` echo server. It checks that a
  datagram from another port is ignored, that timeout returns `null`, and that cancel closes the
  socket and returns `null`.
- `test/synchronized_clock_test.dart` (fake `NtpQuery`): `sync` returns the last sample; every
  update in a pass uses the pre-pass `previous` (the frequency input); `reset` closes an active
  stream and `now` stays `null`, without reloading storage; changing `source` or `storage` reloads
  from storage; a completed pass schedules exactly one poll.
- `dart_test.yaml` declares `tags: {network: {}}`, and the network tests in `clock_test`,
  `dns_resolver_test` and the `NTP client` group get `@Tags(['network'])`.

## 8. Behaviour: what is kept and what changes

Kept deliberately, and pinned by tests or the notes above:

- Each clock pass measures frequency against the state from before the pass, not against the
  latest update.
- `reset()` marks the state as loaded (it does not reload storage). Reconfiguring clears the state
  and does reload.
- KoD holds are process-wide by default (`KissOfDeathRegistry.shared`).
- The measurement flag `selected` means "lowest delay in the filter window". It does not mean
  "cluster survivor".
- `maximumServers` is a per-pool limit.
- Order of socket, timestamp and send: bind, read time, encode, listen, send, start the timeout.

Changed (each one goes in its own commit and is noted in the commit message):

- `TimeStorage.stableTime = null` clears storage (today it does nothing). The clock never writes
  `null`.
- The KoD registry used by the clock follows the injected monotonic clock instead of always using
  the isolate stopwatch.
- `NtpPacket.fromBytes` still throws. The client uses `tryParse` and no longer swallows unrelated
  exceptions from parsing.

Follow-ups (outside this refactor, one ticket each): `socket.send` returning `0` is ignored; tie
ordering in the clock filter; whether the query should report errors through the stream instead of
swallowing them.

## 9. Test call-site edits (all mechanical; no assertion changes)

| File | Phase | Edit |
|---|---|---|
| `test_helpers.dart` | 1 | `writeUint64` → `setInt64`; `originTimestamp` becomes `int?` |
| `ntp_packet_test.dart` | 1 | `sent + BigInt.one` → `sent + 1` |
| `ntp_client_test.dart` | 2 | imports; `selectPeers`/`clusterPeers`/`combinePeers`/`measurements` → the new function names |
| `ntp_client_test.dart` | 3 | KoD group uses a local `KissOfDeathRegistry` and `NtpClient(registry:)` |
| `test_helpers.dart` | 5 | add `fixedSource`; `restoredTime` passes `source:` |
| `time_storage_test.dart` | 5 | `monotonicTime:`/`bootIdentifier:` → `source:`; `uncertainty`/`isSynchronized` take `atUptime:`; imports |
| `clock_test.dart` | 7 | `@Tags(['network'])` only |

## 10. Order of work and done criteria

| Step | Depends on | Guard files | Done when |
|---|---|---|---|
| 0 Tooling | — | all offline | formatter at 100 columns, analyzer clean |
| 1 Primitives + protocol | 0 | `ntp_packet_test` | no `BigInt`, no `1000000` literals outside `local_clock.dart` |
| 2 Filter + selection | 1 | `ntp_client_test` (RFC group) | no algorithm code in `client.dart` |
| 3 KoD instance | 2 | `ntp_client_test` (KoD group) | `NtpClientTestHarness` deleted |
| 4 Transport + session | 3 | `ntp_client_test`, `ntp_query_test`, `udp_transport_test` | `client.dart` ≤ 200 lines, no function > 20 lines |
| 5 ClockSource + storage | 1 | `time_storage_test` | `configureClockSources` deleted |
| 6 Clock engine | 4, 5 | `synchronized_clock_test`, `clock_test` | no mutable statics beyond the facade's `_clock` |
| 7 Cleanup | 6 | per changed file | §6 targets met; README updated |

Phases 2–4 and phase 5 touch disjoint files, so they can go in parallel branches once phase 1 is in.
