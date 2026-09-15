import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'notifications.dart';

/// 장중 실시간 알림: PC 스캐너가 ntfy 토픽으로 보낸 알림을 앱이 60초마다 확인해 팝업으로 띄운다.
/// 미국 정규장 시간에만 포그라운드 서비스("장중 감시 중" 알림)로 동작한다.
class LiveService {
  static const int notifBase = 7000;

  static Future<void> init() async {
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'live_watch',
        channelName: '장중 감시',
        channelDescription: '미국장 시간에 실시간 알림을 확인합니다',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  static Future<bool> isRunning() => FlutterForegroundTask.isRunningService;

  static Future<String> start() async {
    if (await FlutterForegroundTask.isRunningService) {
      return '이미 감시 중';
    }
    final r = await FlutterForegroundTask.startService(
      serviceId: 7001,
      notificationTitle: '장중 감시 중',
      notificationText: '미국장 실시간 EP·단타 알림을 확인합니다 (1분마다)',
      callback: liveStartCallback,
    );
    return r is ServiceRequestSuccess ? '감시 시작' : '시작 실패: $r';
  }

  static Future<String> stop() async {
    final r = await FlutterForegroundTask.stopService();
    return r is ServiceRequestSuccess ? '감시 중지' : '중지 실패: $r';
  }

  /// ntfy 토픽에서 새 알림을 가져와 팝업. 앱 안에서 수동 호출도 가능. 반환: 새 알림 수
  static Future<int> pollOnce(SharedPreferences p) async {
    final topic = (p.getString('ntfyTopic') ?? '').trim();
    if (topic.isEmpty) return 0;
    final lastTime = p.getInt('lastNtfyTime') ?? 0;
    final since = lastTime > 0 ? '$lastTime' : '2h';
    final url = Uri.parse('https://ntfy.sh/$topic/json?poll=1&since=$since');
    final r = await http.get(url).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) return 0;
    var n = 0;
    var maxTime = lastTime;
    final seen = (p.getStringList('ntfySeen') ?? <String>[]).toSet();
    for (final line in const LineSplitter().convert(utf8.decode(r.bodyBytes))) {
      if (line.trim().isEmpty) continue;
      Map<String, dynamic> m;
      try {
        m = Map<String, dynamic>.from(jsonDecode(line) as Map);
      } catch (_) {
        continue;
      }
      if (m['event'] != 'message') continue;
      final id = (m['id'] ?? '').toString();
      final t = (m['time'] is int) ? m['time'] as int : int.tryParse('${m['time']}') ?? 0;
      if (t > maxTime) maxTime = t;
      if (seen.contains(id)) continue;
      seen.add(id);
      final title = (m['title'] ?? '장중 알림').toString();
      final body = (m['message'] ?? '').toString();
      await Notifier.show(notifBase + (id.hashCode & 0x3ff), title, body, channel: 'live');
      n++;
    }
    await p.setInt('lastNtfyTime', maxTime);
    await p.setStringList('ntfySeen', seen.toList().reversed.take(200).toList());
    return n;
  }
}

@pragma('vm:entry-point')
void liveStartCallback() {
  FlutterForegroundTask.setTaskHandler(LiveTaskHandler());
}

class LiveTaskHandler extends TaskHandler {
  SharedPreferences? _p;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _p = await SharedPreferences.getInstance();
    await Notifier.init();
    await _tick();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _tick();
  }

  Future<void> _tick() async {
    try {
      _p ??= await SharedPreferences.getInstance();
      await _p!.reload();
      final n = await LiveService.pollOnce(_p!);
      final now = DateTime.now();
      FlutterForegroundTask.updateService(
        notificationTitle: '장중 감시 중',
        notificationText: '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')} 확인${n > 0 ? ' · 새 알림 $n' : ''}',
      );
      // 세션 종료 시각이 저장되어 있으면 자동 중지
      final endMs = _p!.getInt('liveSessionEndMs') ?? 0;
      if (endMs > 0 && DateTime.now().millisecondsSinceEpoch > endMs) {
        await FlutterForegroundTask.stopService();
      }
    } catch (e) {
      debugPrint('live tick error: $e');
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }
}

/// 세션(미국 정규장, KST) 시작·종료 시각 계산: 서머타임 22:30~05:00, 겨울 23:30~06:00
class UsSession {
  static bool isDst(DateTime utc) {
    // 미국 DST: 3월 둘째 일요일 ~ 11월 첫째 일요일 (대략, 2:00 지역시각)
    final y = utc.year;
    DateTime nthSunday(int month, int n) {
      var d = DateTime.utc(y, month, 1);
      while (d.weekday != DateTime.sunday) {
        d = d.add(const Duration(days: 1));
      }
      return d.add(Duration(days: 7 * (n - 1)));
    }
    final start = nthSunday(3, 2).add(const Duration(hours: 7)); // 2am EST = 07:00 UTC
    final end = nthSunday(11, 1).add(const Duration(hours: 6)); // 2am EDT = 06:00 UTC
    return utc.isAfter(start) && utc.isBefore(end);
  }

  /// 다음(또는 진행 중인) 정규장의 [시작, 종료] 로컬 시각
  static List<DateTime> next() {
    final nowUtc = DateTime.now().toUtc();
    for (var add = 0; add < 8; add++) {
      final day = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day).add(Duration(days: add));
      final dst = isDst(day.add(const Duration(hours: 15)));
      final open = day.add(Duration(hours: dst ? 13 : 14, minutes: 30)); // 09:30 ET in UTC
      final close = open.add(const Duration(hours: 6, minutes: 30));
      final wd = open.toLocal().weekday;
      if (open.weekday >= 6) continue;
      if (close.isAfter(nowUtc) && wd <= 7) return [open.toLocal(), close.toLocal()];
    }
    return [DateTime.now().add(const Duration(days: 1)), DateTime.now().add(const Duration(days: 1, hours: 6))];
  }
}

Future<void> saveSessionEnd(DateTime end) async {
  final p = await SharedPreferences.getInstance();
  await p.setInt('liveSessionEndMs', end.millisecondsSinceEpoch);
}

bool get isAndroid => Platform.isAndroid;
