import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';
import 'settings.dart';

/// GitHub 에 올라간 결과 json 을 읽는다. 실패하면 마지막으로 성공한 캐시를 돌려준다.
class Api {
  final AppSettings settings;
  Api(this.settings);

  Future<Map<String, dynamic>> fetchJson(String name, {bool allowCache = true}) async {
    final url = '${settings.baseUrl}/$name?t=${DateTime.now().millisecondsSinceEpoch}';
    try {
      final r = await http.get(Uri.parse(url), headers: {'Cache-Control': 'no-cache'}).timeout(const Duration(seconds: 25));
      if (r.statusCode == 200) {
        final body = utf8.decode(r.bodyBytes);
        final j = Map<String, dynamic>.from(jsonDecode(body) as Map);
        await settings.setCachedJson(name, body);
        return j;
      }
      if (r.statusCode == 404) {
        final c = allowCache ? settings.cachedJson(name) : null;
        if (c != null) return c;
        return {'count': 0, 'items': [], 'date': '', 'error': '아직 결과 파일이 없습니다 (404)'};
      }
      throw Exception('HTTP ${r.statusCode}');
    } catch (e) {
      final c = allowCache ? settings.cachedJson(name) : null;
      if (c != null) {
        c['_stale'] = true;
        return c;
      }
      rethrow;
    }
  }

  Future<ScreenerFile<ShortItem>> shortList(String market) async =>
      ScreenerFile<ShortItem>(await fetchJson('${market}_short.json'), ShortItem.fromJson);

  Future<ScreenerFile<ShortItem>> epList(String market) async =>
      ScreenerFile<ShortItem>(await fetchJson('${market}_short_ep.json'), ShortItem.fromJson);

  Future<ScreenerFile<MidItem>> midList(String market) async =>
      ScreenerFile<MidItem>(await fetchJson('${market}_mid.json'), MidItem.fromJson);

  Future<LongFile> longList(String market) async => LongFile.fromJson(await fetchJson('${market}_long.json'));

  Future<InsightFile> insight(String market) async => InsightFile.fromJson(await fetchJson('${market}_insight.json'));

  Future<ContextFile> context(String market) async => ContextFile.fromJson(await fetchJson('${market}_context.json'));

  Future<DailyFile> daily(String market) async => DailyFile.fromJson(await fetchJson('${market}_daily.json'));

  Future<PicksFile> picks(String market) async => PicksFile.fromJson(await fetchJson('${market}_picks.json'));

  Future<AnalysisFile?> analysis(String market) async {
    try {
      final j = await fetchJson('${market}_analysis.json');
      if (j['error'] != null || (j['market_brief'] == null && j['tickers'] == null)) return null;
      return AnalysisFile.fromJson(j);
    } catch (_) {
      return null;
    }
  }
}
