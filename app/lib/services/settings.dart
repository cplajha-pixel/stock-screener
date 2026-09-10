import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 결과 파일 기본 주소 (GitHub raw). 설정 화면의 "고급"에서 바꿀 수 있음.
const String kDefaultBaseUrl = 'https://raw.githubusercontent.com/cplajha-pixel/stock-screener/main/output';

class AppSettings {
  final SharedPreferences p;
  AppSettings(this.p);

  static Future<AppSettings> load() async => AppSettings(await SharedPreferences.getInstance());

  // ---- 데이터 주소
  String get baseUrl => (p.getString('baseUrl') ?? '').trim().isEmpty ? kDefaultBaseUrl : p.getString('baseUrl')!.trim();
  Future<void> setBaseUrl(String v) => p.setString('baseUrl', v.trim());

  // ---- 자금 (미국: USD, 국내: KRW)
  double get usShortCapital => p.getDouble('usShortCapital') ?? 700;
  double get usMidCapital => p.getDouble('usMidCapital') ?? 3500;
  double get usLongCapital => p.getDouble('usLongCapital') ?? 3600; // ≈ 500만 원
  double get krShortCapital => p.getDouble('krShortCapital') ?? 1000000;
  double get krMidCapital => p.getDouble('krMidCapital') ?? 5000000;
  double get krLongCapital => p.getDouble('krLongCapital') ?? 5000000;
  Future<void> setCapital(String key, double v) => p.setDouble(key, v);

  double capital(String market, String horizon) {
    if (market == 'kr') {
      return horizon == 'short' ? krShortCapital : (horizon == 'mid' ? krMidCapital : krLongCapital);
    }
    return horizon == 'short' ? usShortCapital : (horizon == 'mid' ? usMidCapital : usLongCapital);
  }

  // ---- 비중/종목 수
  double get maxPositionPct => p.getDouble('maxPositionPct') ?? 50;
  Future<void> setMaxPositionPct(double v) => p.setDouble('maxPositionPct', v);
  int get maxPositionsShort => p.getInt('maxPositionsShort') ?? 3;
  int get maxPositionsMid => p.getInt('maxPositionsMid') ?? 5;
  Future<void> setMaxPositions(String key, int v) => p.setInt(key, v);

  // ---- 목표/현재 자산 (원)
  double get targetAssetKrw => p.getDouble('targetAssetKrw') ?? 10000000;
  double get currentAssetKrw => p.getDouble('currentAssetKrw') ?? 0; // 0 = 자동(자금 합계)
  double get fxRate => p.getDouble('fxRate') ?? 1400;
  Future<void> setDouble(String key, double v) => p.setDouble(key, v);

  double get currentAssetAuto =>
      (usShortCapital + usMidCapital + usLongCapital) * fxRate + krShortCapital + krMidCapital + krLongCapital;
  double get currentAssetEffective => currentAssetKrw > 0 ? currentAssetKrw : currentAssetAuto;

  // ---- 알림
  bool get notifyMorning => p.getBool('notifyMorning') ?? true;
  bool get notifyEp => p.getBool('notifyEp') ?? true;
  int get morningHour => p.getInt('morningHour') ?? 7;
  int get morningMinute => p.getInt('morningMinute') ?? 0;
  int get krHour => p.getInt('krHour') ?? 16;
  int get krMinute => p.getInt('krMinute') ?? 0;
  Future<void> setBool(String key, bool v) => p.setBool(key, v);
  Future<void> setInt(String key, int v) => p.setInt(key, v);

  // ---- 주문 가정
  double get slippagePct => p.getDouble('slippagePct') ?? 0.5; // 손절 시장가 체결 가정 (%)
  bool get notifyIndicators => p.getBool('notifyIndicators') ?? true;
  int get indicatorMinStars => p.getInt('indicatorMinStars') ?? 3;

  // ---- 증권사 앱
  String get brokerPackage => p.getString('brokerPackage') ?? '';
  Future<void> setBrokerPackage(String v) => p.setString('brokerPackage', v.trim());

  // ---- 기타
  bool get setupDone => p.getBool('setupDone') ?? false;
  String get lastInsightSignal => p.getString('lastInsightSignal') ?? '';
  String get lastLongDate => p.getString('lastLongDate') ?? '';
  String get lastEpDate => p.getString('lastEpDate') ?? '';
  Future<void> setString(String key, String v) => p.setString(key, v);

  // ---- 결과 캐시 (오프라인 표시용)
  Map<String, dynamic>? cachedJson(String name) {
    final s = p.getString('cache:$name');
    if (s == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(s) as Map);
    } catch (_) {
      return null;
    }
  }

  Future<void> setCachedJson(String name, String body) => p.setString('cache:$name', body);
}
