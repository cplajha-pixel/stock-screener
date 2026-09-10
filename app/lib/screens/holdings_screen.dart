import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../models.dart';
import '../services/api.dart';
import '../services/holdings.dart';
import '../util.dart';
import 'chart_screen.dart';

class HoldingsScreen extends StatefulWidget {
  const HoldingsScreen({super.key});

  @override
  State<HoldingsScreen> createState() => _HoldingsScreenState();
}

class _HoldingsScreenState extends State<HoldingsScreen> with AutomaticKeepAliveClientMixin {
  HoldingsStore? store;
  List<Holding> items = [];
  final Map<String, HoldingSignal> signals = {};
  bool loading = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    store = await HoldingsStore.load();
    items = store!.all();
    if (mounted) setState(() {});
    await _evaluate();
  }

  Future<void> _evaluate() async {
    if (items.isEmpty) return;
    setState(() => loading = true);
    LongFile? lf;
    if (items.any((h) => h.horizon == 'long')) {
      try {
        lf = await Api(settings).longList('us');
      } catch (_) {}
    }
    for (final h in items) {
      final s = await SignalEngine.evaluate(h, longFile: lf);
      signals[h.id] = s;
      if (mounted) setState(() {});
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _add([Holding? initial]) async {
    final h = await showHoldingDialog(context, initial: initial);
    if (h == null || store == null) return;
    await store!.upsert(h);
    items = store!.all();
    setState(() {});
    final s = await SignalEngine.evaluate(h);
    signals[h.id] = s;
    if (mounted) setState(() {});
  }

  Future<void> _remove(Holding h) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${h.ticker} 삭제'),
        content: const Text('보유 목록에서 지울까요?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('삭제')),
        ],
      ),
    );
    if (ok != true || store == null) return;
    await store!.remove(h.id);
    items = store!.all();
    signals.remove(h.id);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('보유'),
        actions: [IconButton(onPressed: loading ? null : _evaluate, icon: const Icon(Icons.refresh))],
      ),
      floatingActionButton: FloatingActionButton(onPressed: () => _add(), child: const Icon(Icons.add)),
      body: RefreshIndicator(
        onRefresh: _evaluate,
        child: items.isEmpty
            ? ListView(children: const [
                SizedBox(height: 120),
                Center(child: Text('보유 종목이 없습니다.\n+ 버튼으로 추가하세요. (폰에만 저장됩니다)', textAlign: TextAlign.center)),
              ])
            : ListView.builder(
                padding: const EdgeInsets.all(10),
                itemCount: items.length + 1,
                itemBuilder: (ctx, i) {
                  if (i == items.length) return const SizedBox(height: 80);
                  final h = items[i];
                  final s = signals[h.id];
                  return _card(h, s);
                },
              ),
      ),
    );
  }

  Widget _card(Holding h, HoldingSignal? s) {
    final alert = s?.hasAlert ?? false;
    return Card(
      color: alert ? Colors.red.withValues(alpha: 0.12) : null,
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ChartScreen(
            ticker: h.ticker,
            name: h.name,
            exchange: h.exchange,
            market: h.market,
            trigger: h.entryPrice,
            stop: h.stopPrice,
            target: h.horizon == 'mid' && h.stopPrice != null ? h.entryPrice + 2 * (h.entryPrice - h.stopPrice!) : null,
            horizon: h.horizon,
          ),
        )),
        onLongPress: () => _add(h),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text(h.ticker, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(width: 6),
                Chip(label: Text(horizonLabel(h.horizon), style: const TextStyle(fontSize: 11)), visualDensity: VisualDensity.compact),
                const SizedBox(width: 6),
                if (h.market == 'kr') const Text('국내', style: TextStyle(fontSize: 11, color: Colors.grey)),
                const Spacer(),
                if (s?.pnlPct != null)
                  Text(fmtPct(s!.pnlPct), style: TextStyle(fontWeight: FontWeight.bold, color: pctColor(s.pnlPct, context))),
                IconButton(onPressed: () => _remove(h), icon: const Icon(Icons.delete_outline, size: 20)),
              ]),
              Wrap(spacing: 12, runSpacing: 2, children: [
                kv('진입', '${fmtPrice(h.entryPrice, market: h.market)} (${h.entryDate})'),
                kv('수량', '${h.qty}주'),
                if (h.stopPrice != null) kv('손절', fmtPrice(h.stopPrice, market: h.market), color: Colors.blue.shade400),
                if (s?.last != null) kv('현재', fmtPrice(s!.last, market: h.market), bold: true),
                if (s != null) kv('보유', '${s.daysHeld}거래일'),
                if (s?.sma10 != null && h.horizon == 'short') kv('SMA10', fmtPrice(s!.sma10, market: h.market)),
                if (s?.sma50 != null && h.horizon == 'mid') kv('SMA50', fmtPrice(s!.sma50, market: h.market)),
                if (s?.sma200 != null && h.horizon == 'long') kv('SMA200', fmtPrice(s!.sma200, market: h.market)),
                if (s?.rank != null) kv('순위', '${s!.rank}위'),
              ]),
              if (s == null && loading) const Padding(padding: EdgeInsets.only(top: 4), child: Text('신호 계산 중…', style: TextStyle(fontSize: 12, color: Colors.grey))),
              if (s?.error != null) Text(s!.error!, style: const TextStyle(fontSize: 12, color: Colors.orange)),
              if (s != null && s.alerts.isEmpty && s.error == null)
                const Padding(padding: EdgeInsets.only(top: 4), child: Text('신호 없음 · 보유 유지', style: TextStyle(fontSize: 12, color: Colors.green))),
              for (final a in s?.alerts ?? const <String>[])
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Row(children: [
                    const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.red),
                    const SizedBox(width: 4),
                    Expanded(child: Text(a, style: const TextStyle(fontSize: 13, color: Colors.red, fontWeight: FontWeight.w600))),
                  ]),
                ),
              if (h.horizon != 'long')
                Row(children: [
                  Checkbox(
                    value: h.partialDone,
                    visualDensity: VisualDensity.compact,
                    onChanged: (v) async {
                      h.partialDone = v ?? false;
                      await store?.upsert(h);
                      final s2 = await SignalEngine.evaluate(h);
                      signals[h.id] = s2;
                      if (mounted) setState(() {});
                    },
                  ),
                  const Text('절반 매도 완료', style: TextStyle(fontSize: 12)),
                  const Spacer(),
                  const Text('길게 눌러 수정', style: TextStyle(fontSize: 10, color: Colors.grey)),
                ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// 보유 종목 입력/수정 다이얼로그. 저장하면 Holding, 취소하면 null.
Future<Holding?> showHoldingDialog(BuildContext context, {Holding? initial}) async {
  final ticker = TextEditingController(text: initial?.ticker ?? '');
  final name = TextEditingController(text: initial?.name ?? '');
  final entry = TextEditingController(text: initial == null ? '' : initial.entryPrice.toString());
  final qty = TextEditingController(text: initial == null ? '' : initial.qty.toString());
  final stop = TextEditingController(text: initial?.stopPrice?.toString() ?? '');
  final date = TextEditingController(text: initial?.entryDate ?? DateFormat('yyyy-MM-dd').format(DateTime.now()));
  var horizon = initial?.horizon ?? 'short';
  var market = initial?.market ?? 'us';
  final exchange = initial?.exchange ?? '';

  return showDialog<Holding>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSt) => AlertDialog(
        title: Text(initial == null ? '보유 종목 추가' : '보유 종목 수정'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                const Text('시장 '),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: market,
                  items: const [DropdownMenuItem(value: 'us', child: Text('미국')), DropdownMenuItem(value: 'kr', child: Text('국내'))],
                  onChanged: (v) => setSt(() => market = v ?? 'us'),
                ),
                const SizedBox(width: 16),
                const Text('구분 '),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: horizon,
                  items: const [
                    DropdownMenuItem(value: 'short', child: Text('단기')),
                    DropdownMenuItem(value: 'mid', child: Text('중기')),
                    DropdownMenuItem(value: 'long', child: Text('장기')),
                  ],
                  onChanged: (v) => setSt(() => horizon = v ?? 'short'),
                ),
              ]),
              TextField(controller: ticker, decoration: const InputDecoration(labelText: '티커 (예: AAPL / 005930)'), textCapitalization: TextCapitalization.characters),
              TextField(controller: name, decoration: const InputDecoration(labelText: '종목명 (선택)')),
              TextField(controller: entry, decoration: const InputDecoration(labelText: '진입가'), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
              TextField(
                controller: date,
                decoration: InputDecoration(
                  labelText: '진입일 (yyyy-MM-dd)',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.calendar_month),
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: ctx,
                        initialDate: DateTime.tryParse(date.text) ?? DateTime.now(),
                        firstDate: DateTime(2015),
                        lastDate: DateTime.now().add(const Duration(days: 1)),
                      );
                      if (d != null) date.text = DateFormat('yyyy-MM-dd').format(d);
                    },
                  ),
                ),
              ),
              TextField(controller: qty, decoration: const InputDecoration(labelText: '수량'), keyboardType: TextInputType.number),
              TextField(
                controller: stop,
                decoration: const InputDecoration(labelText: '손절가 (단기/중기 신호에 사용)'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          FilledButton(
            onPressed: () {
              final t = ticker.text.trim().toUpperCase();
              final e = double.tryParse(entry.text.trim());
              if (t.isEmpty || e == null || e <= 0) return;
              Navigator.pop(
                ctx,
                Holding(
                  id: initial?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
                  ticker: t,
                  name: name.text.trim(),
                  market: market,
                  horizon: horizon,
                  entryPrice: e,
                  entryDate: date.text.trim(),
                  qty: int.tryParse(qty.text.trim()) ?? 0,
                  stopPrice: double.tryParse(stop.text.trim()),
                  partialDone: initial?.partialDone ?? false,
                  exchange: exchange,
                ),
              );
            },
            child: const Text('저장'),
          ),
        ],
      ),
    ),
  );
}
