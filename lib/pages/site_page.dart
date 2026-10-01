import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/site.dart';
import '../providers/app_state.dart';
import '../services/http_service.dart';
import '../utils/app_colors.dart';
import '../utils/toast.dart';

/// 视频源管理：导入源、可用性检测、青少年模式、启用/停用、置顶
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
        setState(() {
          _results[site.key] = result;
          _done++;
        });
      }
    }

    await Future.wait(List<Future<void>>.generate(4, (_) => worker()));
    if (mounted) setState(() => _batchRunning = false);
  }

  /// 检测出的「启用中但不可用」的源
  List<Site> get _failedActive {
    final sites = context.read<AppState>().sites;
    return sites
        .where((s) => s.isActive && _results.containsKey(s.key) && !_results[s.key]!.ok)
        .toList();
  }

  Future<void> _disableFailed() async {
    final targets = _failedActive;
    if (targets.isEmpty) return;
    await context.read<AppState>().setSitesActive(targets, false);
    if (!mounted) return;
    showToast(context, '已停用 ${targets.length} 个失效源');
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
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('开启青少年模式', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              '过滤片名/分类命中关键词的资源',
              style: TextStyle(
                fontSize: 11,
                color: isDark ? AppColors.darkSubText : AppColors.lightSubText,
              ),
            ),
            value: state.config.r18,
            onChanged: (v) => context.read<AppState>().setR18(v),
          ),
          if (_results.isNotEmpty) _buildSummary(),
        ],
      ),
    );
  }

  /// 检测结果汇总 + 「一键停用失效源」
  Widget _buildSummary() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final values = _results.values;
    final ok = values.where((r) => r.health == SiteHealth.ok).length;
    final warn = values.where((r) => r.health == SiteHealth.warn).length;
    final fail = values.where((r) => r.health == SiteHealth.fail).length;
    final failed = _failedActive.length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
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
          if (failed > 0)
            TextButton.icon(
              onPressed: _disableFailed,
              icon: const Icon(Icons.block, size: 16),
              label: Text('停用 $failed 个失效源'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
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
