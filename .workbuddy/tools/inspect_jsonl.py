import json, sys, os, collections

path = sys.argv[1]
n = 0
kinds = collections.Counter()
roles = collections.Counter()
first_keys = None
user_msgs = []
ts_first = None
ts_last = None
bad = 0

def get_ts(obj):
    for k in ("timestamp", "ts", "createdAt", "time"):
        if isinstance(obj.get(k), (int, float, str)):
            return obj[k]
    return None

with open(path, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        n += 1
        try:
            obj = json.loads(line)
        except Exception:
            bad += 1
            continue
        if first_keys is None:
            first_keys = sorted(obj.keys())
        t = obj.get("type") or obj.get("kind") or "?"
        kinds[t] += 1
        r = obj.get("role")
        if r:
            roles[r] += 1
        ts = get_ts(obj)
        if ts is not None:
            if ts_first is None:
                ts_first = ts
            ts_last = ts
        if r == "user" or t == "user":
            c = obj.get("content") or obj.get("message") or obj.get("text")
            if isinstance(c, list):
                parts = []
                for p in c:
                    if isinstance(p, dict):
                        parts.append(str(p.get("text") or p.get("content") or p.get("type")))
                    else:
                        parts.append(str(p))
                c = " ".join(parts)
            user_msgs.append(str(c)[:200])

print("file:", path)
print("size(MB): %.1f" % (os.path.getsize(path) / 1048576))
print("lines:", n, "unparsable:", bad)
print("first-line keys:", first_keys)
print("type counts:", dict(kinds.most_common(12)))
print("role counts:", dict(roles.most_common()))
print("ts first:", ts_first, "last:", ts_last)
print("--- user messages (%d) ---" % len(user_msgs))
for i, m in enumerate(user_msgs[:40], 1):
    print("[%d] %s" % (i, m.replace("\n", " ")))
