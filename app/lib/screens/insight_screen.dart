import 'package:flutter/material.dart';

import '../main.dart';
import '../models.dart';
import '../services/api.dart';
import '../util.dart';

class InsightScreen extends StatefulWidget {
  const InsightScreen({super.key});

  @override
  State<InsightScreen> createState() => _InsightScreenState();
}

class _InsightScreenState extends State<InsightScreen> with AutomaticKeepAliveClientMixin {
  InsightFile? f;
  bool loading = false;
  String? error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      f = await Api(settings).insight('us');
    } catch (e) {
      error = '불러오기 실패: $e';
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cur = settings.currentAssetEffective;
    final target = settings.targetAssetKrw;
    final prog = target > 0 ? (cur / target).clamp(0.0, 1.0) : 0.0;
    return Scaffold(
      appBar: AppBar(title: const Text('인사이트'), actions: [IconButton(onPressed: loading ? null : _load, icon: const Icon(Icons.refresh))]),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(10),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Text('현재 자산 / 목표', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    const Spacer(),
                    Text('${fmtKrw(cur)} / ${fmtKrw(target)} (${(prog * 100).toStringAsFixed(0)}%)', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ]),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: prog, minHeight: 8, borderRadius: BorderRadius.circular(4)),
                ]),
              ),
            ),
            if (loading && f == null) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
            if (error != null) Padding(padding: const EdgeInsets.all(8), child: Text(error!, style: const TextStyle(color: Colors.red))),
            if (f != null) ..._content(f!),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  List<Widget> _content(InsightFile f) {
    final invest = f.signal == '지금 투입';
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
        child: Text('기준 ${f.date} · 갱신 ${fmtUpdated(f.generatedAt)} (매주 월요일)', style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ),
      if (f.summaryKo != null && f.summaryKo!.trim().isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('이번 주 요약', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(f.summaryKo!.trim(), style: const TextStyle(fontSize: 14, height: 1.5)),
            ]),
          ),
        ),
      Card(
        color: (invest ? Colors.green : Colors.orange).withValues(alpha: 0.15),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(invest ? Icons.wb_sunny : Icons.cloud, color: invest ? Colors.green : Colors.orange),
              const SizedBox(width: 8),
              Text('시장 온도: ${f.signal}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 6),
            Text('${f.index} ${fmtPrice(f.close)} · SMA200 ${fmtPrice(f.sma200)} (${fmtPct(f.pctVsSma200)}) → ${f.aboveSma200 ? '위' : '아래'}'),
            Text('S&P 500 중 SMA200 위 비율(브레드스): ${f.breadthPct?.toStringAsFixed(1) ?? '-'}%'),
            const SizedBox(height: 4),
            Text(
              invest ? '지수가 200일선 위, 절반 넘는 종목이 200일선 위 → 장기 자금 지금 투입' : '조건 미충족 → 장기 자금은 3개월에 나눠 분할 투입',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            if (f.previousSignal != null && f.signalChanged) Text('지난주: ${f.previousSignal} → 이번 주 변경됨', style: const TextStyle(fontSize: 12, color: Colors.red)),
          ]),
        ),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('섹터 순위 (ETF는 지표용, 매수 대상 아님)', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Table(
              columnWidths: const {0: FlexColumnWidth(0.5), 1: FlexColumnWidth(2), 2: FlexColumnWidth(1), 3: FlexColumnWidth(1), 4: FlexColumnWidth(1)},
              children: [
                const TableRow(children: [
                  Text('#', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  Text('섹터', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  Text('1개월', style: TextStyle(fontSize: 12, color: Colors.grey), textAlign: TextAlign.right),
                  Text('3개월', style: TextStyle(fontSize: 12, color: Colors.grey), textAlign: TextAlign.right),
                  Text('6개월', style: TextStyle(fontSize: 12, color: Colors.grey), textAlign: TextAlign.right),
                ]),
                for (final s in f.sectors)
                  TableRow(children: [
                    Text('${s.rank ?? ''}'),
                    Text('${s.name} (${s.etf})'),
                    Text(fmtPct(s.r1m), textAlign: TextAlign.right, style: TextStyle(color: pctColor(s.r1m, context))),
                    Text(fmtPct(s.r3m), textAlign: TextAlign.right, style: TextStyle(color: pctColor(s.r3m, context), fontWeight: FontWeight.bold)),
                    Text(fmtPct(s.r6m), textAlign: TextAlign.right, style: TextStyle(color: pctColor(s.r6m, context))),
                  ]),
              ],
            ),
          ]),
        ),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('이번 달 변화 (장기 후보 ${f.longDate ?? ''})', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('신규 진입: ${f.entered.isEmpty ? '없음' : f.entered.join(', ')}'),
            Text('이탈: ${f.exited.isEmpty ? '없음' : f.exited.join(', ')}'),
            if (f.replace.isNotEmpty) Text('교체 후보: ${f.replace.map((r) => '${r['ticker']} (${r['reason']})').join(', ')}', style: const TextStyle(color: Colors.orange)),
            const SizedBox(height: 4),
            Text('상위 5 중 2주 내 실적 발표: ${f.upcomingEarnings.isEmpty ? '없음' : f.upcomingEarnings.map((e) => '${e['ticker']} ${e['date']}').join(', ')}'),
          ]),
        ),
      ),
    ];
  }
}
