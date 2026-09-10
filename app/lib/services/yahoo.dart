import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';

/// Yahoo chart API (공개 엔드포인트) 로 일봉을 받는다.
class Yahoo {
  static const _headers = {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
    'Accept': 'application/json',
  };

  static String yahooSymbol(String ticker, String market) {
    if (market == 'kr' && !ticker.contains('.')) return '$ticker.KS';
    return ticker;
  }

  static Future<List<Candle>> daily(String symbol, {String range = '1y'}) async {
    final url = 'https://query1.finance.yahoo.com/v8/finance/chart/${Uri.encodeComponent(symbol)}'
        '?range=$range&interval=1d&includePrePost=false&events=div%2Csplit';
    final r = await http.get(Uri.parse(url), headers: _headers).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('Yahoo HTTP ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final result = (j['chart']?['result'] as List?)?.firstOrNull;
    if (result == null) throw Exception('Yahoo: 데이터 없음');
    final ts = (result['timestamp'] as List?) ?? const [];
    final q = (result['indicators']?['quote'] as List?)?.firstOrNull as Map<String, dynamic>?;
    if (q == null) throw Exception('Yahoo: quote 없음');
    final adj = ((result['indicators']?['adjclose'] as List?)?.firstOrNull as Map<String, dynamic>?)?['adjclose'] as List?;
    final out = <Candle>[];
    for (var i = 0; i < ts.length; i++) {
      final o = q['open'][i], h = q['high'][i], l = q['low'][i], c = q['close'][i], v = q['volume'][i];
      if (o == null || h == null || l == null || c == null) continue;
      double factor = 1.0;
      if (adj != null && adj.length > i && adj[i] != null && (c as num) != 0) {
        factor = (adj[i] as num) / c;
      }
      out.add(Candle(
        DateTime.fromMillisecondsSinceEpoch((ts[i] as num).toInt() * 1000, isUtc: true),
        (o as num).toDouble() * factor,
        (h as num).toDouble() * factor,
        (l as num).toDouble() * factor,
        (c as num).toDouble() * factor,
        ((v ?? 0) as num).toDouble(),
      ));
    }
    return out;
  }

  static double? sma(List<Candle> c, int n, [int? endIndex]) {
    final end = endIndex ?? c.length - 1;
    if (end + 1 < n || end < 0) return null;
    double s = 0;
    for (var i = end - n + 1; i <= end; i++) {
      s += c[i].close;
    }
    return s / n;
  }

  static List<double?> smaSeries(List<Candle> c, int n) {
    final out = List<double?>.filled(c.length, null);
    double s = 0;
    for (var i = 0; i < c.length; i++) {
      s += c[i].close;
      if (i >= n) s -= c[i - n].close;
      if (i >= n - 1) out[i] = s / n;
    }
    return out;
  }

  /// entryDate(yyyy-MM-dd) 이후 거래일 수 (진입일 = 0)
  static int tradingDaysSince(List<Candle> c, String entryDate) {
    final d = DateTime.tryParse(entryDate);
    if (d == null) return 0;
    var n = 0;
    for (final k in c) {
      final kd = DateTime.utc(k.date.year, k.date.month, k.date.day);
      if (kd.isAfter(DateTime.utc(d.year, d.month, d.day))) n++;
    }
    return n;
  }
}
