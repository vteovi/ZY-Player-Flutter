import json, sys, collections

path = sys.argv[1]
seen = {}
with open(path, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        t = obj.get("type")
        if t in ("function_call", "function_call_result") and t not in seen:
            seen[t] = obj
            print("=== %s keys: %s" % (t, sorted(obj.keys())))
            print(json.dumps(obj, ensure_ascii=False)[:1200])
            print()
    if len(seen) == 2:
        pass
