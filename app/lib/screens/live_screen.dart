import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../main.dart';
import '../models.dart';
import '../services/live_service.dart';
import '../util.dart';
import 'chart_screen.dart';

/// 장중 탭: PC 스캐너가 1분마다 올리는 라이브 목록 + 알림 기록
class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> with AutomaticKeepAliveClientMixin {
  LiveFile? f;
  String? error;
  bool loading = false;
  bool watching = false;
  Timer? _auto;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    _auto = Timer.periodic(const Duration(seconds: 60), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _auto?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => loading = true);
    try {
      // 1) GitHub Contents API (CDN 캐시 없음, 시간당 60회 제한) → 2) raw (최대 5분 지연)
      final api = Uri.parse('https://api.github.com/repos/cplajha-pixel/stock-screener/contents/us_live.json?ref=live&t=${DateTime.now().millisecondsSinceEpoch}');
      var r = await http.get(api, headers: {'Accept': 'application/vnd.github.raw+json', 'User-Agent': 'stock-screener-app'}).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) {
        r = await http.get(Uri.parse('https://raw.githubusercontent.com/cplajha-pixel/stock-screener/live/us_live.json?t=${DateTime.now().millisecondsSinceEpoch}')).timeout(const Duration(seconds: 20));
      }
      if (r.statusCode == 200) {
        f = LiveFile.fromJson(Map<String, dynamic>.from(jsonDecode(utf8.decode(r.bodyBytes)) as Map));
        error = null;
      } else {
        error = 'HTTP ${r.statusCode}';
      }
    } catch (e) {
      error = '$e';
    }
    try {
      watching = await LiveService.isRunning();
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final s = UsSession.next();
    final d = f;
    return Scaffold(
      appBar: AppBar(
        title: const Text('장중'),
        actions: [IconButton(onPressed: loading ? null : () => _load(), icon: const Icon(Icons.refresh))],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(),
        child: ListView(padding: const EdgeInsets.all(10), children: [
          Card(
            color: (watching ? Colors.green : Colors.grey).withValues(alpha: 0.12),
            child: ListTile(
              leading: Icon(watching ? Icons.radar : Icons.radar_outlined, color: watching ? Colors.green : Colors.grey),
              title: Text(watching ? '실시간 감시 중 (1분마다 확인)' : '감시 꺼짐'),
              subtitle: Text(settings.ntfyTopic.isEmpty
                  ? '설정 → 장중 알림 토픽을 먼저 입력하세요'
                  : '정규장 ${_hm(s[0])}~${_hm(s[1])} (한국시간) 에 자동 시작 · PC 스캐너가 켜져 있어야 합니다'),
              trailing: FilledButton.tonal(
                onPressed: settings.ntfyTopic.isEmpty
                    ? null
                    : () async {
                        final msg = watching ? await LiveService.stop() : await _startNow();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
                        _load(silent: true);
                      },
                child: Text(watching ? '중지' : '지금 시작'),
              ),
            ),
          ),
          if (error != null) Padding(padding: const EdgeInsets.all(8), child: Text('라이브 목록: $error', style: const TextStyle(color: Colors.red, fontSize: 12))),
          if (d != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
              child: Row(children: [
                const Text('실시간 후보', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text(d.asof.isEmpty ? '아직 스캔 없음' : '스캔 ${d.asof} · 경과 ${d.elapsedMin}분 · 검사 ${d.candidatesScanned}종목', style: const TextStyle(fontSize: 10, color: Colors.grey)),
              ]),
            ),
            if (d.items.isEmpty) const Padding(padding: EdgeInsets.all(14), child: Center(child: Text('지금 조건을 만족하는 종목이 없습니다', style: TextStyle(color: Colors.grey)))),
            for (final it in d.items) _card(it),
            if (d.alerts.isNotEmpty) ...[
              const Padding(padding: EdgeInsets.fromLTRB(4, 12, 4, 4), child: Text('오늘 알림 기록', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold))),
              for (final a in d.alerts.take(30))
                ListTile(
                  dense: true,
                  leading: Text(a.time, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  title: Text(a.title, style: const TextStyle(fontSize: 13)),
                  subtitle: Text(a.body, style: const TextStyle(fontSize: 11)),
                  onTap: () => _open(a.ticker, ''),
                ),
            ],
          ],
          const SizedBox(height: 30),
          const Text('규칙: EP = 시가 갭 +10~40% · 거래량 5배 · 3개월 소외. 단타 = 등락 +5% · 거래량 3배 · 당일 고가 2% 이내. 종목당 하루 1번 알림. 데이터: 토스증권 오픈API (PC 스캐너).',
              style: TextStyle(fontSize: 10, color: Colors.grey)),
          const SizedBox(height: 30),
        ]),
      ),
    );
  }

  Future<String> _startNow() async {
    final s = UsSession.next();
    await saveSessionEnd(s[1]);
    return LiveService.start();
  }

  String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  void _open(String ticker, String name, {double? trigger, double? stop}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChartScreen(ticker: ticker, name: name, exchange: '', market: 'us', trigger: trigger, stop: stop, horizon: 'short'),
    ));
  }

  Widget _card(LiveItem it) {
    final isEp = it.setups.contains('ep');
    final cap = settings.capital('us', 'short');
    final entry = isEp ? it.epEntry : it.last;
    final stop = isEp ? it.epStop : it.momStop;
    final ov = orderValues(entry, stop, null, cap, 5, settings.maxPositionPct, settings.slippagePct);
    return Card(
      color: isEp ? Colors.amber.withValues(alpha: 0.12) : null,
      child: InkWell(
        onTap: () => _open(it.ticker, it.name, trigger: entry, stop: stop),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(it.ticker, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Expanded(child: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.grey))),
              for (final s in it.setups)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Chip(
                    label: Text(s == 'ep' ? (it.epTriggered ? 'EP 도달' : 'EP') : '단타', style: const TextStyle(fontSize: 11)),
                    backgroundColor: s == 'ep' ? Colors.amber.withValues(alpha: 0.3) : Colors.blue.withValues(alpha: 0.2),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ]),
            const SizedBox(height: 4),
            Wrap(spacing: 12, runSpacing: 2, children: [
              kv('현재가', fmtPrice(it.last), bold: true),
              kv('등락', fmtPct(it.changePct), color: pctColor(it.changePct, context)),
              kv('갭', fmtPct(it.gapPct)),
              kv('거래량', '${it.rvol?.toStringAsFixed(1) ?? '-'}배'),
              kv('고가', fmtPrice(it.high)),
              if (isEp) kv('EP 진입가', fmtPrice(it.epEntry), bold: true),
              if (stop != null) kv('손절', fmtPrice(stop), color: Colors.blue.shade400),
              if (ov != null) kv('수량', '${ov.qty}주'),
              kv('3개월', fmtPct(it.r3m)),
              kv('시각', it.asof),
            ]),
          ]),
        ),
      ),
    );
  }
}
