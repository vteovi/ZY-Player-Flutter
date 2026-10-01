"""对 api 自带 ?ac=list 的源，验证「旧拼接 vs 新合并」拿到的字段完整度。

判定标准（比 HTTP 200 更有意义）：
- 响应里是否含 "vod_pic"      -> 有封面
- 响应里是否含 "vod_play_url" -> 详情页能拿到播放地址

用法: python verify_fields.py <zyfun_config.json>
"""
import json
import ssl
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

UA = ("Mozilla/5.0 (Linux; Android 12; Mobile) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36")
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def get(url, tries=2):
    last = ""
    for _ in range(tries):
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
        try:
            with urllib.request.urlopen(req, timeout=15, context=CTX) as r:
                return r.read().decode("utf-8", "replace"), ""
        except Exception as e:
            last = str(e)
    return "", last


def mark(body, err):
    if err:
        if "getaddrinfo" in err:
            return "-", "DNS 解析失败"
        if "timed out" in err:
            return "-", "超时"
        if "10054" in err:
            return "-", "连接被重置"
        return "-", err[:24]
    if body.lstrip().startswith("<"):
        return "-", "返回网页(接口已变更)"
    if '"vod_pic"' in body:
        return "Y", "%d B" % len(body)
    return "N", "%d B 无封面字段" % len(body)


def job(item):
    api = item["api"]
    name = item["name"]
    old = "%s?ac=videolist&pg=1" % api
    new = "%s?ac=videolist&pg=1" % api.split("?")[0]
    bo, eo = get(old)
    bn, en = get(new)
    return name, mark(bo, eo), mark(bn, en)


def main():
    items = json.load(open(sys.argv[1], encoding="utf-8"))
    if isinstance(items, dict):
        items = items.get("tbl_site") or []
    sub = [x for x in items if "?" in (x.get("api") or "")]
    print("api 自带查询串的源: %d 个 —— 检查响应是否含 vod_pic（封面字段）\n" % len(sub))
    with ThreadPoolExecutor(max_workers=5) as ex:
        rows = list(ex.map(job, sub))
    print("%-12s %-22s %-22s %s" % ("源", "旧(字符串拼接)", "新(Uri 合并)", "结论"))
    print("-" * 84)
    better = worse = 0
    for name, (so, do), (sn, dn) in rows:
        if so == "N" and sn == "Y":
            verdict = "修复：旧无封面 -> 新有封面"
            better += 1
        elif so == "Y" and sn == "Y":
            verdict = "两种都完整（仍应合并以免歧义）"
        elif so == "-" and sn == "-":
            verdict = "双方都连不上，与本次修复无关"
        elif so == "-" and sn == "Y":
            verdict = "修复：旧不可用 -> 新可用"
            better += 1
        elif so == "Y" and sn == "N":
            verdict = "!! 变差了，需复查"
            worse += 1
        else:
            verdict = "未定性"
        print("%-12s %-4s %-16s %-4s %-16s %s" % (
            name, so, do, sn, dn, verdict))
    print("-" * 84)
    print("因参数合并而改善: %d 个；变差: %d 个" % (better, worse))


if __name__ == "__main__":
    main()
