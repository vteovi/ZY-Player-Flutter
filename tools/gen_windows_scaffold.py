#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从 Flutter SDK 模板生成 windows/ 平台目录（flutter create --platforms=windows 的离线替代）。

本机 flutter CLI 因环境限制（Dart 创建子进程管道失败）无法运行，
复用 C:/flutter/packages/flutter_tools/templates/app/windows.tmpl 官方模板，
按 flutter create 的规则做变量渲染后落地到项目 windows/ 目录。

用法: python tools/gen_windows_scaffold.py
只写 windows/ 与 .metadata，不碰 android/ios/web。
"""
import os
import re
import shutil
import subprocess
import sys

FLUTTER_SDK = r"C:\flutter"
SRC = os.path.join(FLUTTER_SDK, "packages", "flutter_tools",
                   "templates", "app", "windows.tmpl")
DST = r"D:\WorkBuddy\ZY-Player-Flutter"
WIN_DST = os.path.join(DST, "windows")

PROJECT_NAME = "zy_player"
ORG = "com.zy"

CTX = {
    "projectName": PROJECT_NAME,
    "organization": ORG,
    "year": str(subprocess.check_output(
        ["powershell", "-NoProfile", "-Command", "Get-Date -Format yyyy"],
        stderr=subprocess.DEVNULL).decode().strip()) if False else "2026",
    # 以下变量在 app 模板中处于 false section，给默认值即可
    "pluginProjectName": "",
    "windowsLanguage": "cpp",
}


def truthy(v):
    return bool(v) and v != "false"


def render(text, ctx):
    def inv(m):
        return m.group(2) if not truthy(ctx.get(m.group(1))) else ""
    text = re.sub(r"\{\{\^(\w+)\}\}(.*?)\{\{/\1\}\}", inv, text, flags=re.S)

    def sec(m):
        return render(m.group(2), ctx) if truthy(ctx.get(m.group(1))) else ""
    text = re.sub(r"\{\{#(\w+)\}\}(.*?)\{\{/\1\}\}", sec, text, flags=re.S)

    def var(m):
        return str(ctx.get(m.group(1), ""))
    return re.sub(r"\{\{(\w+)\}\}", var, text)


def fix_segments(rel_parts, ctx):
    out = []
    for seg in rel_parts:
        if seg.startswith("{{") and seg.endswith("}}"):
            key = seg[2:-2]
            out.append(str(ctx.get(key, "")))
        else:
            out.append(seg.replace("projectName", ctx["projectName"]))
    return out


def copy_tree(src_dir, dst_dir):
    for root, dirs, files in os.walk(src_dir):
        rel = os.path.relpath(root, src_dir)
        rel_parts = [] if rel == "." else rel.split(os.sep)
        rel_parts = fix_segments(rel_parts, CTX)
        target_dir = os.path.join(dst_dir, *rel_parts) if rel_parts else dst_dir
        os.makedirs(target_dir, exist_ok=True)
        for f in files:
            src_file = os.path.join(root, f)
            if f.endswith(".img.tmpl"):
                dest_name, binary, do_render = f[: -len(".img.tmpl")], True, False
            elif f.endswith(".copy.tmpl"):
                dest_name, binary, do_render = f[: -len(".copy.tmpl")], True, False
            elif f.endswith(".tmpl"):
                dest_name, binary, do_render = f[: -len(".tmpl")], False, True
            else:
                dest_name, binary, do_render = f, True, False
            dest_file = os.path.join(target_dir, dest_name)
            if binary or not do_render:
                shutil.copy2(src_file, dest_file)
            else:
                with open(src_file, "r", encoding="utf-8") as fh:
                    content = fh.read()
                with open(dest_file, "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(render(content, CTX))


def main():
    if os.path.isdir(WIN_DST):
        print("windows/ 已存在，跳过（如需重新生成请先删除）")
        return 1
    copy_tree(SRC, WIN_DST)
    print("generated: windows/")

    # .metadata 平台列表加 windows（flutter 工具识别项目类型用）
    meta_path = os.path.join(DST, ".metadata")
    if os.path.isfile(meta_path):
        with open(meta_path, "r", encoding="utf-8") as fh:
            meta = fh.read()
        if "- windows" not in meta:
            meta = meta.replace("    - web\n", "    - web\n    - windows\n")
            with open(meta_path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(meta)
            print("updated: .metadata (platforms + windows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
