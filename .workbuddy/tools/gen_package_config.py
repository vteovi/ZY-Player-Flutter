#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
临时生成 .dart_tool/package_config.json，让 dart analyze 能在没有执行
`flutter pub get`（本机 flutter CLI 无法启动子进程）的情况下解析依赖。

它直接把本机 pub 缓存里已有的包版本登记进来，仅用于静态检查。
"""
import json
import os
import re

FLUTTER = r"C:\flutter"
PUB_CACHE = os.path.expandvars(r"%LOCALAPPDATA%\Pub\Cache\hosted\pub.dev")
ROOT = r"D:\WorkBuddy\ZY-Player-Flutter"
OUT = os.path.join(ROOT, ".dart_tool", "package_config.json")


def version_key(v):
    parts = re.split(r"[.\-+]", v)
    key = []
    for p in parts:
        key.append((0, int(p)) if p.isdigit() else (1, p))
    return tuple(key)


def main():
    best = {}
    for name in os.listdir(PUB_CACHE):
        path = os.path.join(PUB_CACHE, name)
        if not os.path.isdir(path):
            continue
        if "-" not in name:
            continue
        pkg, _, ver = name.rpartition("-")
        if pkg not in best or version_key(ver) > version_key(best[pkg][0]):
            best[pkg] = (ver, path)

    # 若已存在（pub get 生成过）则在其基础上补齐缺失的包，不覆盖已解析的版本
    existing = {}
    packages = []
    if os.path.isfile(OUT):
        try:
            with open(OUT, encoding="utf-8") as fh:
                old = json.load(fh)
            packages = old.get("packages", [])
            for p in packages:
                existing[p["name"]] = p
        except Exception:
            packages = []
    if not any(p["name"] == "zy_player" for p in packages):
        packages.insert(0, {
            "name": "zy_player",
            "rootUri": "../",
            "packageUri": "lib/",
            "languageVersion": "3.8",
        })

    def add(name, root, package_uri="lib/"):
        if name in existing:
            return
        packages.append({
            "name": name,
            "rootUri": "file:///" + root.replace("\\", "/"),
            "packageUri": package_uri,
            "languageVersion": "3.8",
        })

    # Flutter SDK 内置包
    add("flutter", os.path.join(FLUTTER, "packages", "flutter"))
    add("flutter_test", os.path.join(FLUTTER, "packages", "flutter_test"))
    add("flutter_web_plugins", os.path.join(FLUTTER, "packages", "flutter_web_plugins"))
    add("sky_engine", os.path.join(FLUTTER, "bin", "cache", "pkg", "sky_engine"))

    for pkg, (ver, path) in sorted(best.items()):
        add(pkg, path)

    config = {
        "configVersion": 2,
        "packages": packages,
        "generated": "2026-09-28T00:00:00.000000Z",
        "generator": "pub",
        "generatorVersion": "3.8.1",
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(config, fh, indent=2)
    print("written:", OUT, "packages:", len(packages))


if __name__ == "__main__":
    main()
