import json, sys, re

path = sys.argv[1]

meta_rows = []
user_rows = []
ai_titles = []

with open(path, "r", encoding="utf-8", errors="replace") as f:
    for i, line in enumerate(f, 1):
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        t = obj.get("type")
        if t == "session-meta":
            meta_rows.append((i, obj))
        elif t == "ai-title":
            ai_titles.append(obj)
        elif t == "message":
            msg = obj.get("message")
            if isinstance(msg, dict) and msg.get("role") == "user":
                user_rows.append((i, obj.get("timestamp"), msg))

print("session-meta rows:", len(meta_rows))
for i, o in meta_rows[:3]:
    print("  line", i, "meta:", json.dumps(o.get("meta"), ensure_ascii=False)[:600])
print("ai-title rows:", len(ai_titles))
for o in ai_titles:
    print("  ", json.dumps(o, ensure_ascii=False)[:300])

print()
print("=== raw structure of one user message ===")
if user_rows:
    i, ts, m = user_rows[0]
    print("line", i, "ts", ts, "keys", sorted(m.keys()))
    print(json.dumps(m, ensure_ascii=False)[:1500])

print()
print("=== clean user utterances (filtered) ===")
clean = []
for i, ts, m in user_rows:
    c = m.get("content")
    if isinstance(c, list):
        text = "".join(
            p.get("text", "") for p in c if isinstance(p, dict) and p.get("type") == "text"
        )
    else:
        text = str(c or "")
    # strip system wrappers
    t2 = re.sub(r"<system-reminder[\s\S]*?</system-reminder>", "", text)
    t2 = re.sub(r"<task-notification[\s\S]*?</task-notification>", "", t2)
    t2 = re.sub(r"<cb_summary>[\s\S]*?</cb_summary>", "", t2)
    t2 = re.sub(r"<conversation_history_summary>[\s\S]*?</conversation_history_summary>", "", t2)
    t2 = re.sub(r"<user_query>([\s\S]*?)</user_query>", r"\1", t2)
    t2 = t2.strip()
    if t2 and len(t2) > 2:
        clean.append((i, ts, t2))

print("count:", len(clean))
for i, ts, t in clean:
    one = t.replace("\n", " ")
    print("[L%d | %s] %s" % (i, ts, one[:160]))
