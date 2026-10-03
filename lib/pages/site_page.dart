import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/site.dart';
import '../providers/app_state.dart';
import '../services/http_service.dart';
import '../utils/app_colors.dart';
import '../utils/toast.dart';

/// 视频源管理：导入源、可用性检测、启用/停用、清除死站、置顶
class SitePage extends StatefulWidget {
  const SitePage({super.key});

  @override
  State<SitePage> createState() => _SitePageState();
}

class _SitePageState extends State<SitePage> {
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
    final ok = await context.read<AppState>().importSites(url);
    if (!mounted) return;
    setState(() {
      _importing = false;
      _showImport = !ok;
    });
    showToast(
      context,
      ok ? '导入成功' : '导入失败，请检查地址是否为可直接访问的 JSON',
      success: ok,
    );
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

  /// 检测全部源。
  ///
  /// 并发 4 而不是全量并发：采集站大多在同一个垃圾网络里，
  /// 一次性发几十个请求既容易互相拖慢，也会让进度条长时间不动。
  Future<void> _checkAll() async {
    final list = context.read<AppState>().sites;
    if (list.isEmpty || _batchRunning) return;
    setState(() {
      _batchRunning = true;
      _done = 0;
      _total = list.length;
      _results.clear();
    });
    var next = 0;
    Future<void> worker() async {
      while (next < list.length) {
        // next++ 在 await 之前同步完成，多 worker 之间不会拿到同一个下标
        final site = list[next++];
        final result = await HttpService.instance.checkSite(site);
        if (!mounted) return;
        // 源已被删（清除死站 / 清空所有源）就不写结果，只推进进度
        if (context.read<AppState>().siteOf(site.key) == null) {
          setState(() => _done++);
          continue;
        }
        setState(() {
          _results[site.key] = result;
          _done++;
        });
      }
    }

    await Future.wait(List<Future<void>>.generate(4, (_) => worker()));
    if (mounted) setState(() => _batchRunning = false);
  }

  /// 检测出的「启用中但不可用」的源（一键停用失效源的目标）
  List<Site> get _failedActive {
    final sites = context.read<AppState>().sites;
    return sites
        .where((s) => s.isActive && _results.containsKey(s.key) && !_results[s.key]!.ok)
        .toList();
  }

  /// 检测出的「死站」：健康度为 fail 的源，**不论当前是否启用**。
  ///
  /// 与 [_failedActive] 分开：死站是彻底删掉（连条目一起），
  /// 失效源只是停用（条目留着，说不定哪天又活了）。
  List<Site> get _deadSites {
    final sites = context.read<AppState>().sites;
    return sites
        .where((s) =>
            _results.containsKey(s.key) &&
            _results[s.key]!.health == SiteHealth.fail)
        .toList();
  }

  /// 一键停用：把「启用中但检测不可用」的源批量设为停用（不删条目）
  Future<void> _disableFailed() async {
    final targets = _failedActive;
    if (targets.isEmpty) return;
    await context.read<AppState>().setSitesActive(targets, false);
    if (!mounted) return;
    showToast(context, '已停用 ${targets.length} 个失效源');
  }

  /// 清除死站：把检测不可用的源从列表里删掉。
  ///
  /// 删除不可逆，所以先弹确认框；同时提示可以改用「一键停用失效源」。
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
          '如果只是想暂时屏蔽，请改用「一键停用失效源」。',
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
      appBar: AppBar(title: const Text('源管理')),
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
                : ListView.builder(
                    padding: const EdgeInsets.only(top: 6, bottom: 24),
                    itemCount: sites.length,
                    itemBuilder: (context, index) =>
                        _buildItem(sites[index], index, state),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(AppState state) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 两个清理动作都得先检测出结果才有目标，没检测时为 0 → 按钮保持禁用
    final failed = _failedActive.length;
    final dead = _deadSites.length;
    final idle = _batchRunning || state.sites.isEmpty;
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
                        hintText: '请输入 JSON 后缀的网址',
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
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _toggleImport,
                  icon: Icon(
                    _showImport ? Icons.close : Icons.file_download_outlined,
                    size: 18,
                  ),
                  label: Text(_showImport ? '取消' : '导入视频源'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _batchRunning || state.sites.isEmpty
                      ? null
                      : _checkAll,
                  icon: const Icon(Icons.network_check, size: 18),
                  label: Text(_batchRunning ? '检测中 $_done/$_total' : '检测全部'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: idle || failed == 0 ? null : _disableFailed,
                  icon: const Icon(Icons.block, size: 18),
                  label: const Text('一键停用失效源', style: TextStyle(fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: idle || dead == 0 ? null : _clearDead,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('清除死站', style: TextStyle(fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    foregroundColor:
                        isDark ? AppColors.failDark : AppColors.failLight,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: idle ? null : _clearAllSites,
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: const Text('清空所有源', style: TextStyle(fontSize: 13)),
              style: OutlinedButton.styleFrom(
                foregroundColor: isDark ? AppColors.failDark : AppColors.failLight,
              ),
            ),
          ),
          if (_results.isNotEmpty) _buildSummary(),
        ],
      ),
    );
  }

  /// 检测结果汇总（清理动作放在工具栏第二行，这里只报数）
  Widget _buildSummary() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final values = _results.values;
    final ok = values.where((r) => r.health == SiteHealth.ok).length;
    final warn = values.where((r) => r.health == SiteHealth.warn).length;
    final fail = values.where((r) => r.health == SiteHealth.fail).length;

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
            '已检测 ${values.length} 个源',
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
                            _resultChip(result, isDark),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.15 : 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        result.message,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w500,
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
            '点上方「导入视频源」添加，支持 TVBox / ZYFun 配置',
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
