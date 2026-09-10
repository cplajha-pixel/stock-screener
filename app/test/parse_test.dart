import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stock_screener/models.dart';
import 'package:stock_screener/util.dart';
import 'package:stock_screener/widgets/evidence.dart';

Map<String, dynamic> _load(String name) {
  final f = File('../output/$name');
  if (!f.existsSync()) return {};
  return Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map);
}

void main() {
  test('us_short.json 파싱', () {
    final j = _load('us_short.json');
    if (j.isEmpty) return;
    final f = ScreenerFile<ShortItem>(j, ShortItem.fromJson);
    expect(f.date.isNotEmpty, true);
    expect(f.items.length, f.count);
    expect(f.items.where((e) => e.isPick).length <= 1, true);
    for (final it in f.items) {
      expect(it.ticker.isNotEmpty, true);
      expect(it.triggerPrice, isNotNull);
      expect(it.stopPrice, isNotNull);
      expect(it.stopPrice! < it.triggerPrice!, true);
      expect(suggestQty(it.triggerPrice, it.stopPrice, 700, 5, 50), it.qty);
      expect(shortReasons(it).length >= 5, true);
    }
  });

  test('us_mid.json 파싱', () {
    final j = _load('us_mid.json');
    if (j.isEmpty) return;
    final f = ScreenerFile<MidItem>(j, MidItem.fromJson);
    expect(f.items.length, f.count);
    for (final it in f.items) {
      expect(it.entryPrice, isNotNull);
      expect(it.target2r! > it.entryPrice!, true);
      expect(suggestQty(it.entryPrice, it.stopPrice, 3500, 2, 30), it.qty);
      expect(midReasons(it).length, 6);
    }
  });

  test('us_long.json 파싱', () {
    final j = _load('us_long.json');
    if (j.isEmpty) return;
    final f = LongFile.fromJson(j);
    expect(f.candidates.isNotEmpty, true);
    expect(f.candidates.where((c) => c.hold).length, f.holdN);
    expect(f.rankOf(f.candidates.first.ticker), 1);
    expect(f.candidates.first.passed.contains('trend'), true);
    expect(longReasons(f.candidates.first).length, 6);
  });

  test('us_insight.json 파싱', () {
    final j = _load('us_insight.json');
    if (j.isEmpty) return;
    final f = InsightFile.fromJson(j);
    expect(f.signal == '지금 투입' || f.signal == '3개월 분할 투입', true);
    expect(f.sectors.length, 11);
    expect(f.close, isNotNull);
  });

  test('us_short_ep.json 파싱', () {
    final j = _load('us_short_ep.json');
    if (j.isEmpty) return;
    final f = ScreenerFile<ShortItem>(j, ShortItem.fromJson);
    expect(f.items.length, f.count);
  });

  test('us_context.json 파싱', () {
    final j = _load('us_context.json');
    if (j.isEmpty) return;
    final f = ContextFile.fromJson(j);
    expect(f.items.isNotEmpty, true);
    final c = f.items.values.first;
    expect(c.healthItems.length, 7);
    expect(c.analyst.containsKey('recommendation'), true);
  });

  test('us_daily.json 파싱', () {
    final j = _load('us_daily.json');
    if (j.isEmpty) return;
    final f = DailyFile.fromJson(j);
    expect(f.macro.length >= 8, true);
    expect(f.explain.isNotEmpty, true);
    expect(f.calendar.isNotEmpty, true);
  });

  test('us_picks.json 파싱', () {
    final j = _load('us_picks.json');
    if (j.isEmpty) return;
    final f = PicksFile.fromJson(j);
    expect(f.picks.isNotEmpty, true);
    expect(f.summary.containsKey('total'), true);
  });

  test('보유 종목 직렬화', () {
    final h = Holding(id: '1', ticker: 'AAPL', horizon: 'short', entryPrice: 100, entryDate: '2026-09-01', qty: 3, stopPrice: 95);
    final back = Holding.fromJson(jsonDecode(jsonEncode(h.toJson())) as Map<String, dynamic>);
    expect(back.ticker, 'AAPL');
    expect(back.stopPrice, 95);
    expect(back.market, 'us');
  });
}
