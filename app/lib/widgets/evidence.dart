import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../util.dart';

/// "왜 뽑혔나" — 지표 근거 문장 (규칙 원문 기준)
List<String> shortReasons(ShortItem it) {
  final r = <String>[];
  if (it.setup == 'ep') {
    r.add('시가 갭 ${fmtPct(it.gapPct)} (기준 +10~40%)');
    r.add('거래량이 20일 평균의 ${it.volMult?.toStringAsFixed(1) ?? '-'}배 (기준 5배 이상, 장중 누적을 하루치로 환산)');
    r.add('직전 3개월 수익률 ${fmtPct(it.r3m)} (기준 +25% 이하 = 소외 상태)');
    r.add('진입가 = 시가 × 1.02 = ${fmtPrice(it.triggerPrice)} · ${it.triggered ? '이미 도달' : '아직 미도달'}');
  } else {
    r.add('급등: 저점 대비 +${it.raw['runup_pct'] ?? '-'}% (기준 30% 이상)');
    r.add('횡보: 고점 이후 ${it.boxDays ?? '-'}일, 폭 ${it.raw['box_range_pct'] ?? '-'}% (기준 10~40일, 25% 이내)');
    final vr = it.raw['vol_recent'], vb = it.raw['vol_before_peak'];
    if (vr is num && vb is num && vb > 0) r.add('거래량: 최근 10일이 급등기의 ${(vr / vb * 100).round()}% (기준: 감소)');
    final s20 = it.raw['sma20'];
    if (s20 is num && it.close != null) r.add('추세: 종가 ${fmtPrice(it.close)} vs 20일선 ${fmtPrice(s20.toDouble())}, 10일선 상승 중');
    r.add('트리거: 횡보 고점 ${fmtPrice(it.triggerPrice)} 돌파 시 진입 (5% 넘게 위면 건너뜀)');
  }
  r.add('손절 ${fmtPrice(it.stopPrice)} (${it.stopPct?.toStringAsFixed(1) ?? '-'}% = max(ADR ${it.adr20?.toStringAsFixed(1)}%, 3%), 3~10% 제한)');
  r.add('모멘텀: 1개월 ${fmtPct(it.r1m)} · 3개월 ${fmtPct(it.r3m)} · 6개월 ${fmtPct(it.r6m)} (하나라도 전체 상위 2%)');
  r.add('유동성: 하루 거래대금 \$${fmtBig(it.dv20)} (기준 \$1M 이상), ADR ${it.adr20?.toStringAsFixed(1)}% (기준 5% 이상)');
  return r;
}

List<String> midReasons(MidItem it) => [
      '추세 템플릿 통과: 종가 > 50일선 > 150일선 > 200일선, 200일선 상승, 52주 저가 대비 +30% 이상, 고가 대비 -25% 이내',
      '상대강도: 6개월 ${fmtPct(it.r6m)} (유니버스 상위 20%)',
      '눌림: 20일 고점 대비 ${fmtPct(it.pctFrom20dHigh)} (기준 -5~-15%), 50일선 위, 20일선 대비 ${fmtPct(it.distSma20)} (±ADR 이내)',
      '반등 첫날: 당일 종가가 전일 고가를 넘음 → 내일 시가 매수 후보',
      '손절 ${fmtPrice(it.stopPrice)} (10일 최저가 × 0.99, -8% 한도) · 2R 목표 ${fmtPrice(it.target2r)}',
      '유동성: 거래대금 \$${fmtBig(it.dv20)} (기준 \$5M), ADR ${it.adr20?.toStringAsFixed(1)}% (기준 2~8%)',
    ];

List<String> longReasons(LongItem c) => [
      'ROE ${fmtPct(c.roe, sign: false)} (기준 15% 이상) · 매출성장 ${fmtPct(c.revenueGrowth)} (8% 이상) · 영업이익률 ${fmtPct(c.operatingMargin, sign: false)} (10% 이상)',
      'FCF ${c.passed.contains('fcf') ? '흑자' : '조건 미충족'} · 부채/자본 ${c.passed.contains('debt_to_equity') ? '통과' : '미충족'} (150% 이하, 금융주 제외)',
      '추세: 종가 > 150일선 > 200일선, 200일선 5개월 전보다 위, 52주 고가 대비 ${fmtPct(c.pctFrom52wHigh)} (-25% 이내)',
      '상대강도: 12개월(최근 1개월 제외) ${fmtPct(c.r12mEx1)} (유니버스 상위 30%)',
      '밸류 가드: PEG ${c.peg?.toStringAsFixed(2) ?? '-'} (2.5 이하) 또는 forward PE ${c.forwardPe?.toStringAsFixed(1) ?? '-'} (35 이하)',
      '점수 ${c.score?.toStringAsFixed(0)} = 재무 순위 50% + 상대강도 순위 50%${c.nextEarnings != null ? ' · 다음 실적 ${c.nextEarnings}' : ''}',
    ];

/// 증권사 주문(시세감지주문 등)에 그대로 넣을 값
Widget orderCard(OrderValues o, String market, String horizon, double slippagePct, BuildContext context) {
  String p(double v) => fmtPrice(v, market: market);
  void copy(String label, String v) {
    Clipboard.setData(ClipboardData(text: v));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label $v 복사됨'), duration: const Duration(seconds: 1)));
  }

  Widget row(String label, String value, String copyValue, {Color? color, String? note}) => InkWell(
        onTap: () => copy(label, copyValue),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            SizedBox(width: 110, child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey))),
            Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
            const SizedBox(width: 6),
            if (note != null) Expanded(child: Text(note, style: const TextStyle(fontSize: 10, color: Colors.grey), overflow: TextOverflow.ellipsis)),
            const Icon(Icons.copy, size: 12, color: Colors.grey),
          ]),
        ),
      );
  final isShort = horizon == 'short';
  return Card(
    color: Colors.indigo.withValues(alpha: 0.08),
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('주문에 넣을 값 (누르면 복사)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 4),
        row(isShort ? '매수 지정가' : '매수 (시가)', p(o.entry), o.entry.toStringAsFixed(2), note: isShort ? '돌파 확인 후 지정가. 최대 ${p(o.entryMax)} 까지만' : '내일 시가 매수'),
        row('손절 감지가', p(o.stop), o.stop.toStringAsFixed(2), color: Colors.blue.shade400, note: '도달 시 시장가 매도'),
        row('예상 체결가', p(o.stopFill), o.stopFill.toStringAsFixed(2), note: '슬리피지 $slippagePct% 가정'),
        if (o.target != null) row('목표 감지가', p(o.target!), o.target!.toStringAsFixed(2), color: Colors.red.shade400, note: '2R 도달 시 절반 매도'),
        row('수량', '${o.qty}주', '${o.qty}', note: '리스크 ${o.risk.toStringAsFixed(1)}% × 자금'),
        const SizedBox(height: 2),
        Text(isShort ? '3거래일째 종가에 절반 매도 → 남은 물량 손절 감지가를 매수가로 올리기. 종가 < 10일선이면 전량.' : '+2R 절반 매도 후 종가 < 50일선이면 전량. 최대 120일.',
            style: const TextStyle(fontSize: 10, color: Colors.grey)),
      ]),
    ),
  );
}

Widget reasonList(List<String> reasons) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final r in reasons)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('• ', style: TextStyle(fontSize: 12)),
              Expanded(child: Text(r, style: const TextStyle(fontSize: 12, height: 1.35))),
            ]),
          ),
      ],
    );

Color gradeColor(String? g) {
  switch (g) {
    case 'A':
      return Colors.green.shade600;
    case 'B':
      return Colors.lightGreen.shade600;
    case 'C':
      return Colors.amber.shade700;
    case 'D':
      return Colors.orange.shade700;
    case 'F':
      return Colors.red.shade600;
  }
  return Colors.grey;
}

Widget gradeChip(String? g, {String? label}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: gradeColor(g).withValues(alpha: 0.18), borderRadius: BorderRadius.circular(8), border: Border.all(color: gradeColor(g))),
      child: Text(label ?? (g ?? '-'), style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: gradeColor(g))),
    );

/// 애널리스트 + 공매도 + 실적일 요약 한 카드
Widget analystCard(ContextItem c) {
  final a = c.analyst, s = c.short;
  final bd = a['breakdown'] is Map ? Map<String, dynamic>.from(a['breakdown'] as Map) : null;
  return Card(
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('애널리스트 · 수급', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 4),
        Wrap(spacing: 12, runSpacing: 2, children: [
          kv('의견', '${a['recommendation'] ?? '-'} (${a['count'] ?? '-'}명)'),
          if (a['target_mean'] != null) kv('목표가 평균', '${fmtPrice((a['target_mean'] as num).toDouble())} (${fmtPct((a['upside_pct'] as num?)?.toDouble())})'),
          if (bd != null) kv('매수/중립/매도', '${(bd['strong_buy'] ?? 0) + (bd['buy'] ?? 0)} / ${bd['hold'] ?? 0} / ${(bd['sell'] ?? 0) + (bd['strong_sell'] ?? 0)}'),
          if (s['pct_of_float'] != null) kv('공매도 비율', '${s['pct_of_float']}% (${s['level'] ?? ''})'),
          if (s['institutions_pct'] != null) kv('기관 보유', '${s['institutions_pct']}%'),
          if (c.nextEarnings != null) kv('다음 실적', c.nextEarnings!, bold: true),
        ]),
        if (s['level'] == '높음' || s['level'] == '매우 높음')
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('공매도가 많음: 급등 시 숏 스퀴즈 가능성도, 약세 베팅이 많다는 뜻도 됨. 손절을 지킬 것.', style: TextStyle(fontSize: 11, color: Colors.orange)),
          ),
        if (c.nextEarnings != null && _daysTo(c.nextEarnings!) != null && _daysTo(c.nextEarnings!)! <= 10)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('실적 발표 ${_daysTo(c.nextEarnings!)}일 전: 발표 전후 갭이 커서 단기 규칙 손절이 무의미해질 수 있음', style: const TextStyle(fontSize: 11, color: Colors.red)),
          ),
      ]),
    ),
  );
}

int? _daysTo(String d) {
  final t = DateTime.tryParse(d);
  if (t == null) return null;
  return t.difference(DateTime.now()).inDays;
}

/// 재무건전성 해석 카드 (등급 + 한 줄 설명)
Widget healthCard(ContextItem c, {bool full = false}) {
  final pio = c.piotroski, alt = c.altman;
  return Card(
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('재무건전성', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(width: 8),
          gradeChip(c.overall, label: '종합 ${c.overall ?? '-'} ${c.overallWord ?? ''}'),
        ]),
        if (c.healthSummary.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(c.healthSummary, style: const TextStyle(fontSize: 12))),
        const SizedBox(height: 6),
        for (final h in c.healthItems)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 34, child: gradeChip(h.grade)),
              const SizedBox(width: 6),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${h.name}: ${h.value == null ? '정보 없음' : '${h.unit == 'x' ? h.value!.toStringAsFixed(2) : h.value!.toStringAsFixed(1)}${h.unit == 'x' ? '배' : h.unit}'} → ${h.word}',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  if (full) Text(h.note, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ]),
              ),
            ]),
          ),
        if (full && pio != null) ...[
          const SizedBox(height: 8),
          Text('피오트로스키 F점수 ${pio['score']}/9 — 9개 항목 중 개선된 것의 수. 7 이상 우량, 3 이하 취약', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          if (pio['points'] is Map)
            Wrap(spacing: 6, runSpacing: 2, children: [
              for (final e in (pio['points'] as Map).entries)
                Text('${e.value == true ? '✓' : '✗'} ${e.key}', style: TextStyle(fontSize: 11, color: e.value == true ? Colors.green : Colors.grey)),
            ]),
        ],
        if (full && alt != null) ...[
          const SizedBox(height: 6),
          Text('알트만 Z점수 ${alt['z']} → ${alt['zone']} (2.99 초과 안전, 1.81 미만 부도 위험 구간)', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ]),
    ),
  );
}

/// 연간 실적 표 (억 달러 단위)
Widget yearsTable(ContextItem c) {
  if (c.years.isEmpty) return const SizedBox.shrink();
  String m(dynamic v) => v == null ? '-' : '${((v as num) / 1e6).toStringAsFixed(0)}M';
  String eps(dynamic v) => v == null ? '-' : (v as num).toStringAsFixed(2);
  return Card(
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('연간 실적 (단위: 백만 달러)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 30,
            dataRowMinHeight: 26,
            dataRowMaxHeight: 30,
            columnSpacing: 14,
            columns: const [
              DataColumn(label: Text('연도', style: TextStyle(fontSize: 11))),
              DataColumn(label: Text('매출', style: TextStyle(fontSize: 11))),
              DataColumn(label: Text('영업이익', style: TextStyle(fontSize: 11))),
              DataColumn(label: Text('순이익', style: TextStyle(fontSize: 11))),
              DataColumn(label: Text('EPS', style: TextStyle(fontSize: 11))),
              DataColumn(label: Text('영업현금', style: TextStyle(fontSize: 11))),
              DataColumn(label: Text('FCF', style: TextStyle(fontSize: 11))),
              DataColumn(label: Text('부채', style: TextStyle(fontSize: 11))),
              DataColumn(label: Text('현금', style: TextStyle(fontSize: 11))),
            ],
            rows: [
              for (final y in c.years)
                DataRow(cells: [
                  DataCell(Text(y['year'].toString(), style: const TextStyle(fontSize: 11))),
                  DataCell(Text(m(y['revenue']), style: const TextStyle(fontSize: 11))),
                  DataCell(Text(m(y['operating_income']), style: TextStyle(fontSize: 11, color: (y['operating_income'] ?? 0) < 0 ? Colors.red : null))),
                  DataCell(Text(m(y['net_income']), style: TextStyle(fontSize: 11, color: (y['net_income'] ?? 0) < 0 ? Colors.red : null))),
                  DataCell(Text(eps(y['eps']), style: const TextStyle(fontSize: 11))),
                  DataCell(Text(m(y['operating_cash_flow']), style: const TextStyle(fontSize: 11))),
                  DataCell(Text(m(y['free_cash_flow']), style: TextStyle(fontSize: 11, color: (y['free_cash_flow'] ?? 0) < 0 ? Colors.red : null))),
                  DataCell(Text(m(y['total_debt']), style: const TextStyle(fontSize: 11))),
                  DataCell(Text(m(y['cash']), style: const TextStyle(fontSize: 11))),
                ]),
            ],
          ),
        ),
      ]),
    ),
  );
}

/// 뉴스 목록 (탭하면 세이브티커 원문)
Widget newsList(List<NewsItem> news, {String? title, int max = 10, bool showTickers = false}) {
  if (news.isEmpty) {
    return Padding(padding: const EdgeInsets.all(8), child: Text(title == null ? '뉴스 없음' : '$title: 뉴스 없음', style: const TextStyle(fontSize: 12, color: Colors.grey)));
  }
  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    if (title != null) Padding(padding: const EdgeInsets.fromLTRB(4, 8, 4, 2), child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
    for (final n in news.take(max))
      InkWell(
        onTap: () => launchUrl(Uri.parse(n.url), mode: LaunchMode.externalApplication),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(n.title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            if (n.summary.isNotEmpty) Text(n.summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.grey)),
            Text('${_when(n.time)} · ${n.source}${showTickers && n.tickers.isNotEmpty ? ' · ${n.tickers.take(3).join(' ')}' : ''}${n.positivePct != null ? ' · 긍정 ${n.positivePct}%' : ''}',
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ]),
        ),
      ),
    const Padding(padding: EdgeInsets.only(left: 6, top: 2), child: Text('출처: 세이브티커 (saveticker.com)', style: TextStyle(fontSize: 10, color: Colors.grey))),
  ]);
}

String _when(String iso) {
  final t = DateTime.tryParse(iso)?.toLocal();
  if (t == null) return iso;
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 60) return '${d.inMinutes}분 전';
  if (d.inHours < 24) return '${d.inHours}시간 전';
  if (d.inDays < 7) return '${d.inDays}일 전';
  return '${t.month}/${t.day}';
}
