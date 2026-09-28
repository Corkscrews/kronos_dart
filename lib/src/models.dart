import 'dart:typed_data';

/// The impending leap-second state announced in an NTP packet.
enum LeapIndicator {
  noWarning(0, 'No warning'),
  sixtyOneSeconds(1, 'Last minute of the day has 61 seconds'),
  fiftyNineSeconds(2, 'Last minute of the day has 59 seconds'),
  alarm(3, 'Unknown (clock unsynchronized)');

  const LeapIndicator(this.value, this.description);
  final int value;
  final String description;

  static LeapIndicator fromValue(int value) =>
      values.firstWhere((item) => item.value == value, orElse: () => noWarning);
}

/// A date returned by the stable clock, with its age and current error bound.
class AnnotatedTime {
  const AnnotatedTime({
    required this.date,
    required this.timeSinceLastNtpSync,
    this.uncertainty = 0,
  });

  final DateTime date;
  final double timeSinceLastNtpSync;
  final double uncertainty;
}

enum NtpMacAlgorithm { md5, sha1 }

/// Symmetric key used for the RFC 5905 NTP message authentication code.
class NtpKey {
  NtpKey({
    required this.id,
    required List<int> secret,
    this.algorithm = NtpMacAlgorithm.sha1,
  }) : secret = Uint8List.fromList(secret);

  final int id;
  final Uint8List secret;
  final NtpMacAlgorithm algorithm;

  int get digestLength => algorithm == NtpMacAlgorithm.md5 ? 16 : 20;
  int get macLength => 4 + digestLength;
}

/// An NTP pool host and the number of samples taken from each of its servers.
class NtpPool {
  const NtpPool(this.host, {this.samples = defaultSamples});

  static const defaultSamples = 4;

  final String host;
  final int samples;

  @override
  bool operator ==(Object other) =>
      other is NtpPool && other.host == host && other.samples == samples;

  @override
  int get hashCode => Object.hash(host, samples);
}

/// NTP pools to query, each with its own sample count.
class NtpConfiguration {
  const NtpConfiguration({required this.pools, this.key});

  static const standardPools = [NtpPool('time.apple.com')];
  static const standard = NtpConfiguration(
    pools: NtpConfiguration.standardPools,
  );

  final List<NtpPool> pools;
  final NtpKey? key;
}

/// A valid server reply before replies are combined into a clock estimate.
class NtpMeasurement {
  const NtpMeasurement({
    required this.server,
    required this.stratum,
    required this.roundTripDelay,
    required this.offset,
    required this.dispersion,
    required this.selected,
  });

  final String server;
  final int stratum;
  final double roundTripDelay;
  final double offset;
  final double dispersion;
  final bool selected;

  @override
  bool operator ==(Object other) =>
      other is NtpMeasurement &&
      other.selected == selected &&
      other.stratum == stratum &&
      other.roundTripDelay == roundTripDelay &&
      other.offset == offset &&
      other.dispersion == dispersion &&
      other.server == server;

  @override
  int get hashCode => Object.hash(
    selected,
    stratum,
    roundTripDelay,
    offset,
    dispersion,
    server,
  );
}

/// One usable adjustment produced during a synchronization pass.
class SyncSample {
  const SyncSample({
    required this.date,
    required this.offset,
    required this.completed,
    required this.total,
    this.measurements = const [],
  });

  final DateTime date;
  final double offset;
  final int completed;
  final int total;
  final List<NtpMeasurement> measurements;

  bool get isLast => completed == total;
}

/// Result of a synchronization pass.
class SyncResult {
  const SyncResult({this.date, this.offset});

  final DateTime? date;
  final double? offset;
}
