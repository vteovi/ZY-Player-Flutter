# ZY Player（Flutter 版）

由 [ZY-Player-APP](https://github.com/Hunlongyu/ZY-Player-APP)（uni-app / Vue）重写的 Flutter 版本，
功能与数据结构与原版一一对应，同时把数据存储、网络层、播放器等全部换成 Flutter 生态的实现。

- 版本：1.7.13+144（Android，`pubspec.yaml` / `lib/pages/me_page.dart` / `android/local.properties` 三处需同步）
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
| 源管理 | 视频源启用停用、置顶、从 JSON 地址/文件导入、可用性检测（单条 / 全部）、一键停用失效源、清除死站、清空所有源 |
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

## 实现说明

- **Android 明文流量**：采集站与视频地址大量使用 `http`，已在
  `android/app/src/main/AndroidManifest.xml` 打开 `usesCleartextTraffic` 并声明 `INTERNET` 权限；
  iOS 侧在 `ios/Runner/Info.plist` 放开了 ATS。
- **minSdk**：官方模板默认 21，本项目设为 24，避免 ExoPlayer / sqflite 等插件产生 manifest 冲突。
- **搜索性能**：原版搜索后会对每条结果再请求一次详情，本版直接用列表数据渲染，
  进入详情页时才拉取播放地址。
- **存储兼容**：沿用原版「key 列表 + 单条记录」的存储结构，升级安装不会丢数据（仅指同为 Flutter 版之间）。

## 关于项目骨架

本机的 `flutter` CLI 无法启动子进程（Dart 创建管道失败：`CreateFile failed 231`），
因此 `android/`、`ios/`、`web/` 及 `analysis_options.yaml` 等骨架文件由
`tools/gen_scaffold.py` 直接渲染 Flutter SDK 自带模板
（`C:\flutter\packages\flutter_tools\templates\app`）生成，变量取值与
`flutter create` 一致（AGP 8.7.3 / Kotlin 2.1.0 / Gradle 8.12）。
在正常环境里直接用 `flutter create` 重新生成也不会有差异。

代码已在同环境下用 analyzer 做过全量静态检查（18 个 Dart 文件，0 error / 0 warning），
但**尚未在真机或模拟器上运行过**，首次 `flutter run` 时请留意控制台输出。
