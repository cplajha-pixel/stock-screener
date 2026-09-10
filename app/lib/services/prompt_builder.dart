import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../util.dart';

/// 그날 데이터를 "클로드 앱에 붙여 넣을 질문 글"로 만든다 (API 없이 구독으로 해석 받기)
class PromptBuilder {
  static String build({
    DailyFile? daily,
    ScreenerFile<ShortItem>? short,
    ScreenerFile<ShortItem>? ep,
    ScreenerFile<MidItem>? mid,
    LongFile? long,
    ContextFile? ctx,
    PicksFile? picks,
    InsightFile? weekly,
    List<NewsItem>? liveNews,
  }) {
    final b = StringBuffer();
    b.writeln('아래는 내 주식 스크리너가 오늘 자동으로 뽑은 결과와 근거야. 규칙(트리거가·손절가)은 정해져 있으니 매매 지시 말고, '
        '(1) 오늘 시장 환경이 후보들에 유리한지 불리한지, (2) 종목별로 근거의 강점·약점(뉴스·재무·실적일·공매도), (3) 오늘 지켜볼 지표·뉴스를 한국어로 담담하게 정리해 줘. '
        '각 판단 끝에 근거가 된 숫자나 뉴스 제목을 괄호로 붙여 줘.\n');
    if (daily != null) {
      b.writeln('## 오늘의 시장 (${daily.date})');
      for (final e in daily.explain) {
        b.writeln('- $e');
      }
      b.writeln('거시: ${daily.macro.map((m) => '${m.name} ${m.last} (1일 ${m.level ? (m.d1Abs == null ? '-' : '${m.d1Abs! >= 0 ? '+' : ''}${m.d1Abs!.toStringAsFixed(2)}p') : fmtPct(m.d1)}, 1개월 ${fmtPct(m.m1)})').join('; ')}');
      final today = daily.calendar.where((e) => e.isToday || !e.isPast).take(10);
      if (today.isNotEmpty) b.writeln('지표 일정(한국시간): ${today.map((e) => '${e.kst} ${e.title}${'★' * e.importance}').join('; ')}');
      if (daily.breadthHistory.isNotEmpty) {
        b.writeln('S&P500 브레드스(200일선 위 비율) 최근: ${daily.breadthHistory.takeLast(5).map((h) => '${h['date'].toString().substring(5)} ${h['breadth_pct']}%').join(', ')}');
      }
    }
    if (weekly != null) b.writeln('이번 주 시장 온도: ${weekly.signal} (SPY vs 200일선 ${fmtPct(weekly.pctVsSma200)}, 브레드스 ${weekly.breadthPct}%)');
    final news = (liveNews != null && liveNews.isNotEmpty) ? liveNews : (daily?.topStories ?? const <NewsItem>[]);
    if (news.isNotEmpty) {
      b.writeln('\n## 주요 뉴스 헤드라인');
      for (final n in news.take(12)) {
        b.writeln('- ${n.title}${n.tickers.isNotEmpty ? ' (${n.tickers.take(3).join(', ')})' : ''}');
      }
    }
    void item(String ticker, String setup, String core) {
      b.writeln('\n### $ticker ($setup)');
      b.writeln(core);
      final c = ctx?.items[ticker];
      if (c != null) {
        b.writeln('재무: ${c.healthSummary}');
        final a = c.analyst;
        b.writeln('애널리스트: ${a['recommendation'] ?? '-'} ${a['count'] ?? '-'}명, 목표가 대비 ${a['upside_pct'] == null ? '-' : fmtPct((a['upside_pct'] as num).toDouble())} · 공매도 ${c.short['pct_of_float'] ?? '-'}% · 다음 실적 ${c.nextEarnings ?? '-'}');
        if (c.news.isNotEmpty) b.writeln('뉴스: ${c.news.take(4).map((n) => n.title).join(' / ')}');
      }
    }
    if (short != null && short.items.isNotEmpty) {
      b.writeln('\n## 단기 돌파 대기 (내일 트리거가 돌파 시 진입)');
      for (final it in short.items) {
        item(it.ticker, it.isPick ? '돌파 대기 · 오늘의 1픽' : '돌파 대기 #${it.pickRank ?? '-'}',
            '트리거 ${fmtPrice(it.triggerPrice)}, 손절 ${fmtPrice(it.stopPrice)} (${it.stopPct}%), 급등 +${it.raw['runup_pct']}% 뒤 ${it.boxDays}일 횡보(폭 ${it.raw['box_range_pct']}%), 3개월 ${fmtPct(it.r3m)}, ADR ${it.adr20}%');
      }
    }
    if (ep != null && ep.items.isNotEmpty) {
      b.writeln('\n## EP (갭 상승)');
      for (final it in ep.items) {
        item(it.ticker, 'EP', '갭 ${fmtPct(it.gapPct)}, 거래량 ${it.volMult}배, 진입가 ${fmtPrice(it.triggerPrice)} (${it.triggered ? '도달' : '미도달'}), 손절 ${fmtPrice(it.stopPrice)}');
      }
    }
    if (mid != null && mid.items.isNotEmpty) {
      b.writeln('\n## 중기 눌림목 (내일 시가 매수 후보)');
      for (final it in mid.items) {
        item(it.ticker, '눌림목', '진입 ${fmtPrice(it.entryPrice)}, 손절 ${fmtPrice(it.stopPrice)}, 2R ${fmtPrice(it.target2r)}, 6개월 ${fmtPct(it.r6m)}, 20일 고점 대비 ${fmtPct(it.pctFrom20dHigh)}');
      }
    }
    if (long != null && long.candidates.isNotEmpty) {
      b.writeln('\n## 장기 상위 5 (${long.date})');
      for (final c in long.candidates.where((c) => c.hold)) {
        item(c.ticker, '장기 ${c.rank}위', 'ROE ${c.roe}%, 매출성장 ${c.revenueGrowth}%, 영업이익률 ${c.operatingMargin}%, PEG ${c.peg}, 52주 고가 대비 ${fmtPct(c.pctFrom52wHigh)}');
      }
    }
    if (picks != null && picks.summary.isNotEmpty) {
      b.writeln('\n## 1픽 성적표: 누적 ${picks.summary['total']}건, 승률 ${picks.summary['win_rate'] ?? '-'}%, 평균 ${picks.summary['avg_pnl_pct'] ?? '-'}%');
    }
    return b.toString();
  }

  /// 공유 인텐트로 클로드 앱(또는 아무 앱)에 보내기. 실패하면 클립보드 + claude.ai 새 대화.
  static Future<String> share(String text) async {
    try {
      await AndroidIntent(
        action: 'android.intent.action.SEND',
        type: 'text/plain',
        arguments: {'android.intent.extra.TEXT': text, 'android.intent.extra.SUBJECT': '오늘의 스크리너 결과'},
      ).launchChooser('Claude 앱으로 보내기');
      return '공유 창에서 Claude 를 고르세요';
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
      await launchUrl(Uri.parse('https://claude.ai/new'), mode: LaunchMode.externalApplication);
      return '클립보드에 복사했습니다. 클로드에 붙여 넣으세요';
    }
  }
}

extension _TakeLast<T> on List<T> {
  Iterable<T> takeLast(int n) => length <= n ? this : sublist(length - n);
}
