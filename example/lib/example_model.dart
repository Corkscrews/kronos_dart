import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kronos_dart/kronos_dart.dart' hide NtpPool;
import 'package:kronos_dart/kronos_dart.dart' as kronos show NtpPool;

enum NtpPool {
  apple('time.apple.com'),
  nist('time.nist.gov'),
  galway('ntp-galway.hea.net'),
  netherlands('ntppool3.time.nl');

  const NtpPool(this.hostname);

  final String hostname;
}

enum _SyncStatus { idle, syncing, failed }

class ExampleModel extends ChangeNotifier {
  NtpPool _pool = NtpPool.apple;
  _SyncStatus _status = _SyncStatus.idle;
  int _generation = 0;
  StreamIterator<SyncSample>? _updates;
  double? offset;
  int completed = 0;
  int total = 0;
  List<NtpMeasurement> measurements = const [];

  NtpPool get pool => _pool;
  bool get isSyncing => _status == _SyncStatus.syncing;
  bool get didFail => _status == _SyncStatus.failed;

  double? get bestRoundTrip {
    final selected = measurements.where((item) => item.selected);
    if (selected.isEmpty) return null;
    return selected
        .map((item) => item.roundTripDelay)
        .reduce((a, b) => a < b ? a : b);
  }

  void select(NtpPool value) {
    if (value == _pool) return;
    _pool = value;
    _beginSync(replacingCurrent: true);
  }

  void sync() => _beginSync(replacingCurrent: false);

  void reset() {
    _generation++;
    final updates = _updates;
    _updates = null;
    if (updates != null) unawaited(updates.cancel());
    KronosClock.reset();
    _status = _SyncStatus.idle;
    _clearProgress();
    notifyListeners();
  }

  void _beginSync({required bool replacingCurrent}) {
    if (isSyncing && !replacingCurrent) return;

    final previous = _updates;
    _updates = null;
    if (previous != null) unawaited(previous.cancel());
    if (replacingCurrent) KronosClock.reset();

    _status = _SyncStatus.syncing;
    _clearProgress();
    final generation = ++_generation;
    final updates = StreamIterator<SyncSample>(KronosClock.syncing(
      configuration: NtpConfiguration(pools: [kronos.NtpPool(_pool.hostname)]),
    ));
    _updates = updates;
    notifyListeners();
    unawaited(_consume(updates, generation));
  }

  Future<void> _consume(
      StreamIterator<SyncSample> updates, int generation) async {
    var receivedSample = false;
    try {
      while (await updates.moveNext()) {
        if (generation != _generation) return;
        final sample = updates.current;
        receivedSample = true;
        offset = sample.offset;
        completed = sample.completed;
        total = sample.total;
        measurements = sample.measurements;
        notifyListeners();
      }
    } on Object {
      receivedSample = false;
    } finally {
      await updates.cancel();
    }

    if (generation != _generation) return;
    _updates = null;
    _status = receivedSample ? _SyncStatus.idle : _SyncStatus.failed;
    notifyListeners();
  }

  void _clearProgress() {
    offset = null;
    completed = 0;
    total = 0;
    measurements = const [];
  }

  @override
  void dispose() {
    _generation++;
    final updates = _updates;
    _updates = null;
    if (updates != null) unawaited(updates.cancel());
    KronosClock.reset();
    super.dispose();
  }
}
