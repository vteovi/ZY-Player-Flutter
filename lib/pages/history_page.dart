import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video.dart';
import '../providers/app_state.dart';
import '../widgets/common_widgets.dart';
import 'play_page.dart';

/// 播放记录：显示观看进度，点击从上次位置续播
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().loadHistories();
    });
  }

  void _play(RecordItem item) {
    if (item.url.isEmpty) return;
    // 同收藏页：站点 key 是 UUID，不能用第一个连字符切
    final parts = context.read<AppState>().resolveRecordKey(item.key);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayPage(
          siteKey: parts[0],
          videoId: parts[1],
          title: item.label.isEmpty ? item.name : item.label,
          url: item.url,
          initialTime: item.currentTime,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final histories = context.watch<AppState>().histories;
    return Scaffold(
      appBar: AppBar(title: const Text('播放记录')),
      body: histories.isEmpty
          ? const EmptyHint(message: '还没有播放记录', icon: Icons.history)
          : ListView.separated(
              itemCount: histories.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = histories[index];
                final progress = item.progress;
                return ListTile(
                  title: Text(
                    item.name.isEmpty ? '未知' : item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (item.label.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            item.label,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF606266)),
                          ),
                        ),
                      if (progress > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: LinearProgressIndicator(
                                  value: progress / 100,
                                  minHeight: 3,
                                  backgroundColor: const Color(0xFFEDEDED),
                                  valueColor: const AlwaysStoppedAnimation(
                                      Color(0xFF1E88E5)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '$progress%',
                                style: const TextStyle(
                                    fontSize: 12, color: Color(0xFF909399)),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  trailing: item.type.isEmpty ? null : Text(item.type),
                  onTap: () => _play(item),
                );
              },
            ),
    );
  }
}
