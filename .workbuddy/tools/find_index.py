import os, sys

target = "835e8c41-d036-4300-a6cc-77bc39242b54"
roots = [r"C:/Users/VTE/.workbuddy"]
skip_dirs = {"projects", "node_modules", "binaries", "plugins", "cache", "blobs", "logs", "session"}
hits = []
scanned = 0
for root in roots:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in skip_dirs]
        for fn in filenames:
            if not fn.endswith((".json", ".ndjson", ".txt", ".log")):
                continue
            p = os.path.join(dirpath, fn)
            try:
                if os.path.getsize(p) > 3_000_000:
                    continue
                with open(p, "r", encoding="utf-8", errors="ignore") as f:
                    s = f.read()
            except Exception:
                continue
            scanned += 1
            if target in s:
                hits.append(p)
print("scanned files:", scanned)
print("hits:")
for h in hits:
    print("  ", h)
