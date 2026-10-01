// 独立验证 _apiUrl 的参数合并逻辑（不依赖工程内的任何包，可单进程直接跑）。
//
//   dart .workbuddy/tools/url_merge_test.dart
//
// 复制自 lib/services/http_service.dart 的 _apiUrl，改动那边时同步过来。
String apiUrl(String base, Map<String, String> params) {
  final b = base.trim();
  if (b.isEmpty) return b;
  try {
    final uri = Uri.parse(b);
    if (uri.hasScheme && uri.host.isNotEmpty) {
      return uri
          .replace(
            queryParameters: <String, String>{...uri.queryParameters, ...params},
          )
          .toString();
    }
  } catch (_) {
    // 退回朴素拼接
  }
  final query = params.entries
      .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  return '$b?$query';
}

void main() {
  // 第一列：站点 api，第二列：本次调用参数，第三列：期望结果
  final cases = <List<Object>>[
    // —— zyfun 导出的真实 api（自带 ?ac=list）——
    [
      'https://api.apibdzy.com/api.php/provide/vod/?ac=list',
      {'ac': 'videolist', 'pg': '1'},
      'https://api.apibdzy.com/api.php/provide/vod/?ac=videolist&pg=1'
    ],
    [
      'http://fhapi9.com/api.php/provide/vod/at/json/?ac=list',
      {'ac': 'videolist', 't': '5', 'pg': '2'},
      'http://fhapi9.com/api.php/provide/vod/at/json/?ac=videolist&t=5&pg=2'
    ],
    [
      // 搜索时我们**不**设置 ac，所以站点自带的 ac=list 会保留。
      // 语义上等价：maccms 的 list 动作本身就支持 wd 过滤，不会因此搜不出东西。
      'https://api.ddapi.cc/api.php/provide/vod/?ac=list',
      {'wd': '庆余年'},
      'https://api.ddapi.cc/api.php/provide/vod/?ac=list&wd=%E5%BA%86%E4%BD%99%E5%B9%B4'
    ],
    // —— 路径式（at/json 在 path 里），无 query ——
    [
      'https://jyzyapi.com/provide/vod/from/jinyingyun/at/json',
      {'ac': 'videolist', 'pg': '1'},
      'https://jyzyapi.com/provide/vod/from/jinyingyun/at/json?ac=videolist&pg=1'
    ],
    // —— 普通 api（无 query，最常见的形态，必须与改动前完全一致）——
    [
      'http://cj.lziapi.com/api.php/provide/vod/',
      {'ac': 'videolist', 'pg': '1'},
      'http://cj.lziapi.com/api.php/provide/vod/?ac=videolist&pg=1'
    ],
    [
      'https://www.ffzy.tv/api.php/provide/vod/',
      {'ac': 'videolist', 'ids': '12345'},
      'https://www.ffzy.tv/api.php/provide/vod/?ac=videolist&ids=12345'
    ],
    // —— 端口号必须保留 ——
    [
      'http://127.0.0.1:8080/api.php/provide/vod/',
      {'ac': 'list'},
      'http://127.0.0.1:8080/api.php/provide/vod/?ac=list'
    ],
    // —— 非法/无 host 的地址走兜底，不能崩 ——
    ['not-a-url', {'ac': 'list'}, 'not-a-url?ac=list'],
    ['', {'ac': 'list'}, ''],
  ];

  var pass = 0;
  var fail = 0;
  for (final c in cases) {
    final got = apiUrl(c[0] as String, c[1] as Map<String, String>);
    final want = c[2] as String;
    if (got == want) {
      pass++;
      print('  OK   $got');
    } else {
      fail++;
      print('  FAIL got : $got');
      print('       want: $want');
    }
  }
  print('');
  print('URL_MERGE_TEST $pass passed, $fail failed');
  if (fail > 0) throw StateError('$fail case(s) failed');
}
