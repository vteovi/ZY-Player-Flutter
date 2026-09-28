#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""为「单进程静态检查」准备一个自带 analyzer 依赖的运行环境。

本机的 flutter / dart CLI 无法派生子进程（CreateFile failed 231），
所以把项目里的 analyze.dart 复制到临时目录，并配一份能解析 package:analyzer
的 package_config.json（借用 flutter_tools 的依赖图），这样 `dart xxx.dart`
可以单进程直接跑，不触发任何子进程创建。
"""
import json
import os
import shutil

FLUTTER_TOOLS = r"C:\flutter\packages\flutter_tools"
SRC_CFG = os.path.join(FLUTTER_TOOLS, ".dart_tool", "package_config.json")
SCRIPT_SRC = r"D:\WorkBuddy\ZY-Player-Flutter\.workbuddy\tools\analyze.dart"
DST = os.path.expandvars(r"%TEMP%\zyanalyze")


def absify(uri: str) -> str:
    if uri.startswith("file://"):
        return uri
    path = os.path.normpath(os.path.join(FLUTTER_TOOLS, uri.replace("/", os.sep)))
    return "file:///" + path.replace("\\", "/")


def main() -> None:
    os.makedirs(os.path.join(DST, ".dart_tool"), exist_ok=True)
    with open(SRC_CFG, encoding="utf-8") as fh:
        cfg = json.load(fh)
    for pkg in cfg["packages"]:
        pkg["rootUri"] = absify(pkg["rootUri"])
    out = os.path.join(DST, ".dart_tool", "package_config.json")
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, indent=2)
    shutil.copy(SCRIPT_SRC, os.path.join(DST, "analyze.dart"))
    has_analyzer = any(p["name"] == "analyzer" for p in cfg["packages"])
    print("OK", out, "packages:", len(cfg["packages"]), "has_analyzer:", has_analyzer)


if __name__ == "__main__":
    main()
