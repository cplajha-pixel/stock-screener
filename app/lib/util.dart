import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// 리스크 기반 수량: floor(자산 x 리스크% / (진입가 - 손절가)), 한 종목 최대 비중 제한, 정수 주
int suggestQty(double? entry, double? stop, double capital, double riskPct, double maxPosPct) {
  if (entry == null || stop == null || entry <= 0 || entry <= stop) return 0;
  final q = (capital * riskPct / 100 / (entry - stop)).floor();
  final cap = (capital * maxPosPct / 100 / entry).floor();
  final r = q < cap ? q : cap;
  return r < 0 ? 0 : r;
}

String fmtPrice(double? v, {String market = 'us'}) {
  if (v == null) return '-';
  if (market == 'kr') return NumberFormat('#,###').format(v);
  return v >= 1000 ? NumberFormat('#,##0.0').format(v) : v.toStringAsFixed(2);
}

String fmtPct(double? v, {int digits = 1, bool sign = true}) {
  if (v == null) return '-';
  final s = v.toStringAsFixed(digits);
  final plus = sign && v > 0 ? '+' : '';
  return '$plus$s%';
}

String fmtMoney(double v, String market) {
  if (market == 'kr') return '${NumberFormat('#,###').format(v)}원';
  return '\$${NumberFormat('#,##0').format(v)}';
}

String fmtKrw(double v) => '${NumberFormat('#,###').format(v)}원';

String fmtBig(double? v) {
  if (v == null) return '-';
  if (v >= 1e9) return '${(v / 1e9).toStringAsFixed(1)}B';
  if (v >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
  if (v >= 1e3) return '${(v / 1e3).toStringAsFixed(0)}K';
  return v.toStringAsFixed(0);
}

/// generated_at (UTC ISO) → 로컬 "MM/dd HH:mm"
String fmtUpdated(String iso) {
  if (iso.isEmpty) return '';
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return DateFormat('MM/dd HH:mm').format(d.toLocal());
}

Color pctColor(double? v, BuildContext context) {
  if (v == null) return Theme.of(context).colorScheme.onSurface;
  if (v > 0) return Colors.red.shade400;
  if (v < 0) return Colors.blue.shade400;
  return Theme.of(context).colorScheme.onSurface;
}

/// TradingView 심볼 (거래소 접두어)
String tradingViewSymbol(String ticker, String exchange, String market) {
  if (market == 'kr') return 'KRX:${ticker.replaceAll(RegExp(r'\.(KS|KQ)$'), '')}';
  final t = ticker.replaceAll('-', '.');
  switch (exchange.toUpperCase()) {
    case 'NASDAQ':
      return 'NASDAQ:$t';
    case 'NYSE':
      return 'NYSE:$t';
    case 'NYSE AMERICAN':
    case 'AMEX':
      return 'AMEX:$t';
  }
  return t;
}

Widget kv(String k, String v, {Color? color, bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$k ', style: const TextStyle(fontSize: 12, color: Colors.grey)),
          Text(v, style: TextStyle(fontSize: 13, color: color, fontWeight: bold ? FontWeight.bold : null)),
        ],
      ),
    );
