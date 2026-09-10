import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'yahoo.dart';

/// 보유 종목 저장 (폰에만, shared_preferences)
class HoldingsStore {
  final SharedPreferences p;
  HoldingsStore(this.p);

  static Future<HoldingsStore> load() async => HoldingsStore(await SharedPreferences.getInstance());

  List<Holding> all() {
    final s = p.getString('holdings');
    if (s == null || s.isEmpty) return [];
    try {
      return (jsonDecode(s) as List).map((e) => Holding.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveAll(List<Holding> list) => p.setString('holdings', jsonEncode(list.map((e) => e.toJson()).toList()));

  Future<void> upsert(Holding h) async {
    final list = all();
    final i = list.indexWhere((e) => e.id == h.id);
    if (i >= 0) {
      list[i] = h;
    } else {
      list.add(h);
    }
    await saveAll(list);
  }

  Future<void> remove(String id) async {
    final list = all()..removeWhere((e) => e.id == id);
    await saveAll(list);
  }
}

/// 보유 종목 신호
class HoldingSignal {
  final Holding h;
  final List<String> alerts;
  final double? last, sma10, sma20, sma50, sma200;
  final int daysHeld;
  final int? rank;
  final int belowSma200Days;
  final String? error;
  final double? pnlPct;

  HoldingSignal(this.h,
      {this.alerts = const [],
      this.last,
      this.sma10,
      this.sma20,
      this.sma50,
      this.sma200,
      this.daysHeld = 0,
      this.rank,
      this.belowSma200Days = 0,
      this.error,
      this.pnlPct});

  bool get hasAlert => alerts.isNotEmpty;
}

class SignalEngine {
  /// 단기/중기/장기 규칙대로 신호를 계산한다. longFile 은 장기 순위 확인용 (없으면 순위 신호 생략).
  static Future<HoldingSignal> evaluate(Holding h, {LongFile? longFile}) async {
    List<Candle> c;
    try {
      c = await Yahoo.daily(Yahoo.yahooSymbol(h.ticker, h.market), range: '1y');
    } catch (e) {
      return HoldingSignal(h, error: '시세 조회 실패: $e');
    }
    if (c.isEmpty) return HoldingSignal(h, error: '시세 없음');
    final last = c.last.close;
    final sma10 = Yahoo.sma(c, 10), sma20 = Yahoo.sma(c, 20), sma50 = Yahoo.sma(c, 50), sma200 = Yahoo.sma(c, 200);
    final days = Yahoo.tradingDaysSince(c, h.entryDate);
    final alerts = <String>[];
    final pnl = h.entryPrice > 0 ? (last / h.entryPrice - 1) * 100 : null;
    final stop = h.stopPrice;

    if (h.horizon == 'short') {
      if (stop != null && last <= stop) alerts.add('손절 도달 (현재가 ≤ ${_f(stop)})');
      if (!h.partialDone && days >= 3) alerts.add('3거래일째: 절반 매도, 남은 물량 손절가를 진입가로');
      if (sma10 != null && last < sma10) alerts.add('SMA10 이탈 → 전량 청산');
      if (days > 60) alerts.add('60거래일 초과 → 청산');
    } else if (h.horizon == 'mid') {
      if (stop != null && last <= stop) alerts.add('손절 도달 (현재가 ≤ ${_f(stop)})');
      if (stop != null && !h.partialDone) {
        final target = h.entryPrice + 2 * (h.entryPrice - stop);
        if (last >= target) alerts.add('+2R 도달 (${_f(target)}) → 절반 매도');
      }
      if (sma50 != null && last < sma50) alerts.add('SMA50 이탈 → 전량 청산');
      if (days > 120) alerts.add('120거래일 초과 → 청산');
    } else {
      // 장기: SMA200 아래 10거래일 연속 / 순위 10위 밖
      final s200 = Yahoo.smaSeries(c, 200);
      var below = 0;
      for (var i = c.length - 1; i >= 0; i--) {
        final s = s200[i];
        if (s == null || c[i].close >= s) break;
        below++;
      }
      if (below >= 10) alerts.add('SMA200 아래 $below거래일 → 교체 후보');
      int? rank;
      if (longFile != null) {
        rank = longFile.rankOf(h.ticker);
        if (rank == null || rank > 10) alerts.add(rank == null ? '장기 순위 밖 → 교체 후보' : '순위 $rank위 (10위 밖) → 교체 후보');
      }
      return HoldingSignal(h,
          alerts: alerts,
          last: last,
          sma10: sma10,
          sma20: sma20,
          sma50: sma50,
          sma200: sma200,
          daysHeld: days,
          rank: rank,
          belowSma200Days: below,
          pnlPct: pnl);
    }
    return HoldingSignal(h,
        alerts: alerts, last: last, sma10: sma10, sma20: sma20, sma50: sma50, sma200: sma200, daysHeld: days, pnlPct: pnl);
  }

  static String _f(double v) => v >= 100 ? v.toStringAsFixed(1) : v.toStringAsFixed(2);
}
