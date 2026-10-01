// 端到端验证「源可用性检测」：直接调用工程里的 HttpService.checkSite。
//
// 单进程跑（不派生子进程），所以沙箱拦截不到：
//   cd /d/WorkBuddy/ZY-Player-Flutter
//   /c/flutter/bin/dart .workbuddy/tools/check_site_test.dart [源清单.json]
//
// 清单可以是 zyfun 导出文件（顶层 tbl_site）或裸数组。
import 'dart:convert';
import 'dart:io';

import '../../lib/models/site.dart';
import '../../lib/services/http_service.dart';

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty
      ? args[0]
      : '.workbuddy/recovered/zyfun_sites_20260923.json';
  final raw = await File(path).readAsString();
  final decoded = jsonDecode(raw);
  final list = decoded is Map ? decoded['tbl_site'] : decoded;
  if (list is! List) {
    stderr.writeln('清单格式不对：$path');
    exitCode = 1;
    return;
  }
  final sites = list.whereType<Map>().map(Site.fromJson).toList();
  stdout.writeln('共 ${sites.length} 个源，并发 4 检测中…\n');

  final results = <String, SiteCheckResult>{};
  var next = 0;
  Future<void> worker() async {
    while (next < sites.length) {
      final site = sites[next++];
      results[site.name] = await HttpService.instance.checkSite(site);
    }
  }

  final sw = Stopwatch()..start();
  await Future.wait(List.generate(4, (_) => worker()));
  sw.stop();

  String tag(SiteHealth h) => switch (h) {
        SiteHealth.ok => '可用',
        SiteHealth.warn => '存疑',
        SiteHealth.fail => '不可用',
      };

  for (final s in sites) {
    final r = results[s.name]!;
    stdout.writeln('${tag(r.health).padRight(4)} '
        '${s.name.padRight(14)} '
        '${r.ms.toString().padLeft(5)}ms  ${r.message}');
  }

  final ok = results.values.where((r) => r.health == SiteHealth.ok).length;
  final warn = results.values.where((r) => r.health == SiteHealth.warn).length;
  final fail = results.values.where((r) => r.health == SiteHealth.fail).length;
  stdout.writeln('\n---- 可用 $ok / 存疑 $warn / 不可用 $fail '
      '（总耗时 ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s）');
}
