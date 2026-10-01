"""诊断单个采集站：打印响应正文开头，判断接口是否已变更/字段是否齐全。

用法:
  python compare_body.py                                   # 用默认示例
  python compare_body.py "百度资源" "https://api.apibdzy.com/api.php/provide/vod/"
  python compare_body.py --merge "名称" "https://x/api.php/provide/vod/?ac=list"
      # --merge 会同时打印「旧字符串拼接」与「新 Uri 合并」两种 URL 的结果对比
"""
import ssl
import sys
import urllib.request

UA = ("Mozilla/5.0 (Linux; Android 12; Mobile) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36")
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    try:
        with urllib.request.urlopen(req, timeout=15, context=CTX) as r:
            return r.read().decode("utf-8", "replace")
    except Exception as e:
        return "<ERR %s>" % e


def show(label, url):
    body = get(url)
    print("  %s: %s" % (label, url))
    print("    长度 %d，含 vod_pic: %s，含 vod_play_url: %s"
          % (len(body), '"vod_pic"' in body, '"vod_play_url"' in body))
    print("    开头 240 字符: " + body[:240].replace("\n", " "))


def main():
    args = [a for a in sys.argv[1:] if a != "--merge"]
    merge = "--merge" in sys.argv
    if len(args) >= 2:
        name, api = args[0], args[1]
    else:
        name, api = "示例", "https://api.apibdzy.com/api.php/provide/vod/?ac=list"
    print("=" * 78)
    print("源:", name)
    if merge:
        # 旧：字符串拼接（api 自带 ?ac=list 时会拼坏）
        show("旧拼接", "%s?ac=videolist&pg=1" % api)
        # 新：Uri 合并参数（等价于 _apiUrl 的结果）
        show("新合并", "%s?ac=videolist&pg=1" % api.split("?")[0])
    else:
        show("请求", "%s?ac=videolist&pg=1" % api)


if __name__ == "__main__":
    main()
