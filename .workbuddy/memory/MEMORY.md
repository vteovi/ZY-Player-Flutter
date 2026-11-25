# 项目长期记忆：ZY Player Flutter

uni-app 版 ZY-Player-APP 的 Flutter 重写（首页/详情/播放/收藏/历史/源管理/设置），引擎只认 maccms json/xml 采集站。provider + ChangeNotifier（全局 `AppState`）；shared_preferences 存储（键 `ZY-{db}-DB`）；包名 `com.zy.player`、minSdk 24、targetSdk 35。细节见同目录日记。

## ⚠️ 协作纪律（用户明确要求，勿破）
1. **构建走 GitHub Actions**，本机无常规 Flutter 环境（2026-11-07 用户删掉了 `C:\flutter`）。交付 = 改动清单 + push 到 `dev` + 告诉用户去 Actions 手动跑「Build APK + Windows」。
2. **默认只 `git commit`，push 需用户明确要求**（说「你来帮我推」「发布」才推）。改完 `git add` + `commit`，`git status --porcelain` 为空再汇报。
3. **push 前必须 `unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY`**（2026-11-07 实锤）：环境里挂着 `http_proxy=http://127.0.0.1:64622`，代理访问 github.com 返回 502/000，直连才通。命令模板：`git -c http.version=HTTP/1.1 push origin <ref>`。
   - 若报 403/认证失败，**先看 `git remote -v`** 是否被 `~/.gitconfig` 里的 `[url "...gh-proxy.com..."] insteadOf` 改写成只读镜像（2026-11-17 踩过，已删该配置）。
   - **⭐ 主站不通时走 SSH 443（2026-11-25 两次实锤）**：`curl https://github.com` 返回 000 而 `api.github.com` 200 是典型信号。**别用 API 推 ref**——`PATCH /git/refs/heads/main` 对服务端没有的 commit 必返 **422**（跟权限无关）。正解：
     `git -c core.sshCommand="ssh -p 443 -o StrictHostKeyChecking=no" push ssh://git@ssh.github.com:443/vteovi/ZY-Player-Flutter.git main v1.37.0`
     仓库已有 ed25519 key，`ssh -T -p 443 git@ssh.github.com` 可先验。**fetch 也要带同一个 sshCommand**，否则 `origin/*` 跟踪引用不更新，`git status -sb` 会假报 ahead。
   - `git push` 成功 ≠ Release 资产下载快，两者不同线路。查 CI/Release 用 `curl api.github.com`（public 仓库免认证；`gh` CLI 没装）。
4. 跑 git 前先 `export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"`。
5. **改完必须静态校验 + bump 版本号**（SemVer：feat→MINOR / fix→PATCH，versionCode +1）。本机有一套便携 toolchain 可跑 analyze（会话路径，存在才有）：
   `export PATH="/c/Users/Administrator/Doubao/chats/2026-11-21/new-chat/.toolchain/flutter/bin:$PATH" && flutter analyze --no-fatal-infos --no-fatal-warnings lib`
   **跑完必须 `git checkout -- analysis_options.yaml`**（flutter 会自动往里加 exclude）。基线是 **0 error / 0 warning / ~32 info**（全是 `material.dart` deprecated）。CI 侧 `.github/workflows/analyze.yml` 兜底。
6. 每次发版同步维护根目录 `更新记录.MD`：版本倒序，每条「日期 + 新增/优化/修复/调整 + 一句人话」，不写实现细节与 chore/docs；头部「当前版本」一起改。
7. **分支纪律**：`main` = 稳定发布线，`dev` = 开发线，新功能一律在 `dev`。合回用 `git checkout main && git fetch && git reset --hard origin/main && git merge --no-ff dev`。push `dev` 只跑 analyze，**只有 `v*` tag 才打包发 Release**。

## 构建与发版
- **出包**：Actions → `Build APK + Windows` → Run workflow → 选分支 + `variant`（split 推荐）。手动跑**不发 Release**，产物只在 Artifacts（保留 30 天）。
- **发版顺序（勿乱）**：改 pubspec → 打 `v*` tag → push → CI 产 Release（含固定名 `ZY-Player-arm64-latest.apk` 供清单引用）→ **Release 存在后**才改 `update.json`（5 条左右用户能感知的说明）→ push → 清 CDN → 验证镜像 → 切回 dev `git checkout main -- update.json` 同步。
- **版本号两处**：`pubspec.yaml`（`1.37.0+235`）+ `android/local.properties`（gitignore，本地构建用）。设置页副标题走原生 `PackageManager`，不手写。
- **ABI**：不加 `--split-per-abi` 时 `--target-platform` 被忽略 → fat 包 ~68MB；arm64 单独 ~18MB 必须 split。首次出包 ~26 分钟，缓存命中后 3~5 分钟。
- **签名（2026-10-30 起，勿回退）**：密钥库在仓库外 `C:\Users\Administrator\keystores\zy-player-release.jks`（alias `zyplayer`，口令见本地 `android/key.properties`），证书 SHA-1 `BF:DE:D8:E2:...:C6:53:F7:7A`。`build.gradle.kts` 读 key.properties，有则 release、无则退化 debug；CI 由 Secret `KEYSTORE_BASE64` + `KEYSTORE_PASSWORD` 现场生成。**keystore 绝不能入库**（仓库 public）。⚠️ 换签名后老用户必须卸载重装一次 —— 这条要写进每次更新说明末尾。
- Actions 环境：`runs-on: ubuntu-24.04`（固定，ubuntu-latest 已迁 26）；checkout@v7 / setup-java@v6 / cache@v6 / upload-artifact@v7；产物收集 `tools/ci-collect-apk.sh`（两批构建各调一次，放最后会被覆盖）。**CI 配置不进 APK，不升版本号。**
- Windows 本地构建（基本不用）：需 `SeCreateSymbolicLinkPrivilege`；NDK 固定 `27.0.12077973`（AGP 校验 `source.properties`，软链接骗不过）。

## 应用内版本更新（1.18.0 起，勿回退）
- 流程：拉远端 `update.json` → 用**已安装包**的 versionCode（原生 `PackageManager`）比较 → 弹窗含更新说明 → 应用内下载（可取消）→ `FileProvider` 交系统安装器。
- 分层：`lib/utils/version.dart` 纯逻辑；`lib/services/update_service.dart` 只做网络。只比 versionCode，退化时按版本名逐段数字比（**不能比字符串**：`"1.10" < "1.9"`）。
- **大陆网络必挂**：默认一组镜像**并发竞速**（raw / ghproxy.net / gh-proxy.com / ghfast.top / cdn.jsdelivr.net），用户自定义地址时只试那一个。安装包下载直连失败自动加 `gh-proxy.com/`、`ghproxy.net/` 前缀（两者对 release 资产支持 Range，206）。`fetchManifest` 必须 catch `http.ClientException`。
- **不能「第一个 200 胜出」（1.20.1 修）**：jsDelivr `@main` 有小时级缓存，会返回 200 但内容是旧版。现在收齐所有 200，解析后**取 versionCode 最大**。发版后 `curl https://purge.jsdelivr.net/gh/vteovi/ZY-Player-Flutter@main/update.json` 清缓存，**且必须复查** —— purge 返回 `providers: true` 不代表已刷新，实测常要连清 3~4 次才更新，可能仍落后一两个版本（取最大值兜住）。
- 安装要件：`REQUEST_INSTALL_PACKAGES` + 显式 `androidx.core:core` + manifest `<provider ${applicationId}.fileprovider>` + `res/xml/file_paths.xml`。**必须 `content://`**（Android 7+ `file://` 抛 FileUriExposedException）。对话框用 `PopScope(canPop:false)`；取消下载只置标记，统一由调用方 pop。

## 视频源
- **手动添加接口（1.37.0）**：`lib/pages/site_edit_page.dart`（添加/编辑两用表：地址必填、名称可空回退域名、启用开关、测试连接走 `HttpService.checkSite`）；入口在源管理页三点菜单「手动添加接口」；**长按源卡片**弹菜单（编辑 / 复制地址 / 删除单条）。`AppState.saveSite()` 做 upsert，**编辑沿用原 key**，收藏与播放记录不断；删源不删记录。
- `Site.api` 须真实 URL；`SourceImport._mapType` 0=xml / 1=json；`SourceImport.inferType(api)` 按地址猜（`at/xml` → xml）。type 3/4/7/15（SpiderJS/drpy）先从 ext.url 提取真实 maccms 端点，无端点才跳过。内置默认源 `assets/data/init_site.json`（22 个），仅源库为空时种子化。导入按 `Site.key` upsert，不清空已有源。
- 配置导入：`HttpService.importSites` 返 `ImportSummary`；支持地址规范化（`lib/utils/config_url.dart`，无协议头/中文域名）、JSONP、多仓 `{"urls":[...]}`（≤5）、导航网页自动找 tvbox 链接（≤6、总 25s）、直接粘 maccms 接口、按 api/key 去重。
- **TVBox 加密配置（勿回退）**：`box.iqinu.com` 这类站只在 `okhttp/*` UA 下给真配置，正文是 `$#key#$` + AES-128-CBC + 13 字节 IV。`_fetchConfig` 按 okhttp/3.15 → 3.12 → 浏览器试；`lib/utils/tvbox_crypto.dart` 纯 Dart 解密（**不引 pointycastle**；GF 求逆必须幂运算 `x^254`）。spider 兜底要严：`.js/.json/.txt` 结尾、逗号多域名一律不导入。
- 接口地址一律走 `HttpService._apiUrl()`，别拼字符串；type 不可信，按响应首字符判 JSON/XML；先 GET，仅 4xx 回退 POST；`Site.id` 只是装饰，身份用 `key`。很多源站/CDN 按 UA 拦 ExoPlayer → play_page `_kPlayerHeaders` 用浏览器 UA。

## UI 约定（勿回退）
- **加载态一律骨架屏**，禁灰黑遮罩（`LoadingMask` 已删）；有内容刷新不抹内容，顶部 2px `LinearProgressIndicator`；换源不立刻重置 `_classes`。
- **深色 = 纯黑 OLED**：`darkBg#000000` / `darkSurface#0D0D0D`，层级靠 1px 描边 `0x24FFFFFF`，不提亮底色；`main.dart` 必须把 `colorScheme.surface` 系列压纯黑（M3 Dialog/BottomSheet 默认取 surface）。`bottomNavigationBarTheme.type: fixed`（否则 4 项变 shifting）。
- **卡片显示模式 = 单一枚举 `ViewMode { portrait, landscape, waterfall }`**（1.36.1 起，别再拆成散装布尔）。`ViewMode.parse` 兼容老存档（按旧优先级 瀑布流>横向 反推），`toJson` 仍写 `landscapeCard`/`waterfall` 派生值给旧版读。入口：设置页「卡片显示模式」+ 首页顶栏按钮（**点按循环 竖→横→瀑布，长按弹底部菜单**，共用 `lib/widgets/view_mode_picker.dart`；`IconButton` 无 onLongPress，需 `Tooltip(triggerMode: manual) + InkResponse`）。瀑布流下按钮也要显示，否则切进去出不来。
- 瀑布流：`lib/widgets/waterfall_grid.dart`，`SliverMasonryGrid`（`.count` 构造没有 `addAutomaticKeepAlives`，须用主构造 + `SliverChildBuilderDelegate`）。列数 `width<600→2`，否则 `(w/190).floor().clamp(2,8)`。比例来自 `lib/utils/poster_ratio.dart`：**只读图片头 64KB**（JPEG 找 SOF 排除 C4/C8/CC、PNG IHDR、GIF、WebP VP8/VP8L/VP8X），三级缓存（内存→`poster_ratio.json`→解析），无比例时 `2/3` 占位。
- 首页片单缓存 `list_cache.dart`（siteKey/tid/pg）先读缓存秒出再静默刷新；封面预取 `image_prefetch.dart`（并发 6、URL 去重），网格 `memCacheWidth:480`、详情 600。`PosterCover` 自定义 `imageBuilder` 会丢淡入，用 `frameBuilder + AnimatedOpacity` 补。
- **收藏 / 历史**：1.34.0 起 `AppConfig.mergeRecords` 开关 —— 关（默认）= 导航 4 项（首页/收藏/历史/设置），`StarPage` + `HistoryPage` 各自成页，共用 `lib/widgets/record_grid.dart`；开 = 3 项（首页/我的/设置），`RecordsPage` 顶部 TabBar 两栏。数量角标 `RecordCountTag`。`MainPage` 用**逻辑槽位 + `_slotOf()/_indexOf()`** 映射，别用物理下标（拨开关会越界/弹回首页）。
- 记录 key = `{siteKey}-{videoId}`，siteKey 是 UUID 含连字符，**绝不用 `split('-')[0]`**，用 `AppState.resolveRecordKey()`。
- 源检测：`HttpService.checkSite`（`?ac=list` 超时 8s）→ ok/warn/fail；检测中途只更新 chip，结尾统一启停+重排；结果只放内存。**`PopupMenuButton` 别整个 `enabled:false`**，会让菜单里的非破坏项（如导入）也点不了。
- **大屏（≥600 宽，`MainPage._wideThreshold`）**：首页搜索框并入 AppBar 第一排 [站点切换 ≤260 | 搜索 | 共 N 资源]，toolbarHeight 60；NavigationRail `trailing` 放大屏快捷入口。播放页分栏条件 宽≥840 且 宽>高，右栏 min(屏宽 30%, 420) 且 ≥300。
- **播放页**：进度条独占一行 + 等宽按钮行；比例/大小是两个独立维度（`_stageAreaSize` + 双层 FittedBox）；手势左亮右音量、双击暂停；进度条自绘 `_ProgressSlider`；返回键 `PopScope` 先退全屏再退页；控制层 4s 隐藏；倍速 0.5~3.0 八档；**收藏按钮只在 `!_fullscreen || _landscapeNow` 显示**。
- 设置页（1.36.0 起）：六组圆角卡片（内容与数据 / 播放 / 外观与布局 / 备份与恢复 / 清理与重置 / 关于），`_SettingsSection` + `_SettingsTile` + `_SwitchTile`，桌面限宽 720 居中。导入导出已并入源管理页菜单，**设置页不再有「播放记录」「导入配置源」两项**。

## 其他坑（勿回退）
- Flutter 命中测试：触点在父节点外整棵子树不命中 —— 要露在外面先给父节点留空间。
- 「内容不满一屏 → 触发不了翻页」死局：`CategoryTabState._maybeContinueLoad()` 每帧检查 `maxScrollExtent<=0` 或贴底就主动续拉，配 `didChangeMetrics` + `_noGrowStreak` 兜底。
- 详情 `fetchDetail` 只对**瞬时错误**重试 2 次（300/600ms 退避）；详情页 `EmptyHint` 显示具体原因 + 重试按钮。
- 原生通道 `com.zy.player/system`（+ `/pip`、`/window`）：Dart `system_control.dart` 与 Kotlin `MainActivity.kt` 两端同步改。
- 数据备份 `data_backup.dart`：备份 `saveFile`（bytes 必填），恢复 `pickFiles`。青少年模式已整体移除，别写回。

## Windows 原生窗口（勿回退）
- **C++ 只能写英文注释**（MSVC 按 GBK 读 UTF-8 中文 → C4819 → 构建失败）。
- **一切窗口形状变更必须由 Dart 发起**：原生 `WM_CLOSE` 只回传 `onPipExitRequested`/`onFullscreenExitRequested`。
- **改窗口前后必须「摘视频纹理」**：fvp 用 D3D11 共享纹理，出帧时改尺寸会与纹理回调互等 → UI 线程死锁。`_withVideoDetached()`：置标记换黑盒 → 等两帧 + 60ms → 调原生 → 250ms → 挂回。
- 改窗口用单次 `SetWindowPos(... SWP_FRAMECHANGED|SWP_NOOWNERZORDER)`；诊断日志 `zy_player_debug.log`。三模式：填满 / 原生全屏 / 画中画（`WS_POPUP`，引擎前拦 `WM_NCCALCSIZE`，别用 `WS_CAPTION`）。
- 无边框拖动/缩放走 `WM_NCLBUTTONDOWN`（**lParam 传真实屏幕坐标**）；缩放热区须 `opaque` 吃指针；最小 200x120。

## 工具环境坑（实锤）
- Bash 里反斜杠 `\` 会被转成 `/`（heredoc 也不免）：含反斜杠的脚本用 Write 写文件再 `python file.py`，路径用正斜杠。
- Git Bash 把 `/S`、`/MIR` 当路径：加 `MSYS_NO_PATHCONV=1`（robocopy 0–7 算成功）。
- **Write 工具新建 `.bat`/`.ps1` 会存成 UTF-16**，cmd 读不了：用 Python `encoding='gbk', newline=''` 写。
- `flutter pub get` 会改 `analysis_options.yaml`、`flutter build` 会改 `android/gradle.properties` —— 跑完都要 `git checkout --`。
