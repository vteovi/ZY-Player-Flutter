# ZY Player（Flutter 版）

由 [ZY-Player-APP](https://github.com/Hunlongyu/ZY-Player-APP)（uni-app / Vue）重写的 Flutter 版本，
功能与数据结构与原版一一对应，同时把数据存储、网络层、播放器等全部换成 Flutter 生态的实现。

- 版本：1.18.1+193（Android：`pubspec.yaml` 与 `android/local.properties` 两处需同步；设置页显示的版本号由系统读取已安装包，无需手改）
- 包名：`com.zy.player`
- 支持平台：Android / iOS（Web 骨架同样生成，但视频播放以移动端为主）

## 功能

| 模块 | 说明 |
| --- | --- |
| 首页 | 搜索、视频源切换、分类切换、瀑布流、触底加载、返回顶部 |
| 详情 | 背景模糊海报、封面、收藏、选集播放、分享（复制播放地址） |
| 播放 | m3u8/HLS 播放、播放暂停、进度拖拽、全屏、选集、每 10 秒记录进度 |
| 收藏 | 收藏列表、跳转详情、单项删除 |
| 播放记录 | 显示观看进度百分比、从上次位置续播 |
| 源管理 | 视频源启用停用、置顶、从配置地址/文件导入（TVBox / ZYFun、多仓、导航页自动识别）、可用性检测（单条 / 全部）、一键停用失效源、清除死站、清空所有源 |
| 我 | 播放记录入口、源管理入口、清空记录/收藏、重置软件 |

## 与原版的对应关系

| 原项目（uni-app） | 本项目（Flutter） |
| --- | --- |
| `utils/database.js` | `lib/services/zy_database.dart`（SharedPreferences，键名规则 `ZY-{db}-DB` / `{db}-{key}` 完全保持） |
| `utils/request.js` | `lib/services/http_service.dart`（xml 源用 `xml` 包，json 源走 maccms 字段映射） |
| `utils/initSite.json` | `assets/data/init_site.json`（72 个内置源原样保留） |
| `utils/initSetting.json` | `assets/data/init_setting.json` |
| `pages/film/film.vue` | `lib/pages/film_page.dart` |
| `pages/detail/detail.vue` | `lib/pages/detail_page.dart` |
| `pages/play/play.vue` | `lib/pages/play_page.dart` |
| `pages/star/star.vue` | `lib/pages/star_page.dart` |
| `pages/history/history.vue` | `lib/pages/history_page.dart` |
| `pages/site/site.vue` | `lib/pages/site_page.dart` |
| `pages/me/me.vue` | `lib/pages/me_page.dart` |
| uView 组件库 | Material 3 原生组件 |
| `uni.setStorageSync` | `shared_preferences` |
| `uni-ajax` | `http` |
| `fast-xml-parser` | `xml` |
| `video` 组件 | `video_player`（Android 侧 ExoPlayer，原生支持 HLS） |

## 目录结构

```
lib/
  main.dart                 应用入口 / 主题
  models/                   site、video、detail、record、config 模型
  services/                 本地数据库、采集站请求
  providers/app_state.dart  全局状态（视频源 / 收藏 / 历史 / 配置）
  pages/                    首页、详情、播放、收藏、历史、源管理、我
  widgets/                  卡片、空态、加载遮罩、底部选择器
assets/data/                内置视频源与默认配置
tools/gen_scaffold.py       从 Flutter SDK 模板生成 android/ios/web 骨架的脚本
```

## 运行

```bash
flutter pub get
flutter run                  # 调试运行
flutter build apk --release  # 打 Android 包
flutter build ios --release  # 打 iOS 包（需 macOS + Xcode）
```

环境：Flutter 3.32.6 / Dart 3.8.1。

## 在 GitHub 上构建 APK（GitHub Actions）

云端构建由 `.github/workflows/build-apk.yml` 负责，不需要本地装 Flutter / JDK / Android SDK。

**方式一：手动触发**

仓库页面 → **Actions** → 左侧 **Build APK** → **Run workflow** → 选「打包方式」→ 运行。
首次约 15~25 分钟（之后命中 Gradle 缓存会快很多），跑完在该次运行页底部的 **Artifacts** 下载。

| 打包方式 | 产物 |
|---|---|
| `split`（默认，推荐） | arm64 / armv7 / x86_64 三个按 ABI 拆分的包 |
| `fat` | 三合一万能包（约 69 MB，一份装所有机型） |
| `both` | 两种都出，耗时约翻倍 |

**方式二：推 tag 自动构建并发布 Release**

```bash
git tag v1.17.0
git push origin v1.17.0
```

会构建拆分包，并把 APK 直接挂到该 tag 的 Release 上（Release 已存在则覆盖附件）。

**关于签名**

release 包用**正式的签名密钥库**，不再用 debug 签名。这样「本机出的包」「云端出的包」「以后换电脑出的包」签名完全一致，可以互相覆盖安装。

- 密钥库本体放在**仓库之外**：`C:\Users\Administrator\keystores\zy-player-release.jks`（alias `zyplayer`，RSA 2048，有效期 10000 天）。**绝不提交进仓库**（本仓库是公开的）。
- 证书指纹（换钥匙前请勿变更）：

  ```
  SHA-1:   BF:DE:D8:E2:9F:5D:86:62:4F:D0:06:45:79:D1:9A:8F:C6:53:F7:7A
  SHA-256: 31:25:52:85:3C:6D:D9:A0:A7:CE:CE:2F:43:F9:C1:B8:15:A9:35:EA:45:99:12:FB:5F:96:93:82:72:E8:B9:67
  ```

**本机构建**：Gradle 读 `android/key.properties`（已 gitignore）签名。换电脑时把密钥库和这个文件搬过去即可；文件不存在时自动退回 debug 签名。

```properties
storeFile=C:/Users/Administrator/keystores/zy-player-release.jks
storePassword=******
keyAlias=zyplayer
keyPassword=******
```

**云端构建**：配两个 Secret（仓库 → Settings → Secrets and variables → Actions）：

| Secret | 值 |
|---|---|
| `KEYSTORE_BASE64` | `base64 -w0 zy-player-release.jks` 的输出（PowerShell：`[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\Users\Administrator\keystores\zy-player-release.jks"))`） |
| `KEYSTORE_PASSWORD` | 密钥库口令 |

工作流会现场生成 `android/key.properties` 再构建，日志里会打印 SHA1 便于比对。两个 Secret 都不配时退回 debug 签名，并输出一条 warning。

> ⚠️ **签名一旦变更，所有已安装旧版（debug 签名）的用户必须卸载重装一次**，系统不允许签名不同的包互相覆盖。以后更换密钥库同理。
> 密钥库文件与口令务必备份两份以上（丢了就永远无法给老用户推送更新）。

> **注意**：Actions 页面只有代码已经 push 到 GitHub 之后才看得到这个工作流。

## 应用内版本更新

设置页 →「版本更新」会拉取远端清单 `update.json`，用**已安装包**的 `versionCode`
（原生 `PackageManager` 读取）与清单比较；有新版本时列出更新内容，可直接在应用内
下载并调起系统安装器。

清单就是仓库根目录的 `update.json`：

| 字段 | 说明 |
|---|---|
| `versionName` | 版本名，如 `1.18.0` |
| `versionCode` | 版本号，必须与 `pubspec.yaml` 里 `+` 后面的数字一致 |
| `apkUrl` | 安装包直链。默认指向 `releases/latest/download/ZY-Player-arm64-latest.apk`——CI 发版时会额外产出一份这个固定文件名的副本，所以这个地址**永远不用改** |
| `notes` | 更新说明，用 `\n` 换行 |
| `force` | `true` 时对话框不可取消（强制更新） |

默认清单地址是 `https://raw.githubusercontent.com/vteovi/ZY-Player-Flutter/main/update.json`。
仓库不公开、或直连 raw 不通时，在「检查更新失败」弹窗里点 **设置更新地址** 改成自己的地址即可
（保存在本地配置里，可随时恢复默认）。

**发版顺序（顺序很重要）**

1. 改 `pubspec.yaml` 版本号（`versionCode` 必须比上一版大）；
2. 打 tag 推送，让 Actions 出包并发 Release；
3. **Release 生成之后**，再把 `update.json` 的 `versionName` / `versionCode` / `notes` 改成新版本并 push。

第 3 步必须等 Release 存在——反过来先改清单，用户点更新会拿到 404。

> Android 8.0+ 首次安装需要允许「安装未知来源应用」，应用会引导到授权页。
> 云端包与本地包签名不一致时（一个 CI 构建、一个本机构建），系统会拒绝覆盖安装，需先卸载旧版——见上一节的签名配置。

## 实现说明

- **Android 明文流量**：采集站与视频地址大量使用 `http`，已在
  `android/app/src/main/AndroidManifest.xml` 打开 `usesCleartextTraffic` 并声明 `INTERNET` 权限；
  iOS 侧在 `ios/Runner/Info.plist` 放开了 ATS。
- **minSdk**：官方模板默认 21，本项目设为 24，避免 ExoPlayer / sqflite 等插件产生 manifest 冲突。
- **搜索性能**：原版搜索后会对每条结果再请求一次详情，本版直接用列表数据渲染，
  进入详情页时才拉取播放地址。
- **存储兼容**：沿用原版「key 列表 + 单条记录」的存储结构，升级安装不会丢数据（仅指同为 Flutter 版之间）。

## 视频源导入（TVBox / ZYFun）

入口：源管理页 →「导入视频源」，粘贴配置地址即可。地址不用写得很规范，以下都能识别：

- **缺协议头**：`box.example.com` → 自动补 `http://`；
- **缺 `//`**：`http:box.example.com` → 自动纠正为 `http://box.example.com`；
- **中文域名**：如 `http://www.饭太硬.cc/tv`，自动转成 punycode（`xn--...`）再请求。

支持的配置形态：

- **TVBox / ZYFun 的 JSON 配置**：标准 `{"sites":[...]}`、`tbl_site`、裸数组、JSONP 包装都能解析；
- **TVBox 加密配置**：很多大配置只放一个域名（如 `https://box.iqinu.com`），返回的是
  一大段十六进制文本（`$#key#$` + AES-128-CBC 密文）。本应用会自动解密后再解析，
  不依赖任何第三方加密库；
- **按 UA 分发的站点**：部分配置站只在 `okhttp/*` 的 User-Agent 下才返回真配置，
  浏览器 UA 只会拿到「站点创建成功」的占位页。配置请求会先按 TVBox 的 UA 拉取，
  拿不到再退回浏览器 UA；
- **TVBox spider 源**：本应用只支持 maccms json/xml 接口。`type` 为 3/4/7/15 的 spider 源会
  自动从 `ext.url`（对象或 JSON 字符串）里提取真实接口导入；没有真实接口的跳过
  （drpy 的 `.json` 脚本、多域名列表、加密串不算接口，会一并跳过，避免导入一堆坏源）；
- **多仓配置**：`{"urls":[{"url":"..."}]}` 会逐个拉取子配置并合并（最多 5 个）；
- **导航 / 分享网页**：如果地址返回的是 HTML（TVBox 导航页），会自动从页面里找
  `.json` / tvbox 配置链接并尝试导入；
- **直接粘贴 maccms 接口**：地址形如 `.../api.php/provide/vod/` 时，识别为单个源导入。

导入按 key 合并（同 key 更新、新 key 追加），不会清空已有源；同接口 / 同 key 的重复项会去重。
导入结束后会提示新增、更新、跳过的数量；失败时会显示具体原因（超时 / 403 / 配置加密等）。

> 实测：`https://box.iqinu.com` 解密后含 82 条站点记录，其中 41 条是可直接播放的
> maccms json 接口，另外 41 条是需要 spider 插件的源（本应用不支持，会跳过）。

## 设备同步（局域网）

通过局域网在两台设备之间同步视频源、App 配置、收藏与历史播放记录，**无需云端、无需账号**。
入口：设置页 → 「设备同步」。实现零额外依赖（基于 `dart:io` 的组播发现 + HTTP 传输），
Android 不需要额外权限；iOS 需要本地网络权限（已配置 `NSLocalNetworkUsageDescription`）。

### 使用步骤

1. **发送端（提供数据的一方）**：进入「设备同步」→ 「开启共享」标签页，勾选要共享的数据类别，
   点「开启共享」。此时本机会显示一个服务端口（默认 `9527`）并周期性在局域网内广播自身。
2. **接收端（获取数据的另一方）**：进入「设备同步」→ 「连接同步」标签页。
   - 若两台设备处于同一 Wi-Fi，接收端会自动发现发送端，在「局域网内发现的设备」列表中显示；
     **点击列表中任意一台设备，即可自动把它的 IP 地址和端口填入下方的输入框**（并高亮选中项）。
   - 若自动发现不到（部分手机 rom 会限制组播，或处于隔离网络），可在「或直接输入对方 IP 和端口」
     处手动填写发送端显示的 IP 和端口作为兜底。
3. 在接收端勾选要同步的数据类别，点「开始同步」即可拉取并合并到本机。
   合并按记录 key 做 upsert（同 key 覆盖、新 key 追加），不会清除本机已有数据；同步完立即生效。
   **排序也会一并同步**：同步过来的条目按发送端的顺序排在前面，接收端独有的条目保持在后面，
   因此发送端手动排好的视频源顺序、置顶、检测后重排的结果都会原样带过来。

### 注意事项

- **同步范围**：可单独勾选视频源 / App 配置 / 收藏 / 历史播放记录，默认全选。
- **源 key 一致性**：收藏与历史的记录 key 内含源 key。若两台设备的源 key 不同（各自安装时随机生成），
  同步过来的收藏在对方机器上可能匹配不到源。最省心的用法是**先同步一次「视频源」让两端源一致，再同步其它**。
- **发现不到时的兜底**：优先尝试手动输入对方 IP:端口，传输链路最稳；组播发现失败多为 rom 限制或网络隔离，
  并非功能损坏。
- **端口被占用**：若发送端提示「共享端口 9527 被占用」，关闭占用该端口的程序后重试。

## 关于项目骨架

本机的 `flutter` CLI 无法启动子进程（Dart 创建管道失败：`CreateFile failed 231`），
因此 `android/`、`ios/`、`web/` 及 `analysis_options.yaml` 等骨架文件由
`tools/gen_scaffold.py` 直接渲染 Flutter SDK 自带模板
（`C:\flutter\packages\flutter_tools\templates\app`）生成，变量取值与
`flutter create` 一致（AGP 8.7.3 / Kotlin 2.1.0 / Gradle 8.12）。
在正常环境里直接用 `flutter create` 重新生成也不会有差异。

代码已在同环境下用 analyzer 做过全量静态检查（18 个 Dart 文件，0 error / 0 warning），
但**尚未在真机或模拟器上运行过**，首次 `flutter run` 时请留意控制台输出。
