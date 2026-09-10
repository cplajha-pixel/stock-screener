import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 로컬 알림 (Firebase 없음)
class Notifier {
  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _inited = false;

  static Future<void> init() async {
    if (_inited) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(settings: const InitializationSettings(android: android));
    _inited = true;
  }

  static Future<void> requestPermission() async {
    final impl = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await impl?.requestNotificationsPermission();
  }

  static Future<void> show(int id, String title, String body, {String channel = 'screener'}) async {
    await init();
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        channel,
        channel == 'ep' ? 'EP 알림' : (channel == 'holdings' ? '보유 신호' : (channel == 'indicator' ? '지표 발표' : '스크리너 알림')),
        channelDescription: '스크리너 결과와 보유 종목 신호',
        importance: Importance.high,
        priority: Priority.high,
        styleInformation: BigTextStyleInformation(body),
      ),
    );
    await _plugin.show(id: id, title: title, body: body, notificationDetails: details);
  }
}
