// 打印几个代表性源的真实异常字符串，用来校准 _describeRawError 的分类。
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const ua = 'Mozilla/5.0 (Linux; Android 12; Mobile) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

Future<void> main() async {
  final raw = await File(
          '.workbuddy/recovered/zyfun_sites_20260923.json')
      .readAsString();
  final list = jsonDecode(raw) as List;
  final want = {
    '阿里BB资源网',
    '丝袜资源',
    '淘片资源',
    '卧龙资源',
    '天堂资源',
    '精品x资源',
  };
  for (final item in list.whereType<Map>()) {
    final name = (item['name'] ?? '').toString();
    if (!want.contains(name)) continue;
    final api = (item['api'] ?? '').toString();
    final uri = Uri.parse(api).replace(
      queryParameters: {...Uri.parse(api).queryParameters, 'ac': 'list'},
    );
    try {
      final res = await http
          .get(uri, headers: {'User-Agent': ua, 'Accept': '*/*'})
          .timeout(const Duration(seconds: 8));
      final body = utf8.decode(res.bodyBytes, allowMalformed: true);
      stdout.writeln('[$name] HTTP ${res.statusCode} '
          'len=${body.length} head=${body.trimLeft().substring(0, body.trimLeft().length.clamp(0, 90)).replaceAll('\n', ' ')}');
    } catch (e) {
      stdout.writeln('[$name] ${e.runtimeType}: $e');
    }
    stdout.writeln('');
  }
}
