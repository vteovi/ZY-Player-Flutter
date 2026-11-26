# 项目长期记忆：ZY Player Flutter

uni-app 版 ZY-Player-APP 的 Flutter 重写（首页/详情/播放/收藏/历史/源管理/设置），引擎只认 maccms json/xml 采集站。provider + ChangeNotifier（全局 `AppState`）；shared_preferences 存储（键 `ZY-{db}-DB`）；包名 `com.zy.player`、minSdk 24、targetSdk 35。细节见同目录日记。

## ⚠️ 协作纪律（勿破）
1. **构建走 GitHub Actions**，本机无常规 Flutter 环境（2026-11-07 用户删了 `C:\flutter`）。交付 = 改动清单 + push `dev` + 让用户去 Actions 跑「Build APK + Windows」。
2. **默认只 commit，push 需用户明确要求**（说「你来帮我推」「发布」才推）。提交前 `git status --porcelain` 必须为空。
3. **push 前必须 `unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY`**：环境挂着 `http_proxy=127.0.0.1:64622`，走代理访问 github.com 返 502/000，直连才通。模板 `git -c http.version=HTTP/1.1 push origin <ref>`。
   - 403/认证失败 → **先 `git remote -v`** 看是否被 `~/.gitconfig` 的 `[url ...gh-proxy.com...] insteadOf` 改写成只读镜像（2026-11-17，已删）。
   - **⭐ 主站不通走 SSH 443（两次实锤）**：`curl https://github.com` 000 而 `api.github.com` 200 即信号。**别用 API 推 ref**，`PATCH /git/refs/heads/main` 对服务端没有的 commit 必 422。正解：
     `git -c core.sshCommand="ssh -p 443 -o StrictHostKeyChecking=no" push ssh://git@ssh.github.com:443/vteovi/ZY-Player-Flutter.git main v1.37.0`
     **fetch 也要带同一 sshCommand**，否则 `origin/*` 不更新、`status -sb` 假报 ahead。
   - push 成功 ≠ Release 下载快，两条线路。查 CI/Release 用 `curl api.github.com`（免认证，`gh` 未装）。
4. 跑 git 前 `export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"`。
5. **改完必须静态校验 + bump 版本号**（feat→MINOR / fix→PATCH，versionCode +1）。便携 toolchain（存在才有）：
   `export PATH="/c/Users/Administrator/Doubao/chats/2026-11-21/new-chat/.toolchain/flutter/bin:$PATH"; flutter analyze --no-fatal-infos --no-fatal-warnings lib`
   跑完 `git checkout -- analysis_options.yaml`（flutter 会加 exclude）。基线 **0 error / 0 warning / ~32 info**（`material.dart` deprecated）。
6. 每次发版维护 `更新记录.MD`：版本倒序，「日期 + 新增/优化/修复 + 一句人话」，不写实现细节与 chore/docs；头部「当前版本」同步。
7. **分支**：`main` 稳定线、`dev` 开发线，新功能只在 `dev`。合回：`git checkout main && git fetch && git reset --hard origin/main && git merge --no-ff dev`。push `dev` 只跑 analyze，**只有 `v*` tag 才打包发 Release**。

## 构建与发版
- **出包**：Actions → `Build APK + Windows` → 选分支 + `variant`（split 推荐）。手动跑**不发 Release**，产物在 Artifacts（留 30 天）。
- **发版顺序（勿乱）**：改 pubspec → 打 tag → push → CI 产 Release（含固定名 `ZY-Player-arm64-latest.apk`）→ **Release 存在后**才改 `update.json`（5 条左右用户能感知的说明）→ push → 清 CDN → 验镜像 → 切 dev `git checkout main -- update.json` 同步。
- **版本号两处**：`pubspec.yaml`（`1.37.0+235`）+ `android/local.properties`（gitignore）。设置页副标题走原生 `PackageManager`。
- **ABI**：不加 `--split-per-abi` 时 `--target-platform` 被忽略 → fat 68MB；arm64 单独 18MB 必须 split。首包 ~26 分钟，缓存命中 3~5 分钟。
- **签名（勿回退）**：库在仓库外 `C:\Users\Administrator\keystores\zy-player-release.jks`（alias `zyplayer`，口令见 `android/key.properties`）。`build.gradle.kts` 有则 release、无则退化 debug；CI 用 Secret `KEYSTORE_BASE64` + `KEYSTORE_PASSWORD` 现场生成。**keystore 绝不能入库**（仓库 public）。⚠️ 换签名后老用户须卸载重装 —— 写进每次更新说明末尾。
- CI：`runs-on: ubuntu-24.04` 固定；checkout@v7 / setup-java@v6 / cache@v6 / upload-artifact@v7；产物收集 `tools/ci-collect-apk.sh`（两批各调一次，放最后被覆盖）。**CI 配置不升版本号。**
- Windows 本地构建基本不用：NDK 固定 `27.0.12077973`（AGP 校验 `source.properties`，软链接骗不过）。

## 应用内版本更新（勿回退）
- 流程：拉远端 `update.json` → 用**已安装包** versionCode（`PackageManager`）比较 → 弹窗含说明 → 应用内下载 → `FileProvider` 交安装器。分层：`utils/version.dart` 纯逻辑、`services/update_service.dart` 只做网络。只比 versionCode，退化按版本名逐段数字比（**不能比字符串**）。
- **大陆网络必挂**：默认多镜像**并发竞速**（raw / ghproxy.net / gh-proxy.com / ghfast.top / cdn.jsdelivr.net）；用户自定义地址只试那一个。装包下载直连失败自动加 `gh-proxy.com/`、`ghproxy.net/` 前缀（支持 Range，206）。必须 catch `http.ClientException`。
- **不能「第一个 200 胜出」**：jsDelivr `@main` 小时级缓存会返 200 旧内容。现收齐所有 200 后**取最大 versionCode**。发版后 purge 并**必须复查** —— 返回 `providers:true` 不代表刷新，常要连清 3~4 次，可能仍落后一两版（取最大值兜住）。
- 安装要件：`REQUEST_INSTALL_PACKAGES` + 显式 `androidx.core:core` + manifest `<provider ${applicationId}.fileprovider>` + `res/xml/file_paths.xml`。**必须 `content://`**。对话框 `PopScope(canPop:false)`；取消下载只置标记，由调用方 pop。

## 视频源
- **手动添加接口（1.37.0）**：`lib/pages/site_edit_page.dart`（地址必填、名称可空回退域名、启用开关、测试连接走 `checkSite`）；入口在源管理页三点菜单；**长按源卡片**弹菜单（编辑/复制地址/删除单条）。`AppState.saveSite()` upsert，**编辑沿用原 key**（收藏/记录不断），删源不删记录。
- `Site.api` 须真实 URL；`_mapType` 0=xml / 1=json；`SourceImport.inferType(api)` 按地址猜（`at/xml`→xml）。type 3/4/7/15（SpiderJS/drpy）先从 ext.url 提真实端点，无端点跳过。默认源 `assets/data/init_site.json`（22 个），仅源库为空时种子。按 `key` upsert，不清空已有。
- 配置导入：`importSites` 返 `ImportSummary`；支持 `config_url.dart` 规范化（无协议头/中文域名）、JSONP、多仓 `{"urls":[...]}`（≤5）、导航页找 tvbox 链接（≤6、总 25s）、直接粘接口、按 api/key 去重。
- **TVBox 加密配置（勿回退）**：`box.iqinu.com` 类站只在 `okhttp/*` UA 下给真配置，正文 `$#key#$` + AES-128-CBC + 13 字节 IV。`_fetchConfig` 按 okhttp/3.15→3.12→浏览器试；`utils/tvbox_crypto.dart` 纯 Dart 解密（**不引 pointycastle**；GF 求逆用 `x^254`）。spider 兜底要严：`.js/.json/.txt`、逗号多域名一律不导。
- 地址一律 `HttpService._apiUrl()`；type 不可信，按首字符判 JSON/XML；先 GET 仅 4xx 回退 POST；`Site.id` 只是装饰，身份用 `key`。CDN 常按 UA 拦 ExoPlayer → `_kPlayerHeaders` 用浏览器 UA。
- **多线路（1.44.0，勿回退）**：`vod_play_from` / `vod_play_url` 都是 `$$$` 分段且按序对应，聚合站一部片可达 11 条（`ys.cxkjg.cn` 实测，集数 15~21 不等）。`VideoDetail.lines` 是唯一真源（`m3u8List` 只是 `lines.first.items` 的 getter）；`_mapPlayLines()` 逐段配对、缺名补「线路N」、含 m3u8 的排前。详情页 `_selectLine` 只换选集不重请求；播放页 `_switchLine` 按集名对齐同集、对不上按原位置；进播放页用 `widget.url` 反查线路，历史/收藏不串台。**绝不要再退回「firstWhere 取第一段」**。

## UI 约定（勿回退）
- **加载态一律骨架屏**，禁灰黑遮罩（`LoadingMask` 已删）；刷新不抹内容，顶部 2px `LinearProgressIndicator`；换源不重置 `_classes`。
- **深色 = 纯黑 OLED**：`#000000` / surface `#0D0D0D`，层级靠 1px `0x24FFFFFF` 描边，不提亮底色；`main.dart` 把 `colorScheme.surface` 压纯黑（M3 Dialog/Sheet 默认取它）。`bottomNavigationBarTheme.type: fixed`（否则 4 项变 shifting）。
- **卡片模式 = 单枚举 `ViewMode {portrait, landscape, waterfall}`**（1.36.1 起，别拆回散装布尔）。`parse` 兼容老存档（按 瀑布流>横向 反推），`toJson` 仍写 `landscapeCard`/`waterfall` 派生值。入口：设置页 + 首页顶栏（**点按循环 竖→横→瀑布，长按弹底部菜单**，共用 `widgets/view_mode_picker.dart`；`IconButton` 无 onLongPress，须 `Tooltip(triggerMode: manual)+InkResponse`）。瀑布流下按钮也要显示，否则切进去出不来。
- 瀑布流 `widgets/waterfall_grid.dart`：用 `SliverMasonryGrid` 主构造（`.count` 无 `addAutomaticKeepAlives`）。列数 `<600→2`，否则 `(w/190).floor().clamp(2,8)`。比例来自 `utils/poster_ratio.dart`：**只读图片头 64KB**（JPEG 找 SOF 排除 C4/C8/CC、PNG IHDR、GIF、WebP），三级缓存（内存→`poster_ratio.json`→解析），缺省 `2/3` 占位。
- **首页分类栏不做任何名字屏蔽**（1.44.2 起）：接口给几个就显示几个，只按 tid 去重（`FilmPageState._dedupeClasses`）。别再写「电影/电视剧/综艺/动漫」这类黑名单 —— 那是把采集站最主流的分类整块藏掉，实测某站 9 个分类只剩 6 栏。
- 首页片单缓存 `list_cache.dart` 先读缓存秒出再静默刷新；封面预取并发 6，网格 `memCacheWidth:480`、详情 600。`PosterCover` 自定义 `imageBuilder` 会丢淡入，用 `frameBuilder + AnimatedOpacity` 补。
- **收藏/历史**：`mergeRecords` 开关 —— 关（默认）导航 4 项（首页/收藏/历史/设置），`StarPage`+`HistoryPage`，共用 `widgets/record_grid.dart`；开则 3 项（首页/我的/设置）+ `RecordsPage` TabBar 两栏。角标 `RecordCountTag`。`MainPage` 用**逻辑槽位 + `_slotOf()/_indexOf()`**，别用物理下标（会越界/弹回首页）。
- 记录 key = `{siteKey}-{videoId}`，siteKey 含连字符，**绝不用 `split('-')[0]`**，用 `resolveRecordKey()`。
- **输入框别用 `TextInputType.url`**（2026-11-25 实锤）：映射成 `TYPE_TEXT_VARIATION_URI`，配 `autocorrect:false`/`enableSuggestions:false` 的 `NO_SUGGESTIONS`，国产输入法会判成敏感输入并切「安全键盘」，用户调不出常用输入法与粘贴板。网址/接口地址框一律 `TextInputType.text`。
- 源检测 `checkSite`（`?ac=list` 超时 8s）→ ok/warn/fail；中途只更新 chip，结尾统一启停+重排；结果只放内存。**`PopupMenuButton` 别整个 `enabled:false`**，会连非破坏项一起禁掉。
- **大屏（≥600）**：首页搜索框并入 AppBar 第一排 [站点 ≤260 | 搜索 | 共 N]，toolbarHeight 60；NavigationRail `trailing` 放大屏入口。播放页分栏：宽≥840 且 宽>高，右栏 min(30%,420) 且 ≥300。
- **播放页**：进度条独占一行 + 等宽按钮行；比例/大小底层是独立两维（`_stageAreaSize` + 双层 FittedBox），但 UI 已合并成**单个「画面」按钮 + 单个 `_screenPanelOpen` 面板**（1.43.0，面板内分「画面比例」「画面大小」两段，别再拆回两个按钮）；左亮右音量、双击暂停；自绘 `_ProgressSlider`；`PopScope` 先退全屏再退页；控制层 4s 隐藏；倍速 0.5~3.0 八档；**收藏按钮只在 `!_fullscreen || _landscapeNow` 显示**。
- 设置页：六组卡片（内容与数据/播放/外观与布局/备份与恢复/清理与重置/关于），`_SettingsSection`+`_SettingsTile`+`_SwitchTile`，桌面限宽 720 居中。导入导出已并入源管理菜单，**设置页不再有「播放记录」「导入配置源」**。

## 其他坑（勿回退）
- Flutter 命中测试：触点在父节点外整棵子树不命中 —— 要露在外面先给父节点留空间。
- 「不满一屏触发不了翻页」死局：`CategoryTabState._maybeContinueLoad()` 每帧查 `maxScrollExtent<=0` 或贴底主动续拉，配 `didChangeMetrics` + `_noGrowStreak`。
- 详情 `fetchDetail` 只对**瞬时错误**重试 2 次（300/600ms）；详情页 `EmptyHint` 显示原因 + 重试。
- 原生通道 `com.zy.player/system`（`/pip`、`/window`）：`system_control.dart` 与 `MainActivity.kt` 两端同步改。
- 备份 `data_backup.dart`：`saveFile`（bytes 必填）/ `pickFiles`。青少年模式已整体移除，别写回。
- **批量写/删库必须报进度 + 让出事件循环**（1.44.1）：`SharedPreferences` 无批量接口，每次 `setString`/`remove` 在 Windows 端都是「整份偏好序列化 + 同步写盘」，连着几十次会把 UI 线程按住几秒 = 点了没反应。`removeMany` 现带 `onProgress`，30 条内每条 `Future.delayed(Duration.zero)`，更多按 12 条 / 24ms 预算；界面侧按钮显示「清除中 3/12」+ 2px 进度条。

## Windows 原生窗口（勿回退）
- **C++ 只写英文注释**（MSVC 按 GBK 读 UTF-8 中文 → C4819 → 失败）。
- **窗口形状变更必须由 Dart 发起**：原生 `WM_CLOSE` 只回传 `onPipExitRequested`/`onFullscreenExitRequested`。
- **改窗口前后必须摘视频纹理**：fvp 用 D3D11 共享纹理，出帧时改尺寸互等 → UI 线程死锁。`_withVideoDetached()`：换黑盒 → 等两帧 + 60ms → 调原生 → 250ms → 挂回。
- 单次 `SetWindowPos(... SWP_FRAMECHANGED|SWP_NOOWNERZORDER)`；日志 `zy_player_debug.log`。三模式：填满 / 原生全屏 / 画中画（`WS_POPUP`，拦 `WM_NCCALCSIZE`，别用 `WS_CAPTION`）。
- 无边框拖动/缩放走 `WM_NCLBUTTONDOWN`（**lParam 传真实屏幕坐标**）；热区须 `opaque`；最小 200x120。

## 工具环境坑
- Bash 里 `\` 会被转成 `/`（heredoc 也不行）：含反斜杠的脚本用 Write 落文件再 `python file.py`。
- Git Bash 把 `/S`、`/MIR` 当路径：加 `MSYS_NO_PATHCONV=1`。
- **Write 新建 `.bat`/`.ps1` 会存 UTF-16**，cmd 读不了：用 Python `encoding='gbk', newline=''`。
- `flutter pub get` 改 `analysis_options.yaml`、`flutter build` 改 `android/gradle.properties` —— 跑完都 `git checkout --`。
- **改完不要跑 `dart format`**（2026-11-25 实锤）：toolchain 的 Dart 3.8 新格式化器（pubspec `sdk: ^3.8.0`）按 tall style 重排整个文件，一次 format 能把 86 行改动炸成 360 行噪音 diff。手写代码照现有风格即可，`flutter analyze` 不查格式。
- Bash commit message 里带 `(...)` 走 `$(printf ...)` 会报 syntax error：**写 `.git/commitmsg.txt` 用 `git commit -F`**。
