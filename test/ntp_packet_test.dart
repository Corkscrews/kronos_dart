import 'dart:typed_data';

import 'package:kronos_dart/kronos_dart.dart';
import 'package:kronos_dart/src/protocol.dart'
    show messageAuthenticationCode, ntpTimestampFromEpoch;
import 'package:kronos_dart/src/time/local_clock.dart'
    show currentTime, localPrecision;
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('NTP packet', () {
    test('encodes request fields in network byte order', () {
      final bytes = NtpPacket.request().toBytes(atTime: 1463303662.776552);
      expect(ByteData.sublistView(bytes).getInt8(3), localPrecision);

      bytes[3] = 0xfa;
      expect(
        bytes,
        hexBytes(
          '230004fa0001000000010000000000000000000000000000'
          '00000000000000000000000000000000dae2bc6ec6cc1c00',
        ),
      );
    });

    test('measures local precision', () {
      expect(localPrecision, lessThanOrEqualTo(0));
      expect(localPrecision, greaterThanOrEqualTo(-32));
    });

    test('authenticated requests round-trip for MD5 and SHA-1', () {
      for (final algorithm in NtpMacAlgorithm.values) {
        final key = NtpKey(
          id: 7,
          secret: 'secret'.codeUnits,
          algorithm: algorithm,
        );
        final bytes = NtpPacket.request().toBytes(
          atTime: 1463303662.5,
          key: key,
        );

        expect(bytes.length, 48 + 4 + key.digestLength);
        expect(ByteData.sublistView(bytes).getUint32(48, Endian.big), 7);
        expect(NtpPacket.isAuthentic(bytes, key), isTrue);

        final tampered = Uint8List.fromList(bytes);
        tampered[40] ^= 1;
        expect(NtpPacket.isAuthentic(tampered, key), isFalse);
        expect(
          NtpPacket.isAuthentic(
            bytes,
            NtpKey(id: 7, secret: 'other'.codeUnits, algorithm: algorithm),
          ),
          isFalse,
        );
        expect(NtpPacket.isAuthentic(bytes.sublist(0, 48), key), isFalse);
      }
    });

    test('matches RFC 5905 MD5 MAC construction', () {
      final mac = messageAuthenticationCode(
        List<int>.filled(48, 0),
        NtpKey(id: 1, secret: 'key'.codeUnits, algorithm: NtpMacAlgorithm.md5),
      );
      expect(mac, hexBytes('00000001e20e96ab3803fa6f124d92eaf78a5d45'));
    });

    test('parses kiss-o-death codes', () {
      NtpPacket packetFor(String code) {
        final bytes =
            Uint8List(48)
              ..[0] = (4 << 3) | NtpMode.server.value
              ..setRange(12, 16, code.codeUnits);
        return NtpPacket.fromBytes(bytes, destinationTime: 0);
      }

      expect(packetFor('RATE').kissCode, KissCode.rateExceeded);
      expect(packetFor('DENY').kissCode, KissCode.deny);
      expect(packetFor('RSTR').kissCode, KissCode.restricted);
      expect(packetFor('NOPE').kissCode, KissCode.other);
      expect(packetFor('RATE').isValidResponse(), isFalse);
      expect(serverReply(now: currentTime()).kissCode, isNull);
    });

    test('rejects invalid packet data', () {
      expect(
        () => NtpPacket.fromBytes(hexBytes('0badface'), destinationTime: 0),
        throwsA(isA<NtpParsingException>()),
      );
    });

    test('parses packet header fields', () {
      final packet = NtpPacket.fromBytes(
        hexBytes(
          '1c0203e90000065700000a68ada2c09cdae2d084a5a76d5fdae2d3354a529000'
          'dae2d32bb38bab46dae2d32bb38d9e00',
        ),
        destinationTime: 0,
      );
      expect(packet.version, 3);
      expect(packet.leap, LeapIndicator.noWarning);
      expect(packet.mode, NtpMode.server);
      expect(packet.stratum, 2);
      expect(packet.poll, 3);
      expect(packet.precision, -23);
    });

    test('parses offsets from a byte slice', () {
      final buffer = hexBytes(
        'ffffffff1c0203e90000065700000a68ada2c09cdae2d084a5a76d5fdae2d3354a529000'
        'dae2d32bb38bab46dae2d32bb38d9e00',
      );
      final packet = NtpPacket.fromBytes(buffer.sublist(4), destinationTime: 0);
      expect(packet.version, 3);
      expect(packet.mode, NtpMode.server);
      expect(packet.precision, -23);
      expect(packet.referenceId, 2913124508);
      expect(packet.receiveTime, closeTo(1463309483.7013499737, 1e-6));
    });

    test('parses NTP time and fixed-point fields', () {
      final packet = NtpPacket.fromBytes(
        hexBytes(
          '1c0203e90000065700000a68ada2c09cdae2d084a5a76d5fdae2d3354a529000'
          'dae2d32bb38bab46dae2d32bb38d9e00',
        ),
        destinationTime: 0,
      );
      expect(packet.rootDelay, closeTo(0.0247650146484375, 1e-12));
      expect(packet.rootDispersion, closeTo(0.0406494140625, 1e-12));
      expect(packet.referenceId, 2913124508);
      expect(packet.referenceTime, closeTo(1463308804.6470859051, 1e-6));
      expect(packet.originTime, closeTo(1463309493.2903223038, 1e-6));
      expect(packet.receiveTime, closeTo(1463309483.7013499737, 1e-6));
    });

    test('interprets the 2036 NTP era rollover', () {
      final rolloverBytes = hexBytes(
        '1b0004fa000100000001000000000000000000000000000000000000000000000000000'
        '0000000000000000000000000',
      );
      final packet = NtpPacket.fromBytes(rolloverBytes, destinationTime: 0);
      expect(
        DateTime.fromMillisecondsSinceEpoch(
          (packet.referenceTime * 1000).round(),
          isUtc: true,
        ),
        DateTime.utc(2036, 2, 7, 6, 28, 16),
      );
      expect(packet.toBytes(atTime: 2085978496), rolloverBytes);
    });

    test('accepts only RFC 5905 stratum range for usable replies', () {
      final now = currentTime();
      for (var stratum = 0; stratum <= 16; stratum++) {
        final packet = serverReply(now: now, stratum: stratum);
        expect(packet.stratum, stratum);
        expect(packet.isValidResponse(), stratum >= 1 && stratum <= 15);
      }
    });

    test('parses negative root delay', () {
      final packet = NtpPacket.fromBytes(
        hexBytes(
          '1c0203e9ffff800000000a68ada2c09cdae2d084a5a76d5fdae2d3354a529000'
          'dae2d32bb38bab46dae2d32bb38d9e00',
        ),
        destinationTime: 0,
      );
      expect(packet.rootDelay, -0.5);
    });

    test('rejects a reply that does not echo the request timestamp', () {
      final now = currentTime();
      final sent = ntpTimestampFromEpoch(now);
      final reply = serverReply(now: now, originTimestamp: sent);
      expect(reply.isValidResponse(matchingTransmitTimestamp: sent), isTrue);

      final other = serverReply(now: now, originTimestamp: sent + 1);
      expect(other.isValidResponse(matchingTransmitTimestamp: sent), isFalse);
      expect(
        serverReply(
          now: now,
          version: 5,
          originTimestamp: sent,
        ).isValidResponse(matchingTransmitTimestamp: sent),
        isFalse,
      );
    });
  });
}
