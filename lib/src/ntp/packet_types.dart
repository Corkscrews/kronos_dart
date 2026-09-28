/// The NTP connection mode.
enum NtpMode {
  reserved(0),
  symmetricActive(1),
  symmetricPassive(2),
  client(3),
  server(4),
  broadcast(5),
  reservedNtp(6),
  unknown(7);

  const NtpMode(this.value);
  final int value;

  static NtpMode fromValue(int value) =>
      values.firstWhere((item) => item.value == value, orElse: () => unknown);
}

enum KissCode { deny, restricted, rateExceeded, other }

/// Invalid or truncated NTP packet data.
class NtpParsingException implements Exception {
  const NtpParsingException(this.message);
  final String message;

  @override
  String toString() => 'NtpParsingException: $message';
}
