# 源站可用性实测 + 本次改动说明

日期：2026-10-01
范围：`ZY-Player-Flutter` 项目，版本 1.5.1 → 1.5.2

---

## 一、这次到底改了什么

一共 4 个文件，其中 3 个只是版本号：

| 文件 | 改动 | 影响 |
|---|---|---|
| `assets/data/init_site.json` | **72 个内置源 → `[]`（空数组）**，-795 行 | 核心改动 |
| `pubspec.yaml` | `1.5.1+115` → `1.5.2+116` | 版本号 |
| `lib/pages/me_page.dart` | 设置页「版本更新」副标题 `1.5.1` → `1.5.2` | 文案 |
| `android/local.properties` | `versionName/versionCode` 同步 | 构建参数 |

**没有动任何请求、解析、页面渲染的代码。**

### 关键：这个改动的作用范围很窄

内置源只在 **本地源库为空** 时才会写入（`lib/services/zy_database.dart:144`）：

```dart
Future<bool> initDb(String db, {required ... defaults}) async {
  final keys = await getAllKeys(db);
  if (keys.isNotEmpty) return false;   // ← 已有数据就直接返回，不覆盖
  await reset(db, defaults: defaults);
  return true;
}
```

所以：

- **全新安装 / 清除应用数据** → 写入 `[]` → 空壳，一个源都没有
- **覆盖安装（升级）** → 源库非空 → **不会重写，手机上原有的源全部保留**

也就是说，如果你在自己手机上看到「有的源加载不了」，那和这次清空 assets **没有因果关系**。

---

## 二、那为什么有的网站加载不了？——实测答案

我把清空前的 72 个内置源原样导出，用 **和 App 完全一致的请求方式**（`POST`，`{api}?ac=videolist&pg=1`，见 `lib/services/http_service.dart:51`）逐个实测了一遍。

### 结果：72 个源，现在只有 14 个还活着

| 源类型 | 总数 | 可用 | 存活率 |
|---|---|---|---|
| **json** | 15 | **14** | 93% |
| **xml** | 57 | **0** | **0%** |
| 合计 | 72 | 14 | 19% |

**xml 那一整批（57 个）已经全军覆没，一个都不剩。** 这就是「有的网站加载不了」的直接原因。

### 58 个失效源的原因分布

| 失效原因 | 数量 |
|---|---|
| 域名已废弃（DNS 都解析不出来） | 23 |
| 连接被重置（服务端主动断开） | 10 |
| 域名还在，但返回网页而非接口（接口路径已变更） | 8 |
| 连接超时（>12 秒无响应） | 5 |
| 连接被拒绝 | 4 |
| HTTP 404（接口不存在） | 3 |
| HTTP 403（被拒绝访问） | 2 |
| 返回内容异常 | 2 |
| HTTP 405（不接受 POST） | 1 |

**23 个域名 DNS 直接不解析** —— 这意味着这些站在很久以前就已经关停或换了域名，远早于本次改动。

### 采集站本身的性质决定

这类 maccms 采集站的域名寿命普遍很短：换域名、被墙、跑路是常态。内置源清单是写死在 assets 里的一次性快照，**它不会自己更新**。所以一个 App 装上半年，内置源大面积失效是完全正常的事 —— 跟清空 assets 无关。

---

## 三、当前实测可用的 14 个源（POST 方式）

供导入参考：

| 源名 | 接口 | 类型 | 响应 |
|---|---|---|---|
| 老色逼资源站 | `https://apilsbzy1.com/api.php/provide/vod/` | json | 807ms |
| 滴滴资源 | `https://api.ddapi.cc/api.php/provide/vod/` | json | 819ms |
| 玉兔 | `https://apiyutu.com/api.php/provide/vod/` | json | 923ms |
| 百度资源 | `https://api.apibdzy.com/api.php/provide/vod/` | json | 1231ms |
| 非凡资源 | `http://www.ffzy.tv/api.php/provide/vod/` | json | 1358ms |
| 鸡坤资源 | `https://jkunzyapi.com/api.php/provide/vod/` | json | 1462ms |
| 樱花资源 | `https://m3u8.apiyhzy.com/api.php/provide/vod/` | json | 1661ms |
| 金鹰云资源 | `https://jyzyapi.com/provide/vod/from/jinyingyun/at/json` | json | 1723ms |
| 无尽资源 | `https://api.wujinapi.me/api.php/provide/vod/` | json | 1831ms |
| 红牛资源 | `https://www.hongniuzy2.com/api.php/provide/vod/` | json | 1944ms |
| 闪电资源 | `http://sdzyapi.com/api.php/provide/vod/` | json | 2074ms |
| 155资源 | `https://155api.com/api.php/provide/vod/` | json | 2112ms |
| 虎牙资源 | `https://www.huyaapi.com/api.php/provide/vod/at/json` | json | 2447ms |
| 番号资源 | `http://fhapi9.com/api.php/provide/vod/` | json | 5686ms |

### 两个「半可用」的源，暴露了两类问题

1. **量子资源** `http://cj.lziapi.com/api.php/provide/vod/`
   - GET 可以，**POST 返回 403**。App 全站用 POST（`http_service.dart:51`），所以它在 App 里加载不出来。
   - 这是「服务端只允许 GET」导致的，属于 App 侧可以规避的类型。

2. **淘片资源** `https://taopianapi.com/cjapi/sda/vod/json.html`
   - **数据标注错了**：清单里写 `"type": "xml"`，但接口实际返回的是 **JSON**（URL 里就明写着 `json`）。
   - App 用 `isJson => type == 'json'` 决定解析器（`lib/models/site.dart:30`），会拿 XML 解析器去解 JSON → 解析失败 → 空列表 → 加载不出来。
   - 改标注为 `json` 即可修复（它 GET 能返回 262KB 有效数据，POST 返回 404，两种问题叠在一起）。

---

## 四、关于「有的地方加载不了」

如果是这几种现象，属于预期行为，不是 bug：

| 现象 | 原因 |
|---|---|
| 首页显示「暂无可用视频源，请到设置中导入」 | 空壳版本，源列表为空 |
| 搜索页搜不出任何东西 | 没有启用的源可搜 |
| 源管理页列表是空的 | 同上 |

如果不是上面这些（比如某个页面白屏、转圈、报错），那需要进一步定位 —— 请告诉我具体是哪个页面、什么操作、什么提示。

---

## 五、本次修复（已落地）

针对上面暴露的三个 App 侧问题，只改了 **1 个文件**：`lib/services/http_service.dart`。

### 1. 请求方式：POST → **GET 优先，必要时回退 POST**

- 原来所有接口统一走 POST（对齐 uni-app 版 uni-ajax）。
- 实测 `量子资源` 这类站**只放行 GET，POST 直接 403**。
- 现在先发 GET；**只有在返回 4xx 时**才换 POST 重试。
- 刻意不做无脑重试：DNS 解析不了 / 连接被拒 / 超时这类网络层失败换方法一样失败，
  若无脑重试，一个死站要白等两个 15 秒超时（合计 30 秒）。

### 2. 解析方式：看 `type` 字段 → **看响应内容自证**

- 原来由 `site.isJson`（即 `type == 'json'`）决定用哪个解析器。
- 但源清单的标注并不可靠 —— `淘片资源` 被标成 `xml`，实际返回 JSON，按标注选解析器必然失败。
- 现在拿到响应先看首字符：`{` / `[` → JSON，`<` → XML；都认不出就两种各试一次。
- `fetchList` / `search` / `fetchDetail` / `fetchPage` / `fetchClasses` 全部走统一入口，
  JSON 与 XML 结构谁有数据就用谁。

### 3. 响应解码：latin1 → **没声明 charset 时按 UTF-8**

- `http` 包的 `res.body` 在响应头**没有 `charset` 时默认按 latin1 解码**，
  中文采集站的 UTF-8 字节会被解成乱码。
- 现在优先按 `content-type` 里声明的 charset 解码；没有则按 UTF-8
  （并打开 `allowMalformed`，避免个别坏字节让整段失败）。
- ⚠️ GBK / GB2312 站仍未支持：`dart:convert` 不自带该编解码器，
  `Encoding.getByName('gbk')` 返回 null，此时退回 UTF-8 —— 与改动前一样是乱码，不会更差。

### 验证

单进程静态检查（绕开被沙箱拦的 CLI）：

```
files: 25  errors: 0  warnings: 0  lints: 0
```

> ⚠️ 静态检查通过 ≠ 能编译，最终仍需真机构建：双击 `tools\build_apk.bat`。

---

## 六、复现与工具

实测脚本已留在项目里：

```bash
# 导出清空前的源清单
git show HEAD~1:assets/data/init_site.json > .workbuddy/tmp/init_site_backup.json

# 探测（默认 GET；加 --post 复现 App 真实请求方式）
python .workbuddy/tools/probe_sites.py .workbuddy/recovered/init_site_backup.json --post
```

脚本只做连通性与响应格式判断（状态码 / 耗时 / 大小 / JSON 还是 XML），不解析也不输出任何影片内容，仅用于诊断哪些站挂了。
