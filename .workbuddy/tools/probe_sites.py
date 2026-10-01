# -*- coding: utf-8 -*-
"""探测内置源清单里每个采集站当前是否可用。

只做连通性与响应格式判断（状态码 / 耗时 / 大小 / 是 JSON 还是 XML），
不解析、不打印任何片名或内容，仅用于诊断「哪些站挂了」。

用法：
  python probe_sites.py <init_site.json> [--json-out out.json]
"""
import json
import ssl
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ssl_ctx = ssl.create_default_context()
ssl_ctx.check_hostname = False
ssl_ctx.verify_mode = ssl.CERT_NONE

UA = ("Mozilla/5.0 (Linux; Android 13; SM-S9110) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36")

# App 内 http_service.dart 的 _post() 统一用 POST，加 --post 可复现真实请求
METHOD = "GET"


def classify(head: bytes):
    """判断响应首部属于哪种格式，以及是否像有效的 maccms 列表。"""
    s = head.lstrip()[:400].lower()
    if not s:
        return "EMPTY", False
    if s.startswith(b"{") or s.startswith(b"["):
        return "JSON", b'"list"' in head[:5000].lower() or b'"vod_' in head[:5000].lower()
    if s.startswith(b"<?xml") or s.startswith(b"<rss"):
        return "XML", b"<video" in head[:20000].lower() or b"<list" in head[:20000].lower()
    if s.startswith(b"<!doctype") or s.startswith(b"<html"):
        return "HTML", False
    return "OTHER", False


def type_label(t):
    """type 可能是数字（zyfun 导出是 1/0）或字符串（内置清单是 json/xml）。"""
    if isinstance(t, (int, float)):
        return {0: "xml", 1: "json"}.get(int(t), str(int(t)))
    return str(t)


def probe(item):
    name = item.get("name", "?")
    typ = item.get("type", "?")
    api = (item.get("api") or "").strip()
    if not api:
        return dict(name=name, type=typ, api=api, status="NOAPI", ms=0,
                    size=0, fmt="-", ok=False, note="接口为空")
    # 与 App 内一致：HttpService._apiUrl() 会**合并**参数，同名以调用方为准。
    # 所以 api 自带 ?ac=list 时要替换掉，不能简单追加（否则 maccms 只认第一个 ac）。
    if "?" in api:
        head, _, _ = api.partition("?")
        url = head + "?ac=videolist&pg=1"
    else:
        url = api + "?ac=videolist&pg=1"
    req = urllib.request.Request(
        url,
        data=b"" if METHOD == "POST" else None,
        headers={
            "User-Agent": UA,
            "Accept": "*/*",
            "Accept-Language": "zh-CN,zh;q=0.9",
        },
        method=METHOD,
    )
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=12, context=ssl_ctx) as r:
            body = r.read(300000)
            ms = int((time.time() - t0) * 1000)
            fmt, has_list = classify(body)
            return dict(name=name, type=typ, api=api, status=r.status, ms=ms,
                        size=len(body), fmt=fmt, ok=has_list,
                        note="" if has_list else "响应里没有片单")
    except urllib.error.HTTPError as e:
        ms = int((time.time() - t0) * 1000)
        return dict(name=name, type=typ, api=api, status=e.code, ms=ms,
                    size=0, fmt="-", ok=False, note="HTTP %s" % e.code)
    except Exception as e:  # noqa: BLE001
        ms = int((time.time() - t0) * 1000)
        msg = str(e)
        if len(msg) > 60:
            msg = msg[:60]
        return dict(name=name, type=typ, api=api, status="ERR", ms=ms,
                    size=0, fmt="-", ok=False, note=type(e).__name__ + ": " + msg)


def main():
    global METHOD
    src = sys.argv[1]
    if "--post" in sys.argv:
        METHOD = "POST"
    items = json.load(open(src, encoding="utf-8"))
    if isinstance(items, dict):  # 也接受 zyfun 的 {"tbl_site":[...]} 整体文件
        items = items.get("tbl_site") or items.get("sites") or []
    print("共 %d 个源，请求方式 %s，并发探测中...\n" % (len(items), METHOD))
    with ThreadPoolExecutor(max_workers=16) as ex:
        results = list(ex.map(probe, items))

    ok = [r for r in results if r["ok"]]
    bad = [r for r in results if not r["ok"]]

    def line(r):
        return "%-16s %-5s %-6s %5sms %8sB %-5s %s" % (
            r["name"][:16], type_label(r["type"]), r["status"], r["ms"],
            r["size"], r["fmt"], r["note"])

    print("=" * 78)
    print("【可用】%d 个" % len(ok))
    print("=" * 78)
    for r in sorted(ok, key=lambda x: x["ms"]):
        print("  " + line(r))

    print()
    print("=" * 78)
    print("【不可用】%d 个" % len(bad))
    print("=" * 78)
    for r in sorted(bad, key=lambda x: str(x["status"])):
        print("  " + line(r))

    # 类型标注与实际返回格式是否一致
    print()
    print("=" * 78)
    print("【类型标注 vs 实际返回】")
    print("=" * 78)
    for r in results:
        if r["ok"] and r["fmt"] != "-" and r["fmt"].upper() != type_label(r["type"]).upper():
            print("  ⚠ %-16s 标注=%-5s 实际=%-5s (解析器可能不认)" %
                  (r["name"][:16], type_label(r["type"]), r["fmt"]))

    print()
    print("汇总: 可用 %d / 不可用 %d / 总计 %d" % (len(ok), len(bad), len(results)))

    if "--json-out" in sys.argv:
        out = sys.argv[sys.argv.index("--json-out") + 1]
        json.dump(results, open(out, "w", encoding="utf-8"),
                  ensure_ascii=False, indent=1)
        print("明细已写入 " + out)


if __name__ == "__main__":
    main()
