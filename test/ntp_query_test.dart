import 'dart:async';
import 'package:universal_io/io.dart';
import 'dart:typed_data';

import 'package:kronos_dart/kronos_dart.dart';
import 'package:kronos_dart/src/protocol.dart'
    show messageAuthenticationCode, ntpTimestampFromEpoch;
import 'package:kronos_dart/src/time/local_clock.dart' show currentTime;
import 'package:test/test.dart';

import 'test_helpers.dart';

typedef _ReplyBuilder = NtpReply? Function(double sentAt);

class _ScriptedTransport implements NtpTransport {
  _ScriptedTransport(this.replies);

  final List<_ReplyBuilder> replies;
  int calls = 0;

  @override
  Future<NtpReply?> exchange(
    InternetAddress ip,
    int port,
    Uint8List Function(double sentAt) encode, {
    required double timeout,
    Cancellation? cancellation,
  }) async {
    final sentAt = currentTime();
    encode(sentAt);
    final index = calls++;
    return index < replies.length ? replies[index](sentAt) : null;
  }
}

NtpReply _reply(double sentAt, {String? kissCode}) {
  final bytes = Uint8List(48);
  bytes[0] = (4 << 3) | NtpMode.server.value;
  bytes[1] = kissCode == null ? 2 : 0;
  bytes[2] = 4;
  bytes[3] = (-20) & 0xff;
  if (kissCode != null) bytes.setRange(12, 16, kissCode.codeUnits);
  writeUint64(bytes, 24, ntpTimestampFromEpoch(sentAt));
  writeUint64(bytes, 32, ntpTimestampFromEpoch(sentAt + 0.005));
  writeUint64(bytes, 40, ntpTimestampFromEpoch(sentAt + 0.005));
  return (sentAt: sentAt, data: bytes, receivedAt: sentAt + 0.01);
}

void main() {
  final address = InternetAddress('192.0.2.1');
  Future<List<InternetAddress>> resolve(String _) async => [address];

  test('progress counts the requested samples on one server', () async {
    final transport = _ScriptedTransport([_reply, _reply]);
    final updates =
        await NtpClient(
          transport: transport,
          resolve: resolve,
        ).query(pools: [NtpPool('test.invalid', samples: 2)]).toList();
    expect(updates.map((update) => update.completed), [1, 2]);
    expect(updates.last.total, 2);
    expect(updates.last.measurements, hasLength(2));
  });

  test('total includes every resolved server', () async {
    Future<List<InternetAddress>> twoServers(String _) async => [
      InternetAddress('192.0.2.2'),
      InternetAddress('192.0.2.3'),
    ];
    final transport = _ScriptedTransport([_reply, _reply]);
    final updates =
        await NtpClient(
          transport: transport,
          resolve: twoServers,
        ).query(pools: [NtpPool('test.invalid', samples: 1)]).toList();
    expect(updates.last.total, 2);
    expect(updates.last.completed, 2);
  });

  test('each pool samples its servers by its own count', () async {
    Future<List<InternetAddress>> perHost(String host) async => [
      InternetAddress(host == 'a.invalid' ? '192.0.2.4' : '192.0.2.5'),
    ];
    final transport = _ScriptedTransport([_reply, _reply, _reply]);
    final updates =
        await NtpClient(transport: transport, resolve: perHost)
            .query(
              pools: [
                NtpPool('a.invalid', samples: 1),
                NtpPool('b.invalid', samples: 2),
              ],
            )
            .toList();
    expect(updates.last.total, 3);
    expect(updates.last.completed, 3);
    expect(transport.calls, 3);
  });

  test('RATE holds the server and accounts for remaining samples', () async {
    final registry = KissOfDeathRegistry();
    final transport = _ScriptedTransport([
      _reply,
      (at) => _reply(at, kissCode: 'RATE'),
    ]);
    final updates =
        await NtpClient(
          transport: transport,
          resolve: resolve,
          registry: registry,
        ).query(pools: [NtpPool('test.invalid', samples: 3)]).toList();
    expect(updates.map((update) => update.completed), [1, 3]);
    expect(registry.isBlocked(address), isTrue);
    expect(transport.calls, 2);
  });

  test('a MAC mismatch yields no packet', () async {
    final key = NtpKey(id: 7, secret: 'secret'.codeUnits);
    final transport = _ScriptedTransport([
      (at) {
        final reply = _reply(at);
        final bytes = Uint8List.fromList([
          ...reply.data,
          ...messageAuthenticationCode(reply.data, key),
        ]);
        bytes[20] ^= 1;
        return (sentAt: at, data: bytes, receivedAt: reply.receivedAt);
      },
    ]);
    final result = await NtpClient(
      transport: transport,
    ).sample(ip: address, key: key);
    expect(result.packet, isNull);
    expect(result.blocked, isFalse);
  });

  test('duplicate pool names resolve once', () async {
    var lookups = 0;
    Future<List<InternetAddress>> countingResolver(String _) async {
      lookups++;
      return [address];
    }

    final transport = _ScriptedTransport([_reply]);
    final updates =
        await NtpClient(transport: transport, resolve: countingResolver)
            .query(
              pools: [
                NtpPool('test.invalid', samples: 1),
                NtpPool('test.invalid', samples: 1),
              ],
            )
            .toList();
    expect(lookups, 1);
    expect(updates.last.total, 1);
  });

  test('an empty pool emits empty progress', () async {
    final updates =
        await NtpClient(
          transport: _ScriptedTransport([]),
        ).query(pools: [NtpPool('')]).toList();
    expect(updates, hasLength(1));
    expect(updates.single.total, 0);
  });

  test('cancelling a query invokes registered transport actions', () async {
    final cancelled = Completer<void>();
    final waiting = _WaitingTransport(cancelled);
    final subscription = NtpClient(
      transport: waiting,
      resolve: resolve,
    ).query(pools: [NtpPool('test.invalid', samples: 1)]).listen((_) {});
    await waiting.started.future;
    await subscription.cancel();
    await cancelled.future;
    expect(waiting.cancelled, isTrue);
  });
}

class _WaitingTransport implements NtpTransport {
  _WaitingTransport(this.onCancelled);

  final Completer<void> onCancelled;
  final Completer<void> started = Completer<void>();
  bool cancelled = false;

  @override
  Future<NtpReply?> exchange(
    InternetAddress ip,
    int port,
    Uint8List Function(double sentAt) encode, {
    required double timeout,
    Cancellation? cancellation,
  }) async {
    final done = Completer<NtpReply?>();
    cancellation?.onCancel(() {
      cancelled = true;
      done.complete(null);
      onCancelled.complete();
    });
    started.complete();
    return done.future;
  }
}
