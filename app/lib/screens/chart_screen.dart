import 'dart:async';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../main.dart';
import '../models.dart';
import '../services/holdings.dart';
import '../services/yahoo.dart';
import '../util.dart';
import '../widgets/candle_chart.dart';
import 'holdings_screen.dart';

/// 종목 차트: TradingView 무료 임베드 위젯(WebView). 안 되면 Yahoo 데이터로 직접 그린 차트.
class ChartScreen extends StatefulWidget {
  final String ticker, name, exchange, market, horizon;
  final double? trigger, stop, target;
  final int? qty;

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
  });

  @override
  State<ChartScreen> createState() => _ChartScreenState();
}

class _ChartScreenState extends State<ChartScreen> {
  WebViewController? _web;
  bool useWidget = true;
  bool widgetFailed = false;
  List<Candle>? candles;
  String? candleError;
  Timer? _check;

  String get tvSymbol => tradingViewSymbol(widget.ticker, widget.exchange, widget.market);

  @override
  void initState() {
    super.initState();
    _initWeb();
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
          // 위젯 안의 링크(저작권 표시 등)는 외부 브라우저로
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
        final intent = AndroidIntent(
          action: 'android.intent.action.MAIN',
          category: 'android.intent.category.LAUNCHER',
          package: pkg,
        );
        await intent.launch();
        return;
      } catch (_) {}
    }
    final t = widget.market == 'kr' ? Yahoo.yahooSymbol(widget.ticker, 'kr') : widget.ticker;
    await launchUrl(Uri.parse('https://finance.yahoo.com/quote/$t'), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.market;
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Text(widget.ticker),
          const SizedBox(width: 8),
          Expanded(child: Text(widget.name, style: const TextStyle(fontSize: 13, color: Colors.grey), overflow: TextOverflow.ellipsis)),
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
      ),
      body: Column(
        children: [
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
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text('TradingView 위젯을 불러오지 못해 직접 그린 차트를 표시합니다.', style: TextStyle(fontSize: 11, color: Colors.grey)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
            child: Wrap(spacing: 14, runSpacing: 2, children: [
              if (widget.trigger != null) kv(widget.horizon == 'mid' ? '진입가' : (widget.horizon == 'long' ? '진입가' : '트리거가'), fmtPrice(widget.trigger, market: m), bold: true),
              if (widget.stop != null) kv('손절가', fmtPrice(widget.stop, market: m), color: Colors.blue.shade400),
              if (widget.target != null) kv('2R 목표', fmtPrice(widget.target, market: m), color: Colors.red.shade400),
              if (widget.qty != null) kv('수량 제안', '${widget.qty}주', bold: true),
              if (widget.trigger != null && widget.stop != null && widget.trigger! > 0)
                kv('리스크', fmtPct((widget.trigger! - widget.stop!) / widget.trigger! * 100, sign: false)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Row(children: [
              Expanded(child: OutlinedButton.icon(onPressed: _openTradingView, icon: const Icon(Icons.open_in_new, size: 16), label: const Text('TradingView 앱'))),
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
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${h.ticker} 보유에 추가됨')));
                  },
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('보유 추가'),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}
