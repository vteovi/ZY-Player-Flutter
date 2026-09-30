"""把 WorkBuddy 会话 jsonl 导出为可读的 Markdown 存档。
用法: python export_chat.py <in.jsonl> <out.md> [max_tool_output_chars]
"""
import json, sys, re, os
from datetime import datetime

src = sys.argv[1]
dst = sys.argv[2]
MAXOUT = int(sys.argv[3]) if len(sys.argv) > 3 else 1500

WRAPPERS = [
    r"<system-reminder[\s\S]*?</system-reminder>",
    r"<task-notification[\s\S]*?</task-notification>",
    r"<cb_summary>[\s\S]*?</cb_summary>",
    r"<conversation_history_summary>[\s\S]*?</conversation_history_summary>",
    r"<artifacts[\s\S]*?</artifacts>",
    r"< Idealine[\s\S]*?</ Idealine>",
]


def ts2str(ts):
    try:
        return datetime.fromtimestamp(int(ts) / 1000).strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return ""


def clean_user(text):
    for w in WRAPPERS:
        text = re.sub(w, "", text)
    m = re.search(r"<user_query>([\s\S]*?)</user_query>", text)
    if m:
        text = m.group(1)
    text = re.sub(r"</?user_query>", "", text)
    return text.strip()


def content_text(content, kind):
    if isinstance(content, str):
        return content
    out = []
    if isinstance(content, list):
        for p in content:
            if not isinstance(p, dict):
                out.append(str(p))
                continue
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
                    txt = "（此处为上下文压缩摘要，原始内容已由系统省略）"
            else:
                txt = txt.strip()
                if not txt:
                    continue
            entries.append(("msg", obj.get("timestamp"), role, txt))
        elif t == "function_call":
            name = obj.get("name", "?")
            args = obj.get("arguments")
            disp = (obj.get("providerData") or {}).get("argumentsDisplayText")
            if not disp:
                try:
                    a = json.loads(args) if isinstance(args, str) else (args or {})
                    if isinstance(a, dict):
                        disp = " ".join(
                            "%s=%s" % (k, str(v)[:200])
                            for k, v in list(a.items())[:4]
                        )
                    else:
                        disp = str(a)
                except Exception:
                    disp = str(args)
            entries.append(("call", obj.get("timestamp"), name, (disp or "").strip()))
        elif t == "function_call_result":
            out = obj.get("output")
            if isinstance(out, dict):
                txt = out.get("text") or out.get("output") or json.dumps(out, ensure_ascii=False)
            else:
                txt = str(out or "")
            entries.append(("result", obj.get("timestamp"), obj.get("name", "?"), txt))

lines = []
lines.append("# ZY-Player-Flutter 历史对话存档\n")
lines.append("- 源文件：`%s`" % os.path.basename(src))
lines.append("- 会话 ID：`%s`" % os.path.basename(src).replace(".jsonl", ""))
lines.append("- 条目数：%d（用户/助手消息 + 工具调用及结果）" % len(entries))
if entries:
    lines.append("- 时间范围：%s ~ %s" % (ts2str(entries[0][1]), ts2str(entries[-1][1])))
lines.append("")

# 目录：用户发言
idx = 0
toc = []
for e in entries:
    if e[0] == "msg" and e[2] == "user":
        idx += 1
        toc.append((idx, e[1], e[3]))
lines.append("## 目录（用户发言 %d 条）\n" % len(toc))
for i, ts, txt in toc:
    one = txt.replace("\n", " ")
    lines.append("%d. `%s` %s" % (i, ts2str(ts), one[:90]))
lines.append("\n---\n")

uidx = 0
open_details = False
for kind, ts, who, text in entries:
    when = ts2str(ts)
    if kind == "msg":
        if open_details:
            lines.append("</details>\n")
            open_details = False
        if who == "user":
            uidx += 1
            lines.append("## 👤 用户 #%d · %s\n" % (uidx, when))
            lines.append(text + "\n")
        else:
            lines.append("### 🤖 助手 · %s\n" % when)
            lines.append(text + "\n")
    elif kind == "call":
        if open_details:
            lines.append("</details>\n")
        one = text.replace("\n", " ")
        lines.append("<details><summary>🔧 <b>%s</b> — %s</summary>\n" % (who, one[:220] or "(无参数)"))
        open_details = True
    elif kind == "result":
        body = text.strip()
        trunc = False
        if len(body) > MAXOUT:
            body = body[:MAXOUT]
            trunc = True
        lines.append("```")
        lines.append(body)
        if trunc:
            lines.append("... [已截断，完整输出见源文件]")
        lines.append("```\n")
if open_details:
    lines.append("</details>\n")

os.makedirs(os.path.dirname(dst), exist_ok=True)
with open(dst, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
print("written:", dst, os.path.getsize(dst), "bytes; entries:", len(entries))
