# 项目长期记忆：ZY Player Flutter

## 定位 / 技术选型
uni-app 版 ZY-Player-APP 的 Flutter 重写（首页/详情/播放/收藏/历史/源管理/设置），支持 maccms json/xml 采集站。
- 状态 provider + ChangeNotifier（全局 `AppState`）；存储 shared_preferences，键 `ZY-{db}-DB`（key 列表）/ `{db}-{key}`（单条）
- 网络 http；XML 用 xml 包；播放 video_player（Android=fork ExoPlayer 原生 HLS）；封面 cached_network_image（Windows 需 sqflite_common_ffi）
- 包名 `com.zy.player` / minSdk 24 / targetSdk 35 / v2 签名

## ⚠️ 协作纪律（用户明确要求，勿破）
1. **构建（APK / Windows 包）一律由用户跑**，助手只改代码 + 静态检查。用户原话（2026-10-06）：「你不进行构建，构建 APK 交给我，你只负责写代码」。交付格式 = 改动清单 + 静态自检结论 + 供用户执行的构建命令。
2. **助手只 `git commit` 本地，绝不 `git push`**（2026-10-01：「每次改完，快照还是要你自己来创建一个快照」）。改完必须 `git add` + `git commit` 落本地快照，确认 `git status --porcelain` 为空再汇报；推送命令只附给用户自己执行。
3. **绝不主动重试网络操作**（GitHub 常连接重置，push / ls-remote 会长时间挂起）。
4. 跑 git 前先 `export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"`。
5. **改完照常：静态校验 + bump 版本号**（四处同步，见下）。不编译发现不了错误，改引用/结构后务必人肉复查符号（历史上误删过仍在用的 import）。

## 构建（Android）
- Flutter SDK 3.32.6 装在 `C:\flutter`；`tools/build_apk.bat` 一键（日志 `build_log.txt`）。**版本号同步四处**：pubspec.yaml / me_page.dart 副标题 / README.md / android/local.properties（后者被 gitignore，不入库）；versionCode 严格递增。
- 环境：`ANDROID_HOME=C:\Android\Sdk`、`JAVA_HOME=C:\Java\jdk-17` 须持久化；NDK 固定 `27.0.12077973`；gradle.properties 关 kotlin 增量 + in-process；release 关 lint/jetifier；`android/local.properties` 有 `sdk.dir` 兜底。
- **ABI**：不带 `--split-per-abi` 时 `--target-platform android-arm64` 被忽略 → 实际 fat 包（~68MB，`app-release.apk`）；要纯 arm64（~18MB）必须加 `--split-per-abi`（输出 `app-arm64-release.apk`，bat 里拷贝源路径同步改）。首次出包 ~26 分钟，日志阶段性不刷属正常，别当卡死。
- **符号链接**：Windows 构建插件需 `SeCreateSymbolicLinkPrivilege`，否则报 `Building with plugins requires symlink support`；`build_apk.bat` 已带自动提权（需确认一次 UAC）。
- 历史阻塞（已解决、一般不复现）：`services.gradle.org` 被掐 → 从 `mirrors.cloud.tencent.com/gradle/gradle-8.12-all.zip` 解压进 `~/.gradle/wrapper/dists/gradle-8.12-all/<hash>/`；`fvp` 需 compileSdk 36（gradle 自动装）；失败构建会残留孤儿进程须 `taskkill` 清掉；构建必须非沙盒跑（`dangerouslyDisableSandbox`）。
- Windows 版：`tools/build_windows.bat`（管理员权限，同样交用户跑）。

## 视频源
- 引擎只认 maccms json/xml（`Site.api` 须真实 URL）。`SourceImport._mapType` 收 0=xml / 1=json，type 3/4/7/15（SpiderJS/drpy）跳过。猫影视 CatVod config 是 SpiderJS 跑不了，只抽其中真实 maccms 端点（藏在 ext.url）。
- 内置默认源 `assets/data/init_site.json`（22 个），源库为空时种子化；老用户源库非空不覆盖，需「重置软件」。
- 导入合并（1.7.5）：`importSites`(URL) / `importSitesFromContent`(本地) 都按 `Site.key` upsert，不清空已有源。
- 接口地址一律 `HttpService._apiUrl(site, params)`，别拼字符串（zyfun api 自带查询串，拼错返精简列表且不报错）。type 不可信，按响应首字符判定 JSON/XML；先 GET，仅 4xx 回退 POST；无 charset 按 UTF-8。`Site.id` 只是装饰，身份用 `key`。
- 很多源站 / CDN 会按 UA 拦 ExoPlayer 的 UA → 「播放失败」（play_page 的 `_kPlayerHeaders` 用浏览器 UA 解决）。

## 源可用性检测（1.7.4）
`HttpService.checkSite` → `SiteCheckResult(health,message,ms)`，`SiteHealth{ok,warn,fail}`，请求 `?ac=list` 超时 8s。`site_page`：单条重测 + 「检测全部」(并发 4) + chip + 「清除死站」(fail→真删) + 「清空所有源」。⚠️ 检测中途只更新 chip，结尾统一启停 + 重排（`reorderSites`：可用前 / 不可用后 / 未检测最后）。结果只放内存不落库。

## 首页片单缓存 + 封面预取（1.7.7 / 1.7.9）
- `lib/services/list_cache.dart` 按 `(siteKey,tid,pg)` 缓存分页片单 + 元信息到 `DbNames.listcache`。`CategoryTab._load` 先读缓存秒出 → 后台 `_refresh` 静默替换；刷新失败保留缓存不空白。`ListCache.clearAll()` 单独清，「重置软件」走 `clearDB()` 已含。
- 封面必须下载过一次才进磁盘缓存（硬限制）。`lib/utils/image_prefetch.dart` 在 `_load` / `_refresh` 后后台抢先拉封面（并发 6、URL 去重）。网格 `memCacheWidth:480`、详情大图 `600` 限制解码尺寸。

## 加载态 UI：一律骨架屏，禁灰黑遮罩
`LoadingMask` 已删。列表用 `VideoGridSkeleton`（共用 `videoGridDelegate`）。有内容刷新不抹内容 + 顶部 2px `LinearProgressIndicator`。换源不立刻重置 `_classes`。

## 深色 = 纯黑（OLED）
配色 `app_colors.dart`。层级用 1px 描边（`darkOutline=0x24FFFFFF`）不提亮底色：`darkBg#000000` / `darkSurface#0D0D0D` / 骨架 `#141416`、`#232327`。`main.dart` 必须把 `colorScheme.surface` 系列压纯黑（M3 Dialog/BottomSheet 默认取 surface）。卡片交 `cardTheme`。

## 播放页（勿回退）
- 进度条独占一行 + 等宽按钮行。比例 / 大小是两个独立维度（`_stageAreaSize` + 双层 FittedBox）；交换宽高 = `RotatedBox` + 倒数 aspect。手势层左亮右音量、双击暂停。进度条自绘 `_ProgressSlider`（已播段用 `_accent`）。返回键 `PopScope` 先退全屏再退页。控制层 `AnimatedOpacity` + `IgnorePointer` + 4s 隐藏。实时网速 `AppConfig.showSpeed` 默认关。

## 图标 / 启动（1.7.4、1.7.10 定稿）
- 图标 `make_icons.py`，源图 `.workbuddy/tools/icon_source.png`（透明圆角外 + 黑底 + 青三角 + 声波，无文字），adaptive foreground 满幅 1.0。`assets/images/logo.png` 保留但已无代码引用。
- **无 Flutter 开屏**：`main.dart` 直接 `home: MainPage()`（`AppBootstrap` 已删）；原生 `LaunchTheme` 纯色跟随系统深浅。`FilmPage.initState` 监听 `AppState`，源列表空→非空时 `reloadIfNeeded()` 自动重载（按源签名比对，收藏/历史加载不触发）。

## 收藏 / 历史页（1.7.12 起双分栏）
`star_page` 用 TabBar 分「收藏 / 历史记录」，都是卡片网格（同首页 `VideoGrid`）。卡片 `lib/widgets/record_card.dart` 的 `RecordCard`（图上文下，复用 `PosterCover`；右上角圆形删除按钮；历史模式封面下有进度条）。收藏点开 `DetailPage`，历史点开 `PlayPage` 续播。`AppState.removeHistory(key)` 删单条历史；设置页「播放记录」跳 `StarPage(initialTab:1)`，独立 `history_page.dart` 已删。

## 其他坑（勿回退）
- Flutter 命中测试：触点在父节点外整棵子树不命中 —— 要放外面先给父节点留空间（详情页按钮「点了没反应」即此因）。
- 收藏/历史 key = `{siteKey}-{videoId}`，siteKey 是 UUID 含连字符，**绝不用 `split('-')[0]`**；用 `AppState.resolveRecordKey()` 从右往左匹配前缀。
- 详情页布局：`_buildContent`→`_buildInfoSection`→`_buildInfoCard`；悬浮按钮 `right:116/40`，勿改负偏移。
- 原生通道 `MethodChannel('com.zy.player/system')`：Dart `system_control.dart` + Kotlin `MainActivity.kt` 两端同步改。
- 设置页是底部导航第三项；开关用 `SwitchListTile`，build 顶部 `context.watch<AppState>()`。
- 自定义外部播放器（PC）：`AppConfig.externalPlayerPath` → `openWithExternalPlayer(url,customPath:)`，未设置走自动查找。
- 数据备份/恢复 `data_backup.dart`：备份用 `saveFile`（bytes，Android/iOS 必填），恢复用 `pickFiles`。
- 青少年模式已整体移除，别写回。

## Windows 桌面端原生窗口（1.9.13 / 1.9.14，勿回退）
- **C++ 只能写英文注释**：`windows/runner/` 的 C++ 是 UTF-8 无 BOM，MSVC 按 GBK(936) 读中文 → C4819 →（工程警告即错误）C2220 构建失败。改完数一遍非 ASCII，必须为 0。
- **一切窗口形状变更必须由 Dart 发起**。原生 `WM_CLOSE`（标题栏 X / Alt+F4）在 PiP / 全屏下不再自己改窗口，只回传 `onPipExitRequested` / `onFullscreenExitRequested`（返回 0、不销毁窗口）请 Dart 退出；否则 Dart 停在「只剩视频、没有控件」，看起来像卡死。
- **改窗口前后必须「摘视频纹理」**：fvp 用 D3D11 共享纹理（`fvp_plugin.cpp` 的 `TexturePlayer`，光栅线程与 mdk 回调持同一 `mtx`），出帧时改窗口尺寸 → 引擎重建渲染面与纹理回调互等 → **UI 线程死锁**（同步、延迟 PostMessage 写法都一样）。Dart `_withVideoDetached()`：`_windowSwitching=true` → `_buildStage` 换同尺寸黑盒 → 等两帧 + 60ms → 调原生 → 再等 250ms（原生 PostMessage 异步落地）→ 挂回纹理。
- 改窗口用**单次** `SetWindowPos(位置+尺寸, SWP_FRAMECHANGED|SWP_NOOWNERZORDER|SWP_NOACTIVATE)`，样式在当前样式上增删位（保留 `WS_VISIBLE`/`WS_CLIPCHILDREN`）。诊断日志 `Win32Window::Trace/TraceReset` → `<exe目录>\zy_player_debug.log`。
- 三模式语义：**填满** = 纯 Flutter（视频铺满应用窗口，`_fullscreen`）；**全屏** = 原生无边框铺满显示器盖住任务栏（`_nativeFullscreen`）；**画中画** = 原生置顶小窗。
- 小窗形态 = 无边框纯视频：`WS_POPUP | WS_THICKFRAME | WS_CLIPCHILDREN | WS_VISIBLE`，并在 `FlutterWindow::MessageHandler` **引擎之前**拦 `WM_NCCALCSIZE(wParam TRUE)` 直接 `return 0`（仅 `IsInPip()` 时）。**别再用 `WS_CAPTION`**：系统按浅色主题画标题栏 → 小窗顶上一条白条。
- 无边框窗口的拖动 / 缩放只能交给系统模态循环：`ReleaseCapture(); SendMessage(hwnd, WM_NCLBUTTONDOWN, HTCAPTION|HT*, MAKELPARAM(cursor.x, cursor.y))`（**lParam 必须传真实光标屏幕坐标**，传 0 窗口会跳）。鼠标消息都发给 Flutter 子视图，顶层 `WM_NCHITTEST` 覆盖收不到。Dart 侧：拖动走画面 `onPanStart`；缩放铺 8 个 `opaque` 热区（`_pipResizeHandle`，须吃掉指针否则与拖动手势抢竞技场）；最小尺寸 200x120（`WM_GETMINMAXINFO`）。缩放必须走 `_withVideoDetached`，只改位置（拖动）不用。
- 通道：`com.zy.player/pip`（enterPip / exitPip / startDrag / resizeStart，回传 onPipModeChanged / onPipExitRequested）、`com.zy.player/window`（enterFullscreen / exitFullscreen，回传 onFullscreenExitRequested）。
- **小窗 UI 分支（2026-10-16）**：`_buildPipBody` 里所有交互元素（8 个缩放热区 + 右上角 × 退出按钮）**只在桌面端渲染**（`isDesktop` = `Theme.of(context).platform` 为 windows/macOS/linux）。Android / iOS 的系统 PiP 窗口自带关闭键，Flutter 侧重叠一个既多余、在 PiP 里又点不动，故不显示。

## WorkBuddy 工具环境坑（实锤）
- **Bash 命令里的反斜杠 `\` 会被传输层转成 `/`**（heredoc 引号包裹也不幸免）。含反斜杠字面量的脚本必须用 Write 工具写成文件再 `python file.py`；路径参数尽量用正斜杠。
- **Git Bash 会把 `/MIR`、`/S` 这类 Windows 开关当路径转换** → 命令前加 `MSYS_NO_PATHCONV=1`（robocopy 返回码 0–7 都算成功，`&&` 链会被 1 码打断）。
- **Write 工具新建 `.bat`/`.ps1` 会存成 UTF-16**（`FE FF` BOM + 每字符跟 `\0`），`cmd.exe` 读不了。改用 `sed -b` 基于已存在的 GBK bat 复制后 `s#...#...#` 改关键行，或 Python `open(..., encoding='gbk', newline='')` 写；验证用 `head -c 16 file | od -c`。
- 静态检查：优先 `C:/flutter/bin/cache/dart-sdk/bin/dart.exe analyze lib`（裸 analyze；`--no-lints` 不是合法参数，info 级 lint 不影响编译）。单次工具调用约 3.5 分钟墙钟上限，长构建（gradle 等）必须交用户跑。
- `android/local.properties` 被 gitignore，`git add` 会被拒；提交时只加仓库内文件。
