import 'dart:typed_data';

import 'package:kronos_dart/src/models.dart' show LeapIndicator;
import 'package:kronos_dart/src/protocol.dart';
import 'package:kronos_dart/src/time/local_clock.dart';
import 'package:kronos_dart/src/time/stable_time.dart';

const testBootIdentifier = 'test-boot';

Uint8List hexBytes(String hex) {
  final normalized = hex.replaceAll(RegExp(r'\s+'), '');
  if (normalized.length.isOdd) throw FormatException('Odd-length hex input.');
  return Uint8List.fromList([
    for (var index = 0; index < normalized.length; index += 2)
      int.parse(normalized.substring(index, index + 2), radix: 16),
  ]);
}

void writeUint64(Uint8List bytes, int offset, int value) =>
    ByteData.sublistView(bytes).setInt64(offset, value);

ClockSource fixedSource(double uptime, [String boot = testBootIdentifier]) =>
    ClockSource(monotonicTime: () => uptime, bootIdentifier: () => boot);

NtpPacket serverReply({
  required double now,
  double offset = 0,
  double delay = 0,
  int version = 4,
  int stratum = 2,
  LeapIndicator leap = LeapIndicator.noWarning,
  int? originTimestamp,
}) {
  final receive = now + delay / 2 + offset;
  final bytes = Uint8List(48);
  bytes[0] = (leap.value << 6) | ((version & 0x7) << 3) | NtpMode.server.value;
  bytes[1] = stratum;
  bytes[2] = 4;
  bytes[3] = (-20) & 0xff;
  writeUint64(bytes, 24, originTimestamp ?? ntpTimestampFromEpoch(now));
  writeUint64(bytes, 32, ntpTimestampFromEpoch(receive));
  writeUint64(bytes, 40, ntpTimestampFromEpoch(receive));
  return NtpPacket.fromBytes(bytes, destinationTime: now + delay);
}

StableTime restoredTime({
  required double uptime,
  required double timestamp,
  double offset = 0,
  String bootIdentifier = testBootIdentifier,
  double monotonicNow = 10000,
  Map<String, Object?> extra = const {},
}) {
  return StableTime.fromMap({
    'Uptime': uptime,
    'Timestamp': timestamp,
    'Offset': offset,
    'BootIdentifier': bootIdentifier,
    ...extra,
  }, source: fixedSource(monotonicNow));
}
