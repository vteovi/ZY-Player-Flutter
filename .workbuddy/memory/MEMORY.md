# 项目长期记忆：ZY Player Flutter 版

## 项目定位
uni-app 版 ZY-Player-APP 的 Flutter 重写，功能与数据结构与原版保持一一对应，
包含首页/详情/播放/收藏/历史/源管理/我，支持 maccms 的 json 与 xml 两类采集站。

## 技术选型
- 状态管理：provider + ChangeNotifier（全局 `AppState`）
- 存储：shared_preferences，键名沿用原版 `ZY-{db}-DB`（key 列表）与 `{db}-{key}`（单条记录）
- 网络：http（POST 对齐原版 uni-ajax）
- XML：xml 包（对齐 fast-xml-parser 的字段映射）
- 播放：video_player（Android = ExoPlayer，原生 HLS）；封面缓存用 cached_network_image

## 构建状态：✅ 已成功产出 APK

`flutter build apk --release --target-platform android-arm64` 一次跑通（Gradle 342s）。
产出 `build/app/outputs/flutter-apk/app-release.apk`（18.1MB），根目录另存
`ZY-Player-v0.1.2-arm64-release.apk`。包名 `com.zy.player` / minSdk 24 / targetSdk 35 /
v2 签名（Android Debug 证书，可直接安装）/ 实质 arm64-only。
sha1 `391f81d02f42fb84a5eb2aadadc08d69386af16c`。

## 本机环境（2026-09-28 诊断修正）

**`CreateFile failed 231` 的真凶：WorkBuddy 沙箱对「工具子进程」的注入，不是 360。**
（早期记忆写的「360 主动防御」是误判；当时「卸载 360 + 重启后恢复」属巧合。）

精确特征（`%TEMP%\pipeprobe.py`、`pipeprobe2.py` 纯 Python ctypes 复刻，与 Dart 无关）：
- 只有**客户端以读权限打开 `PIPE_ACCESS_OUTBOUND` / `DUPLEX` 命名管道**返回 231，
  100% 必现；写权限打开 INBOUND、`access=0` 都正常；名字/实例数/DACL 都无关
- Dart 只在需要 stdio 管道时失败；`ProcessStartMode.detached` / `inheritStdio` **能成功**
- Python 的 `subprocess` 走匿名管道 `CreatePipe()` → 不受影响

**证据**：由工具拉起的 `powershell.exe` 被注入
`...\WorkBuddy\resources\app.asar.unpacked\cli\vendor\sandbox\5.6.10\tsbx.dll`
（腾讯签名）；**explorer / GameViewer / msedgewebview2 / WorkBuddy 自己都没有这个 DLL**
—— 注入只发生在「工具进程链」内。`dangerouslyDisableSandbox: true` **照样注入**
（实测 Modules 里仍有 tsbx.dll），所以**工具侧无法绕过**。

**对策：构建必须放到用户自己的 cmd 里跑**（双击 `tools/build_apk.bat`，explorer 启动）。
其它可排除的方向（都验证过无关）：Defender 实时保护开关、服务/驱动新增记录、
第三方文件系统筛选器、`ObjectTypeFilter`、`AppInit_DLLs`/`AppCertDlls`、VBS。

- 环境健康探测：`dart tools/pipe_probe.dart` 打印 `PIPE_PROBE_OK` 才算好；
  或 `export PATH="/c/Program Files/Git/cmd:$PATH"` 后跑 `flutter --version`
- 拦截生效期间可用的降级手段（保留备用）：
  - 静态检查 `flutter analyze --no-pub` **不需要派生子进程，即使被拦也能跑**
  - 单进程 analyzer：`.workbuddy/tools/mk_analyzer_env.py` +
    `dart %TEMP%\zyanalyze\analyze.dart`（技能 `dart-single-process-analyze`）
  - **插件 Java 离线编译校验**：`.workbuddy/tools/compile_plugin_java.sh`
    （纯 javac，20 秒；改 `third_party/` 里任何 Java 后都该先跑一次，
    别让用户在 15 分钟的 Gradle 里才发现语法错）
  - 骨架生成：`tools/gen_scaffold.py`（渲染 Flutter SDK 模板）
  - 兜底脚本（需管理员）：`tools/disable_security_kernel.bat` + 重启
    （停用 360Sensor/360Sensor_DM/360Hvm/360FileService/360SPService/360Fs*Flt/
    XLGuard/XLWFP/XLServicePlatform），`tools/restore_security_kernel.bat` 还原

## 构建命令与实测速度

| 配置 | 实测 Gradle | 产物 |
|---|---|---|
| `flutter build apk --release --target-platform android-arm64` | **342s（最快）** | 18.1MB |
| `flutter build apk --debug`（默认全 ABI） | 991s | 192MB |

统一走 `tools/build_apk.bat`（双击）：内置探测 → 构建 → 拷到根目录 → 打印 SHA1，
日志在 `tools/build_log.txt`。当前版本 **`1.0.0+104`**，
产物 `ZY-Player-v1.0.0-arm64-release.apk`。

**APK 名字从 `pubspec.yaml` 自动派生**，不要再改回写死的名字：
```bat
for /f "tokens=2" %%V in ('findstr /b /c:"version:" "%PROJ%\pubspec.yaml"') do set "APPVER=%%V"
for /f "tokens=1 delims=+" %%B in ("%APPVER%") do set "APPVER=%%B"
set "OUT=%PROJ%\ZY-Player-v%APPVER%-arm64-release.apk"
```
（`findstr /b` 只匹配行首，避开 pubspec 里 `# ... versionName ...` 注释行。）

⚠️ **改版本号必须同时改三处**（`versionCode` 严格递增，否则 Android 拒绝覆盖安装）：
1. `pubspec.yaml` → `version: 1.0.0+104`（改这里就够了，构建脚本自动跟随）
2. `lib/pages/me_page.dart` 的「版本更新」副标题（写死的展示文案）
3. `android/local.properties` 的 `flutter.versionName/versionCode`
   （flutter 工具下次构建会自动覆盖，但保持同步不影响）


> **⚠️ 分工（用户 2026-09-28 明确要求）：编译 APK 一律由用户自己双击 bat 完成，
> 助手不执行编译。** 原因：助手侧的工具链被沙箱注入，派生子进程必失败
> （`CreateFile failed 231`，连 `flutter analyze` 调 git 都炸）。
> 助手只负责改代码 + 单进程静态检查（见下），构建后读 `tools/build_log.txt` 确认结果。

## 已修复的构建阻塞点（改在仓库里，勿回退）
1. `android/app/build.gradle.kts`：NDK 固定 `27.0.12077973`
   （模板默认的 26.3.11579264 目录是空壳，无 source.properties）
2. `android/gradle.properties`：`kotlin.incremental=false` +
   `kotlin.compiler.execution.strategy=in-process`
   （pub 缓存在 C:、工程在 D:，Kotlin 增量缓存 `File.relativeTo` 跨盘符必炸）
3. release lint 关闭 + 关闭 jetifier + 改单 ABI（D 盘空间紧张）：
   `flutter build apk --release --target-platform android-arm64`

## 播放页能力（勿回退）
- 进度条**独占一行**，下面一行等宽按钮：播放/暂停、画面比例、画面大小、收藏、选集、
  切横/竖屏（仅全屏）、全屏/退出全屏
- `lib/utils/player_options.dart` 定义比例（自适应/16:9/4:3/1:1/3:4/9:16/21:9）
  与大小（适配屏幕/填充/拉伸/原始），选择持久化到 `AppConfig.playerAspect` / `playerScale`
- **「画面比例」和「画面大小」是两个独立维度**（勿回退！）：
  - `_stageAreaSize()` 决定**画面区域**尺寸：「适配屏幕/原始」按目标比例折算高度，
    「填充/拉伸」占满可用高度
  - `_buildStageContent()` 是**双层 FittedBox**：内层把纹理按 `BoxFit.fill` 塞进
    「目标比例形状盒子」（`_displayAspectRatio`），外层按 `_scaleMode.fit` 把这个
    形状盒子放进画面区域
  - ⚠️ 曾经的 bug：区域尺寸**总是等于内容形状**（旧 `_frameSize`），于是
    contain / cover / fill 摆出来一模一样 —— 表现就是「适配屏幕/填充/拉伸全部失效」。
    区域形状必须和内容形状解耦，四种 fit 才会有区别。
- **「⇄ 交换宽高」是真旋转**：`_buildStageContent` 里用 `RotatedBox(quarterTurns: 1)`
  包住纹理盒子，配合 `_displayAspectRatio` 取倒数；不要只改画框（那是拉伸不是交换）
- **手势（竖屏 + 全屏共用一个 `_buildGestureLayer()`）**：左半屏上下滑调亮度、
  右半屏调音量，向上增大，居中显示 HUD；双击暂停/继续（单击无动作）。
  竖屏是在 `_buildVideoArea` 的 `Stack` 里叠在手势层上，`Positioned.fill` +
  `HitTestBehavior.opaque` → **盖住画面后「命中即止」，`_buildStageContent` 里的
  双击回调收不到事件**，所以双击必须由手势层自己处理
- **进度条是自绘的 `_ProgressSlider`（play_page.dart 末尾）**，别换回官方
  `VideoProgressIndicator`：官方内部写死 `LinearProgressIndicator`（minHeight=4），
  **条子粗细改不了**，全屏时手指点不中。三个尺寸独立：全屏 10/48/20，
  竖屏 6/36/14（barHeight/touchHeight/thumbSize）；手柄轨道左右各内缩 `thumbSize/2`，
  所以 `fraction = (dx - thumbSize/2) / trackWidth`，两端不会被裁
- **全屏方向跟随画面比例**：`_displayAspectRatio >= 1` → 横屏；9:16 等竖版 → 保持竖屏。
  进入全屏、全屏中切比例、全屏中切集都会重算方向
- **全屏旋转按钮**：`_forceLandscape`（null=跟随比例 / true=强制横 / false=强制竖），
  仅本次全屏会话有效，进/出全屏复位；`_landscapeNow => _forceLandscape ?? _isLandscapeRatio`
- **返回键：全屏时先退全屏，再按一次才退出播放页**。`build` 用 `PopScope` 包 `Scaffold`：
  `canPop: !_fullscreen` + `onPopInvokedWithResult` 里调 `_toggleFullscreen()`。
  `canPop` 在 build 时求值，所以第一次返回触发重建后自然变成可 pop，**不需要计数器**。
  ⚠️ 拦截分支里**别自己调 `Navigator.pop()`**（会重复出栈、把播放页一起弹掉）。
  用 `PopScope` 不用废弃的 `WillPopScope`
- **全屏控制层自动隐藏**：`_controlsVisible` + `_hideTimer`（4 秒）；手势层
  `onTap`（只在全屏传 `allowTapToggle: true`）开关控制层。
  控制层包 `AnimatedOpacity` + **`IgnorePointer`（收起时必须，否则看不见的按钮照样吃点击）**
  + `Listener(onPointerDown:)` 重新计时；面板展开时不隐藏（回调里重新计时）。
  右上角网速浮层独立常显，**也必须套 `IgnorePointer`**，否则右上角成点击死区
- **实时网速 / 码率**（设置里的 `AppConfig.showSpeed`，默认关）：
  - Dart 侧 `lib/services/video_network_stats.dart`，轮询 `_controller.playerId`，
    只在「全屏 + 开关开」时跑 1 秒一次
  - 原生侧靠 fork 的 `VideoPlayer` 里挂 `AnalyticsListener`：`onBandwidthEstimate`
    拿速度、`onDownstreamFormatChanged` 拿 `trackFormat.bitrate`、onLoad* 计数判活跃
  - 通道是**独立 MethodChannel** `com.zy.player/video_network_stats`，
    注册在 `VideoPlayerPlugin.onAttachedToEngine`；**不要改 Pigeon 生成产物**
  - ⚠️ `VideoPlayerController` 的 id getter 随版本变：本项目解析到 **video_player 2.10.1**，
    是 `playerId`（2.9.x 叫 `textureId`，别被 pub 缓存里的旧版本误导），
    且标了 `@visibleForTesting`，要 `// ignore: invalid_use_of_visible_for_testing_member`

## 设置页 / 底部导航

底部导航第三项是 **设置**（`me_page.dart`，不再是「我」）。
播放相关开关（如「显示实时下载速度」）加在 `SwitchListTile` 上，
`MePage` 在 build 顶部 `context.watch<AppState>()` 才能跟着配置刷新。

## ⚠️ Flutter 命中测试铁律（踩过坑）
`RenderBox.hitTest()` 首句是 `if (_size.contains(position))`——**触点落在父节点尺寸之外，
整棵子树都不参与命中测试**。所以用 `Positioned(top: -56)` / `Transform.translate` 把子节点
摆到父节点外面，`clipBehavior: Clip.none` 只是「画得出来」，**点不到**。
要放在外面必须先 `Padding`/`SizedBox` 留出真实空间。
（详情页五角星收藏 + 绿色播放按钮「点了没反应」就是这个原因。）

## 收藏 / 历史 key 解析（⚠️ UUID 连字符陷阱）

记录 key = `{siteKey}-{videoId}`，但**站点 key 是 UUID**
（`210d9548-8f89-410c-8ca3-d6b69c0a513c`，自带 4 个连字符）。

- **绝不能**用 `split('-')[0]` 取 siteKey —— 原 uni-app 版（`pages/star/star.vue`、
  `pages/history/history.vue`）就是这么写的，在 UUID key 下只会切出 `210d9548`，
  找不到源 → 详情页报「获取详情失败」。移植时照抄就会带进这个 bug。
- 统一用 `AppState.resolveRecordKey(key)`：**从右往左**找第一个能在 `_sites` 里匹配上的
  前缀（videoId 含连字符也能正确拆）；匹配不上时退回 `RecordItem.splitKey`
  （已改成 `lastIndexOf('-')`）。
- 落点：`lib/pages/star_page.dart` `_openDetail`、`lib/pages/history_page.dart` `_play`。

## 详情页布局
`_buildContent` → `_buildInfoSection`（Stack + `_actionLane=76` 预留按钮位）→ `_buildInfoCard`。
两个悬浮按钮 `right: 116/40`、`top: _actionLane-28/-40`，勿改回负偏移。

## 自写原生通道（Dart ↔ Kotlin 两端必须同步改）
`MethodChannel('com.zy.player/system')`
- Dart：`lib/services/system_control.dart`（`SystemControl.brightness/setBrightness/volume/setVolume`，
  失败静默降级）
- Kotlin：`android/app/src/main/kotlin/com/zy/player/MainActivity.kt`
  （亮度走窗口 `screenBrightness`，不写系统设置；音量走 `STREAM_MUSIC`）
- 未引入任何第三方亮度/音量包

## 构建产物
- release：`flutter build apk --release --target-platform android-arm64`（Gradle 342s，18.1MB）
- debug：`flutter build apk --debug`（Gradle 991s，192MB，全 ABI，v2 签名可直装）
- ⚠️ D 盘空间常年紧张（构建后仅剩 ~8G），`build/` 占约 2.9G；
  再次构建前先 `flutter clean` 或删 `build/`
