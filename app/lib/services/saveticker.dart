import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';

/// 세이브티커 공개 API (로그인 불필요) — 앱에서 그 순간의 뉴스·캘린더를 바로 조회.
/// 뉴스 본문은 저장하지 않고 링크로 연결한다.
class SaveTicker {
  static const base = 'https://www.saveticker.com';
  static const _headers = {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
    'Accept': 'application/json',
    'Referer': 'https://www.saveticker.com/news',
  };

  static Future<Map<String, dynamic>?> _get(String path, Map<String, String> params) async {
    try {
      final uri = Uri.parse('$base$path').replace(queryParameters: params);
      final r = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(r.bodyBytes)) as Map);
    } catch (_) {
      return null;
    }
  }

  static String _text(dynamic blocks) {
    if (blocks is List) return blocks.map((b) => b is Map ? (b['content'] ?? '').toString() : '').join(' ').trim();
    if (blocks is String) return blocks.trim();
    return '';
  }

  static NewsItem _item(Map<String, dynamic> it) {
    final tr = ((it['translations'] ?? {})['translated'] ?? {}) as Map;
    final ko = (tr['ko_KR'] ?? {}) as Map;
    final en = (tr['en_US'] ?? {}) as Map;
    var summary = _text(ko['summary']);
    if (summary.isEmpty) summary = _text(ko['content']);
    if (summary.isEmpty) summary = (it['content'] ?? '').toString();
    return NewsItem.fromJson({
      'id': it['id'],
      'title': it['title'] ?? ko['title'] ?? '',
      'title_en': en['title'] ?? '',
      'summary': summary.length > 400 ? summary.substring(0, 400) : summary,
      'source': it['source'] ?? '',
      'time': it['created_at'] ?? '',
      'url': '$base/news/${it['id']}',
      'tickers': ((it['tickers'] as List?) ?? const []).map((t) => t is Map ? (t['symbol'] ?? '').toString() : '').toList(),
      'tags': ((it['tags'] as List?) ?? const []).where((t) => t is Map && t['is_ticker'] != true).map((t) => (t as Map)['name'].toString()).toList(),
      'is_top': it['is_top_story'] == true,
      'views': it['view_count'],
      'comments': it['comment_count'],
    });
  }

  static Future<List<NewsItem>> newsFor(String ticker, {int n = 10}) async {
    final j = await _get('/api/news/list', {'page': '1', 'page_size': '$n', 'sort': 'created_at_desc', 'tickers': ticker});
    if (j == null) return [];
    return ((j['news_list'] as List?) ?? const []).map((e) => _item(Map<String, dynamic>.from(e as Map))).toList();
  }

  static Future<List<NewsItem>> latest({int n = 20}) async {
    final j = await _get('/api/news/list', {'page': '1', 'page_size': '$n', 'sort': 'created_at_desc', 'label_group': '1', 'label_name': '1'});
    if (j == null) return [];
    return ((j['news_list'] as List?) ?? const []).map((e) => _item(Map<String, dynamic>.from(e as Map))).toList();
  }

  static Future<List<CalEvent>> calendar({int daysBack = 0, int daysFwd = 7}) async {
    final now = DateTime.now();
    String d(DateTime x) => '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
    final j = await _get('/api/calendar/events', {'start_date': d(now.subtract(Duration(days: daysBack))), 'end_date': d(now.add(Duration(days: daysFwd)))});
    if (j == null) return [];
    final out = <CalEvent>[];
    for (final e in (j['events'] as List?) ?? const []) {
      final m = Map<String, dynamic>.from(e as Map);
      final title = (m['title'] ?? '').toString();
      final t = DateTime.tryParse((m['event_date'] ?? '').toString()); // 시간대 없는 한국시간
      out.add(CalEvent.fromJson({
        'title': title.replaceAll('★', '').trim(),
        'importance': '★'.allMatches(title).length,
        'time': m['event_date'] ?? '',
        'kst': t == null ? '' : '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
        'is_today': t != null && t.year == now.year && t.month == now.month && t.day == now.day,
        'is_past': t != null && t.isBefore(now),
      }));
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }
}
