import '../models/site.dart';

/// 一组「同一个接口」的重复源。
///
/// [members] 是组内全部源（保持源列表原有顺序），[suggestedKey] 是建议保留
/// 的那条 —— 具体的「留谁」由用户在清理页自己选，这里只给默认值。
class DuplicateGroup {
  const DuplicateGroup({
    required this.signature,
    required this.members,
    required this.suggestedKey,
  });

  /// 规范化后的接口标识，同一组的成员它都一样。
  final String signature;

  /// 组内全部源，顺序与源列表一致（置顶过的自然排在前面）。
  final List<Site> members;

  /// 建议保留的 key：组内第一条已启用的；整组都停用时取第一条。
  final String suggestedKey;

  /// 按建议保留的那条
  Site get keep => members.firstWhere(
        (s) => s.key == suggestedKey,
        orElse: () => members.first,
      );

  /// 建议删除的其余源
  List<Site> get drop =>
      members.where((s) => s.key != keep.key).toList(growable: false);

  /// 这个组一共几条源（含保留的那条）。
  int get total => members.length;
}

/// 把接口地址规范化成「同一个采集站」的标识。
///
/// 处理这几类**只在写法上不同、实际是同一个接口**的情况：
/// - 域名 / 协议大小写（`HTTP://WWW.X.COM` 与 `http://www.x.com`）
/// - 默认端口（`https://x.com:443/api` 与 `https://x.com/api`）
/// - 路径末尾多一个斜杠（`/api.php/provide/vod` 与 `/api.php/provide/vod/`）
/// - 查询参数顺序（`?a=1&b=2` 与 `?b=2&a=1`）
/// - maccms 的**操作类参数**（`ac` / `pg` / `t` / `wd`）：App 每次请求都会用
///   自己的值覆盖掉，`?ac=list` 与 `?ac=videolist` 指向的是同一个接口
///
/// **不做 http / https 合并**：少数站只开其中一个，把它们算成重复可能删掉
/// 唯一能用的那条。宁可留两个，也不误删。其余查询参数也一律保留 ——
/// 有些站靠它区分线路（如 `?from=xx`），合并了就变成误删。
///
/// 解析不了的地址按原文小写比较 —— 至少完全相同的字符串还能合到一起。
String siteApiSignature(String api) {
  final raw = api.trim();
  if (raw.isEmpty) return '';
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.host.isEmpty) return raw.toLowerCase();

  var host = uri.host.toLowerCase();
  final scheme = uri.scheme.toLowerCase();
  final isDefaultPort =
      (scheme == 'http' && uri.port == 80) || (scheme == 'https' && uri.port == 443);
  if (uri.hasPort && !isDefaultPort) host = '$host:${uri.port}';

  var path = uri.path;
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }

  final params = Map<String, String>.from(uri.queryParameters)
    ..removeWhere((k, v) => _ignoredQueryKeys.contains(k.toLowerCase()));

  final query = StringBuffer();
  if (params.isNotEmpty) {
    final keys = params.keys.toList()..sort();
    for (final k in keys) {
      query
        ..write(query.isEmpty ? '?' : '&')
        ..write(k)
        ..write('=')
        ..write(params[k]);
    }
  }

  return '$scheme://$host$path$query';
}

/// maccms 的「这次要干什么」类参数，由 App 在每个请求里自己填，
/// 写在源地址里没有意义，不参与去重比较。
const Set<String> _ignoredQueryKeys = <String>{'ac', 'pg', 't', 'tid', 'wd'};

/// 找出所有重复源分组（每组至少 2 条）。
///
/// 默认保留规则：组内**优先保留已启用的第一条**（列表靠前的优先，用户置顶过的
/// 自然排在前面）；整组都停用时保留第一条。这样即使直接采用默认选择，也不会把
/// 用户正在用的源删掉、只留下一个停用的空壳。
///
/// 这里不做任何删除，只是分组 —— 具体留谁由「清理重复源」页面让用户点选。
List<DuplicateGroup> findDuplicateGroups(List<Site> sites) {
  final bySignature = <String, List<Site>>{};
  for (final s in sites) {
    // 接口地址为空的源没有可比性，各自独立，不参与去重
    final sig = siteApiSignature(s.api);
    if (sig.isEmpty) continue;
    bySignature.putIfAbsent(sig, () => <Site>[]).add(s);
  }

  final groups = <DuplicateGroup>[];
  bySignature.forEach((sig, list) {
    if (list.length < 2) return;
    var keepIndex = list.indexWhere((s) => s.isActive);
    if (keepIndex < 0) keepIndex = 0;
    groups.add(
      DuplicateGroup(
        signature: sig,
        members: List<Site>.unmodifiable(list),
        suggestedKey: list[keepIndex].key,
      ),
    );
  });
  return groups;
}

/// 去重会删掉的源总数。
int duplicateDropCount(List<Site> sites) =>
    findDuplicateGroups(sites).fold<int>(0, (sum, g) => sum + g.drop.length);
