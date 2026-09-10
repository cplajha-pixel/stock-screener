import 'package:flutter/material.dart';

import '../main.dart';
import '../models.dart';
import '../services/api.dart';
import '../util.dart';
import 'chart_screen.dart';

/// 매일 1픽 성적표
class PicksScreen extends StatefulWidget {
  const PicksScreen({super.key});

  @override
  State<PicksScreen> createState() => _PicksScreenState();
}

class _PicksScreenState extends State<PicksScreen> {
  PicksFile? f;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      f = await Api(settings).picks('us');
      error = null;
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = f?.summary ?? {};
    return Scaffold(
      appBar: AppBar(title: const Text('1픽 성적표')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(10),
          children: [
            if (error != null) Text(error!, style: const TextStyle(color: Colors.red)),
            if (f == null && error == null) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
            if (f != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('누적 성적 (규칙대로 매매했다고 가정, 수수료 제외)', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Wrap(spacing: 14, runSpacing: 4, children: [
                      kv('1픽 수', '${s['total'] ?? 0}'),
                      kv('발동', '${s['triggered'] ?? 0}'),
                      kv('미발동', '${s['not_triggered'] ?? 0}'),
                      kv('종료', '${s['closed'] ?? 0}'),
                      kv('진행 중', '${s['open'] ?? 0}'),
                      kv('승률', s['win_rate'] == null ? '-' : '${s['win_rate']}%', bold: true),
                      kv('평균 손익', s['avg_pnl_pct'] == null ? '-' : fmtPct((s['avg_pnl_pct'] as num).toDouble()), bold: true),
                      kv('평균 R', s['avg_r'] == null ? '-' : '${s['avg_r']}R'),
                      kv('합계', s['sum_pnl_pct'] == null ? '-' : fmtPct((s['sum_pnl_pct'] as num).toDouble())),
                    ]),
                    const SizedBox(height: 6),
                    const Text('1픽 규칙: 돌파 대기 후보 중 [3개월 수익률 순위 + 횡보 폭(좁을수록) + 거래량 감소율 + 종가의 트리거가 근접도] 평균 순위 1위. '
                        '다음 날 트리거가를 넘으면 발동, 규칙(손절·3일째 절반·SMA10 이탈·60일)대로 자동 채점.',
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                  ]),
                ),
              ),
            for (final p in f?.picks ?? const <PickRow>[]) _card(p),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _card(PickRow p) {
    final r = p.result ?? {};
    final pnl = p.pnlPct;
    Color c = Colors.grey;
    if (p.status == '진행 중') c = Colors.blue;
    if (p.status == '종료') c = (pnl ?? 0) > 0 ? Colors.red : Colors.blue;
    return Card(
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ChartScreen(ticker: p.ticker, name: p.name, exchange: '', market: 'us', trigger: p.triggerPrice, stop: p.stopPrice, horizon: 'short'),
        )),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(p.date, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(width: 8),
              Text(p.ticker, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(width: 6),
              Expanded(child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.grey))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                child: Text('${p.status}${pnl != null ? ' ${fmtPct(pnl)}' : ''}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: c)),
              ),
            ]),
            const SizedBox(height: 4),
            Text('선정 이유: ${p.reason}', style: const TextStyle(fontSize: 11)),
            Wrap(spacing: 12, children: [
              kv('트리거', fmtPrice(p.triggerPrice)),
              kv('손절', fmtPrice(p.stopPrice)),
              if (r['entry_price'] != null) kv('진입', '${fmtPrice((r['entry_price'] as num).toDouble())} (${r['entry_date']})'),
              if (r['exit_reason'] != null) kv('청산', '${r['exit_reason']} (${r['exit_date'] ?? ''})'),
              if (r['r_multiple'] != null) kv('R', '${r['r_multiple']}R'),
              if (r['note'] != null) kv('비고', r['note'].toString()),
            ]),
            if (p.candidates.isNotEmpty) Text('그날 후보: ${p.candidates.join(', ')}', style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ]),
        ),
      ),
    );
  }
}
