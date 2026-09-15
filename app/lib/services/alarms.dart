import 'dart:ui';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models.dart';
import 'api.dart';
import 'holdings.dart';
import 'indicator_alerts.dart';
import 'live_service.dart';
import 'notifications.dart';
import 'settings.dart';

/// 알람 매니저로 정해진 시각에 결과 파일을 확인하고 로컬 알림을 띄운다.
///
/// - 아침 알림(기본 07:00): 단기 대기 + 중기 후보 + 보유 신호, 매월 1일엔 장기 갱신, 월요일엔 인사이트 신호 변화
/// - EP 알림: 미국장 개장 30분 뒤(10:00 미국 동부) 결과 확인
class Alarms {
  static const int morningId = 1001;
  static const int epId = 1002;
  static const int krId = 1003;
  static const int liveId = 1004;

  static bool _tzReady = false;

  static void _ensureTz() {
    if (_tzReady) return;
    tzdata.initializeTimeZones();
    _tzReady = true;
  }

  static Future<void> init() async {
    await AndroidAlarmManager.initialize();
  }

  /// 앱을 열 때마다 호출: 다음 알람을 다시 잡는다 (취소 후 재등록)
  static Future<void> scheduleAll(AppSettings s) async {
    await init();
    await AndroidAlarmManager.cancel(morningId);
    await AndroidAlarmManager.cancel(epId);
    if (s.notifyMorning) {
      final t = _nextLocal(s.morningHour, s.morningMinute);
      await AndroidAlarmManager.oneShotAt(t, morningId, morningCallback,
          exact: true, wakeup: true, rescheduleOnReboot: true, allowWhileIdle: true);
    }
    if (s.notifyEp) {
      final t = nextUsOpenPlus30();
      await AndroidAlarmManager.oneShotAt(t, epId, epCallback,
          exact: true, wakeup: true, rescheduleOnReboot: true, allowWhileIdle: true);
    }
    try {
      await IndicatorAlerts.schedule(s);
    } catch (_) {}
    await AndroidAlarmManager.cancel(liveId);
    if (s.liveEnabled && s.ntfyTopic.isNotEmpty) {
      final ses = UsSession.next();
      final t = ses[0].isAfter(DateTime.now()) ? ses[0] : DateTime.now().add(const Duration(seconds: 30));
      await AndroidAlarmManager.oneShotAt(t, liveId, liveCallback,
          exact: true, wakeup: true, rescheduleOnReboot: true, allowWhileIdle: true);
    }
  }

  /// 정규장 시작: 장중 감시(포그라운드 서비스) 켜고 다음 날 알람 재등록
  @pragma('vm:entry-point')
  static Future<void> liveCallback() async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    final s = await AppSettings.load();
    try {
      await LiveService.init();
      final ses = UsSession.next();
      await saveSessionEnd(ses[1]);
      await LiveService.start();
    } catch (e) {
      await Notifier.show(9003, '장중 감시 시작 실패', '$e');
    }
    try {
      await AndroidAlarmManager.initialize();
      final next = UsSession.next();
      var t = next[0];
      if (!t.isAfter(DateTime.now().add(const Duration(hours: 1)))) t = t.add(const Duration(days: 1));
      await AndroidAlarmManager.oneShotAt(t, liveId, liveCallback,
          exact: true, wakeup: true, rescheduleOnReboot: true, allowWhileIdle: true);
    } catch (_) {}
    if (!s.liveEnabled) await LiveService.stop();
  }

  static DateTime _nextLocal(int hour, int minute) {
    final now = DateTime.now();
    var t = DateTime(now.year, now.month, now.day, hour, minute);
    if (!t.isAfter(now.add(const Duration(minutes: 1)))) t = t.add(const Duration(days: 1));
    return t;
  }

  /// EP 확인 시각: 미국 동부 10:35 과 11:05 (GitHub 가 결과를 올리는 10:25 ET 이후). 다음 평일 슬롯을 로컬 시각으로
  static const List<List<int>> epSlots = [[10, 35], [11, 5]];

  static DateTime nextUsOpenPlus30() {
    _ensureTz();
    final ny = tz.getLocation('America/New_York');
    final now = tz.TZDateTime.now(ny);
    for (var addDays = 0; addDays < 8; addDays++) {
      for (final slot in epSlots) {
        final t = tz.TZDateTime(ny, now.year, now.month, now.day + addDays, slot[0], slot[1]);
        if (t.weekday >= 6) break;
        if (t.isAfter(now.add(const Duration(minutes: 1)))) return t.toLocal();
      }
    }
    return now.add(const Duration(days: 1)).toLocal();
  }

  // ------------------------------------------------------------------
  // 백그라운드 콜백 (별도 isolate 에서 실행)
  // ------------------------------------------------------------------
  @pragma('vm:entry-point')
  static Future<void> morningCallback() async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    final s = await AppSettings.load();
    try {
      await runMorningCheck(s);
    } catch (e) {
      await Notifier.show(9001, '스크리너 확인 실패', '$e');
    }
    // 다음 날 다시 + 오늘 지표 발표 알람 등록
    try {
      await AndroidAlarmManager.initialize();
      final t = _nextLocal(s.morningHour, s.morningMinute);
      await AndroidAlarmManager.oneShotAt(t, morningId, morningCallback,
          exact: true, wakeup: true, rescheduleOnReboot: true, allowWhileIdle: true);
      await IndicatorAlerts.schedule(s);
    } catch (_) {}
  }

  @pragma('vm:entry-point')
  static Future<void> epCallback() async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    final s = await AppSettings.load();
    try {
      await runEpCheck(s);
    } catch (e) {
      await Notifier.show(9002, 'EP 확인 실패', '$e');
    }
    try {
      await AndroidAlarmManager.initialize();
      final t = nextUsOpenPlus30();
      await AndroidAlarmManager.oneShotAt(t, epId, epCallback,
          exact: true, wakeup: true, rescheduleOnReboot: true, allowWhileIdle: true);
    } catch (_) {}
  }

  /// 아침 점검 (앱 안에서 "지금 테스트" 로도 호출)
  static Future<String> runMorningCheck(AppSettings s) async {
    final api = Api(s);
    final lines = <String>[];
    try {
      final sh = await api.shortList('us');
      lines.add('돌파 대기 ${sh.items.length}종목: ${sh.items.take(6).map((e) => e.ticker).join(', ')}');
    } catch (e) {
      lines.add('단기: 조회 실패');
    }
    try {
      final md = await api.midList('us');
      lines.add('중기 후보 ${md.items.length}종목: ${md.items.take(6).map((e) => e.ticker).join(', ')}');
    } catch (e) {
      lines.add('중기: 조회 실패');
    }
    // 보유 신호
    LongFile? lf;
    try {
      lf = await api.longList('us');
    } catch (_) {}
    final store = await HoldingsStore.load();
    final alerts = <String>[];
    for (final h in store.all()) {
      final sig = await SignalEngine.evaluate(h, longFile: lf);
      if (sig.hasAlert) alerts.add('${h.ticker}(${horizonLabel(h.horizon)}): ${sig.alerts.join(' / ')}');
    }
    if (alerts.isNotEmpty) {
      await Notifier.show(2, '보유 종목 신호 ${alerts.length}건', alerts.join('\n'), channel: 'holdings');
    }
    await Notifier.show(1, '오늘의 스크리너', lines.join('\n'));

    final now = DateTime.now();
    // 매월 1일: 장기 갱신
    if (lf != null && lf.date.isNotEmpty && lf.date != s.lastLongDate) {
      if (now.day == 1 || s.lastLongDate.isEmpty) {
        await Notifier.show(3, '장기 후보 갱신 (${lf.date})',
            '상위 5: ${lf.holdings.join(', ')}${lf.entered.isNotEmpty ? '\n신규: ${lf.entered.join(', ')}' : ''}${lf.exited.isNotEmpty ? '\n이탈: ${lf.exited.join(', ')}' : ''}');
        await s.setString('lastLongDate', lf.date);
      }
    }
    // 월요일: 인사이트 신호가 바뀌었을 때
    if (now.weekday == DateTime.monday || s.lastInsightSignal.isEmpty) {
      try {
        final ins = await api.insight('us');
        if (ins.signal.isNotEmpty && ins.signal != s.lastInsightSignal) {
          if (s.lastInsightSignal.isNotEmpty) {
            await Notifier.show(4, '시장 온도 변경: ${ins.signal}',
                '${ins.index} ${ins.aboveSma200 ? '>' : '<'} SMA200, 브레드스 ${ins.breadthPct?.toStringAsFixed(0) ?? '-'}%');
          }
          await s.setString('lastInsightSignal', ins.signal);
        }
      } catch (_) {}
    }
    return lines.join('\n');
  }

  static Future<String> runEpCheck(AppSettings s) async {
    final api = Api(s);
    final ep = await api.epList('us');
    if (ep.items.isEmpty) return 'EP 후보 없음';
    final key = '${ep.date}|${ep.generatedAt}';
    if (key == s.lastEpDate) return '이미 알림함';
    final trig = ep.items.where((e) => e.triggered).map((e) => '${e.ticker} 진입 ${e.triggerPrice?.toStringAsFixed(2)}').toList();
    final wait = ep.items.where((e) => !e.triggered).map((e) => e.ticker).toList();
    final body = [
      if (trig.isNotEmpty) '진입가 도달: ${trig.join(', ')}',
      if (wait.isNotEmpty) '대기: ${wait.join(', ')}',
    ].join('\n');
    await Notifier.show(5, 'EP 후보 ${ep.items.length}종목 (${ep.asofEt} ET)', body, channel: 'ep');
    await s.setString('lastEpDate', key);
    return body;
  }
}
