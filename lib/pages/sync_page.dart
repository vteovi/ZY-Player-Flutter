import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../services/sync_service.dart';
import '../services/zy_database.dart';
import '../utils/toast.dart';

/// 局域网设备同步。
///
/// 两种角色：
/// - 开启共享（发送端）：在 9527 端口起 HTTP 服务暴露选定数据，并周期组播广播自身；
///   另一端用「连接同步」自动发现或直接输入本机 IP 连接。
/// - 连接同步（接收端）：监听组播自动列出局域网内正在共享的设备，选设备 + 勾选范围
///   后拉取并合并到本地。
class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  // 共享端的运行态
  SyncServer? _server;
  Future<void> Function()? _stopAnnounce;
  bool _sharing = false;
  String _localIp = '';
  String _deviceName = '';

  // 接收端的运行态
  LanListener? _lanListener;
  final List<LanDevice> _devices = <LanDevice>[];
  bool _refreshing = false;
  LanDevice? _selectedDevice;
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController =
      TextEditingController(text: '9527');
  bool _syncing = false;
  String _syncResult = '';

  /// 可同步的数据类别（顺序固定，影响 UI 与导出键）
  static const List<_SyncScope> _scopes = [
    _SyncScope(DbNames.site, '视频源', Icons.video_library_outlined),
    _SyncScope(DbNames.setting, 'App 配置', Icons.settings_outlined),
    _SyncScope(DbNames.star, '收藏', Icons.star_outline),
    _SyncScope(DbNames.history, '历史播放记录', Icons.history_outlined),
  ];

  final Set<String> _shareSelected = {DbNames.site, DbNames.setting, DbNames.star, DbNames.history};
  final Set<String> _pullSelected = {DbNames.site, DbNames.setting, DbNames.star, DbNames.history};

  @override
  void initState() {
    super.initState();
    _deviceName = _buildDeviceName();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);
    LanDiscovery.getLocalIp().then((ip) {
      if (mounted) setState(() => _localIp = ip ?? '');
    });
  }

  void _onTabChanged() {
    // 切到「连接同步」时启动自动发现，切走则停止并清空列表
    if (_tabController.index == 1) {
      _startListening();
    } else {
      _stopListening();
      if (mounted) setState(() => _devices.clear());
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _stopSharing();
    _stopListening();
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  String _buildDeviceName() {
    final rand = Random().nextInt(9000) + 1000;
    return 'ZY-Player-$rand';
  }

  // --------------------------------------------------------------------------
  // 共享端
  // --------------------------------------------------------------------------

  Future<void> _startSharing() async {
    if (_shareSelected.isEmpty) {
      showToast(context, '请至少选择一类数据', success: false);
      return;
    }
    final payload =
        await context.read<AppState>().exportDbs(_shareSelected);
    final server = await SyncServer.start(payload);
    if (server == null) {
      showToast(context, '共享端口 9527 被占用，请稍后重试', success: false);
      return;
    }
    final stopAnnounce = await LanDiscovery.startAnnouncing(server.port, _deviceName);
    if (mounted) {
      setState(() {
        _server = server;
        _stopAnnounce = stopAnnounce;
        _sharing = true;
      });
    }
  }

  void _stopSharing() {
    _stopAnnounce?.call();
    _stopAnnounce = null;
    _server?.stop();
    _server = null;
    if (mounted) setState(() => _sharing = false);
  }

  // --------------------------------------------------------------------------
  // 接收端
  // --------------------------------------------------------------------------

  Future<void> _startListening() async {
    if (_lanListener != null) return;
    final listener = await LanDiscovery.startListening((device) {
      if (!mounted) return;
      setState(() {
        final idx = _devices.indexWhere((d) => d == device);
        if (idx >= 0) {
          _devices[idx] = device;
        } else {
          _devices.add(device);
        }
      });
    });
    if (mounted) setState(() => _lanListener = listener);
  }

  void _stopListening() {
    _lanListener?.stop();
    _lanListener = null;
  }

  /// 手动刷新：确保监听在跑，并向局域网发送一次主动探测，
  /// 促使共享端立即单播回应（避免退出重进页面才能看到设备）。
  Future<void> _refreshDevices() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    if (_lanListener == null) await _startListening();
    _lanListener?.probe();
    // 给共享端一点响应时间，期间按钮显示「扫描中」
    await Future.delayed(const Duration(milliseconds: 900));
    if (mounted) setState(() => _refreshing = false);
  }

  Future<void> _doSync() async {
    if (_pullSelected.isEmpty) {
      showToast(context, '请至少选择一类数据', success: false);
      return;
    }
    final host = _ipController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    if (host.isEmpty || port == null) {
      showToast(context, '请输入对方 IP 和端口', success: false);
      return;
    }
    setState(() {
      _syncing = true;
      _syncResult = '';
    });
    try {
      final data = await SyncClient.fetch(host, port);
      // 只合并用户在接收端勾选的类别（对方可能共享了更多）
      final wanted = <String, List<Map<String, dynamic>>>{};
      for (final key in _pullSelected) {
        if (data[key] != null) wanted[key] = data[key]!;
      }
      final summary =
          await context.read<AppState>().importDbs(wanted);
      if (!mounted) return;
      final parts = summary.entries
          .map((e) => '${_scopeLabel(e.key)} ${e.value} 条')
          .toList();
      setState(() {
        _syncResult = parts.isEmpty ? '没有可同步的数据' : '同步完成：\n${parts.join('，')}';
      });
      showToast(context, '同步完成', success: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _syncResult = '同步失败：$e');
      showToast(context, '同步失败：$e', success: false);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  String _scopeLabel(String db) {
    for (final s in _scopes) {
      if (s.db == db) return s.label;
    }
    return db;
  }

  // --------------------------------------------------------------------------
  // UI
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('设备同步'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '开启共享'),
            Tab(text: '连接同步'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildSharePane(isDark),
          _buildPullPane(isDark),
        ],
      ),
    );
  }

  Widget _buildScopeChips(bool isDark, Set<String> selected, void Function(String) toggle) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _scopes.map((s) {
        final on = selected.contains(s.db);
        return FilterChip(
          selected: on,
          label: Text(s.label),
          avatar: Icon(s.icon, size: 18),
          onSelected: (_) => toggle(s.db),
        );
      }).toList(),
    );
  }

  Widget _buildSharePane(bool isDark) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('选择要共享的数据：', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        _buildScopeChips(isDark, _shareSelected, (db) {
          setState(() {
            if (_shareSelected.contains(db)) {
              _shareSelected.remove(db);
            } else {
              _shareSelected.add(db);
            }
          });
        }),
        const SizedBox(height: 20),
        if (!_sharing) ...[
          FilledButton.icon(
            onPressed: _startSharing,
            icon: const Icon(Icons.wifi_tethering),
            label: const Text('开启共享'),
          ),
          const SizedBox(height: 12),
          const Text(
            '开启后本机将作为发送端，在局域网内广播自身。其他设备用「连接同步」'
            '可自动发现本机，或手动输入下方 IP 连接。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ] else ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? Colors.white10 : Colors.black12,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.green, size: 18),
                    const SizedBox(width: 6),
                    const Text('正在共享，等待其他设备连接…',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 8),
                Text('本机名称：$_deviceName'),
                Text('本机 IP：${_localIp.isEmpty ? '获取中…' : _localIp}'),
                Text('端口：9527'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _stopSharing,
            icon: const Icon(Icons.stop),
            label: const Text('停止共享'),
          ),
        ],
      ],
    );
  }

  Widget _buildPullPane(bool isDark) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('局域网内发现的设备（点击自动填入 IP 和端口）：',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            IconButton(
              icon: _refreshing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              tooltip: '刷新设备列表',
              onPressed: _refreshing ? null : _refreshDevices,
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_devices.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('暂无发现。请确保对方已「开启共享」且处于同一 Wi-Fi。',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          )
        else
          ..._devices.map((d) {
            // 点击发现的设备：自动把它的 IP 和端口填入下方输入框，
            // 并高亮当前选中的那台（同步时仍以输入框内容为准）。
            final isSel = _selectedDevice == d;
            return ListTile(
              selected: isSel,
              selectedTileColor:
                  isDark ? Colors.white12 : Colors.black12,
              leading: const Icon(Icons.phone_android_outlined),
              title: Text(d.name),
              subtitle: Text('${d.ip} : ${d.httpPort}'),
              trailing: isSel
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () => setState(() {
                _selectedDevice = d;
                _ipController.text = d.ip;
                _portController.text = '${d.httpPort}';
              }),
            );
          }),
        const SizedBox(height: 18),
        const Text('或直接输入对方 IP 和端口：', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _ipController,
                decoration: const InputDecoration(
                  labelText: 'IP 地址',
                  hintText: '例如 192.168.1.20',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() => _selectedDevice = null),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 1,
              child: TextField(
                controller: _portController,
                decoration: const InputDecoration(
                  labelText: '端口',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        const Text('选择要同步的数据：', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        _buildScopeChips(isDark, _pullSelected, (db) {
          setState(() {
            if (_pullSelected.contains(db)) {
              _pullSelected.remove(db);
            } else {
              _pullSelected.add(db);
            }
          });
        }),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _syncing ? null : _doSync,
          icon: _syncing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sync),
          label: Text(_syncing ? '同步中…' : '开始同步'),
        ),
        if (_syncResult.isNotEmpty) ...[
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? Colors.white10 : Colors.black12,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(_syncResult, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ],
    );
  }
}

class _SyncScope {
  final String db;
  final String label;
  final IconData icon;
  const _SyncScope(this.db, this.label, this.icon);
}
