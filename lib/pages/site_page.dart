import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/site.dart';
import '../providers/app_state.dart';
import '../services/http_service.dart';
import '../utils/app_colors.dart';
import '../utils/site_dup.dart';
import '../utils/toast.dart';
import 'duplicate_page.dart';

/// 视频源管理：导入源、可用性检测、启用/停用、清除死站、置顶
class SitePage extends StatefulWidget {
  const SitePage({super.key});

  @override
  State<SitePage> createState() => _SitePageState();
}

class _SitePageState extends State<SitePage> {
  /// 工具栏从「两行两列」改成「一行排开」的屏宽阈值
  static const double _wideToolbarWidth = 660;

  /// 源列表变成两列 / 三列的屏宽阈值
  static const double _twoColumnWidth = 660;
  static const double _threeColumnWidth = 1080;

  final TextEditingController _urlController = TextEditingController();
  bool _showImport = false;
  bool _importing = false;

  /// key -> 最近一次检测结果。
  ///
  /// **只放内存、不落库** —— 源的可用性有时效，把上次的结论存下来
  /// 反而会误导（明明已经死了却显示"可用"）。重进页面即清空。
  final Map<String, SiteCheckResult> _results = <String, SiteCheckResult>{};

  /// 正在检测中的源（单个检测与"检测全部"共用，条目上转小圈用）
  final Set<String> _busy = <String>{};

  bool _batchRunning = false;
  int _done = 0;
  int _total = 0;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 导入
  // ---------------------------------------------------------------------------

  Future<void> _import() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    setState(() => _importing = true);
    final summary = await context.read<AppState>().importSites(url);
    if (!mounted) return;
    setState(() {
      _importing = false;
      _showImport = !summary.ok;
    });
    if (summary.ok) {
      final parts = <String>['新增 ${summary.added} 个'];
      if (summary.updated > 0) parts.add('更新 ${summary.updated} 个');
      if (summary.skipped > 0) parts.add('跳过 ${summary.skipped} 个');
      final note = summary.message.isEmpty ? '' : '\n${summary.message}';
      showToast(
        context,
        '导入成功：${parts.join('，')}$note',
        success: true,
        duration: const Duration(seconds: 4),
      );
    } else {
      showToast(
        context,
        summary.message.isEmpty
            ? '导入失败，请检查地址是否为有效的配置地址'
            : '导入失败：${summary.message}',
        success: false,
        duration: const Duration(seconds: 5),
      );
    }
  }

  void _toggleImport() {
    setState(() {
      _urlController.clear();
      _showImport = !_showImport;
    });
  }

  // ---------------------------------------------------------------------------
  // 可用性检测
  // ---------------------------------------------------------------------------

  /// 检测单个源
  Future<void> _checkOne(Site site) async {
    if (_busy.contains(site.key)) return;
    setState(() => _busy.add(site.key));
    final result = await HttpService.instance.checkSite(site);
    if (!mounted) return;
    // 检测期间源可能被删了（清除死站 / 清空所有源）—— 过期结果直接丢掉
    if (context.read<AppState>().siteOf(site.key) == null) {
      setState(() => _busy.remove(site.key));
      return;
    }
    setState(() {
      _busy.remove(site.key);
      _results[site.key] = result;
    });
  }

  /// 单次批量检测的并发请求数。
  ///
  /// 实测 11 个内置源（`?ac=list`、浏览器 UA）：单请求中位 1.4 秒、最慢 3.4 秒，
  /// 串行要 18.6 秒；并发 4 约 12 秒，**并发 8 稳定在 4 秒上下**。再往上
  /// （几十路）反而变慢 —— 目标站的限流和本机带宽都会拖后腿，8 是甜点。
  static const int _checkConcurrency = 8;

  /// 去重键：同一个接口（协议 + 域名 + 路径）只检测一次。
  ///
  /// 第三方配置里很常见「一个 api.php 派生出十几个源」（只差分类参数），
  /// 逐个请求纯属重复；查询串不参与键，因为检测只关心可达性。
  static String _probeKey(Site site) {
    final api = site.api.trim();
    if (api.isEmpty) return 'empty:${site.key}';
    try {
      final uri = Uri.parse(api);
      if (uri.host.isNotEmpty) {
        return '${uri.scheme}://${uri.host}${uri.path}';
      }
    } catch (_) {
      // 解析不了就退回原串，至少完全相同的地址还能合并
    }
    return 'raw:$api';
  }

  /// 检测全部源。
  ///
  /// 两条提速主线：**并发**（8 路）与**按接口归组**（同一域名只测一次）。
  /// 不做全量并发：几十个请求同时打，既会被目标站限流，也会让进度条
  /// 半天不动一下。
  Future<void> _checkAll() async {
    final list = context.read<AppState>().sites;
    if (list.isEmpty || _batchRunning) return;
    setState(() {
      _batchRunning = true;
      _done = 0;
      _total = list.length;
      _results.clear();
    });
    // 归组：同接口的源共用一个检测结论（一批配置里常常几十个源只有几个接口）
    final groups = <String, List<Site>>{};
    for (final s in list) {
      groups.putIfAbsent(_probeKey(s), () => <Site>[]).add(s);
    }
    final tasks = groups.values.toList();

    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (!mounted) return;
        // next++ 在 await 之前同步完成，多 worker 之间不会拿到同一个下标
        if (next >= tasks.length) return;
        final group = tasks[next++];
        setState(() {
          for (final s in group) {
            _busy.add(s.key);
          }
        });
        SiteCheckResult result;
        try {
          result = await HttpService.instance.checkSite(group.first);
        } catch (e) {
          // 检测自身出错只影响这一组，不能让它把整个批量打断
          result = SiteCheckResult(
            SiteHealth.fail,
            HttpService.describeRequestError(e),
            0,
          );
        }
        if (!mounted) return;
        final appState = context.read<AppState>();
        setState(() {
          for (final s in group) {
            _busy.remove(s.key);
            // 源已被删（清除死站 / 清空所有源）就不写结果，只推进进度
            if (appState.siteOf(s.key) != null) {
              _results[s.key] = result;
            }
          }
          _done += group.length;
        });
      }
    }

    try {
      final workers = tasks.length < _checkConcurrency
          ? tasks.length
          : _checkConcurrency;
      await Future.wait(List<Future<void>>.generate(workers, (_) => worker()));
    } finally {
      // 进度条 / 按钮必须复位，否则一次异常就让整页卡在「检测中」
      if (mounted) {
        setState(() {
          _batchRunning = false;
          _busy.clear();
        });
      }
    }
    if (!mounted) return;

    // 检测结束后统一整理启用状态（不在中途写库，避免并发整库读改写互相覆盖）：
    //  - **彻底不可用（fail）**且当前启用的源 → 自动停用
    //  - 可用（ok）且当前停用的源 → 自动启用
    //
    // 存疑（warn，"接口能连通但没返回片单"）**不动**：很多采集站的 `ac=list`
    // 本来就只吐分类，judge 成 warn 的源往往还能正常播放，自动停用会把它们
    // 从首页站点列表里悄悄拿掉 —— 用户看到的就是「检测一下源就少了」。
    final appState = context.read<AppState>();
    final toDisable = appState.sites
        .where((s) =>
            s.isActive &&
            _results.containsKey(s.key) &&
            _results[s.key]!.health == SiteHealth.fail)
        .toList();
    final toEnable = appState.sites
        .where((s) =>
            !s.isActive &&
            _results.containsKey(s.key) &&
            _results[s.key]!.ok)
        .toList();
    if (toDisable.isNotEmpty) {
      await appState.setSitesActive(toDisable, false);
      if (!mounted) return;
    }
    if (toEnable.isNotEmpty) {
      await appState.setSitesActive(toEnable, true);
      if (!mounted) return;
    }

    // 重排：可用源排到前面，不可用（warn/fail）排到后面，没检测的放最后。
    final latest = context.read<AppState>();
    final available = <Site>[];
    final unavailable = <Site>[];
    final undetected = <Site>[];
    for (final s in latest.sites) {
      final r = _results[s.key];
      if (r == null) {
        undetected.add(s);
      } else if (r.ok || r.health == SiteHealth.warn) {
        available.add(s);
      } else {
        unavailable.add(s);
      }
    }
    await latest.reorderSites(<Site>[...available, ...unavailable, ...undetected]);
    if (!mounted) return;

    final parts = <String>[];
    if (toDisable.isNotEmpty) parts.add('停用 ${toDisable.length} 个失效源');
    if (toEnable.isNotEmpty) parts.add('启用 ${toEnable.length} 个可用源');
    if (parts.isNotEmpty) {
      showToast(
        context,
        '${parts.join('，')}，并将可用源排到前面',
      );
    }
  }

  /// 检测出的「死站」：健康度为 fail 的源，**不论当前是否启用**。
  ///
  /// 与「检测全部后自动停用」分开：死站是彻底删掉（连条目一起），
  /// 自动停用只是把失效源设为停用（条目留着，说不定哪天又活了）。
  List<Site> get _deadSites {
    final sites = context.read<AppState>().sites;
    return sites
        .where((s) =>
            _results.containsKey(s.key) &&
            _results[s.key]!.health == SiteHealth.fail)
        .toList();
  }

  /// 打开「清理重复源」页面：把**所有**重复组列全，逐组由用户点选保留哪一条。
  ///
  /// 之前是在弹窗里直接按「第一条启用的」批量删，用户看不到全部重复项、
  /// 也没得选；选谁留谁这种事本来就该让用户自己决定。
  Future<void> _openDedupe() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const DuplicatePage()),
    );
    if (!mounted || changed != true) return;
    // 源已经删了，对应的检测结果和「检测中」标记一起丢掉，否则汇总数字会一直挂着
    final keys = context.read<AppState>().sites.map((s) => s.key).toSet();
    setState(() {
      _results.removeWhere((key, _) => !keys.contains(key));
      _busy.removeWhere((key) => !keys.contains(key));
    });
  }

  /// 清除死站：把检测不可用的源从列表里删掉。
  ///
  /// 删除不可逆，所以先弹确认框。提示里说明：只想暂时屏蔽就点「检测全部」
  /// 让失效源自动停用，条目会保留。
  Future<void> _clearDead() async {
    final targets = _deadSites;
    if (targets.isEmpty) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final warnColor = isDark ? AppColors.failDark : AppColors.failLight;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除死站'),
        content: Text(
          '将从源列表中删除 ${targets.length} 个检测不可用的视频源，'
          '删除后无法恢复。\n\n'
          '如果只是想暂时屏蔽而非删除：点「检测全部」后会自动停用失效源，'
          '条目会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: warnColor),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    final removed = await context.read<AppState>().removeSites(targets);
    if (!mounted) return;
    // 源已经删了，对应的检测结果也要一起丢掉，否则汇总数字会一直挂着
    setState(() {
      for (final s in targets) {
        _results.remove(s.key);
      }
    });
    showToast(context, '已清除 $removed 个死站');
  }

  /// 清空所有源：把列表里**全部**视频源删掉（不分好坏）。
  ///
  /// 比「清除死站」更狠，连没检测过的源一起走，所以必须二次确认，
  /// 并明确告知收藏 / 播放记录里的条目会连带打不开。
  Future<void> _clearAllSites() async {
    final sites = context.read<AppState>().sites;
    if (sites.isEmpty) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final warnColor = isDark ? AppColors.failDark : AppColors.failLight;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空所有源'),
        content: Text(
          '将删除全部 ${sites.length} 个视频源（不分可用与否），'
          '清空后需要重新导入才能观看。\n\n'
          '收藏和播放记录里来自这些源的条目将无法再打开，此操作无法撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: warnColor),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    final removed = await context.read<AppState>().removeSites(sites);
    if (!mounted) return;
    // 源都没了，检测结果自然作废（顺带丢掉可能的在飞行中的标记）
    setState(() {
      _results.clear();
      _busy.clear();
    });
    showToast(context, '已清空 $removed 个视频源');
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final sites = state.sites;
    return Scaffold(
      appBar: AppBar(
        title: const Text('源管理'),
        actions: [
          // 「清空所有源」是破坏性操作，放在溢出菜单里，不给它和常用按钮抢位置
          PopupMenuButton<String>(
            tooltip: '更多',
            enabled: sites.isNotEmpty,
            onSelected: (value) {
              if (value == 'clearAll') _clearAllSites();
            },
            itemBuilder: (ctx) {
              final isDark = Theme.of(ctx).brightness == Brightness.dark;
              final danger = isDark ? AppColors.failDark : AppColors.failLight;
              return <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  value: 'clearAll',
                  child: Row(
                    children: [
                      Icon(Icons.delete_sweep_outlined, size: 18, color: danger),
                      const SizedBox(width: 10),
                      Text(
                        '清空所有源',
                        style: TextStyle(fontSize: 14, color: danger),
                      ),
                    ],
                  ),
                ),
              ];
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildToolbar(state),
          if (_batchRunning)
            LinearProgressIndicator(
              value: _total == 0 ? null : _done / _total,
              minHeight: 2,
            ),
          const Divider(height: 1),
          Expanded(
            child: sites.isEmpty
                ? const _EmptySites()
                : _buildSiteList(sites, state),
          ),
        ],
      ),
    );
  }

  /// 源列表：手机上单列；平板 / 桌面按屏宽排成两到三列，
  /// 一屏能看全更多源，也免得上滑下滑翻半天。
  Widget _buildSiteList(List<Site> sites, AppState state) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= _threeColumnWidth
        ? 3
        : (width >= _twoColumnWidth ? 2 : 1);
    if (columns == 1) {
      return ListView.builder(
        padding: const EdgeInsets.only(top: 6, bottom: 24),
        itemCount: sites.length,
        itemBuilder: (context, index) => _buildItem(sites[index], index, state),
      );
    }
    final rowCount = (sites.length + columns - 1) ~/ columns;
    return ListView.builder(
      padding: const EdgeInsets.only(top: 6, bottom: 24),
      itemCount: rowCount,
      itemBuilder: (context, row) {
        final start = row * columns;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var c = 0; c < columns; c++)
              Expanded(
                child: start + c < sites.length
                    ? _buildItem(sites[start + c], start + c, state)
                    : const SizedBox.shrink(),
              ),
          ],
        );
      },
    );
  }

  Widget _buildToolbar(AppState state) {
    final danger = Theme.of(context).brightness == Brightness.dark
        ? AppColors.failDark
        : AppColors.failLight;
    // 「清除死站」得先检测出 fail 才有目标，没检测时为 0 → 按钮保持禁用
    final dead = _deadSites.length;
    // 「清理重复」是纯本地比对，不依赖有没有检测过
    final dup = duplicateDropCount(state.sites);
    final idle = _batchRunning || state.sites.isEmpty;
    final wide = MediaQuery.sizeOf(context).width >= _wideToolbarWidth;

    final actions = <Widget>[
      _toolButton(
        icon: _showImport ? Icons.close : Icons.file_download_outlined,
        label: _showImport ? '取消' : '导入视频源',
        onPressed: _toggleImport,
      ),
      _toolButton(
        icon: Icons.network_check,
        label: _batchRunning ? '检测中 $_done/$_total' : '检测全部',
        onPressed: idle ? null : _checkAll,
      ),
      _toolButton(
        icon: Icons.filter_none,
        label: dup > 0 ? '清理重复 ($dup)' : '清理重复',
        onPressed: idle || dup == 0 ? null : _openDedupe,
      ),
      _toolButton(
        icon: Icons.delete_outline,
        label: dead > 0 ? '清除死站 ($dead)' : '清除死站',
        onPressed: idle || dead == 0 ? null : _clearDead,
        color: danger,
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Column(
        children: [
          if (_showImport)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _urlController,
                      autofocus: true,
                      style: const TextStyle(fontSize: 14),
                      decoration: const InputDecoration(
                        hintText: '粘贴 TVBox / ZYFun 配置地址，或导航页地址',
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(10)),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _importing
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton(
                          onPressed: _import,
                          child: const Text('导入'),
                        ),
                ],
              ),
            ),
          // 宽屏把按钮排成一行（按内容取宽，不拉满整行显得空）；
          // 窄屏两行两列，拇指区更好点。
          if (wide)
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(spacing: 10, runSpacing: 8, children: actions),
            )
          else ...[
            _twoColumn(actions[0], actions[1]),
            const SizedBox(height: 8),
            _twoColumn(actions[2], actions[3]),
          ],
          if (_results.isNotEmpty) _buildSummary(),
        ],
      ),
    );
  }

  /// 窄屏工具栏的一行两个等宽按钮
  Widget _twoColumn(Widget a, Widget b) {
    return Row(
      children: [
        Expanded(child: a),
        const SizedBox(width: 10),
        Expanded(child: b),
      ],
    );
  }

  /// 工具栏统一按钮：内外边距一致，宽屏按内容取宽时也不会高矮参差
  Widget _toolButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 13)),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }

  /// 检测结果汇总（清理动作放在工具栏，这里只报数）
  Widget _buildSummary() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final values = _results.values;
    final ok = values.where((r) => r.health == SiteHealth.ok).length;
    final warn = values.where((r) => r.health == SiteHealth.warn).length;
    final fail = values.where((r) => r.health == SiteHealth.fail).length;
    // 带上源总数：检测完对不上一眼就能看出来，不用自己去数列表
    final total = context.read<AppState>().sites.length;

    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _summaryChip(Icons.check_circle, '可用 $ok', AppColors.okDark,
              AppColors.okLight, isDark),
          _summaryChip(Icons.help_outline, '存疑 $warn', AppColors.warnDark,
              AppColors.warnLight, isDark),
          _summaryChip(Icons.cancel_outlined, '不可用 $fail', AppColors.failDark,
              AppColors.failLight, isDark),
          Text(
            values.length == total
                ? '已检测 $total 个源'
                : '已检测 ${values.length} / 共 $total 个源',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? AppColors.darkSubText : AppColors.lightSubText,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryChip(
    IconData icon,
    String label,
    Color dark,
    Color light,
    bool isDark,
  ) {
    final color = isDark ? dark : light;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.14 : 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItem(Site site, int index, AppState state) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final result = _results[site.key];
    final busy = _busy.contains(site.key);
    final accent = _healthColor(result, isDark);
    final subText = isDark ? AppColors.darkSubText : AppColors.lightSubText;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        // 深色下卡片用纯黑，靠描边区分边界（提亮底色会让整屏发灰）
        color: isDark ? AppColors.darkBg : AppColors.lightSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: result == null
              ? (isDark ? AppColors.darkOutline : AppColors.lightOutline)
              : accent.withValues(alpha: isDark ? 0.5 : 0.42),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _statusDot(accent, busy),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        site.name.isEmpty ? '未命名' : site.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: site.isActive
                              ? null
                              : (isDark ? Colors.white38 : Colors.black38),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${site.type} · ${site.group}',
                        style: TextStyle(fontSize: 11, color: subText),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: site.isActive,
                  onChanged: (v) => state.toggleSite(site, v),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              site.api,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: isDark ? const Color(0xFF6E6E73) : const Color(0xFFB4B8BE),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: result == null
                      ? Text(
                          busy ? '检测中…' : '未检测',
                          style: TextStyle(fontSize: 11, color: subText),
                        )
                      : Row(
                          children: [
                            // 多列布局下卡片更窄，长结论（如「域名解析失败…」）
                            // 必须能省略，否则整行溢出
                            Flexible(child: _resultChip(result, isDark)),
                            const SizedBox(width: 6),
                            Text(
                              '${result.ms}ms',
                              style: TextStyle(fontSize: 11, color: subText),
                            ),
                          ],
                        ),
                ),
                IconButton(
                  onPressed: busy ? null : () => _checkOne(site),
                  icon: Icon(
                    result == null ? Icons.network_check : Icons.refresh,
                    size: 18,
                  ),
                  tooltip: result == null ? '检测' : '重新检测',
                  visualDensity: VisualDensity.compact,
                  color: isDark ? AppColors.darkSubText : AppColors.lightSubText,
                ),
                if (index > 0)
                  IconButton(
                    onPressed: () => state.pinSite(site),
                    icon: const Icon(Icons.vertical_align_top, size: 18),
                    tooltip: '置顶',
                    visualDensity: VisualDensity.compact,
                    color:
                        isDark ? AppColors.darkSubText : AppColors.lightSubText,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusDot(Color color, bool busy) {
    if (busy) {
      return const SizedBox(
        width: 10,
        height: 10,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  Widget _resultChip(SiteCheckResult result, bool isDark) {
    final color = _healthColor(result, isDark);
    return Tooltip(
      message: result.message,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: isDark ? 0.15 : 0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          result.message,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Color _healthColor(SiteCheckResult? result, bool isDark) {
    if (result == null) {
      return isDark ? AppColors.idleDark : AppColors.idleLight;
    }
    switch (result.health) {
      case SiteHealth.ok:
        return isDark ? AppColors.okDark : AppColors.okLight;
      case SiteHealth.warn:
        return isDark ? AppColors.warnDark : AppColors.warnLight;
      case SiteHealth.fail:
        return isDark ? AppColors.failDark : AppColors.failLight;
    }
  }
}

class _EmptySites extends StatelessWidget {
  const _EmptySites();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.video_library_outlined,
            size: 56,
            color: isDark ? const Color(0xFF3A3A3E) : const Color(0xFFC0C4CC),
          ),
          const SizedBox(height: 12),
          Text(
            '还没有视频源',
            style: TextStyle(
              fontSize: 14,
              color: isDark ? AppColors.darkSubText : AppColors.lightSubText,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '点上方「导入视频源」添加，支持 TVBox / ZYFun 配置、多仓与导航页',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? const Color(0xFF6E6E73) : const Color(0xFFB4B8BE),
            ),
          ),
        ],
      ),
    );
  }
}
