import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'screens/holdings_screen.dart';
import 'screens/insight_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/stocks_screen.dart';
import 'services/alarms.dart';
import 'services/notifications.dart';
import 'services/settings.dart';

late AppSettings settings;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  settings = await AppSettings.load();
  await Notifier.init();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '주식 스크리너',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark, useMaterial3: true),
      home: const Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _setup());
  }

  Future<void> _setup() async {
    if (!settings.setupDone && mounted) {
      await showSetupDialog(context);
      await settings.setBool('setupDone', true);
    }
    try {
      await Alarms.scheduleAll(settings);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: const [StocksScreen(), HoldingsScreen(), InsightScreen(), SettingsScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.list_alt), label: '종목'),
          NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), label: '보유'),
          NavigationDestination(icon: Icon(Icons.insights), label: '인사이트'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: '설정'),
        ],
      ),
    );
  }
}

/// 첫 실행 안내: 알림 / 정확한 알람 / 배터리 최적화 제외
Future<void> showSetupDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('알림 권한 설정'),
      content: const Text(
        '정해진 시각(기본 아침 07:00, 미국장 개장 30분 뒤)에 결과를 확인해 알림을 보냅니다.\n\n'
        '제때 알림을 받으려면 3가지가 필요합니다:\n'
        '1. 알림 허용\n'
        '2. 알람 및 리마인더(정확한 알람) 허용\n'
        '3. 배터리 최적화 제외 (백그라운드 실행)\n\n'
        '다음 화면들에서 "허용"을 눌러 주세요.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('나중에')),
        FilledButton(
          onPressed: () async {
            Navigator.pop(ctx);
            await requestAllPermissions();
          },
          child: const Text('설정하기'),
        ),
      ],
    ),
  );
}

Future<String> requestAllPermissions() async {
  final r = <String>[];
  try {
    final n = await Permission.notification.request();
    r.add('알림: ${n.isGranted ? '허용' : '거부'}');
  } catch (e) {
    r.add('알림: $e');
  }
  try {
    var a = await Permission.scheduleExactAlarm.status;
    if (!a.isGranted) a = await Permission.scheduleExactAlarm.request();
    r.add('정확한 알람: ${a.isGranted ? '허용' : '거부'}');
  } catch (e) {
    r.add('정확한 알람: $e');
  }
  try {
    var b = await Permission.ignoreBatteryOptimizations.status;
    if (!b.isGranted) b = await Permission.ignoreBatteryOptimizations.request();
    r.add('배터리 최적화 제외: ${b.isGranted ? '허용' : '거부'}');
  } catch (e) {
    r.add('배터리 최적화 제외: $e');
  }
  return r.join('\n');
}
