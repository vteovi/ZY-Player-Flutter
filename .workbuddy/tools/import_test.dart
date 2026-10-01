// 用真实的 zyfun 导出文件 + 各种变体验证 SourceImport 解析器。
// 直接 import 工程源码，不依赖 Flutter。
//
//   dart .workbuddy/tools/import_test.dart
import 'dart:io';

import '../../lib/services/source_import.dart';

int pass = 0;
int fail = 0;

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    pass++;
    print('  OK   $label  $detail');
  } else {
    fail++;
    print('  FAIL $label  $detail');
  }
}

void main() {
  // ---------- 1. 真实的 zyfun 配置文件 ----------
  const realPath = r'C:\Users\VTE\Documents\新建文件夹\zyfun_config_20260923_100544.json';
  if (File(realPath).existsSync()) {
    final s = SourceImport.parse(File(realPath).readAsStringSync());
    print('[1] 真实 zyfun 文件');
    print('    format=${s.format} sites=${s.sites.length} skipped=${s.skipped} msg="${s.message}"');
    check('识别为 zyfun', s.format == 'zyfun', s.format);
    check('解析出 35 个源', s.sites.length == 35, '${s.sites.length}');
    final first = s.sites.isEmpty ? null : s.sites.first;
    check('首个源名为「百度资源」', first?.name == '百度资源', first?.name ?? '');
    check(
      'api 原样保留 ?ac=list',
      first?.api == 'https://api.apibdzy.com/api.php/provide/vod/?ac=list',
      first?.api ?? '',
    );
    check('type 映射为 json', first?.type == 'json', first?.type ?? '');
    check('key 是 UUID 且非空', (first?.key ?? '').length > 20, first?.key ?? '');
    check('全部 isActive', s.sites.every((e) => e.isActive));
    check('没有重复 key', s.sites.map((e) => e.key).toSet().length == s.sites.length);
  } else {
    print('[1] 跳过：真实文件不存在');
  }

  // ---------- 2. zyfun 旧版（sites.data 包装） ----------
  print('[2] zyfun 旧版 sites.data');
  final old = SourceImport.parse(
    '{"sites":{"default":1,"data":[{"id":1,"key":"k1","name":"旧版","api":"http://a.com/api.php","type":1}]}}',
  );
  check('format=zyfun', old.format == 'zyfun', old.format);
  check('1 个源', old.sites.length == 1, '${old.sites.length}');

  // ---------- 3. zyfun 源管理导出的裸数组（无 type 字段） ----------
  print('[3] 顶层裸数组');
  final bare = SourceImport.parse(
    '[{"id":1,"key":"okzy","name":"OK 资源网","api":"http://cj.okzy.tv/inc/api.php","download":"http://x"}]',
  );
  check('format=zyfun', bare.format == 'zyfun', bare.format);
  check('1 个源', bare.sites.length == 1, '${bare.sites.length}');
  check('缺省 type -> xml', bare.sites.first.type == 'xml', bare.sites.first.type);

  // ---------- 4. TVBox ----------
  print('[4] TVBox sites 数组');
  final tv = SourceImport.parse(
    '{"sites":[{"key":"t1","name":"TV","api":"http://tv/api.php","type":"json"}]}',
  );
  check('format=tvbox', tv.format == 'tvbox', tv.format);
  check('1 个源', tv.sites.length == 1, '${tv.sites.length}');

  // ---------- 5. 完整配置（含 iptv，只应取 tbl_site） ----------
  print('[5] 多表配置只取 tbl_site');
  final multi = SourceImport.parse(
    '{"tbl_site":[{"id":"u1","key":"u1","name":"站点","api":"http://s/api.php","type":1}],'
    '"tbl_iptv":[{"id":"i1","name":"APTV","url":"http://x/list.m3u","epg":""}],'
    '"tbl_analyze":[{"id":"a1","name":"爱豆","url":"http://jx/x.php"}]}',
  );
  check('只解析出 1 个视频源', multi.sites.length == 1, '${multi.sites.length}');
  check('名称是站点而非 IPTV', multi.sites.first.name == '站点', multi.sites.first.name);

  // ---------- 6. 只有 IPTV 的导出：不该把 IPTV 当成视频源 ----------
  print('[6] 只有 IPTV 的导出应报空');
  final onlyIptv = SourceImport.parse(
    '{"tbl_iptv":[{"id":"i1","name":"APTV","url":"http://x/list.m3u","epg":""}]}',
  );
  check('没有解析出源', onlyIptv.sites.isEmpty, '${onlyIptv.sites.length}');
  check('有提示信息', onlyIptv.message.isNotEmpty, onlyIptv.message);

  // ---------- 7. spider 源被跳过 ----------
  print('[7] spider 源跳过');
  final spider = SourceImport.parse(
    '{"tbl_site":[{"key":"s1","name":"蜘蛛","api":"csp_Spider","type":3},'
    '{"key":"s2","name":"正常","api":"http://ok/api.php","type":1}]}',
  );
  check('保留 1 个', spider.sites.length == 1, '${spider.sites.length}');
  check('跳过 1 个', spider.skipped == 1, '${spider.skipped}');

  // ---------- 8. 垃圾输入 ----------
  print('[8] 非法输入');
  final bad = SourceImport.parse('这不是 json');
  check('报错不崩', bad.sites.isEmpty && bad.message.isNotEmpty, bad.message);
  final empty = SourceImport.parse('{}');
  check('空对象给出顶层字段提示', empty.message.contains('顶层字段'), empty.message);

  // ---------- 9. BOM ----------
  print('[9] 带 BOM');
  final bom = SourceImport.parse(
    '\ufeff{"tbl_site":[{"key":"b1","name":"B","api":"http://b/api.php","type":1}]}',
  );
  check('BOM 不影响解析', bom.sites.length == 1, '${bom.sites.length}');

  print('');
  print('IMPORT_TEST $pass passed, $fail failed');
  if (fail > 0) throw StateError('$fail case(s) failed');
}
