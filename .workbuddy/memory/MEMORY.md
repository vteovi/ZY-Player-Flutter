# 项目长期记忆：ZY Player Flutter
uni-app ZY-Player-APP 的 Flutter 重写（首页/详情/播放/收藏/历史/源管理/设置），只认 maccms json/xml 采集站。provider + ChangeNotifier（全局 `AppState`）；shared_preferences（键 `ZY-{db}-DB`）；包名 `com.zy.player`，minSdk 24 / targetSdk 35。历史细节见同目录日记。

## ⚠️ 协作纪律（勿破）
1. 本机无常规 Flutter（`C:\flutter` 已删），构建走 GitHub Actions。默认只 commit；**push / 发布必须用户明确要求**。git 前 `export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"`。
2. push 前 `unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY`（代理会 502/000）。主站不通走 SSH 443，fetch 也要带同一 sshCommand：
   `git -c core.sshCommand="ssh -p 443 -o StrictHostKeyChecking=no" push ssh://git@ssh.github.com:443/vteovi/ZY-Player-Flutter.git main vX.Y.Z`
   403 先 `git remote -v` 查 `~/.gitconfig` 的 insteadOf 镜像改写；**别用 API 推 ref**（422）。
3. 改完必须静态校验：便携 toolchain `/c/Users/Administrator/Doubao/chats/2026-11-21/new-chat/.toolchain/flutter/bin`，`flutter analyze --no-fatal-infos --no-fatal-warnings lib`，跑完 `git checkout -- analysis_options.yaml`（pub get/build 还会改 gradle.properties）。基线 **0 error / 0 warning / 31 info**。不要跑 `dart format`（Dart 3.8 tall style 会把 diff 炸开）。
4. 每个进 APK 的提交都升版本：feat→MINOR、fix→PATCH，versionCode +1；同步 `pubspec.yaml` + `android/local.properties`（gitignore）+ `更新记录.MD`（倒序、一句人话、头部当前版本）+ 发版后 `update.json`。
5. 分支：`main` 稳定、`dev` 开发，新功能只在 dev。合回 `git checkout main && git fetch && git reset --hard origin/main && git merge --no-ff dev`。只有 `v*` tag 发 Release。中文 commit 消息写 `.git/commitmsg.txt` + `git commit -F`。

## 构建与发版
- Actions `Build APK + Windows`：tag 触发出 Release，手动跑只出 Artifacts。顺序：tag → CI 出 Release → **Release 存在后**才改 `update.json` → push → 清 CDN → 验镜像 → 切 dev `git checkout main -- update.json`。
- Release 正文由 `tools/release-notes.sh <版本> <输出> [根目录]` 从 `更新记录.MD` 截取 + 下载表 + 可点击链接（指向 tag）；补写用 `.github/workflows/sync-release-notes.yml`。**Release 404 先查 `releases?per_page=3`**，可能是用户手动删了（踩过 6 次白排查）。
- ABI 必须 `--split-per-abi`（arm64 约 18MB）；签名库在仓库外 `C:\Users\Administrator\keystores\zy-player-release.jks`（alias zyplayer），CI 用 Secret；**keystore 绝不能入库**（仓库 public），换签名后老用户须卸载重装，写进每次更新说明。
- CI ubuntu-24.04，checkout@v7 / setup-java@v6 / cache@v6 / upload-artifact@v7，产物收集 `tools/ci-collect-apk.sh`。Windows 本地 NDK 27.0.12077973。APK 直连本机常年 000，验镜像 Range 206。

## 应用内更新（勿回退）
- 拉 `update.json` → 用**已装包** versionCode（PackageManager）比对 → 弹窗 → 下载 → FileProvider 安装。只比数字，退化按版本名逐段比（不能比字符串）。安装要件：`REQUEST_INSTALL_PACKAGES` + `androidx.core:core` + `<provider ${applicationId}.fileprovider>` + `file_paths.xml`，必须 `content://`；对话框 `PopScope(canPop:false)`。
- 多镜像并发竞速（raw / ghproxy.net / gh-proxy.com / ghfast.top / jsDelivr），**收齐所有 200 后取最大 versionCode**（jsDelivr 会返 200 旧内容）；purge 后必须复查，常要 3~7 次。清 jsDelivr 缓存要带代理，其余 git 操作要 unset 代理。

## 视频源（勿回退）
- `Site.api` 须真实 URL；身份用 `key`（`Site.id` 只是装饰）；`_mapType` 0=xml / 1=json；type 3/4/7/15 从 ext.url 提真实端点，无端点跳过；默认源 `assets/data/init_site.json`（22 个）仅空库种子，按 key upsert。地址一律 `HttpService._apiUrl()`；按首字符判 JSON/XML；先 GET 仅 4xx 回退 POST；播放器 UA 用 `_kPlayerHeaders`。
- 配置导入支持 JSONP / `{"urls":[...]}`（≤5）/ 导航页 tvbox 链接（≤6、总 25s）/ 直接接口，api+key 去重。TVBox 加密配置只在 okhttp UA 下给真配置，`$#key#$` + AES-128-CBC + 13B IV，`utils/tvbox_crypto.dart` 纯 Dart 解密（不引 pointycastle）。
- **多线路**：`vod_play_from` / `vod_play_url` 按 `$$$` 顺序配对（`_mapPlayLines`），`VideoDetail.lines` 唯一真源，`m3u8List` 是 `lines.first.items` getter；详情页 `_selectLine` 不重请求，播放页 `_switchLine` 按集名对齐、用 `widget.url` 反查线路。绝不退回 firstWhere。
- 详情页滑动切线路：内容区 `GestureDetector(onHorizontalDrag*)`，48px 或 320px/s，左滑下一条；chip 挂 GlobalKey，切换后 postFrame `Scrollable.ensureVisible(alignment:.5)` 横纵都拉回；<2 条不挂手势。
- 手动添加/编辑：`site_edit_page.dart`，长按源卡片菜单；编辑沿用原 key，删源不删记录。
- **checkSite 防误判**：`checkSite(site,{retry:true})` 拆出 `_checkSiteOnce`，fail 自动重试一次（错峰 300~700ms、二次 9s），ok/warn 一次返回。批量 8 并发下瞬超时/5xx/限流常见，旧逻辑一次 fail 就停用有效源。检测中途只更新 chip，结尾统一启停重排。
- **导入要有始有终**：选完文件立刻 `showDialog`（不可取消）→ `_ImportProgressDialog`（读文件→解析→写库 N/M→结果淡入），0.8/2.4s 自动关；`importSitesFromContent` 带 onProgress + 每 12 条 16ms 让出事件循环。

## UI（勿回退）
- 加载一律骨架屏，禁灰黑遮罩；刷新不抹内容，顶部 2px 进度；换源不重置 `_classes`。
- 深色纯黑 OLED `#000000` / `#0D0D0D`，层级靠 1px `0x24FFFFFF` 描边；`colorScheme.surface` 压纯黑；`bottomNavigationBarTheme.type: fixed`。
- 卡片模式单枚举 `ViewMode{portrait,landscape,waterfall}`（parse 兼容老存档）；入口设置页 + 首页顶栏（点按循环、长按菜单，共用 `widgets/view_mode_picker.dart`）。瀑布流 `SliverMasonryGrid`，列数 `<600→2` 否则 `(w/190).floor().clamp(2,8)`；比例 `utils/poster_ratio.dart` 只读图片头 64KB，三级缓存，缺省 2/3。
- 首页分类不屏蔽名字，只按 tid 去重；片单 `list_cache.dart` 缓存秒出 + 静默刷新；封面预取 6，memCacheWidth 480 / 600。
- 收藏/历史：`mergeRecords` 决定 4 项或 3 项 + TabBar；`MainPage` 用逻辑槽位 `_slotOf()/_indexOf()`；记录 key `{siteKey}-{videoId}` 用 `resolveRecordKey()`，绝不 split('-')。
- 输入框一律 `TextInputType.text`（url 类型触发国产输入法安全键盘）。
- 大屏 ≥600 搜索并入 AppBar；播放页宽≥840 且横向时右栏 min(30%,420)≥300；播放页单个「画面」按钮 + `_screenPanelOpen`（别拆回两个），进度条独占行、自绘 `_ProgressSlider`、倍速 0.5~3.0 八档、控制层 4s 隐藏、收藏按钮只在 `!_fullscreen || _landscapeNow`。
- 设置页六组卡片，桌面限宽 720；导入导出在源管理菜单。
- **批量写/删库报进度 + 让出事件循环**：Windows 每次 `setString/remove` 整份同步写盘会卡 UI；`removeMany` 带 onProgress（12 条 / 24ms），界面显示「清除中 3/12」+ 2px 条。

## 其他坑
- Flutter 命中测试：触点在父节点外整棵子树不命中。不满一屏翻页靠 `CategoryTabState._maybeContinueLoad()`。详情 `fetchDetail` 只对瞬时错误重试 2 次，EmptyHint 显示原因。
- 原生通道 `com.zy.player/system`（`/pip`、`/window`）两端同步改；备份 `data_backup.dart`（saveFile bytes 必填）；青少年模式已移除。
- Windows：C++ 只写英文注释（MSVC GBK 读 UTF-8 → C4819）；窗口形状变更由 Dart 发起，改窗口前后 `_withVideoDetached()` 摘 fvp D3D11 纹理否则死锁；三模式填满/原生全屏/PiP（`WS_POPUP` + 拦 `WM_NCCALCSIZE`）；拖动 `WM_NCLBUTTONDOWN` lParam 传屏幕坐标；最小 200x120。
- Bash heredoc 中反斜杠会被转义：脚本用 Write 落文件；Git Bash `/S` 加 `MSYS_NO_PATHCONV=1`；`.bat/.ps1` 用 Python gbk 写。
