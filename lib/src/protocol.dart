import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'models.dart';
import 'ntp/packet_types.dart';
import 'time/local_clock.dart'
    show currentTime, frequencyTolerance, localPrecision, precisionFloor;

export 'ntp/packet_types.dart' show NtpMode, KissCode, NtpParsingException;

const double _epochDelta = 2208988800;
const double _eraWidth = 4294967296;
const double _maximumDelayDifference = 0.1;
const double _maximumDispersion = 100;
const int _headerLength = 48;

/// Big-endian NTP message authentication code: key ID plus digest(secret || message).
Uint8List messageAuthenticationCode(List<int> message, NtpKey key) {
  final input = <int>[...key.secret, ...message];
  final digest =
      key.algorithm == NtpMacAlgorithm.md5
          ? md5.convert(input).bytes
          : sha1.convert(input).bytes;
  final output = Uint8List(key.macLength);
  ByteData.sublistView(output).setUint32(0, key.id);
  output.setRange(4, output.length, digest);
  return output;
}

/// One parsed or outgoing NTP packet.
class NtpPacket {
  NtpPacket.request({this.version = 4, this.mode = NtpMode.client})
    : leap = LeapIndicator.noWarning,
      stratum = 0,
      poll = 4,
      precision = localPrecision,
      rootDelay = 1,
      rootDispersion = 1,
      referenceId = 0,
      referenceTime = -_epochDelta,
      originTimestamp = 0,
      originTime = -_epochDelta,
      receiveTimestamp = 0,
      receiveTime = -_epochDelta,
      transmitTimestamp = 0,
      transmitTime = 0,
      destinationTime = -1;

  factory NtpPacket.fromBytes(
    List<int> bytes, {
    required double destinationTime,
  }) {
    if (bytes.length < _headerLength) {
      throw NtpParsingException('Invalid PDU length: ${bytes.length}');
    }
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final header = data.getUint8(0);
    final stratum = data.getUint8(1);
    final originTimestamp = data.getInt64(24);
    final receiveTimestamp = data.getInt64(32);
    final transmitTimestamp = data.getInt64(40);
    return NtpPacket._(
      leap: LeapIndicator.fromValue((header >> 6) & 0x3),
      version: (header >> 3) & 0x7,
      mode: NtpMode.fromValue(header & 0x7),
      stratum: stratum,
      poll: data.getInt8(2),
      precision: data.getInt8(3),
      rootDelay: data.getInt32(4) / 65536,
      rootDispersion: data.getUint32(8) / 65536,
      referenceId: data.getUint32(12),
      referenceTime: _dateFromNtp(data.getInt64(16)),
      originTimestamp: originTimestamp,
      originTime: _dateFromNtp(originTimestamp),
      receiveTimestamp: receiveTimestamp,
      receiveTime: _dateFromNtp(receiveTimestamp),
      transmitTimestamp: transmitTimestamp,
      transmitTime: _dateFromNtp(transmitTimestamp),
      destinationTime: destinationTime,
    );
  }

  NtpPacket._({
    required this.leap,
    required this.version,
    required this.mode,
    required this.stratum,
    required this.poll,
    required this.precision,
    required this.rootDelay,
    required this.rootDispersion,
    required this.referenceId,
    required this.referenceTime,
    required this.originTimestamp,
    required this.originTime,
    required this.receiveTimestamp,
    required this.receiveTime,
    required this.transmitTimestamp,
    required this.transmitTime,
    required this.destinationTime,
  });

  final LeapIndicator leap;
  final int version;
  final NtpMode mode;
  final int stratum;
  final int poll;
  final int precision;
  final double rootDelay;
  final double rootDispersion;
  final int referenceId;
  final double referenceTime;
  final int originTimestamp;
  final double originTime;
  final int receiveTimestamp;
  final double receiveTime;
  final int transmitTimestamp;
  final double transmitTime;
  final double destinationTime;

  double get offset =>
      ((receiveTime - originTime) + (transmitTime - destinationTime)) / 2;

  double get delay =>
      (destinationTime - originTime) - (transmitTime - receiveTime);

  double get dispersion =>
      math.pow(2, precision).toDouble() +
      precisionFloor +
      frequencyTolerance * (destinationTime - originTime);

  KissCode? get kissCode {
    if (!_fromServer || stratum != 0) {
      return null;
    }
    return switch (referenceId) {
      0x44454e59 => KissCode.deny,
      0x52535452 => KissCode.restricted,
      0x52415445 => KissCode.rateExceeded,
      _ => KissCode.other,
    };
  }

  bool get _fromServer =>
      mode == NtpMode.server || mode == NtpMode.symmetricPassive;

  static NtpPacket? tryParse(
    List<int> bytes, {
    required double destinationTime,
  }) {
    try {
      return NtpPacket.fromBytes(bytes, destinationTime: destinationTime);
    } on NtpParsingException {
      return null;
    }
  }

  /// Encodes the packet and appends its optional RFC 5905 MAC.
  Uint8List toBytes({double? atTime, NtpKey? key}) {
    final output = Uint8List(_headerLength + (key?.macLength ?? 0));
    final data = ByteData.sublistView(output);
    data.setUint8(0, (leap.value << 6) | ((version & 0x7) << 3) | mode.value);
    data.setUint8(1, stratum & 0xff);
    data.setInt8(2, poll);
    data.setInt8(3, precision);
    data.setInt32(
      4,
      (rootDelay * 65536).clamp(-0x80000000, 0x7fffffff).truncate(),
    );
    data.setUint32(8, (rootDispersion * 65536).truncate() & 0xffffffff);
    data.setUint32(12, referenceId);
    data.setInt64(16, _dateToNtp(referenceTime));
    data.setInt64(24, _dateToNtp(originTime));
    data.setInt64(32, _dateToNtp(receiveTime));
    data.setInt64(40, _dateToNtp(atTime ?? currentTime()));
    if (key != null) {
      output.setRange(
        _headerLength,
        output.length,
        messageAuthenticationCode(output.sublist(0, _headerLength), key),
      );
    }
    return output;
  }

  static bool isAuthentic(List<int> bytes, NtpKey key) {
    final macLength = key.macLength;
    if (bytes.length < _headerLength + macLength) return false;
    final split = bytes.length - macLength;
    final expected = messageAuthenticationCode(bytes.sublist(0, split), key);
    var difference = 0;
    for (var i = 0; i < macLength; i++) {
      difference |= bytes[split + i] ^ expected[i];
    }
    return difference == 0;
  }

  bool isValidResponse({int? matchingTransmitTimestamp, double? now}) {
    final originMatches =
        matchingTransmitTimestamp == null ||
        originTimestamp == matchingTransmitTimestamp;
    return originMatches &&
        _fromServer &&
        leap != LeapIndicator.alarm &&
        receiveTimestamp != 0 &&
        transmitTimestamp != 0 &&
        version >= 1 &&
        version <= 4 &&
        stratum > 0 &&
        stratum <= 15 &&
        rootDispersion < _maximumDispersion &&
        ((now ?? currentTime()) - originTime - delay).abs() <
            _maximumDelayDifference;
  }
}

int _dateToNtp(double time) {
  final seconds = (time + _epochDelta).floor() & 0xffffffff;
  final fractional = (((time - time.floor()) * _eraWidth).floor()) & 0xffffffff;
  final bits = (seconds << 32) | fractional;
  return bits.toSigned(64);
}

/// Encodes a Unix timestamp as the 64-bit NTP wire timestamp.
int ntpTimestampFromEpoch(double epochTime) => _dateToNtp(epochTime);

double _dateFromNtp(int timestamp) {
  final seconds = timestamp >>> 32;
  final fraction = (timestamp & 0xffffffff) / _eraWidth;
  final nowNtp = currentTime() + _epochDelta;
  final era = (nowNtp / _eraWidth).floor();
  final lowSeconds = (nowNtp - era * _eraWidth).floor();
  var delta = (seconds - lowSeconds) & 0xffffffff;
  if (delta >= 0x80000000) delta -= 0x100000000;
  final ntpSeconds = era * _eraWidth + lowSeconds + delta;
  return ntpSeconds - _epochDelta + fraction;
}
