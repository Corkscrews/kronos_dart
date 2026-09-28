import 'dart:async';
import 'package:universal_io/io.dart';

import '../models.dart';
import '../protocol.dart';
import '../time/local_clock.dart';
import 'clock_filter.dart';
import 'kiss_of_death.dart';
import 'query_models.dart';
import 'selection.dart';
import 'servers.dart';
import 'transport.dart';

export 'query_models.dart' show NtpProgress, NtpRequestOptions, NtpSampleResult;

const int _maximumNtpServers = 5;
const double _minimumSampleSpacing = 2;

typedef NtpResolver = Future<List<InternetAddress>> Function(String host);

/// Performs DNS resolution, NTP exchanges and RFC 5905 clock selection.
class NtpClient {
  const NtpClient({
    this.transport = const UdpNtpTransport(),
    this.resolve = NtpDnsResolver.resolve,
    KissOfDeathRegistry? registry,
  }) : _registryOverride = registry;

  final NtpTransport transport;
  final NtpResolver resolve;
  final KissOfDeathRegistry? _registryOverride;

  KissOfDeathRegistry get _registry =>
      _registryOverride ?? KissOfDeathRegistry.shared;

  Stream<NtpProgress> query({
    List<NtpPool> pools = NtpConfiguration.standardPools,
    int version = NtpRequestOptions.defaultVersion,
    int port = NtpRequestOptions.defaultPort,
    int maximumServers = _maximumNtpServers,
    NtpKey? key,
    double timeout = NtpRequestOptions.defaultTimeout,
  }) {
    final controller = StreamController<NtpProgress>();
    final cancellation = Cancellation();
    final options = NtpRequestOptions(
      version: version,
      port: port,
      key: key,
      timeout: timeout,
    );
    controller.onListen = () {
      unawaited(_run(controller, cancellation, pools, maximumServers, options));
    };
    controller.onCancel = cancellation.cancel;
    return controller.stream;
  }

  Future<void> _run(
    StreamController<NtpProgress> controller,
    Cancellation cancellation,
    List<NtpPool> pools,
    int maximumServers,
    NtpRequestOptions options,
  ) async {
    try {
      final servers = await _servers(pools, maximumServers);
      if (cancellation.isCancelled) return;
      final total = servers.fold(0, (sum, server) => sum + server.samples);
      if (total == 0) {
        controller.add(NtpProgress.empty);
        return;
      }
      final session = _QuerySession(controller, cancellation, total);
      await Future.wait(
        servers.map(
          (server) =>
              _runServer(server.address, server.samples, options, session),
        ),
      );
    } catch (_) {
      // An unexpected query failure must not become an uncaught asynchronous error.
    } finally {
      if (!controller.isClosed) await controller.close();
    }
  }

  Future<List<NtpServer>> _servers(
    List<NtpPool> pools,
    int maximumServers,
  ) async {
    final hosts = <String, int>{};
    for (final pool in pools) {
      if (pool.host.isNotEmpty && pool.samples > 0) {
        hosts.putIfAbsent(pool.host, () => pool.samples);
      }
    }
    final resolved = await Future.wait(
      hosts.entries.map(
        (host) async => (
          addresses: await resolve(host.key),
          samples: host.value,
        ),
      ),
    );
    return selectServers(resolved, maximumServers, _registry);
  }

  Future<void> _runServer(
    InternetAddress address,
    int count,
    NtpRequestOptions options,
    _QuerySession session,
  ) async {
    var previousStart = double.negativeInfinity;
    for (var index = 0; index < count; index++) {
      if (session.isCancelled) return;
      if (_registry.isBlocked(address)) {
        session.record(address, null, finished: count - index);
        return;
      }
      final wait = previousStart + _minimumSampleSpacing - currentTime();
      if (wait > 0) await Future<void>.delayed(durationFromSeconds(wait));
      if (session.isCancelled) return;
      previousStart = currentTime();
      final result = await _sample(address, options, session.cancellation);
      if (session.isCancelled) return;
      session.record(
        address,
        result.packet,
        finished: result.blocked ? count - index : 1,
      );
      if (result.blocked) return;
    }
  }

  /// Sends one NTP request and waits for a matching valid reply or timeout.
  Future<NtpSampleResult> sample({
    required InternetAddress ip,
    int port = NtpRequestOptions.defaultPort,
    int version = NtpRequestOptions.defaultVersion,
    NtpKey? key,
    double timeout = NtpRequestOptions.defaultTimeout,
  }) => _sample(
    ip,
    NtpRequestOptions(version: version, port: port, key: key, timeout: timeout),
  );

  Future<NtpSampleResult> _sample(
    InternetAddress ip,
    NtpRequestOptions options, [
    Cancellation? cancellation,
  ]) async {
    if (_registry.isBlocked(ip)) return NtpSampleResult.blockedServer;
    final request = NtpPacket.request(version: options.version);
    final reply = await transport.exchange(
      ip,
      options.port,
      (at) => request.toBytes(atTime: at, key: options.key),
      timeout: options.timeout,
      cancellation: cancellation,
    );
    if (reply == null || (cancellation?.isCancelled ?? false))
      return NtpSampleResult.noReply;
    return _interpret(reply, ip, options.key);
  }

  NtpSampleResult _interpret(NtpReply reply, InternetAddress ip, NtpKey? key) {
    if (key != null && !NtpPacket.isAuthentic(reply.data, key))
      return NtpSampleResult.noReply;
    final packet = NtpPacket.tryParse(
      reply.data,
      destinationTime: reply.receivedAt,
    );
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
}

class _QuerySession {
  _QuerySession(this._sink, this.cancellation, this._total);

  final StreamController<NtpProgress> _sink;
  final Cancellation cancellation;
  final int _total;
  final Map<String, List<NtpPacket>> _packetsByServer = {};
  final List<ReceivedSample> _received = [];
  int _completed = 0;

  bool get isCancelled => cancellation.isCancelled;

  void record(InternetAddress address, NtpPacket? packet, {int finished = 1}) {
    if (packet != null) {
      _packetsByServer.putIfAbsent(address.key, () => []).add(packet);
      _received.add((address: address, packet: packet));
    }
    _completed += finished;
    if (isCancelled || _sink.isClosed) return;
    _sink.add(
      NtpProgress(
        estimate: estimateSystem(_packetsByServer.values, currentTime()),
        completed: _completed,
        total: _total,
        measurements: measurementsOf(_received),
      ),
    );
  }
}
