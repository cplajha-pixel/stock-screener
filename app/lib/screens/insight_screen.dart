import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../models.dart';
import '../services/api.dart';
import '../services/saveticker.dart';
import '../util.dart';
import '../widgets/evidence.dart';
import 'picks_screen.dart';

/// 인사이트: 오늘의 시장(매일) + 이번 주 시장 온도(주 1회) + Claude 분석(루틴) + 1픽 성적표
class InsightScreen extends StatefulWidget {
  const InsightScreen({super.key});

  @override
  State<InsightScreen> createState() => _InsightScreenState();
}

class _InsightScreenState extends State<InsightScreen> with AutomaticKeepAliveClientMixin {
  InsightFile? weekly;
  DailyFile? daily;
  AnalysisFile? analysis;
  PicksFile? picks;
  List<NewsItem> liveNews = [];
  List<CalEvent> liveCal = [];
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
    final api = Api(settings);
    try {
      daily = await api.daily('us');
    } catch (e) {
      error = '오늘의 시장 불러오기 실패: $e';
    }
    try {
      weekly = await api.insight('us');
    } catch (_) {}
    analysis = await api.analysis('us');
    try {
      picks = await api.picks('us');
    } catch (_) {}
    if (mounted) setState(() {});
    // 실시간: 세이브티커 직접 조회 (실패해도 저장된 파일로 대체)
    final n = await SaveTicker.latest(n: 15);
    final c = await SaveTicker.calendar(daysBack: 0, daysFwd: 6);
    if (n.isNotEmpty) liveNews = n;
    if (c.isNotEmpty) liveCal = c;
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cur = settings.currentAssetEffective;
    final target = settings.targetAssetKrw;
    final prog = target > 0 ? (cur / target).clamp(0.0, 1.0) : 0.0;
    final d = daily;
    final cal = liveCal.isNotEmpty ? liveCal : (d?.calendar ?? const <CalEvent>[]);
    final news = liveNews.isNotEmpty ? liveNews : (d?.topStories ?? const <NewsItem>[]);
    return Scaffold(
      appBar: AppBar(
        title: const Text('인사이트'),
        actions: [
          IconButton(tooltip: '1픽 성적표', icon: const Icon(Icons.emoji_events_outlined), onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PicksScreen()))),
          IconButton(onPressed: loading ? null : _load, icon: const Icon(Icons.refresh)),
        ],
      ),
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
            if (error != null) Padding(padding: const EdgeInsets.all(8), child: Text(error!, style: const TextStyle(color: Colors.red))),
            if (loading && d == null) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),

            // ---- Claude 분석 (루틴)
            if (analysis != null && analysis!.marketBrief.isNotEmpty)
              Card(
                color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Icon(Icons.auto_awesome, size: 18),
                      const SizedBox(width: 6),
                      Text('오늘의 해석 (${analysis!.date})', style: const TextStyle(fontWeight: FontWeight.bold)),
                    ]),
                    const SizedBox(height: 6),
                    Text(analysis!.marketBrief, style: const TextStyle(fontSize: 13, height: 1.5)),
                    if (analysis!.watch.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      const Text('오늘 지켜볼 것', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      for (final w in analysis!.watch) Text('• $w', style: const TextStyle(fontSize: 12)),
                    ],
                    if (analysis!.pickComment.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text('1픽 코멘트: ${analysis!.pickComment}', style: const TextStyle(fontSize: 12)),
                    ],
                    const SizedBox(height: 4),
                    const Text('Claude 가 뉴스·지표·후보 근거를 읽고 쓴 해석입니다. 투자 권유가 아닙니다.', style: TextStyle(fontSize: 10, color: Colors.grey)),
                  ]),
                ),
              ),

            // ---- 오늘의 시장
            if (d != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
                child: Row(children: [
                  const Text('오늘의 시장', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text('기준 ${d.date} · 갱신 ${fmtUpdated(d.generatedAt)}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ]),
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('숫자가 뜻하는 것', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 4),
                    for (final e in d.explain) Padding(padding: const EdgeInsets.only(top: 3), child: Text('• $e', style: const TextStyle(fontSize: 12, height: 1.35))),
                    if (d.shortUniverseSize != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text('• 단기 유니버스(강한 모멘텀 + 변동성 종목) ${d.shortUniverseSize}개: ${d.shortUniverseSize! >= 150 ? '많음 — 시장이 뜨거움' : d.shortUniverseSize! >= 80 ? '보통' : '적음 — 돌파 기회 드묾'}',
                            style: const TextStyle(fontSize: 12, height: 1.35)),
                      ),
                  ]),
                ),
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('거시 지표', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 4),
                    Table(
                      columnWidths: const {0: FlexColumnWidth(2.2), 1: FlexColumnWidth(1.3), 2: FlexColumnWidth(1), 3: FlexColumnWidth(1), 4: FlexColumnWidth(1)},
                      children: [
                        const TableRow(children: [
                          Text('', style: TextStyle(fontSize: 11)),
                          Text('현재', style: TextStyle(fontSize: 11, color: Colors.grey), textAlign: TextAlign.right),
                          Text('1일', style: TextStyle(fontSize: 11, color: Colors.grey), textAlign: TextAlign.right),
                          Text('1주', style: TextStyle(fontSize: 11, color: Colors.grey), textAlign: TextAlign.right),
                          Text('1개월', style: TextStyle(fontSize: 11, color: Colors.grey), textAlign: TextAlign.right),
                        ]),
                        for (final m in d.macro)
                          TableRow(children: [
                            Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(m.name, style: const TextStyle(fontSize: 12))),
                            Text(m.last?.toStringAsFixed(2) ?? '-', style: const TextStyle(fontSize: 12), textAlign: TextAlign.right),
                            Text(m.level ? (m.d1Abs == null ? '-' : '${m.d1Abs! >= 0 ? '+' : ''}${m.d1Abs!.toStringAsFixed(2)}') : fmtPct(m.d1), style: TextStyle(fontSize: 12, color: pctColor(m.level ? m.d1Abs : m.d1, context)), textAlign: TextAlign.right),
                            Text(fmtPct(m.w1), style: TextStyle(fontSize: 12, color: pctColor(m.w1, context)), textAlign: TextAlign.right),
                            Text(fmtPct(m.m1), style: TextStyle(fontSize: 12, color: pctColor(m.m1, context)), textAlign: TextAlign.right),
                          ]),
                      ],
                    ),
                    if (d.fred.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text('최근 발표된 미국 경제지표 (FRED)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      for (final f in d.fred)
                        Text('• ${f['name']}: ${f['value']} (이전 ${f['previous'] ?? '-'}) · ${f['date']}', style: const TextStyle(fontSize: 11)),
                    ],
                  ]),
                ),
              ),
            ],

            // ---- 지표 발표 일정 (실시간)
            if (cal.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Text('지표·이벤트 일정 (한국시간)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      const Spacer(),
                      Text(liveCal.isNotEmpty ? '실시간' : '저장본', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                    ]),
                    const SizedBox(height: 4),
                    for (final e in cal.where((e) => e.isToday || !e.isPast).take(14))
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Row(children: [
                          SizedBox(width: 82, child: Text(e.kst, style: TextStyle(fontSize: 11, color: e.isToday ? Colors.red : Colors.grey, fontWeight: e.isToday ? FontWeight.bold : null))),
                          Expanded(child: Text(e.title, style: TextStyle(fontSize: 12, fontWeight: e.importance >= 3 ? FontWeight.bold : null))),
                          Text('★' * e.importance, style: const TextStyle(fontSize: 11, color: Colors.orange)),
                        ]),
                      ),
                    const Padding(padding: EdgeInsets.only(top: 4), child: Text('발표치는 "[속보]" 뉴스로 바로 올라옵니다 (아래 주요 뉴스). 출처: 세이브티커', style: TextStyle(fontSize: 10, color: Colors.grey))),
                  ]),
                ),
              ),

            // ---- 주요 뉴스 (실시간)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: newsList(news, title: liveNews.isNotEmpty ? '주요 뉴스 (실시간)' : '주요 뉴스', max: 12, showTickers: true),
              ),
            ),

            // ---- 이번 주 시장 온도 (주 1회)
            if (weekly != null) ..._weekly(weekly!),

            // ---- 1픽 성적표 요약
            if (picks != null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.emoji_events_outlined),
                  title: Text('1픽 성적표: 승률 ${picks!.summary['win_rate'] ?? '-'}% · 평균 ${picks!.summary['avg_pnl_pct'] == null ? '-' : fmtPct((picks!.summary['avg_pnl_pct'] as num).toDouble())} · ${picks!.summary['total'] ?? 0}건'),
                  subtitle: picks!.picks.isNotEmpty ? Text('최근 1픽: ${picks!.picks.first.date} ${picks!.picks.first.ticker} (${picks!.picks.first.status})') : null,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PicksScreen())),
                ),
              ),
            OutlinedButton.icon(
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('세이브티커 열기 (리포트는 로그인 후 열람)'),
              onPressed: () => launchUrl(Uri.parse('https://www.saveticker.com/report'), mode: LaunchMode.externalApplication),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  List<Widget> _weekly(InsightFile f) {
    final invest = f.signal == '지금 투입';
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
        child: Text('이번 주 시장 온도 · 기준 ${f.date} (매주 월요일)', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      ),
      if (f.summaryKo != null && f.summaryKo!.trim().isNotEmpty)
        Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(f.summaryKo!.trim(), style: const TextStyle(fontSize: 13, height: 1.5)))),
      Card(
        color: (invest ? Colors.green : Colors.orange).withValues(alpha: 0.15),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(invest ? Icons.wb_sunny : Icons.cloud, color: invest ? Colors.green : Colors.orange),
              const SizedBox(width: 8),
              Text('장기 자금: ${f.signal}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 4),
            Text('${f.index} ${fmtPrice(f.close)} vs 200일선 ${fmtPrice(f.sma200)} (${fmtPct(f.pctVsSma200)}) · S&P500 중 200일선 위 ${f.breadthPct?.toStringAsFixed(1) ?? '-'}%', style: const TextStyle(fontSize: 12)),
            Text(invest ? '규칙: 지수가 200일선 위이고 절반 넘는 종목이 200일선 위면 "지금 투입"' : '규칙 미충족 → 장기 자금은 3개월에 나눠 분할 투입', style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ]),
        ),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('섹터 순위 (3개월 수익률 순, ETF는 지표용)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 6),
            Table(
              columnWidths: const {0: FlexColumnWidth(0.5), 1: FlexColumnWidth(2), 2: FlexColumnWidth(1), 3: FlexColumnWidth(1), 4: FlexColumnWidth(1)},
              children: [
                const TableRow(children: [
                  Text('#', style: TextStyle(fontSize: 11, color: Colors.grey)),
                  Text('섹터', style: TextStyle(fontSize: 11, color: Colors.grey)),
                  Text('1개월', style: TextStyle(fontSize: 11, color: Colors.grey), textAlign: TextAlign.right),
                  Text('3개월', style: TextStyle(fontSize: 11, color: Colors.grey), textAlign: TextAlign.right),
                  Text('6개월', style: TextStyle(fontSize: 11, color: Colors.grey), textAlign: TextAlign.right),
                ]),
                for (final s in f.sectors)
                  TableRow(children: [
                    Text('${s.rank ?? ''}', style: const TextStyle(fontSize: 12)),
                    Text('${s.name} (${s.etf})', style: const TextStyle(fontSize: 12)),
                    Text(fmtPct(s.r1m), textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: pctColor(s.r1m, context))),
                    Text(fmtPct(s.r3m), textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: pctColor(s.r3m, context), fontWeight: FontWeight.bold)),
                    Text(fmtPct(s.r6m), textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: pctColor(s.r6m, context))),
                  ]),
              ],
            ),
            const SizedBox(height: 4),
            const Text('읽는 법: 상위 섹터에 속한 후보가 돌파에 성공할 확률이 높고, 하위 섹터는 반등이 짧게 끝나기 쉽습니다.', style: TextStyle(fontSize: 11, color: Colors.grey)),
          ]),
        ),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('이번 달 장기 후보 변화 (${f.longDate ?? ''})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 4),
            Text('신규 진입: ${f.entered.isEmpty ? '없음' : f.entered.join(', ')}', style: const TextStyle(fontSize: 12)),
            Text('이탈: ${f.exited.isEmpty ? '없음' : f.exited.join(', ')}', style: const TextStyle(fontSize: 12)),
            if (f.replace.isNotEmpty) Text('교체 후보: ${f.replace.map((r) => '${r['ticker']} (${r['reason']})').join(', ')}', style: const TextStyle(fontSize: 12, color: Colors.orange)),
            Text('상위 5 중 2주 내 실적 발표: ${f.upcomingEarnings.isEmpty ? '없음' : f.upcomingEarnings.map((e) => '${e['ticker']} ${e['date']}').join(', ')}', style: const TextStyle(fontSize: 12)),
          ]),
        ),
      ),
    ];
  }
}
