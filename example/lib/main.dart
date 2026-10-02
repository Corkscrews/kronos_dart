import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:kronos_dart/kronos_dart.dart' hide NtpPool;

import 'example_model.dart';
import 'led_clock.dart';

void main() {
  // ios/Runner/PrivacyInfo.xcprivacy declares the boot-time reason this needs.
  KronosClock.useKernelClock();
  runApp(const KronosExampleApp());
}

class KronosExampleApp extends StatefulWidget {
  const KronosExampleApp({super.key});

  @override
  State<KronosExampleApp> createState() => _KronosExampleAppState();
}

class _KronosExampleAppState extends State<KronosExampleApp> {
  late final ExampleModel model;

  @override
  void initState() {
    super.initState();
    model = ExampleModel();
  }

  @override
  void dispose() {
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Kronos',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: phosphorBackground,
          colorScheme: const ColorScheme.dark(
            primary: phosphorBright,
            secondary: phosphorBright,
            surface: Color(0xFF101510),
          ),
        ),
        home: _ExampleScreen(model: model),
      );
}

class _ExampleScreen extends StatelessWidget {
  const _ExampleScreen({required this.model});

  final ExampleModel model;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS): model.sync,
          const SingleActivator(LogicalKeyboardKey.keyR): model.reset,
        },
        child: Focus(
          autofocus: true,
          child: AnimatedBuilder(
            animation: model,
            builder: (context, _) => Scaffold(
              body: SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: ListView(
                      padding: const EdgeInsets.all(20),
                      children: [
                        const _Header(),
                        const SizedBox(height: 20),
                        _LiveTimeSection(model: model),
                        if (model.measurements.isNotEmpty) ...[
                          const SizedBox(height: 20),
                          _MeasurementList(measurements: model.measurements),
                        ],
                        const SizedBox(height: 20),
                        _Controls(model: model),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) => const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Kronos',
              style: TextStyle(
                  color: phosphorBright,
                  fontSize: 22,
                  fontWeight: FontWeight.w600)),
          SizedBox(height: 4),
          Text('Monotonic NTP clock', style: TextStyle(color: Colors.white70)),
        ],
      );
}

class _LiveTimeSection extends StatefulWidget {
  const _LiveTimeSection({required this.model});

  final ExampleModel model;

  @override
  State<_LiveTimeSection> createState() => _LiveTimeSectionState();
}

class _LiveTimeSectionState extends State<_LiveTimeSection> {
  late final Timer timer;
  DateTime deviceDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (mounted) setState(() => deviceDate = DateTime.now());
    });
  }

  @override
  void dispose() {
    timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final annotated = KronosClock.annotatedNow;
    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final horizontal = constraints.maxWidth >= 580;
            final ntp = _ClockPanel(
              title: annotated != null
                  ? 'NTP date'
                  : model.isSyncing
                      ? 'Syncing'
                      : "Not sync'ed",
              date: annotated?.date,
              lit: annotated != null,
            );
            final system =
                _ClockPanel(title: 'Clock date', date: deviceDate, lit: true);
            if (horizontal) {
              return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: ntp),
                    const SizedBox(width: 16),
                    Expanded(child: system),
                  ]);
            }
            return Column(children: [ntp, const SizedBox(height: 16), system]);
          },
        ),
        const SizedBox(height: 16),
        _Metrics(model: model, annotated: annotated),
      ],
    );
  }
}

class _ClockPanel extends StatelessWidget {
  const _ClockPanel(
      {required this.title, required this.date, required this.lit});

  final String title;
  final DateTime? date;
  final bool lit;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: phosphorBright.withValues(alpha: 0.28)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    color: phosphorBright.withValues(alpha: 0.9),
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            RepaintBoundary(child: LedClock(date: date, lit: lit)),
            const SizedBox(height: 10),
            Text(_clockStamp(date),
                style: const TextStyle(
                    color: Colors.white54,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ],
        ),
      );
}

class _Metrics extends StatelessWidget {
  const _Metrics({required this.model, required this.annotated});

  final ExampleModel model;
  final AnnotatedTime? annotated;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          children: [
            _MetricRow(
                'Offset',
                annotated == null || model.offset == null
                    ? '—'
                    : _milliseconds(model.offset, signed: true)),
            _MetricRow('Uncertainty', _milliseconds(annotated?.uncertainty)),
            _MetricRow('Best RTT', _milliseconds(model.bestRoundTrip)),
            if (KronosClock.calibration.mode == ClockMode.kernel)
              _MetricRow('Kernel − Flutter', _microseconds(_kernelDrift())),
            _MetricRow('Since sync', _seconds(annotated?.timeSinceLastNtpSync)),
            if (model.total > 0)
              _MetricRow('Attempts', '${model.completed} / ${model.total}'),
          ],
        ),
      );
}

class _MetricRow extends StatelessWidget {
  const _MetricRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Text(label, style: const TextStyle(color: Colors.white60)),
            const Spacer(),
            Text(value,
                style: const TextStyle(
                    color: phosphorBright,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ],
        ),
      );
}

class _Controls extends StatelessWidget {
  const _Controls({required this.model});

  final ExampleModel model;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Pool', style: TextStyle(color: Colors.white60)),
              const Spacer(),
              DropdownButton<NtpPool>(
                value: model.pool,
                underline: const SizedBox.shrink(),
                dropdownColor: const Color(0xFF101510),
                style: const TextStyle(color: phosphorBright),
                items: [
                  for (final pool in NtpPool.values)
                    DropdownMenuItem(value: pool, child: Text(pool.hostname))
                ],
                onChanged: (pool) {
                  if (pool != null) model.select(pool);
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _SyncButton(model: model)),
              const SizedBox(width: 12),
              Expanded(
                  child: OutlinedButton(
                      onPressed: model.reset, child: const Text('Reset'))),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'S syncs with ${model.pool.hostname}. Choosing another pool syncs again. NTP time keeps counting if the device clock changes.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.white60),
          ),
          if (model.didFail) ...[
            const SizedBox(height: 8),
            Text(
              'No response from ${model.pool.hostname}. Check the simulator network, then sync again.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.orangeAccent),
            ),
          ],
        ],
      );
}

class _SyncButton extends StatelessWidget {
  const _SyncButton({required this.model});

  final ExampleModel model;

  @override
  Widget build(BuildContext context) => FilledButton(
        onPressed: model.isSyncing ? null : model.sync,
        style: FilledButton.styleFrom(
          backgroundColor: phosphorBright,
          foregroundColor: Colors.black,
          disabledBackgroundColor: phosphorBright.withValues(alpha: 0.65),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(vertical: 13),
        ),
        child: model.isSyncing
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.black))
            : const Text('Sync'),
      );
}

class _MeasurementList extends StatefulWidget {
  const _MeasurementList({required this.measurements});

  final List<NtpMeasurement> measurements;

  @override
  State<_MeasurementList> createState() => _MeasurementListState();
}

class _MeasurementListState extends State<_MeasurementList> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: phosphorBright.withValues(alpha: 0.28)),
        ),
        child: Column(
          children: [
            InkWell(
              onTap: () => setState(() => expanded = !expanded),
              child: Row(
                children: [
                  const Text('Measurements',
                      style: TextStyle(
                          color: phosphorBright, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('${widget.measurements.length}',
                      style: const TextStyle(color: Colors.white60)),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: expanded ? 0.25 : 0,
                    duration: const Duration(milliseconds: 200),
                    child:
                        const Icon(Icons.chevron_right, color: phosphorBright),
                  ),
                ],
              ),
            ),
            if (expanded) ...[
              const SizedBox(height: 12),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    'Each row is one reply. Kronos keeps the lowest round trip from each server.',
                    style: TextStyle(color: Colors.white60)),
              ),
              const SizedBox(height: 8),
              for (final measurement in widget.measurements)
                _MeasurementRow(
                  measurement: measurement,
                  queued: _isQueued(measurement, widget.measurements),
                ),
            ],
          ],
        ),
      );
}

class _MeasurementRow extends StatelessWidget {
  const _MeasurementRow({required this.measurement, required this.queued});

  final NtpMeasurement measurement;
  final bool queued;

  @override
  Widget build(BuildContext context) {
    final color = queued
        ? Colors.orangeAccent
        : phosphorBright.withValues(alpha: measurement.selected ? 1 : 0.6);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                  child: Text(measurement.server,
                      style: TextStyle(
                          color: phosphorBright, fontFamily: 'monospace'))),
              const SizedBox(width: 8),
              Text('stratum ${measurement.stratum}',
                  style: const TextStyle(color: Colors.white60, fontSize: 12)),
              const Spacer(),
              if (measurement.selected)
                const Text('lowest RTT',
                    style: TextStyle(
                        color: phosphorBright,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${_milliseconds(measurement.offset, signed: true)}   ${_milliseconds(measurement.roundTripDelay)} RTT   ${_milliseconds(measurement.dispersion)} dispersion',
            style: TextStyle(
                color: color,
                fontSize: 12,
                fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );
  }
}

bool _isQueued(NtpMeasurement item, List<NtpMeasurement> values) {
  if (item.selected) return false;
  NtpMeasurement? kept;
  for (final candidate in values) {
    if (candidate.selected && candidate.server == item.server) {
      kept = candidate;
      break;
    }
  }
  return kept != null && item.roundTripDelay > kept.roundTripDelay + 0.05;
}

String _milliseconds(double? value, {bool signed = false}) {
  if (value == null) return '—';
  final number = (value * 1000).toStringAsFixed(1);
  return signed && value >= 0 ? '+$number ms' : '$number ms';
}

/// Kernel timescale (`CLOCK_MONOTONIC_RAW + C`) minus Flutter's `DateTime.now()`.
double _kernelDrift() {
  final flutter = DateTime.now().microsecondsSinceEpoch / 1e6;
  return ClockSource.process.sample().timestamp - flutter;
}

String _microseconds(double value) {
  final number = (value * 1e6).toStringAsFixed(1);
  return value >= 0 ? '+$number µs' : '$number µs';
}

String _seconds(double? value) =>
    value == null ? '—' : '${value.toStringAsFixed(1)} s';

String _clockStamp(DateTime? value) {
  if (value == null) return '—';
  final date = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  String three(int number) => number.toString().padLeft(3, '0');
  final zone = date.timeZoneName;
  return '${date.year}-${two(date.month)}-${two(date.day)}  ${two(date.hour)}:${two(date.minute)}:${two(date.second)}.${three(date.millisecond)} $zone';
}
