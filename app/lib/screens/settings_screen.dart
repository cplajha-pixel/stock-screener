import 'package:flutter/material.dart';

import '../main.dart';
import '../services/alarms.dart';
import '../services/live_service.dart';
import '../services/notifications.dart';
import '../services/settings.dart';
import '../util.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  static const brokerPresets = <String, String>{
    '': '없음 (웹 링크로 열기)',
    'com.samsungpop.android.mpop': '삼성증권 mPOP',
    'com.miraeasset.trade': '미래에셋 M-STOCK',
    'com.truefriend.neosmartaplus': '한국투자증권',
    'com.kiwoom.heroSN': '키움 영웅문S#',
    'com.nhqv.mts': 'NH 나무',
    'com.kbsec.mts.mable': 'KB M-able',
    'viva.republica.toss': '토스',
    'custom': '직접 입력',
  };

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final s = settings;
    final preset = brokerPresets.containsKey(s.brokerPackage) ? s.brokerPackage : 'custom';
    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _section('자금 (미국, USD)'),
          _num('단기 자금 (\$)', s.usShortCapital, (v) => s.setCapital('usShortCapital', v)),
          _num('중기 자금 (\$)', s.usMidCapital, (v) => s.setCapital('usMidCapital', v)),
          _num('장기 자금 (\$) — 기본 3,600 ≈ 500만 원', s.usLongCapital, (v) => s.setCapital('usLongCapital', v)),
          _section('자금 (국내, 원) — 국내 기능 준비 중'),
          _num('단기 자금 (원)', s.krShortCapital, (v) => s.setCapital('krShortCapital', v)),
          _num('중기 자금 (원)', s.krMidCapital, (v) => s.setCapital('krMidCapital', v)),
          _num('장기 자금 (원)', s.krLongCapital, (v) => s.setCapital('krLongCapital', v)),
          _section('비중 / 종목 수'),
          _num('한 종목 최대 비중 (%) — 전량 매매면 100', s.maxPositionPct, (v) => s.setMaxPositionPct(v.clamp(1, 100))),
          _num('단기 동시 보유 종목 수', s.maxPositionsShort.toDouble(), (v) => s.setMaxPositions('maxPositionsShort', v.round())),
          _num('중기 동시 보유 종목 수', s.maxPositionsMid.toDouble(), (v) => s.setMaxPositions('maxPositionsMid', v.round())),
          _section('주문 가정'),
          _num('손절 슬리피지 가정 (%) — 시장가 손절이 손절가보다 이만큼 아래서 체결된다고 보고 수량 계산', s.slippagePct, (v) => s.setDouble('slippagePct', v.clamp(0, 10))),
          _section('목표'),
          _num('목표 자산 (원)', s.targetAssetKrw, (v) => s.setDouble('targetAssetKrw', v)),
          _num('현재 자산 (원) — 0이면 자금 합계로 자동 계산', s.currentAssetKrw, (v) => s.setDouble('currentAssetKrw', v)),
          _num('환율 (원/\$) — 자동 계산용', s.fxRate, (v) => s.setDouble('fxRate', v)),
          _section('알림'),
          SwitchListTile(
            title: const Text('아침 알림 (단기 대기 + 중기 후보 + 보유 신호)'),
            subtitle: Text('매일 ${s.morningHour.toString().padLeft(2, '0')}:${s.morningMinute.toString().padLeft(2, '0')} · 매월 1일 장기 갱신 · 월요일 인사이트 변화'),
            value: s.notifyMorning,
            onChanged: (v) async {
              await s.setBool('notifyMorning', v);
              await Alarms.scheduleAll(s);
              setState(() {});
            },
          ),
          ListTile(
            title: const Text('아침 알림 시각'),
            trailing: Text('${s.morningHour.toString().padLeft(2, '0')}:${s.morningMinute.toString().padLeft(2, '0')}'),
            onTap: () async {
              final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: s.morningHour, minute: s.morningMinute));
              if (t == null) return;
              await s.setInt('morningHour', t.hour);
              await s.setInt('morningMinute', t.minute);
              await Alarms.scheduleAll(s);
              setState(() {});
            },
          ),
          SwitchListTile(
            title: const Text('EP 알림 (미국장 개장 30분 뒤)'),
            subtitle: Text('다음 예정: ${_fmt(Alarms.nextUsOpenPlus30())}'),
            value: s.notifyEp,
            onChanged: (v) async {
              await s.setBool('notifyEp', v);
              await Alarms.scheduleAll(s);
              setState(() {});
            },
          ),
          SwitchListTile(
            title: const Text('지표 발표 알림 (발표 +1분, 없으면 +5분 재확인)'),
            subtitle: Text('중요도 ${'★' * s.indicatorMinStars} 이상 · 세이브티커 캘린더 기준'),
            value: s.notifyIndicators,
            onChanged: (v) async {
              await s.setBool('notifyIndicators', v);
              await Alarms.scheduleAll(s);
              setState(() {});
            },
          ),
          ListTile(
            title: const Text('지표 알림 최소 중요도'),
            trailing: DropdownButton<int>(
              value: s.indicatorMinStars,
              items: const [DropdownMenuItem(value: 3, child: Text('★★★만')), DropdownMenuItem(value: 2, child: Text('★★ 이상')), DropdownMenuItem(value: 1, child: Text('전부'))],
              onChanged: (v) async {
                if (v == null) return;
                await s.setInt('indicatorMinStars', v);
                await Alarms.scheduleAll(s);
                setState(() {});
              },
            ),
          ),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.notifications_active_outlined),
                label: const Text('알림 테스트'),
                onPressed: () async {
                  await Notifier.requestPermission();
                  await Notifier.show(99, '테스트 알림', '이 알림이 보이면 알림 설정이 정상입니다.');
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.security),
                label: const Text('권한 확인'),
                onPressed: () async {
                  final r = await requestAllPermissions();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r)));
                },
              ),
            ),
          ]),
          OutlinedButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: const Text('지금 아침 점검 실행 (알림으로 결과 확인)'),
            onPressed: () async {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('확인 중… 잠시 뒤 알림이 옵니다')));
              try {
                await Alarms.runMorningCheck(s);
              } catch (e) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('실패: $e')));
              }
            },
          ),
          _section('장중 실시간 알림 (PC 스캐너 → 앱)'),
          ListTile(
            title: const Text('알림 토픽'),
            subtitle: Text(s.ntfyTopic.isEmpty ? '미설정 — PC의 toss.env 에 있는 NTFY_TOPIC 값' : s.ntfyTopic, style: const TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.edit, size: 18),
            onTap: () async {
              final v = await _askText(context, '알림 토픽 (예: stk-abc123...)', s.ntfyTopic);
              if (v == null) return;
              await s.setString('ntfyTopic', v.trim());
              await Alarms.scheduleAll(s);
              setState(() {});
            },
          ),
          SwitchListTile(
            title: const Text('미국 정규장에 자동 감시 (1분마다 확인, "감시 중" 알림 표시)'),
            value: s.liveEnabled,
            onChanged: (v) async {
              await s.setBool('liveEnabled', v);
              await Alarms.scheduleAll(s);
              if (!v) await LiveService.stop();
              setState(() {});
            },
          ),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('감시 지금 시작'),
                onPressed: () async {
                  final ses = UsSession.next();
                  await saveSessionEnd(ses[1]);
                  final m = await LiveService.start();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.stop),
                label: const Text('감시 중지'),
                onPressed: () async {
                  final m = await LiveService.stop();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
                },
              ),
            ),
          ]),
          OutlinedButton.icon(
            icon: const Icon(Icons.notifications_active_outlined),
            label: const Text('최근 2시간 알림 지금 확인 (테스트)'),
            onPressed: () async {
              await s.setInt('lastNtfyTime', 0);
              final n = await LiveService.pollOnce(s.p);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('새 알림 $n건')));
            },
          ),
          _section('차트'),
          DropdownButtonFormField<String>(
            initialValue: preset,
            decoration: const InputDecoration(labelText: '증권사 앱 ("증권사 앱에서 열기" 버튼)'),
            items: [for (final e in brokerPresets.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) async {
              if (v == null) return;
              if (v == 'custom') {
                final c = await _askText(context, '앱 패키지명 (예: com.example.app)', s.brokerPackage);
                if (c != null) await s.setBrokerPackage(c);
              } else {
                await s.setBrokerPackage(v);
              }
              setState(() {});
            },
          ),
          if (preset == 'custom') Padding(padding: const EdgeInsets.only(left: 4, top: 4), child: Text('패키지: ${s.brokerPackage}', style: const TextStyle(fontSize: 12, color: Colors.grey))),
          const SizedBox(height: 12),
          ExpansionTile(
            title: const Text('고급', style: TextStyle(fontSize: 14)),
            children: [
              ListTile(
                title: const Text('결과 데이터 주소'),
                subtitle: Text(s.baseUrl, style: const TextStyle(fontSize: 11)),
                trailing: const Icon(Icons.edit, size: 18),
                onTap: () async {
                  final v = await _askText(context, '결과 파일 폴더 주소 (비우면 기본값)', s.baseUrl == kDefaultBaseUrl ? '' : s.baseUrl);
                  if (v == null) return;
                  await s.setBaseUrl(v);
                  setState(() {});
                },
              ),
            ],
          ),
          const SizedBox(height: 30),
          const Center(child: Text('보유 종목·자금 정보는 이 폰에만 저장됩니다.', style: TextStyle(fontSize: 11, color: Colors.grey))),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  String _fmt(DateTime d) => '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 16, 2, 4),
        child: Text(t, style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
      );

  Widget _num(String label, double value, Future<void> Function(double) onSave) {
    final text = value == value.roundToDouble() ? value.toInt().toString() : value.toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextFormField(
        initialValue: text,
        decoration: InputDecoration(labelText: label, isDense: true, helperText: value >= 10000 ? fmtKrw(value) : null),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (v) {
          final d = double.tryParse(v.replaceAll(',', '').trim());
          if (d != null && d >= 0) onSave(d).then((_) => setState(() {}));
        },
      ),
    );
  }

  Future<String?> _askText(BuildContext context, String label, String initial) async {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label, style: const TextStyle(fontSize: 15)),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('저장')),
        ],
      ),
    );
  }
}
