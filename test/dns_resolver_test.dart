import 'package:kronos_dart/kronos_dart.dart';
import 'package:test/test.dart';

@Tags(['network'])
void main() {
  group('NTP DNS resolver', () {
    test('resolves one IPv4 address', () async {
      final addresses = await NtpDnsResolver.resolve('127.0.0.1');
      expect(addresses.map((address) => address.address), ['127.0.0.1']);
    });

    test('resolves multiple pool addresses', () async {
      final addresses = await NtpDnsResolver.resolve('pool.ntp.org');
      expect(addresses.length, greaterThan(1));
    });

    test('resolves IPv6-capable hosts', () async {
      final addresses = await NtpDnsResolver.resolve('ipv6friday.org');
      expect(addresses, isNotEmpty);
    });

    test('returns an empty list for an invalid host', () async {
      final addresses = await NtpDnsResolver.resolve('l33t.h4x');
      expect(addresses, isEmpty);
    });

    test('returns quickly when the lookup timeout is zero', () async {
      final start = DateTime.now();
      final addresses = await NtpDnsResolver.resolve(
        'ip6.nl',
        timeout: Duration.zero,
      );
      expect(addresses, isEmpty);
      expect(
        DateTime.now().difference(start),
        lessThan(const Duration(seconds: 1)),
      );
    });
  });
}
