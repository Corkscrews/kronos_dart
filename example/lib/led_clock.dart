import 'package:flutter/material.dart';

const phosphorBright = Color(0xFF78FF8F);
const phosphorDim = Color(0xFF29522E);
const phosphorOff = Color(0xFF0D1510);
const phosphorBackground = Color(0xFF030503);

class LedClock extends StatelessWidget {
  const LedClock({super.key, required this.date, this.lit = true});

  final DateTime? date;
  final bool lit;

  @override
  Widget build(BuildContext context) {
    final local = date?.toLocal();
    final color = lit ? phosphorBright : phosphorDim;
    return FittedBox(
      alignment: Alignment.centerLeft,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _pair(local?.hour ?? 0, lit),
          _Colon(second: local?.second ?? 0, lit: lit),
          _pair(local?.minute ?? 0, lit),
          _Colon(second: local?.second ?? 0, lit: lit),
          _pair(local?.second ?? 0, lit),
          const SizedBox(width: 7),
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 3),
          _Digit((local?.millisecond ?? 0) ~/ 100,
              width: 15, height: 27, lit: lit),
          const SizedBox(width: 2),
          _Digit(((local?.millisecond ?? 0) ~/ 10) % 10,
              width: 15, height: 27, lit: lit),
          const SizedBox(width: 2),
          _Digit((local?.millisecond ?? 0) % 10,
              width: 15, height: 27, lit: lit),
        ],
      ),
    );
  }

  Widget _pair(int value, bool lit) => Row(
        children: [
          _Digit(value ~/ 10, width: 27, height: 48, lit: lit),
          const SizedBox(width: 3),
          _Digit(value % 10, width: 27, height: 48, lit: lit),
        ],
      );
}

class _Colon extends StatelessWidget {
  const _Colon({required this.second, required this.lit});

  final int second;
  final bool lit;

  @override
  Widget build(BuildContext context) {
    final color = lit && second.isEven ? phosphorBright : phosphorOff;
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _dot(color),
            const SizedBox(height: 9),
            _dot(color),
          ],
        ),
      ),
    );
  }

  Widget _dot(Color color) => Container(
        width: 5,
        height: 5,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

class _Digit extends StatelessWidget {
  const _Digit(this.value,
      {required this.width, required this.height, required this.lit});

  final int value;
  final double width;
  final double height;
  final bool lit;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(width, height),
        painter: _DigitPainter(value: value, lit: lit),
      );
}

class _DigitPainter extends CustomPainter {
  const _DigitPainter({required this.value, required this.lit});

  final int value;
  final bool lit;

  static const _masks = [
    0x3f,
    0x06,
    0x5b,
    0x4f,
    0x66,
    0x6d,
    0x7d,
    0x07,
    0x7f,
    0x6f,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final thickness = size.width * 0.18;
    final half = size.height / 2;
    final span = size.width - thickness * 2;
    final leg = half - thickness * 1.35;
    final upper = thickness * 0.8;
    final lower = half + thickness * 0.45;
    final segments = <Rect>[
      Rect.fromLTWH(thickness, 0, span, thickness),
      Rect.fromLTWH(size.width - thickness, upper, thickness, leg),
      Rect.fromLTWH(size.width - thickness, lower, thickness, leg),
      Rect.fromLTWH(thickness, size.height - thickness, span, thickness),
      Rect.fromLTWH(0, lower, thickness, leg),
      Rect.fromLTWH(0, upper, thickness, leg),
      Rect.fromLTWH(thickness, half - thickness / 2, span, thickness),
    ];
    final mask = _masks[value.clamp(0, 9).toInt()];
    for (var index = 0; index < segments.length; index++) {
      final rect = segments[index];
      final paint = Paint()
        ..color = (mask & (1 << index)) != 0
            ? (lit ? phosphorBright : phosphorDim)
            : phosphorOff;
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(rect.shortestSide / 2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DigitPainter oldDelegate) =>
      oldDelegate.lit != lit || oldDelegate.value != value;
}
