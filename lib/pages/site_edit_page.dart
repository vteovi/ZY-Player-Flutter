import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/site.dart';
import '../providers/app_state.dart';
import '../services/http_service.dart';
import '../services/source_import.dart';
import '../utils/app_colors.dart';
import '../utils/config_url.dart';
import '../utils/toast.dart';

/// 手动添加 / 编辑一个 CMS 采集接口。
///
/// 与「导入配置文件」的分工：那边批量读现成配置、名字由配置决定；
/// 这里由用户自己填**名称和接口地址** —— 也就是「手里已经有一个 maccms
/// 接口，想给它起个好记的名字」的场景。
class SiteEditPage extends StatefulWidget {
  const SiteEditPage({super.key, this.site});

  /// 编辑已有源时传入；为 null 表示新增。
  final Site? site;

  @override
  State<SiteEditPage> createState() => _SiteEditPageState();
}

class _SiteEditPageState extends State<SiteEditPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _apiController;
  late final TextEditingController _nameController;

  late bool _enabled;
  bool _testing = false;
  bool? _testOk;
  String? _testResult;
  bool _saving = false;

  bool get _isEdit => widget.site != null;

  @override
  void initState() {
    super.initState();
    _apiController = TextEditingController(text: widget.site?.api ?? '');
    _nameController = TextEditingController(text: widget.site?.name ?? '');
    _enabled = widget.site?.isActive ?? true;
  }

  @override
  void dispose() {
    _apiController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 校验
  // ---------------------------------------------------------------------------

  /// 校验接口地址。
  ///
  /// 用 [normalizeConfigUrl] 先补协议头 / 转 punycode 再判断：用户常直接粘
  /// `xxx.com/api.php/provide/vod/`（没有 http://），按裸字符串校验会把
  /// 这种完全可用的地址判成非法。
  String? _validateApi(String? value) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) return '请填写采集接口地址';
    final url = normalizeConfigUrl(raw);
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      return '地址不完整，需要形如 https://域名/api.php/provide/vod/';
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return '只支持 http / https 地址';
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 测试 / 保存
  // ---------------------------------------------------------------------------

  Future<void> _test() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    final api = normalizeConfigUrl(_apiController.text);
    setState(() {
      _testing = true;
      _testOk = null;
      _testResult = null;
    });

    // 借一个临时 Site 走常规检测：与源管理页的「检测」是同一套请求与判定，
    // 不会出现「这里说可用、列表里却显示失效」的分歧。
    final probe = Site(
      id: 0,
      key: 'probe',
      name: 'probe',
      api: api,
      type: SourceImport.inferType(api),
    );
    final result = await HttpService.instance.checkSite(probe);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = result.ok;
      _testResult = '${result.message}（${result.ms}ms）';
    });
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();

    final api = normalizeConfigUrl(_apiController.text);
    final host = Uri.tryParse(api)?.host ?? '';
    final typedName = _nameController.text.trim();
    final name = typedName.isNotEmpty ? typedName : host;
    if (name.isEmpty) {
      showToast(context, '认不出域名，先填个名称吧', success: false);
      return;
    }

    final initial = widget.site;
    // 编辑时**沿用原 key**：它是收藏与播放记录的关联标识，改了接口地址
    // 也不该让用户的历史记录断掉。新增时用域名，保证同一站点只有一条。
    final key = initial?.key ?? host;
    if (key.isEmpty) {
      showToast(context, '认不出域名，先填个名称吧', success: false);
      return;
    }

    final state = context.read<AppState>();
    if (!_isEdit) {
      Site? occupied;
      for (final s in state.sites) {
        if (s.key == key) {
          occupied = s;
          break;
        }
      }
      if (occupied != null) {
        final replace = await _confirmReplace(occupied);
        if (replace != true) return;
      }
    }

    final site = Site(
      id: initial?.id ?? 0,
      key: key,
      name: name,
      api: api,
      // 手动添加没有 type 字段可填，按地址猜；编辑时保留原值
      type: initial?.type ?? SourceImport.inferType(api),
      download: initial?.download ?? '',
      group: initial?.group ?? '手动',
      isActive: _enabled,
      status: '可用',
    );

    setState(() => _saving = true);
    final added = await state.saveSite(site);
    if (!mounted) return;
    setState(() => _saving = false);
    showToast(
      context,
      added ? '已添加「$name」' : '已更新「$name」',
      success: true,
    );
    Navigator.of(context).pop(true);
  }

  /// 同一域名下已经有源时的确认 —— 直接覆盖会悄悄改掉那条源的名称与地址。
  Future<bool?> _confirmReplace(Site occupied) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('这个域名已经有源了'),
        content: Text(
          '已有「${occupied.name}」，接口地址：\n${occupied.api}\n\n'
          '继续保存会更新它的名称和地址，收藏与播放记录不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('更新它'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sub = isDark ? AppColors.darkSubText : AppColors.lightSubText;

    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? '编辑接口' : '添加采集接口')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 32),
              children: [
                Text(
                  '苹果 CMS v10 采集接口，一般形如：\n'
                  'https://你的域名/api.php/provide/vod/\n'
                  '路径里带 at/xml 的按 XML 接口处理，其余按 JSON。',
                  style: TextStyle(fontSize: 12.5, height: 1.65, color: sub),
                ),
                const SizedBox(height: 18),
                TextFormField(
                  controller: _apiController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: '接口地址',
                    hintText: 'https://example.com/api.php/provide/vod/',
                    border: OutlineInputBorder(),
                  ),
                  validator: _validateApi,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: '显示名称',
                    hintText: '不填就用域名',
                    helperText: '这个名字只在本机显示，随便起',
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _save(),
                ),
                const SizedBox(height: 6),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用这个源'),
                  subtitle: Text(
                    '关掉后不参与首页站点切换与聚合搜索',
                    style: TextStyle(fontSize: 12, color: sub),
                  ),
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _testing || _saving ? null : _test,
                        icon: _testing
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.wifi_tethering, size: 18),
                        label: Text(_testing ? '正在测试…' : '测试连接'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _saving ? null : _save,
                        icon: _saving
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.check, size: 18),
                        label: Text(_isEdit ? '保存' : '添加'),
                      ),
                    ),
                  ],
                ),
                if (_testResult != null) ...[
                  const SizedBox(height: 14),
                  _testResultCard(_testResult!, _testOk ?? false, isDark),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 测试结果：成功绿框、失败红框。用描边而不是整块填色，
  /// 与设置页 / 源列表的卡片语言保持一致（纯黑底上不提亮底色）。
  Widget _testResultCard(String text, bool ok, bool isDark) {
    final color = ok
        ? (isDark ? AppColors.okDark : AppColors.okLight)
        : (isDark ? AppColors.failDark : AppColors.failLight);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkBg : AppColors.lightSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: isDark ? AppColors.darkSubText : AppColors.lightSubText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
