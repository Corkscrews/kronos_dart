import 'package:universal_io/io.dart';

import 'kiss_of_death.dart';

const Duration _defaultDnsTimeout = Duration(seconds: 8);

abstract final class NtpDnsResolver {
  static Future<List<InternetAddress>> resolve(
    String host, {
    Duration timeout = _defaultDnsTimeout,
  }) async {
    try {
      return await InternetAddress.lookup(host).timeout(timeout);
    } on Object {
      return const [];
    }
  }
}

extension NtpAddressKey on InternetAddress {
  String get key => '${type.name}:$address';
}

/// A resolved server and the number of samples its pool asks for.
typedef NtpServer = ({InternetAddress address, int samples});

/// A pool's resolved addresses and the number of samples per server.
typedef ResolvedPool = ({List<InternetAddress> addresses, int samples});

List<NtpServer> selectServers(
  List<ResolvedPool> pools,
  int perPool,
  KissOfDeathRegistry registry,
) {
  final seen = <String>{};
  return [
    for (final pool in pools)
      ...pool.addresses
          .where(
            (address) => !registry.isBlocked(address) && seen.add(address.key),
          )
          .take(perPool)
          .map((address) => (address: address, samples: pool.samples)),
  ];
}
