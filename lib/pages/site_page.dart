import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../utils/toast.dart';

/// 视频源管理：导入源、青少年模式、启用/停用、置顶
class SitePage extends StatefulWidget {
  const SitePage({super.key});

  @override
  State<SitePage> createState() => _SitePageState();
}

class _SitePageState extends State<SitePage> {
  final TextEditingController _urlController = TextEditingController();
  bool _showImport = false;
  bool _importing = false;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    setState(() => _importing = true);
    final res = await context.read<AppState>().importSites(url);
    if (!mounted) return;
    setState(() {
      _importing = false;
      _showImport = !res.ok;
    });
    if (res.ok) {
      final skip = res.skipped > 0 ? '，跳过 ${res.skipped} 个需插件的源' : '';
      final merge = res.merged ? '（已合并到现有源）' : '';
      showToast(context, '导入成功：${res.sites.length} 个源$skip$merge', success: true);
    } else {
      showToast(
        context,
        '导入失败，请检查网络或地址（配置内的源可能都需要插件支持）',
      );
    }
  }

  void _toggleImport() {
    setState(() {
      _urlController.clear();
      _showImport = !_showImport;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final sites = state.sites;
    return Scaffold(
      appBar: AppBar(title: const Text('源管理')),
      body: Column(
        children: [
          if (_showImport)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _urlController,
                      decoration: InputDecoration(
                        hintText: '输入采集站 JSON 或 TVBox 配置地址',
                        isDense: true,
                        filled: true,
                        fillColor: Theme.of(context).brightness == Brightness.dark
                            ? Colors.grey[900]
                            : Colors.white,
                        border: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(8)),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _importing
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : TextButton(onPressed: _import, child: const Text('导入')),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                OutlinedButton(
                  onPressed: _toggleImport,
                  child: Text(_showImport ? '取消导入' : '导入视频源'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('开启青少年模式', style: TextStyle(fontSize: 14)),
                    value: state.config.r18,
                    onChanged: (v) => context.read<AppState>().setR18(v),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: sites.isEmpty
                ? const Center(child: Text('暂无视频源'))
                : ListView.separated(
                    itemCount: sites.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final site = sites[index];
                      return ListTile(
                        title: Text(
                          site.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${site.type}${site.status.isEmpty ? '' : ' · ${site.status}'}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        leading: index == 0
                            ? null
                            : TextButton(
                                onPressed: () => state.pinSite(site),
                                child: const Text('置顶'),
                              ),
                        trailing: Switch(
                          value: site.isActive,
                          onChanged: (v) => state.toggleSite(site, v),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
