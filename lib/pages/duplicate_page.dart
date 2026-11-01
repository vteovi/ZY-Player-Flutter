import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/site.dart';
import '../providers/app_state.dart';
import '../utils/app_colors.dart';
import '../utils/site_dup.dart';
import '../utils/toast.dart';

/// 清理重复源。
///
/// 同一个采集接口经常被重复导入（换个名字、换个写法就又进来一条），播放器
/// 只会用其中一条。这个页面把**所有**重复组一次列全，每组由用户点选要保留
/// 哪一条；拿不准的组可以整组「跳过」，一条都不删。
class DuplicatePage extends StatefulWidget {
  const DuplicatePage({super.key});

  @override
  State<DuplicatePage> createState() => _DuplicatePageState();
}

class _DuplicatePageState extends State<DuplicatePage> {
  /// signature -> 该组要保留的源 key
  final Map<String, String> _keep = <String, String>{};

  /// 整组跳过的 signature（这些组一条都不删）
  final Set<String> _skipped = <String>{};

  bool _busy = false;
  bool _seeded = false;

  List<DuplicateGroup> get _groups =>
      findDuplicateGroups(context.read<AppState>().sites);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    _seeded = true;
    // 首次进入：每组默认勾在「建议保留」的那条上（组内第一条启用的）
    for (final g in _groups) {
      _keep[g.signature] = g.suggestedKey;
    }
  }

  /// 全部恢复成默认选择（也用于「拿不准」时一键复位）
  void _resetToSuggested(List<DuplicateGroup> groups) {
    setState(() {
      _keep
        ..clear()
        ..addEntries(groups.map((g) => MapEntry(g.signature, g.suggestedKey)));
      _skipped.clear();
    });
  }

  /// 按当前选择算出真正要删的源（跳过的组不算）
  List<Site> _targetsOf(List<DuplicateGroup> groups) {
    final targets = <Site>[];
    for (final g in groups) {
      if (_skipped.contains(g.signature)) continue;
      final keepKey = _keep[g.signature] ?? g.suggestedKey;
      for (final s in g.members) {
        if (s.key != keepKey) targets.add(s);
      }
    }
    return targets;
  }

  Future<void> _apply(List<DuplicateGroup> groups) async {
    if (_busy) return;
    final targets = _targetsOf(groups);
    if (targets.isEmpty) return;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final warnColor = isDark ? AppColors.failDark : AppColors.failLight;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认清理'),
        content: Text(
          '将删除 ${targets.length} 个重复源，剩下的每组各保留 1 条。\n\n'
          '删除后无法恢复，收藏和播放记录里来自这些源的条目将无法再打开。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: warnColor),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final removed = await context.read<AppState>().removeSites(targets);
    if (!mounted) return;
    showToast(context, '已清理 $removed 个重复源');
    Navigator.of(context).pop(true);
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final deleteCount = _targetsOf(groups).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('清理重复源'),
        actions: [
          TextButton(
            onPressed: groups.isEmpty ? null : () => _resetToSuggested(groups),
            child: const Text('全部用推荐'),
          ),
        ],
      ),
      body: groups.isEmpty
          ? const _EmptyDuplicates()
          : Column(
              children: [
                _buildHint(isDark),
                const Divider(height: 1),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      // 大屏上限宽，卡片不至于被拉成一条长带
                      constraints: const BoxConstraints(maxWidth: 900),
                      child: ListView.builder(
                        padding: const EdgeInsets.only(top: 4, bottom: 24),
                        itemCount: groups.length,
                        itemBuilder: (context, index) =>
                            _buildGroup(groups[index], isDark),
                      ),
                    ),
                  ),
                ),
              ],
            ),
      bottomNavigationBar: groups.isEmpty
          ? null
          : _buildBottomBar(groups, deleteCount, isDark),
    );
  }

  Widget _buildHint(bool isDark) {
    final subText = isDark ? AppColors.darkSubText : AppColors.lightSubText;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 15, color: subText),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '同一个采集接口被重复导入时，播放器只会用其中一条。'
              '逐组点选要保留的那条，其余会被删除；拿不准就点这一组的「跳过」，'
              '那一组一条都不会删。',
              style: TextStyle(fontSize: 12, height: 1.45, color: subText),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroup(DuplicateGroup group, bool isDark) {
    final skipped = _skipped.contains(group.signature);
    final keepKey = _keep[group.signature] ?? group.suggestedKey;
    final subText = isDark ? AppColors.darkSubText : AppColors.lightSubText;
    final divider = isDark ? AppColors.darkDivider : AppColors.lightDivider;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: skipped ? 0.5 : 1,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          // 深色下卡片用纯黑，靠描边区分边界
          color: isDark ? AppColors.darkBg : AppColors.lightSurface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark ? AppColors.darkOutline : AppColors.lightOutline,
          ),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 6, 8),
              child: Row(
                children: [
                  Icon(Icons.link, size: 15, color: subText),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Tooltip(
                          message: group.members.first.api,
                          child: Text(
                            group.members.first.api,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: subText),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          skipped
                              ? '同接口 ${group.total} 条 · 已跳过'
                              : '同接口 ${group.total} 条',
                          style: TextStyle(fontSize: 11, color: subText),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              if (skipped) {
                                _skipped.remove(group.signature);
                              } else {
                                _skipped.add(group.signature);
                              }
                            }),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      skipped ? '恢复' : '跳过',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: divider),
            for (var i = 0; i < group.members.length; i++) ...[
              if (i > 0) Divider(height: 1, indent: 46, color: divider),
              _buildMember(group, group.members[i], keepKey, skipped, isDark),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMember(
    DuplicateGroup group,
    Site site,
    String keepKey,
    bool skipped,
    bool isDark,
  ) {
    final selected = !skipped && site.key == keepKey;
    final subText = isDark ? AppColors.darkSubText : AppColors.lightSubText;
    final keepColor = isDark ? AppColors.okDark : AppColors.okLight;
    final dropColor = isDark ? AppColors.failDark : AppColors.failLight;

    return InkWell(
      onTap: _busy || skipped
          ? null
          : () => setState(() => _keep[group.signature] = site.key),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
        child: Row(
          children: [
            _radio(selected, isDark),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    site.name.isEmpty ? '未命名' : site.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: site.isActive
                          ? null
                          : (isDark ? Colors.white38 : Colors.black38),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${site.type} · ${site.group}${site.isActive ? '' : ' · 已停用'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: subText),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (!skipped)
              _tag(selected ? '保留' : '将删除',
                  selected ? keepColor : dropColor, isDark),
          ],
        ),
      ),
    );
  }

  Widget _radio(bool selected, bool isDark) {
    final on = isDark ? AppColors.okDark : AppColors.okLight;
    final off = isDark ? const Color(0xFF4A4A4E) : const Color(0xFFC8CCD2);
    return Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? on : Colors.transparent,
        border: Border.all(color: selected ? on : off, width: 1.6),
      ),
      child: selected
          ? const Icon(Icons.check, size: 13, color: Colors.white)
          : null,
    );
  }

  Widget _tag(String label, Color color, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.16 : 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildBottomBar(
    List<DuplicateGroup> groups,
    int deleteCount,
    bool isDark,
  ) {
    final subText = isDark ? AppColors.darkSubText : AppColors.lightSubText;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkBg : AppColors.lightSurface,
        border: Border(
          top: BorderSide(
            color: isDark ? AppColors.darkDivider : AppColors.lightDivider,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      switch (_skipped.length) {
                        0 => '共 ${groups.length} 组重复',
                        final n => '共 ${groups.length} 组重复 · 跳过 $n 组',
                      },
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      deleteCount > 0
                          ? '每组保留 1 条，将删除 $deleteCount 个'
                          : '每组的源都保留，没有会删除的条目',
                      style: TextStyle(fontSize: 11.5, color: subText),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: deleteCount == 0 || _busy
                    ? null
                    : () => _apply(groups),
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(deleteCount > 0 ? '清理 $deleteCount 个' : '清理'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyDuplicates extends StatelessWidget {
  const _EmptyDuplicates();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subText = isDark ? AppColors.darkSubText : AppColors.lightSubText;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.filter_none,
              size: 52,
              color: isDark ? const Color(0xFF3A3A3E) : const Color(0xFFC0C4CC),
            ),
            const SizedBox(height: 12),
            Text(
              '没有发现重复源',
              style: TextStyle(fontSize: 14, color: subText),
            ),
            const SizedBox(height: 6),
            Text(
              '这里只找「同一个采集接口被导入多次」的情况；'
              '不同接口的源不会被当成重复',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, height: 1.5, color: subText),
            ),
          ],
        ),
      ),
    );
  }
}
