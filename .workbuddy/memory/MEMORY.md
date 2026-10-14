# 项目长期记忆：ZY Player Flutter

## 定位 / 技术选型
uni-app 版 ZY-Player-APP 的 Flutter 重写，页面/数据一一对应（首页/详情/播放/收藏/历史/源管理/设置）。支持 maccms 的 json/xml 采集站。
- 状态：provider + ChangeNotifier（全局 `AppState`）；存储 shared_preferences，键名 `ZY-{db}-DB`（key 列表）/ `{db}-{key}`（单条）
- 网络 http；XML 用 xml 包；播放 video_player（Android=fork ExoPlayer 原生 HLS）；封面 cached_network_image（Windows 需 sqflite_common_ffi）
- 包名 `com.zy.player` / minSdk 24 / targetSdk 35 / v2 签名

## ⚠️ 协作纪律（用户明确要求，勿破）
1. **编译 APK/出构建物由用户做**，助手只改代码 + 单进程静态检查（`dart-single-process-analyze`）。沙箱注入 tsbx.dll 使任何派生子进程失败（CreateFile failed 231），工具侧无法绕过。用户原话（2026-10-06）：「你不进行构建，构建 APK 交给我，你只负责写代码」。
2. **助手只 `git commit` 本地，绝不 `git push`**。用户原话（2026-10-01）：「每次改完，快照还是要你自己来创建一个快照」——即收尾、改完代码/文档后要主动 `git add`+`git commit` 落本地快照，并确认 `git status --porcelain` 为 0（工作区干净）再汇报。
3. **绝不主动重试任何网络操作**。GitHub 在本机网络下常连接重置，`git push` / `git ls-remote` 都会长时间挂起，用户不愿助手卡在那里反复推；推送命令附上供用户自己执行即可。
4. 跑 git 前先 `export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"`。
5. **静态自检要格外仔细**：不编译发现不了错误；历史上 Edit 替换 import 块时误删过仍在使用的 `DetailActivity` import（人肉复查才发现）。改引用/结构后务必复查符号。改完照常：静态校验 + bump 版本号。

## 构建
`flutter build apk --release --target-platform android-arm64` → ~342s / 18.1MB；debug 全 ABI ~991s / 192MB。双击 `tools/build_apk.bat`（探测→构建→拷根目录→SHA1，日志 build_log.txt）。APK 名从 pubspec 派生（`findstr /b /c:"version:"`）。**版本号同步四处**：pubspec.yaml / me_page.dart 副标题 / android/local.properties / README.md；versionCode 严格递增。构建阻塞点：NDK 固定 `27.0.12077973`；gradle.properties 关 kotlin 增量+in-process；release 关 lint/jetifier、单 ABI。D 盘常剩~8G，构建前 `flutter clean`。
- **分工交付物格式**：助手改完代码交付「改动清单 + 静态自检结论 + 建议用户执行的构建命令」，由用户跑并反馈报错，助手据报错改。环境佐证（Android/Gradle）：单次工具调用约 3.5 分钟墙钟上限，gradle daemon 会被外部终止（报 `Gradle build daemon has been stopped: stop command received`）；后台/`nohup` 脱离也活不过单次调用，长构建交用户跑是更合理的分工。

## 视频源
- 引擎只认 maccms json/xml（`Site.api` 须真实 URL）。`SourceImport._mapType` 收 type 0=xml/1=json，**type 3/4/7/15(SpiderJS/drpy) 跳过**。
- 猫影视/CatVod config 是 SpiderJS 跑不了；内置只抽其中真实 maccms 端点（藏在 ext.url）。
- 内置默认源 `assets/data/init_site.json`（22 个猫影视 maccms 源），`AppState.bootstrap→ZyDatabase.initDb` 源库空时种子化。老用户升级源库非空不覆盖，需「重置软件」。
- 导入合并（1.7.5）：`importSites`(URL) 与 `importSitesFromContent`(本地) 都按 `Site.key` upsert，不清空已有源。
- 接口地址一律 `HttpService._apiUrl(site, params)`，别字符串拼接（zyfun api 自带查询串，拼错返精简列表不报错）。type 不可信，按响应首字符判定 JSON/XML。先 GET 仅 4xx 回退 POST。无 charset 按 UTF-8。`Site.id` 装饰，身份用 `key`。

## 源可用性检测（1.7.4 折中版）
`HttpService.checkSite` → `SiteCheckResult(health,message,ms)`，`SiteHealth{ok,warn,fail}`，请求 `?ac=list`，超时 8s。`_describeRawError` 实测校准（连接被拒 errno 1225/10061、CERTIFICATE_VERIFY_FAILED、`<!DOCTYPE html`→接口已变更）。`site_page`：单条重测+「检测全部」(并发4)+chip+「清除死站」(fail→removeSites 真删)+「清空所有源」。⚠️ **检测中途只更新 chip，结尾统一启停+重排**（`reorderSites`：可用前/不可用后/未检测最后）。结果只放内存不落库。

## 首页片单本地缓存（1.7.7）
`lib/services/list_cache.dart` 按 `(siteKey,tid,pg)` 缓存分页片单+元信息(`pagecount/recordcount/ts`) 到 `DbNames.listcache`。`film_page` `CategoryTab._load`：先读缓存秒出→后台 `_refresh` 静默替换；刷新失败保留缓存不空白。`_appendPage(page,{sink})` 写缓存。`video_grid` 给 `VideoCard` 加 `ValueKey(video.id)` 防闪烁。「重置软件」走 `clearDB()` 已清 listcache。`ListCache.clearAll()` 可单独清。
- **封面秒显靠预取（1.7.9）**：图必须下载过一次才进磁盘缓存，首见/新内容必走网络（硬限制）。`lib/utils/image_prefetch.dart` 的 `ImagePrefetch.prefetch()` 在 `_load`（读缓存后）/ `_refresh`（刷新后）后台抢先拉封面进磁盘缓存（并发上限 6、URL 去重），让滚动/下次打开直接读本地。网格封面 `memCacheWidth:480`、详情大图 `600` 限制解码尺寸降内存。

## 加载态 UI：一律骨架屏，禁灰黑遮罩
`LoadingMask` 已删。列表用 `VideoGridSkeleton`（共用 `videoGridDelegate`）。有内容刷新不抹内容+顶部 2px `LinearProgressIndicator`。换源不立刻重置 `_classes`。

## 深色 = 纯黑（OLED）
配色 `app_colors.dart`。层级用 1px 描边(`darkOutline=0x24FFFFFF`)不提亮底色。`darkBg#000000`、`darkSurface#0D0D0D`、`darkSkeletonLow/High#141416/#232327`。`main.dart` 必须把 `colorScheme.surface` 系列压纯黑（M3 Dialog/BottomSheet 默认取 surface）。卡片交 `cardTheme`。

## 播放页（勿回退）
进度条独占一行+等宽按钮行。比例/大小两独立维度（`_stageAreaSize`+双层 FittedBox）。交换宽高是 `RotatedBox`+倒数 aspect。手势层左亮右音量双击暂停。进度条自绘 `_ProgressSlider`（轨道色跟主题，已播段用 `_accent`）。全屏方向跟比例。返回键 `PopScope(canPop:!_fullscreen)` 先退全屏再退页。全屏控制层 `AnimatedOpacity`+`IgnorePointer`+4s 隐藏。实时网速 `AppConfig.showSpeed` 默认关（`video_network_stats.dart` 轮询 `playerId`，video_player 2.10.1）。

## 应用图标（1.7.4 定稿）
`make_icons.py`，源图 `.workbuddy/tools/icon_source.png`（透明圆角外+黑底+青三角+声波，无文字）。adaptive foreground 满幅1.0。`assets/images/logo.png` 资源保留但**已不再被代码引用**（1.7.10 删掉 Flutter 启动页 `AppBootstrap` 后）。设置页顶部品牌区已删。

## 启动流程（1.7.10 定稿）
- **无 Flutter 开屏**：`main.dart` 直接 `home: MainPage()`，删除了 `AppBootstrap`（原 logo+转圈）。原生 `LaunchTheme` 背景已纯色（`drawable-v21` 用 `?android:colorBackground` 跟随系统深浅，与 app 背景同色，过渡无缝），无 logo。
- `FilmPage.initState` 注册 `AppState` 监听，源列表就绪（空→非空）后 `reloadIfNeeded()` 自动重载，避免直进主页时短暂卡"暂无可用视频源"。`reloadIfNeeded` 按源签名比对，收藏/历史加载不触发重复拉取。

## 其他坑（勿回退）
- Flutter 命中测试：触点在父节点外整棵子树不命中；要放外面先留空间（详情页收藏/播放按钮「点了没反应」即此因）。
- 收藏/历史 key=`{siteKey}-{videoId}`，siteKey 是 UUID 含连字符，**绝不用 `split('-')[0]`**；用 `AppState.resolveRecordKey()` 从右往左匹配前缀。
- 详情页布局：`_buildContent`→`_buildInfoSection`→`_buildInfoCard`；悬浮按钮 `right:116/40`，勿改负偏移。
- 原生通道 `MethodChannel('com.zy.player/system')`：Dart `system_control.dart` + Kotlin `MainActivity.kt` 两端同步改。
- 设置页底部导航第三项；开关 `SwitchListTile`，build 顶部 `context.watch<AppState>()`。
- 自定义播放器（PC/Windows）：设置页选 `.exe` 持久化 `AppConfig.externalPlayerPath`；详情页「外部播放」调 `openWithExternalPlayer(url,customPath:)`；未设置走自动查找。
- 数据备份/恢复 `data_backup.dart`：备份用 `saveFile`(bytes Android/iOS 必填)；恢复用 `pickFiles`。
- 青少年模式已整体移除，别写回。

## WorkBuddy 工具环境坑（实锤，避免重踩）
- **Bash 命令里的反斜杠 `\` 会被传输层转成 `/`**（heredoc 引号包裹也不幸免：`b'D:\\WorkBuddy'` 到手 len=13、值 `D://WorkBuddy`）。含反斜杠字面量的 python/脚本必须用 Write 工具写成文件再 `python file.py`，绝不能内联进 Bash 命令；文件路径参数尽量用正斜杠（Windows API 都接受）。
- **Git Bash 会把 `/MIR`、`/S` 这类 Windows 命令开关当路径转换**（`robocopy src dst /MIR` → 报 `错误: 无效参数 #3: C:/Users/.../PortableGit/.../MIR`）。解决：命令前加 `MSYS_NO_PATHCONV=1`，即 `MSYS_NO_PATHCONV=1 robocopy "D:/a" "D:/b" /MIR /NFL /NDL /NJH /NJS /NP`。注意 Windows 下 robocopy 返回码 0–7 都算成功，`&&` 链会被 1 码打断。

## 静态检查的硬约束
- 本项目用 `dart-single-process-analyze` 技能跑单进程静态检查（生成环境到 `C:/Users/VTE/AppData/Local/Temp/zyanalyze/analyze.dart`，再 `C:/flutter/bin/dart .../analyze.dart --no-lints`）。
- 沙箱禁止派生子进程，故不能跑 `flutter analyze`/`dart analyze`（会报 CreateFile failed 231）；只能走该技能的单进程路径。
- `android/local.properties` 被 gitignore（本地不入库），`git add` 它会被拒；提交时注意只加仓库内文件。
