// 결과 파일(json) 모델
double? _d(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

int? _i(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}

String _s(dynamic v) => v == null ? '' : v.toString();

class ShortItem {
  final String ticker, name, setup, exchange;
  final double? triggerPrice, stopPrice, stopPct, adr20, r1m, r3m, r6m, dv20, score, close;
  final double? boxLow, gapPct, volMult, high, last, open, maxEntry;
  final int? boxDays, qty;
  final bool triggered;

  ShortItem.fromJson(Map<String, dynamic> j)
      : ticker = _s(j['ticker']),
        name = _s(j['name']),
        setup = _s(j['setup']),
        exchange = _s(j['exchange']),
        triggerPrice = _d(j['trigger_price']),
        stopPrice = _d(j['stop_price']),
        stopPct = _d(j['stop_pct']),
        adr20 = _d(j['adr20']),
        r1m = _d(j['r1m']),
        r3m = _d(j['r3m']),
        r6m = _d(j['r6m']),
        dv20 = _d(j['dv20']),
        score = _d(j['score']),
        close = _d(j['close']),
        boxLow = _d(j['box_low']),
        gapPct = _d(j['gap_pct']),
        volMult = _d(j['vol_mult']),
        high = _d(j['high_so_far']),
        last = _d(j['last']),
        open = _d(j['open']),
        maxEntry = _d(j['max_entry_price']),
        boxDays = _i(j['box_days']),
        qty = _i(j['qty']),
        triggered = j['triggered'] == true;
}

class MidItem {
  final String ticker, name, exchange;
  final double? entryPrice, stopPrice, stopPct, target2r, adr20, r6m, r3m, distSma20, pctFrom20dHigh, dv20, score;
  final int? qty;

  MidItem.fromJson(Map<String, dynamic> j)
      : ticker = _s(j['ticker']),
        name = _s(j['name']),
        exchange = _s(j['exchange']),
        entryPrice = _d(j['entry_price']),
        stopPrice = _d(j['stop_price']),
        stopPct = _d(j['stop_pct']),
        target2r = _d(j['target_2r']),
        adr20 = _d(j['adr20']),
        r6m = _d(j['r6m']),
        r3m = _d(j['r3m']),
        distSma20 = _d(j['dist_sma20']),
        pctFrom20dHigh = _d(j['pct_from_20d_high']),
        dv20 = _d(j['dv20']),
        score = _d(j['score']),
        qty = _i(j['qty']);
}

class LongItem {
  final String ticker, name, sector, exchange;
  final double? close, score, roe, revenueGrowth, operatingMargin, peg, forwardPe, pctFrom52wHigh, r12mEx1, sma200;
  final int? rank, daysBelowSma200;
  final bool hold;
  final String? nextEarnings;
  final List<String> passed;

  LongItem.fromJson(Map<String, dynamic> j)
      : ticker = _s(j['ticker']),
        name = _s(j['name']),
        sector = _s(j['sector']),
        exchange = _s(j['exchange']),
        close = _d(j['close']),
        score = _d(j['score']),
        roe = _d(j['roe']),
        revenueGrowth = _d(j['revenue_growth']),
        operatingMargin = _d(j['operating_margin']),
        peg = _d(j['peg']),
        forwardPe = _d(j['forward_pe']),
        pctFrom52wHigh = _d(j['pct_from_52w_high']),
        r12mEx1 = _d(j['r12m_ex1']),
        sma200 = _d(j['sma200']),
        rank = _i(j['rank']),
        daysBelowSma200 = _i(j['days_below_sma200']),
        hold = j['hold'] == true,
        nextEarnings = j['next_earnings']?.toString(),
        passed = (j['passed'] as List?)?.map((e) => e.toString()).toList() ?? const [];
}

class HoldingStatus {
  final String ticker, reason;
  final int? rank, daysBelowSma200;
  final bool replace;
  HoldingStatus.fromJson(Map<String, dynamic> j)
      : ticker = _s(j['ticker']),
        reason = _s(j['reason']),
        rank = _i(j['rank']),
        daysBelowSma200 = _i(j['days_below_sma200']),
        replace = j['replace'] == true;
}

class ScreenerFile<T> {
  final String date, generatedAt, asofEt;
  final double capital, riskPct;
  final int maxPositions, count;
  final List<T> items;
  final Map<String, dynamic> raw;

  ScreenerFile(this.raw, T Function(Map<String, dynamic>) parse)
      : date = _s(raw['date']),
        generatedAt = _s(raw['generated_at']),
        asofEt = _s(raw['asof_et']),
        capital = _d(raw['capital']) ?? 0,
        riskPct = _d(raw['risk_pct']) ?? 0,
        maxPositions = _i(raw['max_positions']) ?? 0,
        count = _i(raw['count']) ?? 0,
        items = ((raw['items'] ?? raw['candidates']) as List? ?? const [])
            .map((e) => parse(Map<String, dynamic>.from(e as Map)))
            .toList();
}

class LongFile {
  final String date, generatedAt;
  final int holdN, universeSize, passAll;
  final List<LongItem> candidates;
  final List<String> holdings, entered, exited;
  final List<HoldingStatus> previousHoldings;
  final String? previousDate;

  LongFile.fromJson(Map<String, dynamic> j)
      : date = _s(j['date']),
        generatedAt = _s(j['generated_at']),
        holdN = _i(j['hold_n']) ?? 5,
        universeSize = _i(j['universe_size']) ?? 0,
        passAll = _i(j['pass_all']) ?? 0,
        candidates = (j['candidates'] as List? ?? const [])
            .map((e) => LongItem.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        holdings = (j['holdings'] as List? ?? const []).map((e) => e.toString()).toList(),
        entered = (j['entered'] as List? ?? const []).map((e) => e.toString()).toList(),
        exited = (j['exited'] as List? ?? const []).map((e) => e.toString()).toList(),
        previousHoldings = (j['previous_holdings'] as List? ?? const [])
            .map((e) => HoldingStatus.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        previousDate = j['previous_date']?.toString();

  int? rankOf(String ticker) {
    for (final c in candidates) {
      if (c.ticker == ticker) return c.rank;
    }
    return null;
  }
}

class SectorRow {
  final String etf, name;
  final double? r1m, r3m, r6m;
  final int? rank;
  SectorRow.fromJson(Map<String, dynamic> j)
      : etf = _s(j['etf']),
        name = _s(j['name']),
        r1m = _d(j['r1m']),
        r3m = _d(j['r3m']),
        r6m = _d(j['r6m']),
        rank = _i(j['rank']);
}

class InsightFile {
  final String date, generatedAt, signal, index;
  final double? close, sma200, pctVsSma200, breadthPct;
  final bool aboveSma200;
  final List<SectorRow> sectors;
  final List<String> entered, exited;
  final List<Map<String, dynamic>> upcomingEarnings, replace;
  final String? summaryKo, previousSignal, longDate;
  final bool signalChanged;

  InsightFile.fromJson(Map<String, dynamic> j)
      : date = _s(j['date']),
        generatedAt = _s(j['generated_at']),
        signal = _s((j['temperature'] ?? {})['signal']),
        index = _s((j['temperature'] ?? {})['index']),
        close = _d((j['temperature'] ?? {})['close']),
        sma200 = _d((j['temperature'] ?? {})['sma200']),
        pctVsSma200 = _d((j['temperature'] ?? {})['pct_vs_sma200']),
        breadthPct = _d((j['temperature'] ?? {})['breadth_pct']),
        aboveSma200 = (j['temperature'] ?? {})['above_sma200'] == true,
        sectors = ((j['sectors'] as List?) ?? const [])
            .map((e) => SectorRow.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        entered = (((j['changes'] ?? {})['entered'] as List?) ?? const []).map((e) => e.toString()).toList(),
        exited = (((j['changes'] ?? {})['exited'] as List?) ?? const []).map((e) => e.toString()).toList(),
        upcomingEarnings = (((j['changes'] ?? {})['upcoming_earnings'] as List?) ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
        replace = (((j['changes'] ?? {})['replace'] as List?) ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
        longDate = (j['changes'] ?? {})['long_date']?.toString(),
        summaryKo = j['summary_ko']?.toString(),
        previousSignal = j['previous_signal']?.toString(),
        signalChanged = j['signal_changed'] == true;
}

/// 보유 종목 (폰에만 저장)
class Holding {
  String id;
  String ticker;
  String name;
  String market; // us | kr
  String horizon; // short | mid | long
  double entryPrice;
  String entryDate; // yyyy-MM-dd
  int qty;
  double? stopPrice;
  bool partialDone;
  String exchange;

  Holding({
    required this.id,
    required this.ticker,
    this.name = '',
    this.market = 'us',
    required this.horizon,
    required this.entryPrice,
    required this.entryDate,
    required this.qty,
    this.stopPrice,
    this.partialDone = false,
    this.exchange = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'ticker': ticker,
        'name': name,
        'market': market,
        'horizon': horizon,
        'entryPrice': entryPrice,
        'entryDate': entryDate,
        'qty': qty,
        'stopPrice': stopPrice,
        'partialDone': partialDone,
        'exchange': exchange,
      };

  factory Holding.fromJson(Map<String, dynamic> j) => Holding(
        id: _s(j['id']),
        ticker: _s(j['ticker']),
        name: _s(j['name']),
        market: _s(j['market']).isEmpty ? 'us' : _s(j['market']),
        horizon: _s(j['horizon']),
        entryPrice: _d(j['entryPrice']) ?? 0,
        entryDate: _s(j['entryDate']),
        qty: _i(j['qty']) ?? 0,
        stopPrice: _d(j['stopPrice']),
        partialDone: j['partialDone'] == true,
        exchange: _s(j['exchange']),
      );
}

class Candle {
  final DateTime date;
  final double open, high, low, close, volume;
  Candle(this.date, this.open, this.high, this.low, this.close, this.volume);
}

String horizonLabel(String h) {
  switch (h) {
    case 'short':
      return '단기';
    case 'mid':
      return '중기';
    case 'long':
      return '장기';
  }
  return h;
}
