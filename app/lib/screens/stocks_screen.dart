import 'package:flutter/material.dart';

import '../main.dart';
import '../models.dart';
import '../services/api.dart';
import '../util.dart';
import '../widgets/evidence.dart';
import 'chart_screen.dart';

class StocksScreen extends StatefulWidget {
  const StocksScreen({super.key});

  @override
  State<StocksScreen> createState() => _StocksScreenState();
}

class _StocksScreenState extends State<StocksScreen> with AutomaticKeepAliveClientMixin {
  String market = 'us';
  String horizon = 'short';
  ScreenerFile<ShortItem>? shortF;
  ScreenerFile<ShortItem>? epF;
  ScreenerFile<MidItem>? midF;
  LongFile? longF;
  ContextFile? ctx;
  AnalysisFile? analysis;
  final Set<String> expanded = {};
  bool loading = false;
  String? error;
  late final Api api = Api(settings);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (market == 'kr') return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (horizon == 'short') {
        shortF = await api.shortList(market);
        try {
          epF = await api.epList(market);
        } catch (_) {
          epF = null;
        }
      } else if (horizon == 'mid') {
        midF = await api.midList(market);
      } else {
        longF = await api.longList(market);
      }
    } catch (e) {
      error = '불러오기 실패: $e';
    }
    if (mounted) setState(() {});
    try {
      ctx = await api.context(market);
    } catch (_) {}
    analysis = await api.analysis(market);
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('종목'),
        actions: [IconButton(onPressed: loading ? null : _load, icon: const Icon(Icons.refresh))],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(96),
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'us', label: Text('미국'), icon: Icon(Icons.flag_outlined)),
                  ButtonSegment(value: 'kr', label: Text('국내 (준비 중)'), icon: Icon(Icons.flag)),
                ],
                selected: {market},
                onSelectionChanged: (s) {
                  setState(() => market = s.first);
                  _load();
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'short', label: Text('단기')),
                  ButtonSegment(value: 'mid', label: Text('중기')),
                  ButtonSegment(value: 'long', label: Text('장기')),
                ],
                selected: {horizon},
                onSelectionChanged: (s) {
                  setState(() => horizon = s.first);
                  _load();
                },
              ),
            ),
          ]),
        ),
      ),
      body: RefreshIndicator(onRefresh: _load, child: market == 'kr' ? _placeholder() : _body()),
    );
  }

  Widget _placeholder() => ListView(children: const [
        SizedBox(height: 120),
        Icon(Icons.construction, size: 48, color: Colors.grey),
        SizedBox(height: 12),
        Center(child: Text('국내주식은 준비 중입니다.\n미국 버전이 안정화된 뒤 추가됩니다.', textAlign: TextAlign.center)),
      ]);

  Widget _body() {
    final children = <Widget>[];
    if (loading && shortF == null && midF == null && longF == null) {
      children.add(const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())));
    }
    if (error != null) children.add(Padding(padding: const EdgeInsets.all(12), child: Text(error!, style: const TextStyle(color: Colors.red))));
    if (horizon == 'short') {
      children.addAll(_shortBody());
    } else if (horizon == 'mid') {
      children.addAll(_midBody());
    } else {
      children.addAll(_longBody());
    }
    children.add(const SizedBox(height: 40));
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 10), children: children);
  }

  Widget _header(String title, String date, String updated, {bool stale = false, String? extra}) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
        child: Row(children: [
          Expanded(child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold))),
          Text('${date.isNotEmpty ? '기준 $date' : ''}${updated.isNotEmpty ? ' · 갱신 ${fmtUpdated(updated)}' : ''}${extra ?? ''}${stale ? ' (오프라인)' : ''}',
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ]),
      );

  Widget _empty(String msg) => Padding(padding: const EdgeInsets.all(16), child: Center(child: Text(msg, style: const TextStyle(color: Colors.grey))));

  /// 근거 펼침 영역 (지표 이유 + 뉴스 + 애널리스트 + 재무 요약 + Claude 코멘트)
  Widget _evidence(String ticker, List<String> reasons) {
    final c = ctx?.items[ticker];
    final a = analysis?.tickers[ticker];
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('왜 뽑혔나 (지표 근거)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
        reasonList(reasons),
        if (a != null && (a['text'] ?? '').toString().isNotEmpty) ...[
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.auto_awesome, size: 14),
            const SizedBox(width: 4),
            Text('Claude 해석 · ${a['view'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          ]),
          Text(a['text'].toString(), style: const TextStyle(fontSize: 12, height: 1.4)),
        ],
        if (c != null) ...[
          const SizedBox(height: 6),
          Wrap(spacing: 10, runSpacing: 2, children: [
            if (c.overall != null) gradeChip(c.overall, label: '재무 ${c.overall} ${c.overallWord ?? ''}'),
            if (c.analyst['recommendation'] != null) kv('애널리스트', '${c.analyst['recommendation']} (${c.analyst['count'] ?? '-'}명)'),
            if (c.analyst['upside_pct'] != null) kv('목표가 대비', fmtPct((c.analyst['upside_pct'] as num).toDouble())),
            if (c.short['pct_of_float'] != null) kv('공매도', '${c.short['pct_of_float']}%'),
            if (c.nextEarnings != null) kv('실적', c.nextEarnings!),
          ]),
          if (c.healthSummary.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 3), child: Text(c.healthSummary, style: const TextStyle(fontSize: 11, color: Colors.grey))),
          newsList(c.news, title: '최근 뉴스', max: 4),
        ] else if (ctx == null) ...[
          const Padding(padding: EdgeInsets.only(top: 6), child: Text('뉴스·재무 근거 불러오는 중… (차트 화면에서 더 자세히)', style: TextStyle(fontSize: 11, color: Colors.grey))),
        ],
        const Padding(padding: EdgeInsets.only(top: 4), child: Text('종목을 누르면 차트 · 뉴스 · 재무 해석 전체를 볼 수 있습니다.', style: TextStyle(fontSize: 10, color: Colors.grey))),
      ]),
    );
  }

  Widget _expandButton(String key) => TextButton.icon(
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
        onPressed: () => setState(() => expanded.contains(key) ? expanded.remove(key) : expanded.add(key)),
        icon: Icon(expanded.contains(key) ? Icons.expand_less : Icons.expand_more, size: 16),
        label: Text(expanded.contains(key) ? '근거 접기' : '근거 보기', style: const TextStyle(fontSize: 11)),
      );

  // ------------------------------------------------------------------ 단기
  List<Widget> _shortBody() {
    final out = <Widget>[];
    final f = shortF;
    final cap = settings.capital(market, 'short');
    if (f != null) {
      out.add(_header('돌파 대기 (내일 트리거가 돌파 시 진입)', f.date, f.generatedAt, stale: f.raw['_stale'] == true));
      out.add(Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 4),
        child: Text('자금 ${fmtMoney(cap, market)} · 리스크 ${f.riskPct}% · 최대 ${settings.maxPositionsShort}종목 · 수량은 진입가=트리거가 가정 · ★ = 오늘의 1픽',
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ));
      if (f.items.isEmpty) out.add(_empty(f.raw['error']?.toString() ?? '오늘은 돌파 대기 종목이 없습니다'));
      for (final it in f.items) {
        out.add(_shortCard(it, cap, f.riskPct));
      }
    }
    final e = epF;
    out.add(_header('EP (에피소딕 피벗, 장중)', e?.date ?? '', e?.generatedAt ?? '', stale: e?.raw['_stale'] == true, extra: (e?.asofEt.isNotEmpty ?? false) ? ' · ${e!.asofEt} ET' : null));
    if (e == null || e.items.isEmpty) {
      out.add(_empty('EP 후보가 없습니다 (미국장 개장 30분 뒤 갱신)'));
    } else {
      for (final it in e.items) {
        out.add(_shortCard(it, cap, e.riskPct));
      }
    }
    return out;
  }

  Widget _shortCard(ShortItem it, double cap, double riskPct) {
    final qty = suggestQty(it.triggerPrice, it.stopPrice, cap, riskPct, settings.maxPositionPct);
    final isEp = it.setup == 'ep';
    final key = '${it.setup}:${it.ticker}';
    return Card(
      color: it.isPick ? Colors.amber.withValues(alpha: 0.12) : null,
      child: InkWell(
        onTap: () => _openChart(it.ticker, it.name, it.exchange, trigger: it.triggerPrice, stop: it.stopPrice, horizon: 'short', qty: qty),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (it.isPick) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.star, color: Colors.amber, size: 18)),
              Text(it.ticker, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Expanded(child: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.grey))),
              if (isEp)
                Chip(label: Text(it.triggered ? '진입가 도달' : '대기', style: const TextStyle(fontSize: 11)), backgroundColor: it.triggered ? Colors.green.withValues(alpha: 0.2) : null, visualDensity: VisualDensity.compact)
              else if (it.pickRank != null)
                Text('#${it.pickRank}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ]),
            const SizedBox(height: 4),
            Wrap(spacing: 14, runSpacing: 2, children: [
              kv(isEp ? '진입가' : '트리거가', fmtPrice(it.triggerPrice, market: market), bold: true),
              kv('손절가', fmtPrice(it.stopPrice, market: market), color: Colors.blue.shade400),
              kv('수량', '$qty주', bold: true),
              kv('ADR', fmtPct(it.adr20, sign: false)),
              kv('3개월', fmtPct(it.r3m), color: pctColor(it.r3m, context)),
              if (isEp) kv('갭', fmtPct(it.gapPct)),
              if (isEp) kv('거래량', '${it.volMult?.toStringAsFixed(1) ?? '-'}x'),
              if (isEp) kv('현재가', fmtPrice(it.last, market: market)),
              if (!isEp && it.close != null) kv('종가', fmtPrice(it.close, market: market)),
              if (!isEp && it.boxDays != null) kv('횡보', '${it.boxDays}일'),
            ]),
            Row(children: [
              _expandButton(key),
              const Spacer(),
              if (ctx?.items[it.ticker]?.overall != null) gradeChip(ctx!.items[it.ticker]!.overall, label: '재무 ${ctx!.items[it.ticker]!.overall}'),
              if (analysis?.tickers[it.ticker]?['view'] != null)
                Padding(padding: const EdgeInsets.only(left: 6), child: Text('Claude: ${analysis!.tickers[it.ticker]!['view']}', style: const TextStyle(fontSize: 11))),
            ]),
            if (expanded.contains(key)) _evidence(it.ticker, shortReasons(it)),
          ]),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 중기
  List<Widget> _midBody() {
    final out = <Widget>[];
    final f = midF;
    final cap = settings.capital(market, 'mid');
    if (f == null) return out;
    out.add(_header('추세 눌림목 (내일 시가 매수 후보)', f.date, f.generatedAt, stale: f.raw['_stale'] == true));
    out.add(Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Text('자금 ${fmtMoney(cap, market)} · 리스크 ${f.riskPct}% · 최대 ${settings.maxPositionsMid}종목', style: const TextStyle(fontSize: 11, color: Colors.grey)),
    ));
    if (f.items.isEmpty) out.add(_empty(f.raw['error']?.toString() ?? '오늘은 중기 후보가 없습니다'));
    for (final it in f.items) {
      final qty = suggestQty(it.entryPrice, it.stopPrice, cap, f.riskPct, settings.maxPositionPct);
      final key = 'mid:${it.ticker}';
      out.add(Card(
        child: InkWell(
          onTap: () => _openChart(it.ticker, it.name, it.exchange, trigger: it.entryPrice, stop: it.stopPrice, target: it.target2r, horizon: 'mid', qty: qty),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(it.ticker, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Expanded(child: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.grey))),
              ]),
              const SizedBox(height: 4),
              Wrap(spacing: 14, runSpacing: 2, children: [
                kv('진입가', fmtPrice(it.entryPrice, market: market), bold: true),
                kv('손절가', fmtPrice(it.stopPrice, market: market), color: Colors.blue.shade400),
                kv('2R 목표', fmtPrice(it.target2r, market: market), color: Colors.red.shade400),
                kv('수량', '$qty주', bold: true),
                kv('6개월', fmtPct(it.r6m), color: pctColor(it.r6m, context)),
                kv('20일선 대비', fmtPct(it.distSma20)),
                kv('ADR', fmtPct(it.adr20, sign: false)),
              ]),
              Row(children: [
                _expandButton(key),
                const Spacer(),
                if (ctx?.items[it.ticker]?.overall != null) gradeChip(ctx!.items[it.ticker]!.overall, label: '재무 ${ctx!.items[it.ticker]!.overall}'),
              ]),
              if (expanded.contains(key)) _evidence(it.ticker, midReasons(it)),
            ]),
          ),
        ),
      ));
    }
    return out;
  }

  // ------------------------------------------------------------------ 장기
  List<Widget> _longBody() {
    final out = <Widget>[];
    final f = longF;
    if (f == null) return out;
    final cap = settings.capital(market, 'long');
    out.add(_header('장기 후보 상위 ${f.candidates.length}', f.date, f.generatedAt));
    final top = f.candidates.where((c) => c.hold).toList();
    if (top.isNotEmpty) {
      final per = cap / f.holdN;
      out.add(Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('배분표 · 장기 자금 ${fmtMoney(cap, market)} → 상위 ${f.holdN}종목 균등 (${fmtMoney(per, market)}씩)', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 6),
            Table(
              columnWidths: const {0: FlexColumnWidth(1.2), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1), 3: FlexColumnWidth(1)},
              children: [
                const TableRow(children: [
                  Text('종목', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  Text('종가', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  Text('금액', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  Text('수량', style: TextStyle(fontSize: 12, color: Colors.grey)),
                ]),
                for (final c in top)
                  TableRow(children: [
                    Text(c.ticker, style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(fmtPrice(c.close, market: market)),
                    Text(fmtMoney(per, market)),
                    Text(c.close != null && c.close! > 0 ? '${(per / c.close!).floor()}주' : '-'),
                  ]),
              ],
            ),
          ]),
        ),
      ));
    }
    if (f.previousHoldings.any((h) => h.replace)) {
      out.add(Card(
        color: Colors.orange.withValues(alpha: 0.15),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('교체 후보 (지난달 상위 5 중)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            for (final h in f.previousHoldings.where((h) => h.replace)) Text('${h.ticker}: ${h.reason}', style: const TextStyle(fontSize: 12)),
          ]),
        ),
      ));
    }
    if (f.candidates.isEmpty) out.add(_empty('장기 후보가 아직 없습니다 (매월 첫 거래일 갱신)'));
    for (final c in f.candidates) {
      final key = 'long:${c.ticker}';
      out.add(Card(
        child: InkWell(
          onTap: () => _openChart(c.ticker, c.name, c.exchange, horizon: 'long'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('${c.rank ?? '-'}. ', style: const TextStyle(fontSize: 15, color: Colors.grey)),
                Text(c.ticker, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Expanded(child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.grey))),
                if (c.hold) const Chip(label: Text('편입', style: TextStyle(fontSize: 11)), visualDensity: VisualDensity.compact),
                Text(' ${c.score?.toStringAsFixed(0) ?? '-'}점', style: const TextStyle(fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 4),
              Wrap(spacing: 12, runSpacing: 2, children: [
                kv('ROE', fmtPct(c.roe, sign: false)),
                kv('매출성장', fmtPct(c.revenueGrowth)),
                kv('영업이익률', fmtPct(c.operatingMargin, sign: false)),
                kv('PEG', c.peg?.toStringAsFixed(2) ?? '-'),
                kv('fwd PE', c.forwardPe?.toStringAsFixed(1) ?? '-'),
                kv('52주고가 대비', fmtPct(c.pctFrom52wHigh)),
                if (c.nextEarnings != null) kv('실적', c.nextEarnings!),
              ]),
              const SizedBox(height: 4),
              Wrap(spacing: 4, runSpacing: 2, children: [
                for (final p in c.passed)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                    child: Text(_condLabel(p), style: const TextStyle(fontSize: 10)),
                  ),
              ]),
              Row(children: [_expandButton(key)]),
              if (expanded.contains(key)) _evidence(c.ticker, longReasons(c)),
            ]),
          ),
        ),
      ));
    }
    return out;
  }

  String _condLabel(String k) {
    switch (k) {
      case 'roe':
        return 'ROE';
      case 'revenue_growth':
        return '매출성장';
      case 'operating_margin':
        return '영업이익률';
      case 'fcf':
        return 'FCF';
      case 'debt_to_equity':
        return '부채';
      case 'trend':
        return '추세';
      case 'rs':
        return '상대강도';
      case 'value':
        return '밸류';
    }
    return k;
  }

  void _openChart(String ticker, String name, String exchange, {double? trigger, double? stop, double? target, String horizon = 'short', int? qty}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChartScreen(ticker: ticker, name: name, exchange: exchange, market: market, trigger: trigger, stop: stop, target: target, horizon: horizon, qty: qty,
          context: ctx?.items[ticker], analysis: analysis?.tickers[ticker]),
    ));
  }
}
