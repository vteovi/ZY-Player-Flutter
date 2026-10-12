# 项目长期记忆：ZY Player Flutter

## 定位 / 技术选型
uni-app 版 ZY-Player-APP 的 Flutter 重写，页面/数据结构一一对应（首页/详情/播放/收藏/历史/源管理/设置），支持 maccms 的 json 与 xml 采集站。
- 状态：provider + ChangeNotifier（全局 `AppState`）；存储：shared_preferences，键名沿用原版 `ZY-{db}-DB`（key 列表）/ `{db}-{key}`（单条）
- 网络：http；XML：xml 包；播放：video_player（Android = fork 的 ExoPlayer，原生 HLS）
- 封面缓存：cached_network_image（Windows 下需 sqflite_common_ffi）
- 包名 `com.zy.player` / minSdk 24 / targetSdk 35 / v2 签名（Android Debug 证书，可直装）

## ⚠️ 最硬的两条纪律
**1. 编译 APK 由用户双击 `tools/build_apk.bat`，助手不编译。** 助手侧工具链被沙箱注入 `tsbx.dll`，任何派生子进程失败（`CreateFile failed 231`，连 `flutter analyze` 调 git 都炸；`dangerouslyDisableSandbox: true` 照样注入 → 工具侧无法绕过）。→ 助手只改代码 + 单进程静态检查（技能 `dart-single-process-analyze`），构建后读 `tools/build_log.txt` 确认。兜底脚本（需管理员）`tools/disable_security_kernel.bat` / `restore_security_kernel.bat`。

**2. 助手只 `git commit` 本地，绝不 `git push`**（用户 2026-10-01 要求）。收尾**主动**落快照，确认 `git status --porcelain` 为 0 再汇报；推送用户自己做（GitHub 常连接重置，重试=卡死）。远端 `origin → https://github.com/vteovi/ZY-Player-Flutter.git`（main），仓库**零 apk**（filter-repo 清过 + `.gitignore` 有 `*.apk`）。⚠️ 跑 git 前先 `export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"`，否则撞配置锁。

## 构建
| 命令 | Gradle | 产物 |
|---|---|---|
| `flutter build apk --release --target-platform android-arm64` | **342s（最快）** | 18.1MB |
| `flutter build apk --debug`（全 ABI） | 991s | 192MB |

## 视频源（源清单 / 内置默认源）
- **源引擎只支持 maccms 的 json/xml HTTP 接口**（Site.api 必须是真实 URL；`SourceImport._mapType` 把 type 0=xml、1=json 收下，**type 3/4/7/15…（SpiderJS/drpy）直接跳过**）。
- **猫影视 / CatVod 的 config 是 SpiderJS**：`api` 多为本地 `.js` 爬虫、`type:3`，本 APP 跑不了——导入/内置会被全部跳过（0 可用源）。只有把其中真实的 maccms 端点（藏在 `ext.url` 里，形如 `api.php/provide/vod`、`apijson.php`、`api.php/app/`）抽出来当 `api` 才能用。
- **内置默认源**在 `assets/data/init_site.json`（数组，Site 格式），由 `AppState.bootstrap → ZyDatabase.initDb` 在**源库为空时**种子化（首次启动 / 重置软件时生效；已装过、源库非空的老用户不会自动加，需「重置软件」）。`pubspec.yaml` 已声明该 asset。
- 当前内置 22 个猫影视 maccms 源（group=猫影视）：13 个 `provide/vod` 采集源 + 1 个 apijson + 8 个 `api.php/app/`（APP丨*）。live.php / 主页 / 阿里token 占位 / mogai_api.php / `api.php/v1.vod` 等非标准接口未纳入。
- ⚠️ 老用户升级后看不到新内置源是正常的（源库非空不覆盖）。要么清源库重来，要么手动「源管理→导入网址」。`config_open.json` 留在仓库根目录（用户丢进来的原始文件，未入仓、运行时不引用）。

统一双击 `tools/build_apk.bat`：探测 → 构建 → 拷到根目录 → 打印 SHA1，日志 `tools/build_log.txt`。**APK 名从 pubspec 派生**，勿写死：`findstr /b /c:"version:"`（`/b` 只匹配行首，避开 versionName 注释行）。
⚠️ **改版本号同步四处**（versionCode 严格递增，否则拒装）：`pubspec.yaml`（`version:`，bat 自动跟随）/ `lib/pages/me_page.dart`「版本更新」副标题 / `android/local.properties`（git 不跟踪）/ `README.md` 版本行。
**构建阻塞点（勿回退）**：`android/app/build.gradle.kts` NDK 固定 `27.0.12077973`（模板默认目录是空壳）；`android/gradle.properties` 开 `kotlin.incremental=false` + `in-process`（pub 缓存 C:、工程 D:，Kotlin 增量缓存 `File.relativeTo` 跨盘符必炸）；release 关 lint / 关 jetifier / 单 ABI。⚠️ D 盘常剩 ~8G，构建前先 `flutter clean`。

## Windows 桌面版
- `windows/` 由 `tools/gen_windows_scaffold.py` 离线渲染；⚠️ 别重跑 `gen_scaffold.py`（会覆盖 android/）
- 播放走 **fvp 0.38.1**，仅 `Platform.isWindows` 时 registerWith（内置 FFmpeg 支持 HLS，实现 video_player 平台接口 → 播放页零改动）。`video_player_win` 不支持 HLS，已否
- 封面缓存：`databaseFactory = databaseFactoryFfi`
- 构建：双击 `tools/build_windows.bat` → Release + 便携 zip
- ⚠️ **Bash 工具传输层会把命令里的 `\` 转成 `/`（heredoc 也不例外）**：含反斜杠字面量的脚本必须 Write 成文件再跑
- 离线校验：`.workbuddy/tools/compile_plugin_java.sh`（纯 javac，20s；改 `third_party/` 的 Java 后先跑它，别等 Gradle）

## 视频源导入 / 接口地址（勿回退）
**解析**统一在 `source_import.dart` 的 `SourceImport.parse()`（本地文件与网址导入共用）。必认：zyfun 新版 `{"tbl_site":[...]}`（**只取 tbl_site**，同批还有 tbl_iptv/tbl_analyze/tbl_drive/tbl_star）、zyfun「源管理→导出」顶层**裸数组**、zyfun 旧版 `{"sites":{"data":[...]}}`、TVBox `{"sites":[...]}`。兜底扫描顶层数组**要求元素含 `api`**（IPTV/解析源用 `url`，据此避开误选）。
⚠️ **接口地址一律用 `HttpService._apiUrl(site, params)`，别退回字符串拼接。** zyfun 的 `api` 常自带查询串（`.../?ac=list`），拼成 `?ac=list?ac=videolist&pg=1` 后 maccms 只认第一个 `ac=list`，返回**精简列表**（无 `vod_pic`/`vod_play_url`）——症状「首页能列片名但封面全空、详情无简介与播放地址」，**不报错**，极易误判。改动后同步 `.workbuddy/tools/url_merge_test.dart` 的副本。
- 源清单 `type` **不可信**（有标 xml 实际返 JSON），一律按**响应首字符**判定：`{`/`[` → JSON，`<` → XML（`http_service.dart` `_parse`）
- 请求**先 GET，仅 4xx 才回退 POST**；网络层失败不重试（换方法一样失败，白等两超时）
- 响应无 `charset` 按 UTF-8 解（http 包默认 latin1 会乱码）；GBK 不支持
- `Site.id` 是装饰字段，身份用 `key`（`zy_database.dart` 全按 `item['key']` 索引）
- **不编译也能端到端测**：`source_import.dart` 只依赖 dart:convert + `models/site.dart` → `.workbuddy/tools/import_test.dart`（24 断言）

## 源可用性检测（2026-10-01）
- `HttpService.checkSite(site)` → `SiteCheckResult(health, message, ms)`，`enum SiteHealth { ok, warn, fail }`。请求 `?ac=list`，**与 App 取数逻辑完全一致**。ok=解析出分类/片单；warn=接口通但无片单；fail=连接层失败或返回非采集接口。检测超时 **8s**（正常 15s）；`_fetch`/`_load` 有可选 `timeout`
- `_describeRawError` 分类**实测校准，别凭感觉改**：Windows 连接被拒 `errno=1225`/`10061`（Linux 111），文案中文「远程计算机拒绝网络连接」；`HandshakeException` 分出 `CERTIFICATE_VERIFY_FAILED`（证书过期/无效）与纯握手失败；正文 `<!DOCTYPE html>` →「返回的是网页，接口已变更」（采集站最常见死法）
- 入口 `site_page.dart`：单条重测 +「检测全部」（**并发 4**）+ 汇总 chip + 工具栏三个清理按钮（未检测禁用，批量中全禁用）。⚠️ **「一键停用失效源」按钮已删除**，其逻辑并入「检测全部」：**检测中途**只要某源检测为不可用（warn/fail）且当前启用，**立即 `setSitesActive([site], false)` 停用**（实时反馈，开关马上掉，不再等结束统一处理）；**检测全部完成后**再「可用（ok）且停用的源自动启用」+ **按健康度重排**（`AppState.reorderSites`：可用排前、不可用排后、未检测放最后）。⚠️ 4 个 worker 并发写库，用页面内 `_serializeDb` 串行写链避免 shared_preferences 整文件读改写互相覆盖。工具栏仍有：**「清除死站」**（`_deadSites`=检测 fail，不论启用与否 → `AppState.removeSites` 真删，二次确认，删后清对应 `_results`）/ **「清空所有源」**（整行按钮，全删，二次确认提示收藏/历史失效）。⚠️ 结果写回前确认源还在（`siteOf(key) != null`）；⚠️ 结果**只放内存不落库**（有时效）
- **青少年模式已整体移除**（2026-10-03）：UI 开关、`AppConfig.r18`、`AppConstants.r18KeyWords`、film/search 的 `_matchesR18` 全删，别再写回来
- 工具：`.workbuddy/tools/check_site_test.dart`（真实 35 源，14.2s）、`raw_error_probe.dart`（打印真实异常串校准分类）

## 加载态 UI：一律骨架屏，禁灰黑遮罩（勿回退）
用户反馈「切分栏/换网站总是变灰，体验非常不好」。
- **`LoadingMask`（0x33000000 黑罩+转圈）已删**，别再写回来——它盖的是**空网格**，纯属压暗
- 列表加载用 **`VideoGridSkeleton`**（`widgets/video_grid.dart`），靠顶层 **`videoGridDelegate(context)`** 与真实网格共用列数/比例——⚠️ 改列数/比例只改这一处
- 有内容再刷新**不要抹掉内容**：内容不动 + 顶部 2px `LinearProgressIndicator`
- 换源**不要立刻把 `_classes` 重置成 `[最新]`**（分类栏 N→1→N 闪跳）；`_initTabs(length, force: true)` 长度相同也重建并把分栏归零

## 深色 = 纯黑（OLED，勿回退）
配色集中 **`lib/utils/app_colors.dart`**。⚠️ **区分层级不要"提亮底色"，改用 1px 描边**（`darkOutline = 0x24FFFFFF`）——一提亮整屏"发灰"。
- `darkBg #000000`：页面/卡片/AppBar/底部导航（真纯黑，OLED 不发光）
- `darkSurface #0D0D0D`：只给必须与纯黑分开的小元素（输入框、圆形按钮、弹层）
- `darkSkeletonLow/High #141416/#232327`（骨架屏必须看得见）
- `main.dart` 除各 theme 外，**必须把 `colorScheme` 的 surface 系列也压到纯黑**——M3 Dialog/BottomSheet/Menu/Chip 默认取 `surface`，不覆盖会冒灰面板
- 卡片色优先**删掉 `color:` 交给 `cardTheme`**，别再写死 `0xFF1E1E1E`。浅色模式不变（历史/收藏页写死色已改跟主题）

## 播放页能力（勿回退）
- 进度条**独占一行**，下行为等宽按钮：播放/暂停、画面比例、画面大小、收藏、选集、切横/竖屏（仅全屏）、全屏/退出全屏
- `utils/player_options.dart` 定义比例（自适应/16:9/4:3/1:1/3:4/9:16/21:9）与大小（适配屏幕/填充/拉伸/原始），持久化到 `AppConfig.playerAspect`/`playerScale`
- **「画面比例」与「画面大小」是两个独立维度**：`_stageAreaSize()` 定**画面区域**尺寸，`_buildStageContent()` 是**双层 FittedBox**（内层 `BoxFit.fill` 把纹理塞进目标比例形状盒子 `_displayAspectRatio`，外层按 `_scaleMode.fit` 把形状盒子放进区域）。⚠️ 区域尺寸**不能等于内容形状**，否则 contain/cover/fill 摆出来一模一样（曾是 bug「适配屏幕/填充/拉伸全失效」）
- **「⇄ 交换宽高」是真旋转**：`RotatedBox(quarterTurns: 1)` 包住纹理盒子 + `_displayAspectRatio` 取倒数；只改画框是拉伸不是交换
- **手势（竖屏/全屏共用 `_buildGestureLayer()`）**：左半屏上下滑调亮度、右半屏调音量，向上增大，居中 HUD；双击暂停/继续（单击无动作）。手势层 `Positioned.fill` + `HitTestBehavior.opaque` → **命中即止**，双击必须由手势层自己处理
- **进度条是自绘 `_ProgressSlider`**（play_page.dart 末尾），别换回官方 `VideoProgressIndicator`（内部写死 `minHeight=4`，全屏手指点不中）。尺寸：全屏 10/48/20，竖屏 6/36/14（barHeight/touchHeight/thumbSize）；轨道左右各内缩 `thumbSize/2`，故 `fraction = (dx - thumbSize/2) / trackWidth`
- ⚠️ **进度条轨道色跟主题走**（2026-10-07 修过）：深色（含全屏）用白色半透明、浅色用深色半透明——竖屏深色控制面板是黑底，黑轨道会看不见。已播放段始终用主题蓝 `_accent`
- **全屏方向跟随画面比例**（`_displayAspectRatio >= 1` → 横屏；9:16 保持竖屏），进全屏/切比例/切集都重算。`_forceLandscape`（null 跟随/true 强制横/false 强制竖）仅本次全屏会话有效，进出复位
- **返回键：全屏时先退全屏，再按一次才退播放页**。`PopScope(canPop: !_fullscreen)` + `onPopInvokedWithResult` 调 `_toggleFullscreen()`；`canPop` 每次 build 求值，**不需计数器**。⚠️ 拦截分支**别自己调 `Navigator.pop()`**（重复出栈会把播放页弹掉）。用 `PopScope`，别用废弃 `WillPopScope`
- **全屏控制层自动隐藏**：`_controlsVisible` + `_hideTimer`（4s）；手势层 `onTap`（仅全屏传 `allowTapToggle: true`）开关。控制层 = `AnimatedOpacity` + **`IgnorePointer`（收起时必须，否则隐形按钮吃点击）** + `Listener(onPointerDown:)` 重新计时；面板展开时不隐藏。右上角网速浮层独立常显，**也必须套 `IgnorePointer`**
- **实时网速/码率**（`AppConfig.showSpeed`，默认关）：Dart 侧 `services/video_network_stats.dart` 轮询 `_controller.playerId`，仅「全屏 + 开关开」时 1s 一次；原生侧在 fork 的 `VideoPlayer` 挂 `AnalyticsListener`（`onBandwidthEstimate` 取速度、`onDownstreamFormatChanged` 取码率、onLoad* 判活跃）。通道 `MethodChannel('com.zy.player/video_network_stats')`，注册在 `VideoPlayerPlugin.onAttachedToEngine`；**不要改 Pigeon 生成产物**。⚠️ id getter 随版本变：本项目 video_player **2.10.1** 是 `playerId`（2.9.x 叫 `textureId`），标了 `@visibleForTesting`，需 `// ignore: invalid_use_of_visible_for_testing_member`

## 应用图标（勿回退，2026-10-04 定稿：播放三角+声波 logo）
`make_icons.py`（+ `probe_icon.py` / `analyze_source.py`；预览 `icon_preview/` 已 gitignore）。
**源图 `.workbuddy/tools/icon_source.png`**：1214×1215 RGBA，圆角外**透明**（仅 ~1.2%），黑底 ≈`#090907` + 青色播放三角 + 声波弧线，**无文字**（源图已 gitignore）。处理：`alpha_composite(纯黑, 源图)`（圆角外→`#000000`）；adaptive foreground 用**满幅 1.0**（logo 仅占画布 0.53 宽、居中，圆内不裁）。
覆盖：Android 五密度 legacy + adaptive（`mipmap-anydpi-v26/ic_launcher.xml` + `values/colors.xml` `ic_launcher_background=#000000` + 五密度 foreground）、Windows `app_icon.ico`、iOS 15 尺寸、Web。
**设置页顶部品牌区已删**（`me_page.dart` 无 logo 图与 "ZY Player APP" 文字）；⚠️ **`assets/images/logo.png` 不可删**——`main.dart` 启动页 `AppBootstrap` 仍用（width:120）。
坑（换图会复现）：① 源图圆角外是**白**→ 必须四角 flood-fill（不能用亮度阈值，会吃亮青文字）；② 图标**含文字**→ adaptive foreground 缩 **0.72**（圆形遮罩直径仅 ~66–72%）；③ 局部**不透明**贴纯黑画布会露深灰矩形 → 先按 `max(R,G,B)` 抠底。

## 其他坑（勿回退）
- **⚠️ Flutter 命中测试铁律**：`RenderBox.hitTest()` 首句 `if (_size.contains(position))`——触点落在**父节点之外**，整棵子树不参与命中。用 `Positioned(top:-56)`/`Transform.translate` 摆到父节点外，`clipBehavior: Clip.none` 只是「画得出来」**点不到**；要放外面先 `Padding`/`SizedBox` 留空间。（详情页五角星收藏 + 绿色播放按钮「点了没反应」就是这个原因。）
- **收藏/历史 key 解析**：key=`{siteKey}-{videoId}`，但 **siteKey 是 UUID**（自带 4 连字符）。**绝不能用 `split('-')[0]`**——原 uni-app 就这么写，UUID 下只切出 `210d9548`，找不到源→详情页报「获取详情失败」。统一 `AppState.resolveRecordKey()`：**从右往左**找第一个能匹配源列表的前缀（videoId 含连字符也能拆）；匹配不上退回 `RecordItem.splitKey`（`lastIndexOf('-')`）
- **详情页布局**：`_buildContent` → `_buildInfoSection`（Stack + `_actionLane=76` 预留按钮位）→ `_buildInfoCard`；两个悬浮按钮 `right: 116/40`、`top: _actionLane-28/-40`，勿改回负偏移
- **自写原生通道** `MethodChannel('com.zy.player/system')`：Dart 侧 `services/system_control.dart`，Kotlin 侧 `MainActivity.kt`（亮度走窗口 `screenBrightness` 不写系统设置；音量走 `STREAM_MUSIC`），**两端必须同步改**。未引入第三方亮度/音量包
- **设置页**是底部导航第三项（`me_page.dart`，不再是「我」）；播放开关用 `SwitchListTile`，`MePage` 的 build 顶部要 `context.watch<AppState>()` 才会跟着刷新
- **自定义第三方播放器（PC/Windows，2026-10-06）**：设置页「第三方播放器（PC）」区块（`Platform.isWindows` 专属）用文件选择器选 `.exe` 并持久化到 `AppConfig.externalPlayerPath`（`setExternalPlayerPath`）。详情页「使用第三方播放器播放」（`detail_page.dart` `_onExternalPlay`) 调用 `SystemControl.openWithExternalPlayer(url, customPath:)`；`system_control._openExternalWindows` 优先启动用户指定 exe（存在则启动，缺失则回退自动查找；启动失败返回 error）。未设置时走原注册表/固定路径自动查找。版本 1.6.9+130。
- **数据备份/恢复**（`services/data_backup.dart`）：备份用 `FilePicker.platform.saveFile()`（系统「另存为」对话框），**不是** `getDirectoryPath()`（那是选目录）。⚠️ `saveFile` 的 `bytes` **Android/iOS 必填**（不传抛 `ArgumentError`，桌面不传要在 Dart 侧自己写文件；macOS 传 bytes 会抛 `UnsupportedError`）；`_autoDir()` 兜底防 saveFile 不可用。恢复用 `pickFiles()`
