import '../models.dart';
import '../protocol.dart';
import 'selection.dart';

class NtpRequestOptions {
  const NtpRequestOptions({
    this.version = defaultVersion,
    this.port = defaultPort,
    this.key,
    this.timeout = defaultTimeout,
  });

  static const defaultVersion = 4;
  static const defaultPort = 123;
  static const defaultTimeout = 6.0;

  final int version;
  final int port;
  final NtpKey? key;
  final double timeout;
}

/// Progress after one or more sample operations have completed.
class NtpProgress {
  const NtpProgress({
    required this.estimate,
    required this.completed,
    required this.total,
    required this.measurements,
  });

  static const empty = NtpProgress(
    estimate: null,
    completed: 0,
    total: 0,
    measurements: [],
  );

  final NtpEstimate? estimate;
  final int completed;
  final int total;
  final List<NtpMeasurement> measurements;

  bool get isComplete => completed == total;
}

class NtpSampleResult {
  const NtpSampleResult({required this.packet, required this.blocked});

  static const noReply = NtpSampleResult(packet: null, blocked: false);
  static const blockedServer = NtpSampleResult(packet: null, blocked: true);

  final NtpPacket? packet;
  final bool blocked;
}
