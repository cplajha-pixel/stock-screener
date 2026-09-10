import 'dart:convert';
import 'dart:ui';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/widgets.dart';

import '../models.dart';
import 'notifications.dart';
import 'saveticker.dart';
import 'settings.dart';

/// 중요 지표 발표 알림: 발표 시각 +1분에 "[속보]" 뉴스에서 실제 수치를 찾아 알림. 없으면 +5분에 다시 확인.
class IndicatorAlerts {
  static const int baseId = 5000; // 알람 ID 5000~5099
  static const String key = 'indicator_events';

  /// 앱 시작·아침 점검 때 호출: 오늘~내일 ★ 이상 이벤트에 알람 등록
  static Future<int> schedule(AppSettings s) async {
    // 기존 알람 취소
    for (var i = 0; i < 100; i++) {
      await AndroidAlarmManager.cancel(baseId + i);
    }
    if (!s.notifyIndicators) {
      await s.setString(key, '{}');
      return 0;
    }
    final events = await SaveTicker.calendar(daysBack: 0, daysFwd: 2);
    final now = DateTime.now();
    final map = <String, dynamic>{};
    var n = 0;
    for (final e in events) {
      if (e.importance < s.indicatorMinStars) continue;
      final t = DateTime.tryParse(e.time); // 한국시간(시간대 없음) → 로컬로 해석
      if (t == null || !t.isAfter(now)) continue;
      if (n >= 100) break;
      final id = baseId + n;
      map['$id'] = {'title': e.title, 'time': e.time, 'stars': e.importance, 'retry': 0};
      await AndroidAlarmManager.oneShotAt(t.add(const Duration(minutes: 1)), id, callback,
          exact: true, wakeup: true, rescheduleOnReboot: true, allowWhileIdle: true);
      n++;
    }
    await s.setString(key, jsonEncode(map));
    return n;
  }

  @pragma('vm:entry-point')
  static Future<void> callback(int id) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    final s = await AppSettings.load();
    Map<String, dynamic> map = {};
    try {
      map = Map<String, dynamic>.from(jsonDecode(s.p.getString(key) ?? '{}') as Map);
    } catch (_) {}
    final ev = map['$id'];
    if (ev == null) return;
    final title = (ev['title'] ?? '').toString();
    final retry = (ev['retry'] ?? 0) as int;
    final hit = await findRelease(title);
    if (hit != null) {
      await Notifier.show(id, '지표 발표: $title', '${hit.title}${hit.summary.isNotEmpty ? '\n${hit.summary}' : ''}', channel: 'indicator');
      map.remove('$id');
      await s.setString(key, jsonEncode(map));
      return;
    }
    if (retry < 1) {
      ev['retry'] = retry + 1;
      map['$id'] = ev;
      await s.setString(key, jsonEncode(map));
      try {
        await AndroidAlarmManager.initialize();
        await AndroidAlarmManager.oneShotAt(DateTime.now().add(const Duration(minutes: 4)), id, callback,
            exact: true, wakeup: true, allowWhileIdle: true);
      } catch (_) {}
      return;
    }
    await Notifier.show(id, '지표 발표 시각 지남: $title', '아직 속보를 찾지 못했습니다. 인사이트 탭 → 주요 뉴스에서 확인하세요.', channel: 'indicator');
    map.remove('$id');
    await s.setString(key, jsonEncode(map));
  }

  static const _stop = {'월', '분기', '연간', '지수', '상승률', '발표', '결과', '전년비', '전월비', '증가율', '변동', '주간', '미국', '미', '유럽', '중국', '일본', '한국', '속보', '최종', '예비', '수정'};
  static const _alias = {
    'CPI': ['CPI', '소비자물가'],
    'PPI': ['PPI', '생산자물가'],
    'PCE': ['PCE', '개인소비지출'],
    '실업수당': ['실업수당', '실업보험'],
    '비농업': ['비농업', '고용', '일자리'],
    '실업률': ['실업률'],
    '소매판매': ['소매판매', '소매'],
    'GDP': ['GDP', '경제성장률', '성장률'],
    'FOMC': ['FOMC', '연준', '금리 결정', '기준금리'],
    'ISM': ['ISM', 'PMI'],
    'PMI': ['PMI'],
    '원유': ['원유 재고', 'EIA', '원유'],
    '소비자심리': ['소비자심리', '소비자신뢰'],
    '주택': ['주택', '건축허가', '착공'],
    '국채': ['국채 입찰', '입찰'],
  };

  static List<String> keywords(String title) {
    final out = <String>{};
    for (final e in _alias.entries) {
      if (title.contains(e.key)) out.addAll(e.value);
    }
    for (final tok in title.replaceAll(RegExp(r'[^\w가-힣 ]'), ' ').split(RegExp(r'\s+'))) {
      final t = tok.trim();
      if (t.length < 2 || _stop.contains(t) || RegExp(r'^\d+월?$').hasMatch(t)) continue;
      out.add(t);
    }
    return out.toList();
  }

  /// 최근 20분 안의 뉴스 중 제목 키워드가 맞는 것
  static Future<NewsItem?> findRelease(String title) async {
    final kws = keywords(title);
    final news = await SaveTicker.latest(n: 30);
    final cutoff = DateTime.now().toUtc().subtract(const Duration(minutes: 25));
    for (final n in news) {
      final t = DateTime.tryParse(n.time)?.toUtc();
      if (t != null && t.isBefore(cutoff)) continue;
      final text = '${n.title} ${n.titleEn}';
      var score = 0;
      for (final k in kws) {
        if (text.toLowerCase().contains(k.toLowerCase())) score++;
      }
      if (score >= (kws.length >= 3 ? 2 : 1)) return n;
    }
    return null;
  }
}
