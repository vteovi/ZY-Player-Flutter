# 项目长期记忆：ZY Player Flutter

uni-app 版 ZY-Player-APP 的 Flutter 重写（首页/详情/播放/收藏/历史/源管理/设置），引擎只认 maccms json/xml 采集站。provider + ChangeNotifier（全局 `AppState`）；shared_preferences 存储（键 `ZY-{db}-DB` / `{db}-{key}`）；包名 `com.zy.player`、minSdk 24、targetSdk 35。日期细节见同目录日誌。

## ⚠️ 协作纪律（用户明确要求，勿破）
1. **构建（APK / Windows 包）一律由用户跑**（2026-10-06 原话：「你不进行构建…你只负责写代码」）。交付 = 改动清单 + 静态自检结论 + 给用户执行的命令。
2. **只 `git commit` 本地，绝不 `git push`**（2026-10-01）。改完 `git add` + `commit`，确认 `git status --porcelain` 为空再汇报；推送命令只附给用户。
3. **绝不主动重试网络操作**。2026-10-30 实测本机直连 `github.com:443` 不通（DNS 正常、TCP 21s 超时），沙箱代理只放行 `api.github.com`/`codeload.github.com`，无 SSH key、无本地代理端口。push 跑一次失败就把命令交用户。
4. 跑 git 前先 `export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"`。
5. 改完必须静态校验 + bump 版本号（SemVer：feat→MINOR / fix→PATCH，versionCode +1）。不编译发现不了错误，改引用后务必人肉复查仍被使用的符号（曾误删仍在用的 import）。
6. 每次发版同步维护根目录 `更新记录.MD`：按版本**倒序**，每条「日期 + 新增/优化/修复/调整 + 一句人话」，不写实现细节与 chore/docs 提交；头部「当前版本」一起改。

## 构建
- Flutter 3.32.6 在 `C:\flutter`；`tools/build_apk.bat` 一键（日志 `build_log.txt`）；`tools/build_apk_all_abi.bat` 一次出三 ABI。**版本号只需同步两处**：`pubspec.yaml` + `android/local.properties`（被 gitignore，不入库）；设置页副标题 1.18.0 起走原生 `PackageManager`，不再手写。
- 环境：`ANDROID_HOME=C:\Android\Sdk`、`JAVA_HOME=C:\Java\jdk-17` 须持久化；NDK 固定 `27.0.12077973`；gradle.properties 关 kotlin 增量 + in-process；release 关 lint/jetifier。
- **ABI**：不加 `--split-per-abi` 时 `--target-platform` 被忽略 → fat 包 ~68MB（`app-release.apk`）；纯 arm64 ~18MB 必须 `--split-per-abi`（`app-arm64-release.apk`）。首次出包 ~26 分钟，日志阶段性不刷属正常。
- **GitHub Actions**（`.github/workflows/build-apk.yml`）：手动 `variant`=split/fat/both，或 push `v*` tag 自动构建并发 Release；产物收集在 `tools/ci-collect-apk.sh`（两批构建各调一次，放最后会被覆盖）。`runs-on` 已固定 `ubuntu-24.04`（ubuntu-latest 2026-10 起迁 Ubuntu 26）。actions 版本 2026-10 已升：checkout@v7 / setup-java@v6 / cache@v6 / upload-artifact@v7（Node20 弃用提示即因此）。
- **正式签名（2026-10-30 起，勿回退）**：release 不再用 debug 签名。密钥库在仓库外 `C:\Users\Administrator\keystores\zy-player-release.jks`（alias `zyplayer`、**口令见本地 `android/key.properties`**、RSA2048、10000 天），证书 `SHA-1 BF:DE:D8:E2:9F:5D:86:62:4F:D0:06:45:79:D1:9A:8F:C6:53:F7:7A`。`build.gradle.kts` 读 `android/key.properties`（gitignore）→ 有则用 release 配置、无则退化 debug；CI 由 Secret `KEYSTORE_BASE64` + `KEYSTORE_PASSWORD` 现场生成该文件。**keystore 绝不能入库**（仓库 public）。`./gradlew :app:signingReport --offline` 可验证各 variant 用哪把钥匙。⚠️ 换签名后老用户必须卸载重装一次。
- Windows 构建插件需 `SeCreateSymbolicLinkPrivilege`（bat 已自动提权，需确认 UAC）。历史阻塞（一般不复发）：gradle 发行包被掐（腾讯镜像解压进 wrapper dists）、fvp 需 compileSdk 36、失败构建残留孤儿进程须 taskkill、必须非沙盒跑。

## 应用内版本更新（1.18.0 起，勿回退）
- 真流程：拉远端 `update.json` → 用**已安装包**的 versionCode（原生 `PackageManager`）比较 → 弹窗含更新说明 → 应用内下载（进度可取消）→ `FileProvider` 交系统安装器。
- 分层：`lib/utils/version.dart` 纯逻辑（**不依赖 Flutter**，可用 `dart run` 验证，因本机 `flutter test` 起不了 flutter_tester）；`lib/services/update_service.dart` 只做网络。
- 只用 versionCode 比较，退化时按版本名逐段数字比（**不能比字符串**：`"1.10" < "1.9"`）。清单字段做了兼容（versionName/version、apkUrl/apk_url/url、notes/changelog、force/mandatory）。默认地址 raw.githubusercontent.com 占位，`AppConfig.updateUrl` 可覆盖（哨兵 `__use_default__` 恢复默认）；仓库若 private 整条链路不通。
- 安装要件：`REQUEST_INSTALL_PACKAGES` + 显式 `androidx.core:core` + manifest `<provider ${applicationId}.fileprovider>` + `res/xml/file_paths.xml`（放行 cache 根）。**必须 `content://`**（Android 7+ `file://` 抛 FileUriExposedException）。返回 ok/no_file/no_permission/error；error 多为签名不一致需先卸载。
- 对话框必须 `PopScope(canPop:false)`（返回键会 pop 掉 DialogRoute，之后代码再 pop 会多关一层）；取消下载只置标记，**统一由调用方 pop**。
- **发版顺序**：改 pubspec 版本 → 打 `v*` tag 出包发 Release（CI 另产固定名 `ZY-Player-arm64-latest.apk` 供 update.json 引用）→ **Release 存在后**再改 update.json 并 push，反了用户拿 404。
- CI 配置不进 APK，**不升版本号**。

## 视频源
- `Site.api` 须真实 URL；`SourceImport._mapType` 0=xml / 1=json；type 3/4/7/15（SpiderJS/drpy）先从 ext.url（对象或 JSON 串）提取真实 maccms 端点再导入，无端点才跳过。内置默认源 `assets/data/init_site.json`（22 个），仅源库为空时种子化。导入按 `Site.key` upsert，不清空已有源。
- 配置导入增强：`HttpService.importSites` 返 `ImportSummary`；支持地址规范化（`lib/utils/config_url.dart`）、JSONP、多仓 `{"urls":[...]}`（≤5）、导航网页自动找 tvbox 链接（≤6、总 25s）、直接粘贴 maccms 接口、按 api/key 去重。
- **TVBox 加密配置（勿回退）**：`box.iqinu.com` 这类站只在 `okhttp/*` UA 下给真配置（浏览器 UA 得占位 HTML），正文是 `$#key#$` + AES-128-CBC 密文 + 13 字节 IV。`_fetchConfig` 按 okhttp/3.15 → okhttp/3.12.0 → 浏览器试；`lib/utils/tvbox_crypto.dart` 纯 Dart 解密（**不引 pointycastle**；GF 求逆必须幂运算 `x^254`）。spider 兜底要严：`.js/.json/.txt` 结尾、逗号多域名一律不导入。
- 接口地址一律 `HttpService._apiUrl()`，别拼字符串；type 不可信，按响应首字符判 JSON/XML；先 GET，仅 4xx 回退 POST；`Site.id` 只是装饰，身份用 `key`。很多源站/CDN 按 UA 拦 ExoPlayer → play_page `_kPlayerHeaders` 用浏览器 UA。

## UI 约定（勿回退）
- **加载态一律骨架屏**，禁灰黑遮罩（`LoadingMask` 已删）；有内容刷新不抹内容，顶部 2px `LinearProgressIndicator`；换源不立刻重置 `_classes`。
- **深色 = 纯黑 OLED**：`darkBg#000000` / `darkSurface#0D0D0D`，层级用 1px 描边 `0x24FFFFFF` 不提亮底色；`main.dart` 必须把 `colorScheme.surface` 系列压纯黑（M3 Dialog/BottomSheet 默认取 surface）。
- 首页片单缓存 `list_cache.dart`（按 siteKey/tid/pg）先读缓存秒出再静默刷新，失败保留缓存；封面预取 `image_prefetch.dart`（并发 6、URL 去重），网格 `memCacheWidth:480`、详情大图 600。
- 收藏/历史双分栏（`star_page` TabBar + `RecordCard`）。key = `{siteKey}-{videoId}`，siteKey 是 UUID 含连字符，**绝不用 `split('-')[0]`**，用 `AppState.resolveRecordKey()`。
- 源检测：`HttpService.checkSite`（`?ac=list` 超时 8s）→ ok/warn/fail；检测中途只更新 chip，结尾统一启停+重排；结果只放内存。
- **大屏（≥600 宽，`MainPage._wideThreshold`）**：首页搜索框并入 AppBar 第一排 [站点切换 ≤260 | 搜索 | 共 N 资源]，toolbarHeight 60；NavigationRail `trailing` 放大屏快捷入口（视频源管理 / 设备同步，不参与 selectedIndex）。播放页分栏条件 宽≥840 且 宽>高，右栏 min(屏宽 30%, 420) 且 ≥300。
- **播放页**：进度条独占一行 + 等宽按钮行；比例/大小是两个独立维度（`_stageAreaSize` + 双层 FittedBox）；手势左亮右音量、双击暂停；进度条自绘 `_ProgressSlider`；返回键 `PopScope` 先退全屏再退页；控制层 4s 隐藏。全屏标题栏（返回+片名集数+倍速标记）；倍速 0.5~3.0 八档；**收藏按钮只在 `!_fullscreen || _landscapeNow` 显示**（竖屏全屏隐藏）。

## 其他坑（勿回退）
- Flutter 命中测试：触点在父节点外整棵子树不命中 —— 要露在外面先给父节点留空间。
- 「内容不满一屏 → 触发不了翻页」死局：不能只把加载更多挂在滚动监听；`CategoryTabState._maybeContinueLoad()` 每帧检查 `maxScrollExtent<=0` 或贴底就主动续拉，配 `didChangeMetrics` + `_noGrowStreak` 兜底。
- 详情请求 `fetchDetail` 只对**瞬时错误**重试 2 次（300/600ms 退避），永久错误不重试；详情页 `EmptyHint` 显示具体原因 + 重试按钮。
- 原生通道 `com.zy.player/system`（+ `/pip`、`/window`）：Dart `system_control.dart` 与 Kotlin `MainActivity.kt` 两端同步改。
- 数据备份 `data_backup.dart`：备份 `saveFile`（bytes 必填），恢复 `pickFiles`。青少年模式已整体移除，别写回。

## Windows 原生窗口（勿回退）
- **C++ 只能写英文注释**（MSVC 按 GBK 读 UTF-8 中文 → C4819 → C2220 构建失败），改完非 ASCII 必须为 0。
- **一切窗口形状变更必须由 Dart 发起**：原生 `WM_CLOSE` 只回传 `onPipExitRequested`/`onFullscreenExitRequested`，不自己销毁窗口。
- **改窗口前后必须「摘视频纹理」**：fvp 用 D3D11 共享纹理，出帧时改尺寸会与纹理回调互等 → UI 线程死锁。`_withVideoDetached()`：置标记换黑盒 → 等两帧 + 60ms → 调原生 → 250ms → 挂回。
- 改窗口用单次 `SetWindowPos(... SWP_FRAMECHANGED|SWP_NOOWNERZORDER)`；诊断日志 `zy_player_debug.log`。三模式：填满 / 原生全屏 / 画中画（`WS_POPUP`，引擎前拦 `WM_NCCALCSIZE`，别用 `WS_CAPTION`）。
- 无边框拖动/缩放走 `WM_NCLBUTTONDOWN`（**lParam 传真实屏幕坐标**，传 0 会跳）；缩放热区须 `opaque` 吃指针；最小 200x120。小窗交互元素只在桌面端渲染。

## 工具环境坑（实锤）
- Bash 里反斜杠 `\` 会被转成 `/`（heredoc 也不免）：含反斜杠的脚本用 Write 写成文件再 `python file.py`，路径尽量正斜杠。
- Git Bash 会把 `/S`、`/MIR` 当路径：加 `MSYS_NO_PATHCONV=1`（robocopy 0–7 都算成功）。
- **Write 工具新建 `.bat`/`.ps1` 会存成 UTF-16**，cmd 读不了：用 Python `encoding='gbk', newline=''` 写，或复制已有 bat 再 `sed -b` 改。
- 静态检查：`C:/flutter/bin/cache/dart-sdk/bin/dart.exe analyze lib`（`--no-lints` 不是合法参数）。单次工具调用约 3.5 分钟上限，长构建交用户。
