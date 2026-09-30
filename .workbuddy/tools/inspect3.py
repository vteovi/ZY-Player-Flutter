import json, sys, collections

path = sys.argv[1]
topkey = collections.Counter()
samples = []
with open(path, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if obj.get("type") != "message":
            continue
        topkey[tuple(sorted(obj.keys()))] += 1
        if len(samples) < 4:
            samples.append(obj)

print("message top-level key sets:", topkey)
for s in samples:
    print("---")
    print(json.dumps(s, ensure_ascii=False)[:1600])
