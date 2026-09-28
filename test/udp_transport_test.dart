import 'dart:async';
import 'package:universal_io/io.dart';
import 'dart:typed_data';

import 'package:kronos_dart/src/ntp/transport.dart';
import 'package:test/test.dart';

void main() {
  test('ignores datagrams sent from a different port', () async {
    final server = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final other = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final events = server.listen((event) {
      if (event != RawSocketEvent.read) return;
      final request = server.receive();
      if (request == null) return;
      other.send([1], request.address, request.port);
      Timer(const Duration(milliseconds: 40), () {
        server.send([2], request.address, request.port);
      });
    });
    try {
      final reply = await const UdpNtpTransport().exchange(
        InternetAddress.loopbackIPv4,
        server.port,
        (_) => Uint8List.fromList([0]),
        timeout: 1,
      );
      expect(reply?.data, [2]);
    } finally {
      await events.cancel();
      server.close();
      other.close();
    }
  });

  test('returns null when no server replies', () async {
    final server = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    try {
      final reply = await const UdpNtpTransport().exchange(
        InternetAddress.loopbackIPv4,
        server.port,
        (_) => Uint8List.fromList([0]),
        timeout: 0.02,
      );
      expect(reply, isNull);
    } finally {
      server.close();
    }
  });

  test('cancellation closes the pending exchange', () async {
    final server = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final cancellation = Cancellation();
    final events = server.listen((event) {
      if (event == RawSocketEvent.read && server.receive() != null)
        cancellation.cancel();
    });
    try {
      final reply = await const UdpNtpTransport().exchange(
        InternetAddress.loopbackIPv4,
        server.port,
        (_) => Uint8List.fromList([0]),
        timeout: 1,
        cancellation: cancellation,
      );
      expect(reply, isNull);
      expect(cancellation.isCancelled, isTrue);
    } finally {
      await events.cancel();
      server.close();
    }
  });
}
