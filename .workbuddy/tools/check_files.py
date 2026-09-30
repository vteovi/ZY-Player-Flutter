"""从会话 jsonl 中提取所有出现过的项目文件路径，检查是否仍在磁盘上。
用法: python check_files.py <in.jsonl> <project_root>
"""
import json, sys, os, re

src = sys.argv[1]
root = sys.argv[2].rstrip("/\\")

abs_re = re.compile(r"D:[\\/]WorkBuddy[\\/]ZY-Player-Flutter[\\/]([A-Za-z0-9_\-\.\u4e00-\u9fff/\\]+)")
rel_re = re.compile(r'"(?:file_path|path|filePath|target_file|output)"\s*:\s*"([A-Za-z0-9_\-\./\\]+\.(?:dart|kt|java|kts|gradle|xml|yaml|yml|json|md|bat|sh|py|txt|png|apk|properties|cmake|h|cc|cpp|html|plist|swift|ndjson|log))"')

paths = set()
with open(src, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        for m in abs_re.finditer(line):
            p = m.group(1).replace("\\\\", "/").replace("\\", "/").rstrip("/")
            p = re.sub(r'["\'\),;\]]$', "", p)
            paths.add(p)
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("type") == "function_call":
            args = obj.get("arguments")
            for m in rel_re.finditer(args or ""):
                paths.add(m.group(1).replace("\\", "/"))

skip_prefix = ("build/", ".git/", ".dart_tool/", "node_modules/")
checked = {}
for p in sorted(paths):
    if p.startswith(skip_prefix) or p == "":
        continue
    full = os.path.join(root, p.replace("/", os.sep))
    checked[p] = os.path.exists(full)

missing = [p for p, ok in checked.items() if not ok]
present = [p for p, ok in checked.items() if ok]
print("提取到路径 %d 个（已排除 build/.git/.dart_tool）" % len(checked))
print("存在: %d   缺失: %d" % (len(present), len(missing)))
if missing:
    print("\n=== 缺失文件 ===")
    for p in missing:
        print("  ", p)
else:
    print("\n无缺失。")
