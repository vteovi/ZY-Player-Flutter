# 项目长期记忆：ZY Player Flutter

## 定位 / 技术选型
uni-app 版 ZY-Player-APP 的 Flutter 重写，页面与数据结构一一对应（首页/详情/播放/
收藏/历史/源管理/设置），支持 maccms 的 json 与 xml 两类采集站。
- 状态：provider + ChangeNotifier（全局 `AppState`）
- 存储：shared_preferences，键名沿用原版 `ZY-{db}-DB`（key 列表）/ `{db}-{key}`（单条）
- 网络：http；XML：xml 包；播放：video_player（Android = fork 的 ExoPlayer，原生 HLS）
- 封面缓存：cached_network_image（Windows 下需 sqflite_common_ffi）
- 包名 `com.zy.player` / minSdk 24 / targetSdk 35 / v2 签名（Android Debug 证书，可直装）

## ⚠️ 最硬的两条纪律
**1. 编译 APK 一律由用户双击 `tools/build_apk.bat`，助手不编译。**
助手侧工具链被 WorkBuddy 沙箱注入（`tsbx.dll`），任何派生子进程都失败
（`CreateFile failed 231`，连 `flutter analyze` 调 git 都炸）。
证据：只有 `PIPE_ACCESS_OUTBOUND`/`DUPLEX` 命名管道**读侧**打开必返 231；
`dangerouslyDisableSandbox: true` 照样注入 → **工具侧无法绕过**。
已排除方向：Defender、第三方文件系统筛选器、AppInit_DLLs、VBS、360（早期误判）。
→ 助手只改代码 + 单进程静态检查（技能 `dart-single-process-analyze`），
构建后读 `tools/build_log.txt` 确认。另有兜底脚本（需管理员）
`tools/disable_security_kernel.bat` / `restore_security_kernel.bat`。

**2. 助手只 `git commit` 到本地，绝不 `git push`**（用户 2026-10-01 明确要求）。
收尾时**主动**落快照，确认 `git status --porcelain` 为 0 项再汇报；推送由用户自己做
（本机到 GitHub 经常连接重置，助手重试纯属卡死）。
远端 `origin → https://github.com/vteovi/ZY-Player-Flutter.git`（main），
仓库内**零 apk**（filter-repo 清过历史 + `.gitignore` 有 `*.apk`）。
⚠️ 跑 git 前先 `export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"`，否则撞配置锁。

## 构建
| 命令 | Gradle | 产物 |
|---|---|---|
| `flutter build apk --release --target-platform android-arm64` | **342s（最快）** | 18.1MB |
| `flutter build apk --debug`（全 ABI） | 991s | 192MB |

统一双击 `tools/build_apk.bat`：探测 → 构建 → 拷到根目录 → 打印 SHA1，
日志 `tools/build_log.txt`。**APK 名字从 pubspec 派生**，不要写死：
`findstr /b /c:"version:"`（`/b` 只匹配行首，避开 pubspec 里的 versionName 注释行）。

⚠️ **改版本号必须同步三处**（versionCode 严格递增，否则拒绝覆盖安装）：
1. `pubspec.yaml` → `version: 1.5.5+119`（改这里就行，bat 自动跟随）
2. `lib/pages/me_page.dart` 的「版本更新」副标题
3. `android/local.properties` 的 `flutter.versionName/versionCode`（git 不跟踪，保持同步）

**构建阻塞点（勿回退）**：`android/app/build.gradle.kts` NDK 固定 `27.0.12077973`
（模板默认目录是空壳）；`android/gradle.properties` 开 `kotlin.incremental=false` +
`in-process`（pub 缓存在 C:、工程在 D:，Kotlin 增量缓存 `File.relativeTo` 跨盘符必炸）；
release 关 lint / 关 jetifier / 单 ABI。⚠️ D 盘常年只剩 ~8G，构建前先 `flutter clean`。

## Windows 桌面版
- `windows/` 由 `tools/gen_windows_scaffold.py` 离线渲染；⚠️ 别重跑 `gen_scaffold.py`（会覆盖 android/）
- 播放走 **fvp 0.38.1**，仅 `Platform.isWindows` 时 registerWith（内置 FFmpeg 支持 HLS，
  实现 video_player 平台接口 → 播放页零改动）。`video_player_win` 不支持 HLS，已否。
- 封面缓存：`databaseFactory = databaseFactoryFfi`（sqflite 无 Windows 原生实现）
- 构建：双击 `tools/build_windows.bat` → Release + 便携 zip
- ⚠️ **Bash 工具传输层会把命令里的 `\` 转成 `/`（heredoc 也不例外）**：
  含反斜杠字面量的脚本必须用 Write 写成文件再跑，不能内联
- 离线校验工具：`.workbuddy/tools/compile_plugin_java.sh`（纯 javac，20 秒；
  改 `third_party/` 里任何 Java 后先跑它，别让用户在 15 分钟的 Gradle 里才发现错）

## 视频源导入 / 接口地址（勿回退）
**解析**统一在 `source_import.dart` 的 `SourceImport.parse()`，本地文件导入与网址导入共用。
必须认：zyfun 新版 `{"tbl_site":[...]}`（**只取 tbl_site**，同批还有 tbl_iptv/
tbl_analyze/tbl_drive/tbl_star）、zyfun「源管理→导出」顶层**裸数组**、
zyfun 旧版 `{"sites":{"data":[...]}}`、TVBox `{"sites":[...]}`。
兜底扫描顶层数组时**要求元素含 `api`** —— IPTV/解析源用 `url`，据此避开误选。

⚠️ **接口地址一律用 `HttpService._apiUrl(site, params)`，别退回字符串拼接。**
zyfun 的 `api` 常自带查询串（`.../?ac=list`），拼成 `?ac=list?ac=videolist&pg=1` 后
maccms 只认第一个 `ac=list`，返回**精简列表**（无 `vod_pic`、无 `vod_play_url`）——
症状是「首页能列出片名但封面全空、点进详情没简介和播放地址」，**不报错**，极易误判。
改动后要同步 `.workbuddy/tools/url_merge_test.dart` 里的副本。

- 源清单的 `type` 字段**不可信**（有标 xml 实际返 JSON 的），
  解析一律按**响应首字符**判定：`{`/`[` → JSON，`<` → XML（`http_service.dart` `_parse`）。
- 请求**先 GET，仅 4xx 才回退 POST**（有站只放行 GET）；网络层失败不重试
  （换方法一样失败，白等两个超时）。
- 响应无 `charset` 时按 UTF-8 解（http 包默认 latin1 会乱码）；GBK 仍不支持。
- `Site.id` 是装饰字段，身份用 `key`（`zy_database.dart` 全按 `item['key']` 索引）。
- **不编译也能端到端测**：`source_import.dart` 只依赖 dart:convert + `models/site.dart`，
  纯 dart 脚本可直接 import → `.workbuddy/tools/import_test.dart`（24 项断言）。

## 源可用性检测（2026-10-01 新增）
- `HttpService.checkSite(site)` → `SiteCheckResult(health, message, ms)`，
  `enum SiteHealth { ok, warn, fail }`。请求 `?ac=list`，**与 App 取数逻辑完全一致**
  （不是另写一套猜）。ok = 解析出分类/片单；warn = 接口通但没片单；
  fail = 连接层失败或返回非采集接口。
- 检测超时 **8s**（正常请求 15s）；`_fetch` / `_load` 有可选 `timeout` 参数。
- `_describeRawError` 的分类规则**是实测校准的，别凭感觉改**：
  Windows 连接被拒是 `errno = 1225`/`10061`（Linux 是 111），且文案是中文
  「远程计算机拒绝网络连接」；`HandshakeException` 要分出 `CERTIFICATE_VERIFY_FAILED`
  （证书过期/无效）与纯握手失败；正文 `<!DOCTYPE html>` → 「返回的是网页，接口已变更」
  （采集站最常见的死法）。
- 入口在 `site_page.dart`：单条重测 + 「检测全部」（**并发 4**）+ 汇总 chip
  + 工具栏第二/三行三个清理按钮（未检测时禁用，批量检测中全禁用）：
  **「一键停用失效源」**（`_failedActive` = 启用中且检测不可用 →
  `AppState.setSitesActive` 批量 upsert 置停用，条目留着）
  / **「清除死站」**（`_deadSites` = 检测 `fail` 的源，不论启用与否 →
  `AppState.removeSites` 真删除，弹二次确认，删完把对应 `_results` 一起清掉）
  / **「清空所有源」**（整行按钮，全部源一起删，二次确认提示收藏/历史会失效）。
  ⚠️ 检测结果写回前必须确认源还在列表里（`siteOf(key) != null`）——
  源可能在检测期间被清掉，否则汇总会挂着已删源的数字。
  ⚠️ 检测结果**只放内存不落库** —— 可用性有时效，存下来反而误导。
- **青少年模式已整体移除**（2026-10-03）：UI 开关、`AppConfig.r18`、
  `AppConstants.r18KeyWords`、film/search 的 `_matchesR18` 全删，别再写回来。
- 工具：`.workbuddy/tools/check_site_test.dart`（真实 35 源端到端，14.2s 跑完）、
  `raw_error_probe.dart`（打印真实异常串，用来校准分类）。

## 加载态 UI：一律骨架屏，禁灰黑遮罩（勿回退）
用户反馈「切分栏/换网站总是变灰，体验非常不好」。
- **`LoadingMask`（0x33000000 半透明黑罩 + 居中转圈）已从项目删除**，别再写回来 ——
  它盖住的是**空网格**（首次进分栏/换源时底下本来没内容），纯属把区域压暗。
- 列表类加载用 **`VideoGridSkeleton`**（`widgets/video_grid.dart`），
  靠顶层函数 **`videoGridDelegate(context)`** 与真实网格共用列数/比例 ——
  ⚠️ 改列数/比例只改这一处，否则骨架会错形跳版。
- 有内容再刷新时**不要抹掉内容**：内容保持不动 + 顶部 2px `LinearProgressIndicator`。
- 换源时**不要立刻把 `_classes` 重置成 `[最新]`**（分类栏会 N→1→N 闪跳）；
  `_initTabs(length, force: true)` 负责长度相同也重建、并把分栏归零。

## 深色 = 纯黑（OLED，勿回退）
配色集中在 **`lib/utils/app_colors.dart`**。
⚠️ **要区分层级时不要"提亮底色"，改用 1px 描边**（`darkOutline = 0x24FFFFFF`）——
一提亮整屏就"发灰"，正是要避免的。
- `darkBg #000000`：页面 / 卡片 / AppBar / 底部导航 —— 真纯黑，OLED 不发光
- `darkSurface #0D0D0D`：只给必须和纯黑底分开的小元素（输入框、圆形按钮、弹层）
- `darkSkeletonLow/High #141416/#232327`（骨架屏必须看得见）
- `main.dart` 除各 theme 外，**必须把 `colorScheme` 的 surface 系列也压到纯黑** ——
  M3 的 Dialog/BottomSheet/Menu/Chip 默认取 `surface`，不覆盖会从纯黑页面上冒灰面板。
- 卡片色优先**删掉 `color:` 交给 `cardTheme`**，别再各处写死 `0xFF1E1E1E` 那类值。
- 浅色模式不变。历史/收藏页原先写死的颜色已改为跟主题走。

## 播放页能力（勿回退）
- 进度条**独占一行**，下面一行等宽按钮：播放/暂停、画面比例、画面大小、收藏、选集、
  切横/竖屏（仅全屏）、全屏/退出全屏
- `utils/player_options.dart` 定义比例（自适应/16:9/4:3/1:1/3:4/9:16/21:9）与
  大小（适配屏幕/填充/拉伸/原始），持久化到 `AppConfig.playerAspect` / `playerScale`
- **「画面比例」与「画面大小」是两个独立维度**：`_stageAreaSize()` 决定**画面区域**尺寸，
  `_buildStageContent()` 是**双层 FittedBox**（内层按 `BoxFit.fill` 把纹理塞进目标比例
  形状盒子 `_displayAspectRatio`，外层按 `_scaleMode.fit` 把形状盒子放进区域）。
  ⚠️ 区域尺寸**不能等于内容形状**，否则 contain/cover/fill 四个 fit 摆出来一模一样
  （曾经的 bug：「适配屏幕/填充/拉伸全部失效」）。
- **「⇄ 交换宽高」是真旋转**：`RotatedBox(quarterTurns: 1)` 包住纹理盒子 +
  `_displayAspectRatio` 取倒数；只改画框是拉伸不是交换。
- **手势（竖屏/全屏共用 `_buildGestureLayer()`）**：左半屏上下滑调亮度、右半屏调音量，
  向上增大，居中 HUD；双击暂停/继续（单击无动作）。手势层 `Positioned.fill` +
  `HitTestBehavior.opaque` → **命中即止，`_buildStageContent` 收不到事件**，
  所以双击必须由手势层自己处理。
- **进度条是自绘 `_ProgressSlider`**（play_page.dart 末尾），别换回官方
  `VideoProgressIndicator`（内部写死 `LinearProgressIndicator` minHeight=4，粗细改不了，
  全屏时手指点不中）。尺寸：全屏 10/48/20，竖屏 6/36/14（barHeight/touchHeight/thumbSize）；
  轨道左右各内缩 `thumbSize/2`，故 `fraction = (dx - thumbSize/2) / trackWidth`。
- **全屏方向跟随画面比例**（`_displayAspectRatio >= 1` → 横屏；9:16 等保持竖屏），
  进全屏 / 全屏中切比例 / 切集都会重算。`_forceLandscape`（null 跟随 / true 强制横 /
  false 强制竖）仅本次全屏会话有效，进出复位。
- **返回键：全屏时先退全屏，再按一次才退播放页**。`PopScope(canPop: !_fullscreen)` +
  `onPopInvokedWithResult` 里调 `_toggleFullscreen()`；`canPop` 每次 build 求值，
  **不需要计数器**。⚠️ 拦截分支里**别自己调 `Navigator.pop()`**（重复出栈会把播放页
  一起弹掉）。用 `PopScope`，别用废弃的 `WillPopScope`。
- **全屏控制层自动隐藏**：`_controlsVisible` + `_hideTimer`（4 秒）；手势层 `onTap`
  （仅全屏传 `allowTapToggle: true`）开关。控制层 = `AnimatedOpacity` +
  **`IgnorePointer`（收起时必须，否则隐形按钮照样吃点击）** + `Listener(onPointerDown:)`
  重新计时；面板展开时不隐藏（回调里重新计时）。右上角网速浮层独立常显，
  **也必须套 `IgnorePointer`**，否则右上角成点击死区。
- **实时网速 / 码率**（`AppConfig.showSpeed`，默认关）：Dart 侧
  `services/video_network_stats.dart` 轮询 `_controller.playerId`，
  仅「全屏 + 开关开」时 1 秒一次；原生侧在 fork 的 `VideoPlayer` 里挂 `AnalyticsListener`
  （`onBandwidthEstimate` 拿速度、`onDownstreamFormatChanged` 拿码率、onLoad* 判活跃）。
  通道是独立 MethodChannel `com.zy.player/video_network_stats`，注册在
  `VideoPlayerPlugin.onAttachedToEngine`；**不要改 Pigeon 生成产物**。
  ⚠️ id getter 随版本变：本项目 video_player **2.10.1** 是 `playerId`
  （2.9.x 叫 `textureId`，别被 pub 缓存里的旧版本误导），且标了 `@visibleForTesting`，
  需 `// ignore: invalid_use_of_visible_for_testing_member`。

## 应用图标（勿回退，2026-10-04 换新）
生成脚本 `.workbuddy/tools/make_icons.py`（探测 `probe_icon.py`；自检预览输出
`.workbuddy/tools/icon_preview/`，已 gitignore）。源图：黑底圆角 + 青色播放 logo +
"ZY Player" 文字（1282×1282，圆角外纯白）。
- 覆盖范围：Android 五密度 legacy `ic_launcher.png` + **自适应图标**
  （`mipmap-anydpi-v26/ic_launcher.xml`、`values/colors.xml` 的
  `ic_launcher_background=#000000`、五密度 `ic_launcher_foreground.png`）；
  Windows `windows/runner/resources/app_icon.ico`（原为 **0 字节空文件**）；
  iOS `AppIcon.appiconset` 15 尺寸；Web favicon + icons 四尺寸。
- ⚠️ **圆角外的白边不能用亮度阈值填黑**：文字 "ZY Player" 是亮青色（亮度≈220），
  会被阈值当背景一起填黑、文字消失。必须从**四角 flood-fill**
  （`ImageDraw.floodfill`，候选背景 lum≥245、thresh=20）+ `MaxFilter(7)` 膨胀，
  只填与边缘连通的外部白。
- ⚠️ **自适应 foreground 内容缩到 0.72**：圆形遮罩直径仅画布 ~66–72%，
  满幅会把文字两端裁掉；legacy 则用满幅完整图（圆角方形遮罩下文字完整）。

## 其他坑（勿回退）
- **⚠️ Flutter 命中测试铁律**：`RenderBox.hitTest()` 首句是
  `if (_size.contains(position))` —— 触点落在**父节点尺寸之外**，整棵子树都不参与命中。
  用 `Positioned(top: -56)` / `Transform.translate` 把子节点摆到父节点外，
  `clipBehavior: Clip.none` 只是「画得出来」，**点不到**；
  要放外面必须先 `Padding`/`SizedBox` 留出真实空间。
  （详情页五角星收藏 + 绿色播放按钮「点了没反应」就是这个原因。）
- **收藏 / 历史 key 解析**：key = `{siteKey}-{videoId}`，但 **siteKey 是 UUID**
  （自带 4 个连字符）。**绝不能用 `split('-')[0]`** —— 原 uni-app 版就这么写，
  在 UUID 下只会切出 `210d9548`，找不到源 → 详情页报「获取详情失败」。
  统一用 `AppState.resolveRecordKey()`：**从右往左**找第一个能在源列表里匹配上的前缀
  （videoId 含连字符也能正确拆）；匹配不上时退回 `RecordItem.splitKey`
  （已改成 `lastIndexOf('-')`）。
- **详情页布局**：`_buildContent` → `_buildInfoSection`（Stack + `_actionLane=76` 预留
  按钮位）→ `_buildInfoCard`；两个悬浮按钮 `right: 116/40`、`top: _actionLane-28/-40`，
  勿改回负偏移。
- **自写原生通道** `MethodChannel('com.zy.player/system')`：Dart 侧
  `services/system_control.dart`，Kotlin 侧 `MainActivity.kt`（亮度走窗口
  `screenBrightness` 不写系统设置；音量走 `STREAM_MUSIC`），**两端必须同步改**。
  未引入任何第三方亮度/音量包。
- **设置页**是底部导航第三项（`me_page.dart`，不再是「我」）；播放相关开关用
  `SwitchListTile`，`MePage` 的 build 顶部要 `context.watch<AppState>()` 才会跟着刷新。
