import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video.dart';
import '../providers/app_state.dart';
import '../utils/toast.dart';
import '../widgets/common_widgets.dart';
import 'detail_page.dart';

/// 收藏夹
class StarPage extends StatefulWidget {
  const StarPage({super.key});

  @override
  State<StarPage> createState() => _StarPageState();
}

class _StarPageState extends State<StarPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().loadStars();
    });
  }

  void _openDetail(RecordItem item) {
    // 站点 key 是 UUID（自带连字符），必须交给 AppState 去精确拆，
    // 否则切出的 siteKey 找不到对应源，详情页会报「获取详情失败」
    final parts = context.read<AppState>().resolveRecordKey(item.key);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailPage(siteKey: parts[0], videoId: parts[1]),
      ),
    );
  }

  Future<void> _remove(BuildContext context, RecordItem item) async {
    final ok = await context.read<AppState>().removeStar(item.key);
    if (!context.mounted) return;
    showToast(context, ok ? '已移除收藏' : '移除失败', success: ok);
  }

  @override
  Widget build(BuildContext context) {
    final stars = context.watch<AppState>().stars;
    return Scaffold(
      appBar: AppBar(title: const Text('收藏')),
      body: stars.isEmpty
          ? const EmptyHint(message: '还没有收藏任何影片', icon: Icons.star_border)
          : ListView.separated(
              itemCount: stars.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = stars[index];
                return ListTile(
                  title: Text(
                    item.name.isEmpty ? '未知' : item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: item.type.isEmpty ? null : Text(item.type),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline,
                        color: Color(0xFF909399)),
                    onPressed: () => _remove(context, item),
                  ),
                  onTap: () => _openDetail(item),
                );
              },
            ),
    );
  }
}
