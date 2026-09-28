import 'package:universal_io/io.dart';
import 'dart:math' as math;

import '../protocol.dart';
import '../time/local_clock.dart';
import 'servers.dart';

const double _minimumRateHold = 64;

/// Server restrictions shared across queries unless an instance is injected.
class KissOfDeathRegistry {
  KissOfDeathRegistry({double Function() monotonicTime = defaultMonotonicTime})
    : _now = monotonicTime;

  static final shared = KissOfDeathRegistry();

  final double Function() _now;
  final Set<String> _denied = {};
  final Map<String, double> _holdUntil = {};

  void record(KissCode code, InternetAddress address, {int poll = 4}) {
    if (code == KissCode.deny || code == KissCode.restricted) {
      _denied.add(address.key);
      return;
    }
    if (code != KissCode.rateExceeded) return;
    final seconds = math.pow(2, poll.clamp(0, 17)).toDouble();
    _holdUntil[address.key] = _now() + math.max(_minimumRateHold, seconds);
  }

  bool isBlocked(InternetAddress address) {
    final key = address.key;
    if (_denied.contains(key)) return true;
    final until = _holdUntil[key];
    if (until == null) return false;
    if (_now() < until) return true;
    _holdUntil.remove(key);
    return false;
  }
}
