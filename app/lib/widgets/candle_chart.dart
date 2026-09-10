import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/yahoo.dart';

/// 일봉 캔들 + SMA10/20/50/200 + 트리거가/손절가/목표가 선 (위젯이 안 될 때의 대체 차트)
class CandleChart extends StatelessWidget {
  final List<Candle> candles;
  final double? trigger, stop, target;
  final int bars;

  const CandleChart({super.key, required this.candles, this.trigger, this.stop, this.target, this.bars = 120});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        Expanded(
          child: CustomPaint(
            size: Size.infinite,
            painter: _Painter(candles, trigger, stop, target, bars, dark),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Wrap(spacing: 12, children: [
            _legend('SMA10', Colors.purple),
            _legend('SMA20', Colors.orange),
            _legend('SMA50', Colors.green),
            _legend('SMA200', Colors.blueGrey),
            if (trigger != null) _legend('진입/트리거', Colors.amber),
            if (stop != null) _legend('손절', Colors.blue),
            if (target != null) _legend('목표', Colors.red),
          ]),
        ),
      ],
    );
  }

  Widget _legend(String t, Color c) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 3, color: c),
        const SizedBox(width: 3),
        Text(t, style: const TextStyle(fontSize: 10)),
      ]);
}

class _Painter extends CustomPainter {
  final List<Candle> all;
  final double? trigger, stop, target;
  final int bars;
  final bool dark;
  _Painter(this.all, this.trigger, this.stop, this.target, this.bars, this.dark);

  @override
  void paint(Canvas canvas, Size size) {
    if (all.isEmpty) return;
    final s10 = Yahoo.smaSeries(all, 10), s20 = Yahoo.smaSeries(all, 20), s50 = Yahoo.smaSeries(all, 50), s200 = Yahoo.smaSeries(all, 200);
    final start = math.max(0, all.length - bars);
    final c = all.sublist(start);
    const left = 4.0, right = 52.0, top = 8.0, bottom = 18.0;
    final w = size.width - left - right, h = size.height - top - bottom;
    if (w <= 0 || h <= 0) return;
    double lo = double.infinity, hi = -double.infinity;
    for (final k in c) {
      lo = math.min(lo, k.low);
      hi = math.max(hi, k.high);
    }
    for (final v in [trigger, stop, target]) {
      if (v != null && v > 0) {
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
    }
    for (final series in [s10, s20, s50, s200]) {
      for (var i = start; i < all.length; i++) {
        final v = series[i];
        if (v != null) {
          lo = math.min(lo, v);
          hi = math.max(hi, v);
        }
      }
    }
    if (hi <= lo) hi = lo + 1;
    final pad = (hi - lo) * 0.04;
    lo -= pad;
    hi += pad;
    double y(double v) => top + (hi - v) / (hi - lo) * h;
    final bw = w / c.length;

    // 격자 + 가격 라벨
    final grid = Paint()
      ..color = (dark ? Colors.white : Colors.black).withValues(alpha: 0.08)
      ..strokeWidth = 1;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i <= 4; i++) {
      final v = lo + (hi - lo) * i / 4;
      final yy = y(v);
      canvas.drawLine(Offset(left, yy), Offset(left + w, yy), grid);
      tp.text = TextSpan(text: v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(2), style: TextStyle(fontSize: 10, color: dark ? Colors.white70 : Colors.black54));
      tp.layout();
      tp.paint(canvas, Offset(left + w + 4, yy - 6));
    }
    // 날짜 라벨
    for (var i = 0; i < c.length; i += math.max(1, c.length ~/ 4)) {
      final d = c[i].date;
      tp.text = TextSpan(text: '${d.month}/${d.day}', style: TextStyle(fontSize: 10, color: dark ? Colors.white70 : Colors.black54));
      tp.layout();
      tp.paint(canvas, Offset(left + i * bw, top + h + 3));
    }

    // 캔들
    final up = Paint()..color = Colors.red.shade400;
    final down = Paint()..color = Colors.blue.shade400;
    for (var i = 0; i < c.length; i++) {
      final k = c[i];
      final x = left + i * bw + bw / 2;
      final p = k.close >= k.open ? up : down;
      p.strokeWidth = 1;
      canvas.drawLine(Offset(x, y(k.high)), Offset(x, y(k.low)), p);
      final bodyTop = y(math.max(k.open, k.close)), bodyBot = y(math.min(k.open, k.close));
      canvas.drawRect(Rect.fromLTRB(x - bw * 0.35, bodyTop, x + bw * 0.35, math.max(bodyBot, bodyTop + 1)), p);
    }

    // 이동평균
    void line(List<double?> series, Color color) {
      final path = Path();
      var started = false;
      for (var i = 0; i < c.length; i++) {
        final v = series[start + i];
        if (v == null) continue;
        final x = left + i * bw + bw / 2;
        if (!started) {
          path.moveTo(x, y(v));
          started = true;
        } else {
          path.lineTo(x, y(v));
        }
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2);
    }

    line(s10, Colors.purple);
    line(s20, Colors.orange);
    line(s50, Colors.green);
    line(s200, Colors.blueGrey);

    // 기준선
    void hline(double? v, Color color, String label) {
      if (v == null || v <= 0) return;
      final yy = y(v);
      final p = Paint()
        ..color = color
        ..strokeWidth = 1.2;
      for (var x = left; x < left + w; x += 8) {
        canvas.drawLine(Offset(x, yy), Offset(x + 4, yy), p);
      }
      tp.text = TextSpan(text: '$label ${v >= 100 ? v.toStringAsFixed(1) : v.toStringAsFixed(2)}', style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.bold));
      tp.layout();
      tp.paint(canvas, Offset(left + 2, yy - 12));
    }

    hline(trigger, Colors.amber.shade700, '진입');
    hline(stop, Colors.blue, '손절');
    hline(target, Colors.red, '목표');
  }

  @override
  bool shouldRepaint(covariant _Painter old) =>
      old.all != all || old.trigger != trigger || old.stop != stop || old.target != target || old.dark != dark;
}
