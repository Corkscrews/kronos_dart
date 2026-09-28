import 'package:universal_io/io.dart';
import 'dart:math' as math;
import 'dart:typed_data';

import '../time/local_clock.dart';

typedef NtpReply = ({double sentAt, List<int> data, double receivedAt});

final class Cancellation {
  bool _cancelled = false;
  final Set<void Function()> _actions = {};

  bool get isCancelled => _cancelled;

  void Function() onCancel(void Function() action) {
    if (_cancelled) {
      action();
      return () {};
    }
    _actions.add(action);
    return () => _actions.remove(action);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final action in _actions.toList()) {
      action();
    }
    _actions.clear();
  }
}

abstract interface class NtpTransport {
  Future<NtpReply?> exchange(
    InternetAddress ip,
    int port,
    Uint8List Function(double sentAt) encode, {
    required double timeout,
    Cancellation? cancellation,
  });
}

class UdpNtpTransport implements NtpTransport {
  const UdpNtpTransport();

  @override
  Future<NtpReply?> exchange(
    InternetAddress ip,
    int port,
    Uint8List Function(double sentAt) encode, {
    required double timeout,
    Cancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled ?? false) return null;
    RawDatagramSocket? socket;
    void Function()? unregister;
    try {
      final bind =
          ip.type == InternetAddressType.IPv6
              ? InternetAddress.anyIPv6
              : InternetAddress.anyIPv4;
      final active = await RawDatagramSocket.bind(bind, 0);
      socket = active;
      unregister = cancellation?.onCancel(active.close);
      if (cancellation?.isCancelled ?? false) return null;
      final sentAt = currentTime();
      final data = encode(sentAt);
      final reply = _firstReplyFrom(active, ip, port);
      active.send(data, ip, port);
      final datagram = await reply.timeout(
        durationFromSeconds(math.max(0.0, timeout)),
        onTimeout: () => null,
      );
      if (datagram == null || (cancellation?.isCancelled ?? false)) return null;
      return (
        sentAt: sentAt,
        data: datagram.data,
        receivedAt: datagram.receivedAt,
      );
    } on Object {
      // Socket bind, send and stream errors mean no usable reply.
      return null;
    } finally {
      unregister?.call();
      socket?.close();
    }
  }

  Future<({List<int> data, double receivedAt})?> _firstReplyFrom(
    RawDatagramSocket socket,
    InternetAddress ip,
    int port,
  ) async {
    await for (final event in socket) {
      if (event != RawSocketEvent.read) continue;
      for (
        var datagram = socket.receive();
        datagram != null;
        datagram = socket.receive()
      ) {
        if (datagram.port == port && datagram.address.address == ip.address) {
          return (data: datagram.data, receivedAt: currentTime());
        }
      }
    }
    return null;
  }
}
