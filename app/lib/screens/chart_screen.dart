import 'dart:async';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../main.dart';
import '../models.dart';
import '../services/api.dart';
import '../services/holdings.dart';
import '../services/saveticker.dart';
import '../services/yahoo.dart';
import '../util.dart';
import '../widgets/candle_chart.dart';
import '../widgets/evidence.dart';
import 'holdings_screen.dart';

/// 종목 상세: 차트(TradingView 위젯 / 직접 그린 차트) · 근거·뉴스 · 재무 해석
class ChartScreen extends StatefulWidget {
  final String ticker, name, exchange, market, horizon;
  final double? trigger, stop, target;
  final int? qty;
  final ContextItem? context;
  final Map<String, dynamic>? analysis;

  const ChartScreen({
    super.key,
    required this.ticker,
    required this.name,
    required this.exchange,
    required this.market,
    this.trigger,
    this.stop,
    this.target,
    this.horizon = 'short',
    this.qty,
    this.context,
    this.analysis,
  });

  @override
  State<ChartScreen> createState() => _ChartScreenState();
}

class _ChartScreenState extends State<ChartScreen> with SingleTickerProviderStateMixin {
  WebViewController? _web;
  bool useWidget = true;
  bool widgetFailed = false;
  List<Candle>? candles;
  String? candleError;
  Timer? _check;
  late final TabController _tab = TabController(length: 3, vsync: this);
  ContextItem? ctx;
  List<NewsItem> liveNews = [];
  bool ctxLoading = false;

  String get tvSymbol => tradingViewSymbol(widget.ticker, widget.exchange, widget.market);

  @override
  void initState() {
    super.initState();
    ctx = widget.context;
    _initWeb();
    _loadContext();
  }

  Future<void> _loadContext() async {
    setState(() => ctxLoading = true);
    if (ctx == null) {
      try {
        final f = await Api(settings).context(widget.market);
        ctx = f.items[widget.ticker];
      } catch (_) {}
    }
    final n = await SaveTicker.newsFor(widget.ticker, n: 12);
    if (n.isNotEmpty) liveNews = n;
    if (mounted) setState(() => ctxLoading = false);
  }

  void _initWeb() {
    final dark = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    final html = '''
<!DOCTYPE html>
<html><head><meta name="viewport" content="width=device-width, initial-scale=1">
<style>html,body{margin:0;padding:0;height:100%;background:${dark ? '#131722' : '#ffffff'};}
.tradingview-widget-container{height:100%;width:100%;}
.tradingview-widget-container__widget{height:calc(100% - 28px);width:100%;}
.tradingview-widget-copyright{font-size:12px;line-height:28px;text-align:center;font-family:sans-serif;}
.tradingview-widget-copyright a{color:#2962FF;text-decoration:none;}
</style></head>
<body>
<div class="tradingview-widget-container">
  <div class="tradingview-widget-container__widget"></div>
  <div class="tradingview-widget-copyright"><a href="https://www.tradingview.com/" rel="noopener nofollow" target="_blank"><span class="blue-text">Track all markets on TradingView</span></a></div>
  <script type="text/javascript" src="https://s3.tradingview.com/external-embedding/embed-widget-advanced-chart.js" async>
  {
    "autosize": true,
    "symbol": "$tvSymbol",
    "interval": "D",
    "timezone": "${widget.market == 'kr' ? 'Asia/Seoul' : 'America/New_York'}",
    "theme": "${dark ? 'dark' : 'light'}",
    "style": "1",
    "locale": "kr",
    "allow_symbol_change": true,
    "hide_side_toolbar": true,
    "studies": ["STD;SMA"],
    "support_host": "https://www.tradingview.com"
  }
  </script>
</div>
</body></html>
''';
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(dark ? const Color(0xff131722) : Colors.white)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (req) {
          if (req.isMainFrame && !req.url.startsWith('https://www.tradingview.com/widgetembed')) {
            if (req.url.startsWith('http')) {
              launchUrl(Uri.parse(req.url), mode: LaunchMode.externalApplication);
              return NavigationDecision.prevent;
            }
          }
          return NavigationDecision.navigate;
        },
        onWebResourceError: (e) {
          if (e.isForMainFrame == true) _fallback();
        },
      ))
      ..loadHtmlString(html, baseUrl: 'https://www.tradingview.com/');
    _check = Timer(const Duration(seconds: 10), () async {
      if (!mounted || !useWidget || _web == null) return;
      try {
        final r = await _web!.runJavaScriptReturningResult("document.querySelector('iframe') ? '1' : '0'");
        if (r.toString().replaceAll('"', '') != '1') _fallback();
      } catch (_) {
        _fallback();
      }
    });
  }

  Future<void> _fallback() async {
    if (!mounted) return;
    setState(() {
      useWidget = false;
      widgetFailed = true;
    });
    await _loadCandles();
  }

  Future<void> _loadCandles() async {
    if (candles != null) return;
    try {
      final c = await Yahoo.daily(Yahoo.yahooSymbol(widget.ticker, widget.market), range: '1y');
      if (mounted) setState(() => candles = c);
    } catch (e) {
      if (mounted) setState(() => candleError = '$e');
    }
  }

  @override
  void dispose() {
    _check?.cancel();
    _tab.dispose();
    super.dispose();
  }

  Future<void> _openTradingView() async {
    final url = Uri.parse('https://www.tradingview.com/chart/?symbol=${Uri.encodeComponent(tvSymbol)}');
    try {
      final ok = await launchUrl(url, mode: LaunchMode.externalNonBrowserApplication);
      if (ok) return;
    } catch (_) {}
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  Future<void> _openBroker() async {
    final pkg = settings.brokerPackage;
    if (pkg.isNotEmpty) {
      try {
        await AndroidIntent(action: 'android.intent.action.MAIN', category: 'android.intent.category.LAUNCHER', package: pkg).launch();
        return;
      } catch (_) {}
    }
    final t = widget.market == 'kr' ? Yahoo.yahooSymbol(widget.ticker, 'kr') : widget.ticker;
    await launchUrl(Uri.parse('https://finance.yahoo.com/quote/$t'), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Text(widget.ticker),
          const SizedBox(width: 8),
          Expanded(child: Text(widget.name.isNotEmpty ? widget.name : (ctx?.name ?? ''), style: const TextStyle(fontSize: 13, color: Colors.grey), overflow: TextOverflow.ellipsis)),
        ]),
        actions: [
          IconButton(
            tooltip: useWidget ? '직접 그린 차트로' : 'TradingView 위젯으로',
            icon: Icon(useWidget ? Icons.candlestick_chart : Icons.web),
            onPressed: () async {
              if (useWidget) {
                setState(() => useWidget = false);
                await _loadCandles();
              } else {
                setState(() => useWidget = true);
              }
            },
          ),
        ],
        bottom: TabBar(controller: _tab, tabs: const [Tab(text: '차트'), Tab(text: '근거 · 뉴스'), Tab(text: '재무 해석')]),
      ),
      body: TabBarView(controller: _tab, children: [_chartTab(), _evidenceTab(), _financeTab()]),
    );
  }

  // ------------------------------------------------------------------ 차트
  Widget _chartTab() {
    final m = widget.market;
    return Column(children: [
      Expanded(
        child: useWidget && _web != null
            ? WebViewWidget(controller: _web!)
            : Padding(
                padding: const EdgeInsets.all(6),
                child: candles != null
                    ? CandleChart(candles: candles!, trigger: widget.trigger, stop: widget.stop, target: widget.target)
                    : Center(child: candleError != null ? Text('차트 데이터 실패: $candleError') : const CircularProgressIndicator()),
              ),
      ),
      if (widgetFailed && useWidget == false)
        const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('TradingView 위젯을 불러오지 못해 직접 그린 차트를 표시합니다.', style: TextStyle(fontSize: 11, color: Colors.grey))),
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
        child: Wrap(spacing: 14, runSpacing: 2, children: [
          if (widget.trigger != null) kv(widget.horizon == 'short' ? '트리거가' : '진입가', fmtPrice(widget.trigger, market: m), bold: true),
          if (widget.stop != null) kv('손절가', fmtPrice(widget.stop, market: m), color: Colors.blue.shade400),
          if (widget.target != null) kv('2R 목표', fmtPrice(widget.target, market: m), color: Colors.red.shade400),
          if (widget.qty != null) kv('수량 제안', '${widget.qty}주', bold: true),
          if (widget.trigger != null && widget.stop != null && widget.trigger! > 0) kv('리스크', fmtPct((widget.trigger! - widget.stop!) / widget.trigger! * 100, sign: false)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: Row(children: [
          Expanded(child: OutlinedButton.icon(onPressed: _openTradingView, icon: const Icon(Icons.open_in_new, size: 16), label: const Text('TradingView'))),
          const SizedBox(width: 6),
          Expanded(child: OutlinedButton.icon(onPressed: _openBroker, icon: const Icon(Icons.account_balance, size: 16), label: const Text('증권사 앱'))),
          const SizedBox(width: 6),
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: () async {
                final h = await showHoldingDialog(
                  context,
                  initial: Holding(
                    id: DateTime.now().millisecondsSinceEpoch.toString(),
                    ticker: widget.ticker,
                    name: widget.name,
                    market: m,
                    horizon: widget.horizon,
                    entryPrice: widget.trigger ?? 0,
                    entryDate: DateTime.now().toIso8601String().substring(0, 10),
                    qty: widget.qty ?? 0,
                    stopPrice: widget.stop,
                    exchange: widget.exchange,
                  ),
                );
                if (h == null) return;
                final store = await HoldingsStore.load();
                await store.upsert(h);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${h.ticker} 보유에 추가됨')));
              },
              icon: const Icon(Icons.add, size: 16),
              label: const Text('보유 추가'),
            ),
          ),
        ]),
      ),
    ]);
  }

  // ------------------------------------------------------------------ 근거 · 뉴스
  Widget _evidenceTab() {
    final c = ctx;
    final a = widget.analysis;
    final news = liveNews.isNotEmpty ? liveNews : (c?.news ?? const <NewsItem>[]);
    return ListView(padding: const EdgeInsets.all(10), children: [
      if (a != null && (a['text'] ?? '').toString().isNotEmpty)
        Card(
          color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [const Icon(Icons.auto_awesome, size: 16), const SizedBox(width: 4), Text('Claude 해석 · ${a['view'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))]),
              const SizedBox(height: 4),
              Text(a['text'].toString(), style: const TextStyle(fontSize: 13, height: 1.45)),
              const SizedBox(height: 4),
              const Text('투자 권유가 아닙니다. 규칙(트리거·손절)이 우선입니다.', style: TextStyle(fontSize: 10, color: Colors.grey)),
            ]),
          ),
        ),
      if (c != null && c.description.isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${c.sector} · ${c.industry}${c.marketCap != null ? ' · 시총 \$${fmtBig(c.marketCap)}' : ''}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(c.description, style: const TextStyle(fontSize: 12, height: 1.4), maxLines: 6, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ),
      if (c != null) analystCard(c),
      if (c != null) healthCard(c),
      if (ctxLoading && c == null) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
      if (!ctxLoading && c == null) const Padding(padding: EdgeInsets.all(12), child: Text('이 종목의 근거 파일이 아직 없습니다 (후보로 뽑힌 종목만 매일 수집).', style: TextStyle(fontSize: 12, color: Colors.grey))),
      Card(child: Padding(padding: const EdgeInsets.all(6), child: newsList(news, title: liveNews.isNotEmpty ? '뉴스 (실시간)' : '뉴스', max: 12))),
      OutlinedButton.icon(
        icon: const Icon(Icons.open_in_new, size: 16),
        label: const Text('세이브티커에서 이 종목 더 보기'),
        onPressed: () => launchUrl(Uri.parse('https://www.saveticker.com/news?ticker=${widget.ticker}'), mode: LaunchMode.externalApplication),
      ),
      const SizedBox(height: 30),
    ]);
  }

  // ------------------------------------------------------------------ 재무 해석
  Widget _financeTab() {
    final c = ctx;
    final t = widget.market == 'kr' ? Yahoo.yahooSymbol(widget.ticker, 'kr') : widget.ticker;
    return ListView(padding: const EdgeInsets.all(10), children: [
      if (c != null) healthCard(c, full: true),
      if (c != null && c.valuation.isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('밸류에이션', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 4),
              Wrap(spacing: 12, runSpacing: 2, children: [
                kv('PER(과거)', _n(c.valuation['trailing_pe'])),
                kv('PER(예상)', _n(c.valuation['forward_pe'])),
                kv('PBR', _n(c.valuation['price_to_book'])),
                kv('PEG', _n(c.valuation['peg'])),
              ]),
              const SizedBox(height: 4),
              Text(_valuationNote(c), style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ]),
          ),
        ),
      if (c != null) yearsTable(c),
      if (c == null) const Padding(padding: EdgeInsets.all(12), child: Text('재무 데이터가 아직 없습니다 (후보 종목만 매일 수집).', style: TextStyle(fontSize: 12, color: Colors.grey))),
      OutlinedButton.icon(
        icon: const Icon(Icons.open_in_new, size: 16),
        label: const Text('Yahoo 재무제표 원문 보기'),
        onPressed: () => launchUrl(Uri.parse('https://finance.yahoo.com/quote/$t/financials/'), mode: LaunchMode.externalApplication),
      ),
      const SizedBox(height: 30),
    ]);
  }

  String _n(dynamic v) => v == null ? '-' : (v as num).toStringAsFixed(1);

  String _valuationNote(ContextItem c) {
    final fpe = c.valuation['forward_pe'];
    final peg = c.valuation['peg'];
    final parts = <String>[];
    if (fpe is num) {
      parts.add(fpe < 0 ? '적자라 PER 계산 불가(성장 기대로 거래되는 종목)' : fpe <= 15 ? '예상 PER ${fpe.toStringAsFixed(0)}: 이익 대비 싼 편' : fpe <= 35 ? '예상 PER ${fpe.toStringAsFixed(0)}: 보통~성장주 수준' : '예상 PER ${fpe.toStringAsFixed(0)}: 비싼 편, 성장이 꺾이면 급락 위험');
    }
    if (peg is num && peg > 0) parts.add('PEG ${peg.toStringAsFixed(2)}: ${peg <= 1 ? '성장 대비 저평가' : peg <= 2.5 ? '적정' : '성장 대비 비쌈'}');
    return parts.isEmpty ? '밸류에이션 정보 없음' : parts.join(' · ');
  }
}
