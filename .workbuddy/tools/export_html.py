"""把 WorkBuddy 会话 jsonl 导出为带侧边目录的可读 HTML。
用法: python export_html.py <in.jsonl> <out.html> [max_tool_output_chars]
"""
import json, sys, os, html
from datetime import datetime

src = sys.argv[1]
dst = sys.argv[2]
MAXOUT = int(sys.argv[3]) if len(sys.argv) > 3 else 2000

import re

WRAPPERS = [
    r"<system-reminder[\s\S]*?</system-reminder>",
    r"<task-notification[\s\S]*?</task-notification>",
    r"<cb_summary>[\s\S]*?</cb_summary>",
    r"<conversation_history_summary>[\s\S]*?</conversation_history_summary>",
    r"<artifacts[\s\S]*?</artifacts>",
]


def ts2str(ts):
    try:
        return datetime.fromtimestamp(int(ts) / 1000).strftime("%m-%d %H:%M")
    except Exception:
        return ""


def clean_user(text):
    for w in WRAPPERS:
        text = re.sub(w, "", text)
    m = re.search(r"<user_query>([\s\S]*?)</user_query>", text)
    if m:
        text = m.group(1)
    return text.strip()


def content_text(content, kind):
    if isinstance(content, str):
        return content
    out = []
    if isinstance(content, list):
        for p in content:
            if isinstance(p, dict):
                t = p.get("type")
                if kind == "user" and t in ("input_text", "text"):
                    out.append(p.get("text", ""))
                elif kind == "assistant" and t in ("output_text", "text"):
                    out.append(p.get("text", ""))
    return "".join(out)


entries = []
with open(src, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        t = obj.get("type")
        if t == "message":
            role = obj.get("role")
            if role not in ("user", "assistant"):
                continue
            txt = content_text(obj.get("content"), role)
            if role == "user":
                txt = clean_user(txt)
                if not txt:
                    continue
                if txt.startswith("Use the TaskOutput tool") or txt.startswith("Use the Bash"):
                    continue
                if "<conversation_history_summary>" in txt or txt.startswith("Summary of the conversation"):
                    txt = "(此处为上下文压缩摘要)"
            else:
                txt = txt.strip()
                if not txt:
                    continue
            entries.append(("msg", obj.get("timestamp"), role, txt))
        elif t == "function_call":
            disp = (obj.get("providerData") or {}).get("argumentsDisplayText")
            if not disp:
                try:
                    a = json.loads(obj.get("arguments") or "{}")
                    disp = " ".join("%s=%s" % (k, str(v)[:200]) for k, v in list(a.items())[:4]) if isinstance(a, dict) else str(a)
                except Exception:
                    disp = str(obj.get("arguments"))
            entries.append(("call", obj.get("timestamp"), obj.get("name", "?"), (disp or "").strip()))
        elif t == "function_call_result":
            out = obj.get("output")
            txt = out.get("text") if isinstance(out, dict) else str(out or "")
            entries.append(("result", obj.get("timestamp"), obj.get("name", "?"), txt or ""))

E = html.escape
body = []
toc = []
uidx = 0
open_details = False

for kind, ts, who, text in entries:
    when = ts2str(ts)
    if kind == "msg":
        if open_details:
            body.append("</details>")
            open_details = False
        if who == "user":
            uidx += 1
            toc.append((uidx, when, text))
            body.append(
                '<div class="u" id="u%d"><div class="hd"><span class="badge bu">用户</span><span class="t">%s</span></div>'
                '<div class="tx">%s</div></div>' % (uidx, when, E(text).replace("\n", "<br>"))
            )
        else:
            body.append(
                '<div class="a"><div class="hd"><span class="badge ba">助手</span><span class="t">%s</span></div>'
                '<div class="tx">%s</div></div>' % (when, E(text).replace("\n", "<br>"))
            )
    elif kind == "call":
        if open_details:
            body.append("</details>")
        body.append(
            '<details class="tool"><summary><span class="badge bt">%s</span><code>%s</code></summary>' % (E(who), E(text.replace("\n", " ")[:300]))
        )
        open_details = True
    elif kind == "result":
        b = text.strip()
        tr = len(b) > MAXOUT
        if tr:
            b = b[:MAXOUT]
        body.append('<pre class="out">%s%s</pre>' % (E(b), "\n... [输出已截断]" if tr else ""))
if open_details:
    body.append("</details>")

toc_html = "\n".join(
    '<a href="#u%d" title="%s"><span class="n">%d</span>%s</a>' % (i, E(t.replace('"', "")), i, E(t.replace("\n", " ")[:60]))
    for i, w, t in toc
)

doc = """<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
<title>ZY-Player-Flutter 历史对话存档</title>
<style>
*{box-sizing:border-box}
body{margin:0;font:14px/1.7 -apple-system,"Segoe UI","Microsoft YaHei",sans-serif;background:#f7f8fa;color:#1f2328}
#side{position:fixed;left:0;top:0;bottom:0;width:320px;overflow:auto;background:#fff;border-right:1px solid #e5e7eb;padding:16px 12px}
#side h1{font-size:15px;margin:0 0 4px}
#side .meta{font-size:12px;color:#6b7280;margin-bottom:12px;line-height:1.6}
#side a{display:block;padding:5px 8px;border-radius:6px;color:#374151;text-decoration:none;font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#side a:hover{background:#f3f4f6}
#side a .n{display:inline-block;min-width:26px;color:#9ca3af}
#main{margin-left:320px;padding:24px 28px 80px;max-width:1000px}
.hd{margin-bottom:6px}
.badge{display:inline-block;font-size:11px;padding:1px 7px;border-radius:10px;margin-right:8px;vertical-align:1px}
.bu{background:#fee2e2;color:#b91c1c}.ba{background:#dbeafe;color:#1d4ed8}.bt{background:#ede9fe;color:#6d28d9}
.t{font-size:11.5px;color:#9ca3af}
.u,.a{background:#fff;border:1px solid #e5e7eb;border-radius:10px;padding:12px 14px;margin:14px 0}
.u{border-left:3px solid #ef4444}
.a{border-left:3px solid #3b82f6;background:#fbfdff}
.tx{white-space:normal;word-break:break-word}
details.tool{margin:8px 0 8px 18px;background:#fafafa;border:1px dashed #d1d5db;border-radius:8px}
details.tool summary{cursor:pointer;padding:7px 10px;font-size:12.5px}
details.tool summary code{color:#4b5563;word-break:break-all}
pre.out{margin:0 0 10px 18px;padding:10px 12px;background:#f3f4f6;border-radius:8px;overflow:auto;max-height:420px;font:12px/1.6 Consolas,Menlo,monospace;color:#374151;white-space:pre-wrap}
h2.sec{font-size:13px;color:#6b7280;font-weight:600;margin:28px 0 0}
</style></head><body>
<div id="side"><h1>历史对话存档</h1>
<div class="meta">会话 %s<br>用户发言 %d 条 / 共 %d 条记录<br>%s ~ %s</div>
%s</div>
<div id="main">%s</div></body></html>
""" % (
    os.path.basename(src).replace(".jsonl", "")[:8],
    len(toc),
    len(entries),
    ts2str(entries[0][1]) if entries else "",
    ts2str(entries[-1][1]) if entries else "",
    toc_html,
    "\n".join(body),
)

os.makedirs(os.path.dirname(dst), exist_ok=True)
with open(dst, "w", encoding="utf-8") as f:
    f.write(doc)
print("written:", dst, os.path.getsize(dst), "bytes; entries:", len(entries), "user:", len(toc))
