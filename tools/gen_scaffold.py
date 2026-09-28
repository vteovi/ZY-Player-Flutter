#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从 Flutter SDK 模板生成 Flutter 项目骨架。

本机的 flutter CLI 因环境限制（Dart 创建子进程管道失败）无法运行，
因此这里直接复用 C:/flutter/packages/flutter_tools/templates/app 下的官方模板，
按 flutter create 的规则做变量渲染后落地到项目目录。

用法: python tools/gen_scaffold.py
"""
import os
import re
import shutil
import subprocess
import sys

FLUTTER_SDK = r"C:\flutter"
SRC = os.path.join(FLUTTER_SDK, "packages", "flutter_tools", "templates", "app")
DST = r"D:\WorkBuddy\ZY-Player-Flutter"

PROJECT_NAME = "zy_player"
ANDROID_ID = "com.zy.player"

CTX = {
    "projectName": PROJECT_NAME,
    "description": "ZY Player 移动端 APP Flutter 版",
    "androidIdentifier": ANDROID_ID,
    "iosIdentifier": ANDROID_ID,
    "org": "com.zy",
    "dartSdkVersionBounds": "^3.8.0",
    "agpVersion": "8.7.3",
    "agpVersionForModule": "8.7.3",
    "kotlinVersion": "2.1.0",
    "gradleVersion": "8.12",
    "androidLanguage": "kotlin",
    "iosLanguage": "swift",
    "withEmptyMain": False,
    "withPluginHook": False,
    "withPlatformChannelPluginHook": False,
    "withWidgetPreviewScaffold": False,
    "hasPlugins": False,
    "pluginProjectName": "",
    "macosLanguage": "swift",
    "windowsLanguage": "cpp",
}

# 需要合成的源目录 -> 目标目录（按顺序，后者覆盖/补充前者）
MERGES = [
    ("android.tmpl", "android"),
    ("android-kotlin.tmpl", "android"),
    ("ios.tmpl", "ios"),
    ("ios-swift.tmpl", "ios"),
    ("web", "web"),
]


def truthy(v):
    return bool(v) and v != "false"


def render(text, ctx):
    # 反向 section {{^k}}...{{/k}}
    def inv(m):
        return m.group(2) if not truthy(ctx.get(m.group(1))) else ""

    text = re.sub(r"\{\{\^(\w+)\}\}(.*?)\{\{/\1\}\}", inv, text, flags=re.S)

    # 正向 section {{#k}}...{{/k}}
    def sec(m):
        return render(m.group(2), ctx) if truthy(ctx.get(m.group(1))) else ""

    text = re.sub(r"\{\{#(\w+)\}\}(.*?)\{\{/\1\}\}", sec, text, flags=re.S)

    # 普通变量
    def var(m):
        return str(ctx.get(m.group(1), ""))

    return re.sub(r"\{\{(\w+)\}\}", var, text)


def fix_segments(rel_parts, ctx):
    """把路径片段里的模板变量替换成真实值（含 androidIdentifier -> com/zy/player）"""
    out = []
    for seg in rel_parts:
        if seg == "androidIdentifier":
            out.extend(ctx["androidIdentifier"].split("."))
        elif seg.startswith("{{") and seg.endswith("}}"):
            key = seg[2:-2]
            out.append(str(ctx.get(key, "")))
        else:
            seg = seg.replace("projectName", ctx["projectName"])
            out.append(seg)
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
                dest_name = f[: -len(".img.tmpl")]
                binary = True
                do_render = False
            elif f.endswith(".copy.tmpl"):
                dest_name = f[: -len(".copy.tmpl")]
                binary = True
                do_render = False
            elif f.endswith(".tmpl"):
                dest_name = f[: -len(".tmpl")]
                binary = False
                do_render = True
            else:
                dest_name = f
                binary = True
                do_render = False
            dest_name = fix_segments([dest_name], CTX)[0]
            dest_file = os.path.join(target_dir, dest_name)
            os.makedirs(os.path.dirname(dest_file), exist_ok=True)
            if binary or not do_render:
                shutil.copy2(src_file, dest_file)
            else:
                with open(src_file, "r", encoding="utf-8") as fh:
                    content = fh.read()
                with open(dest_file, "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(render(content, CTX))


def main():
    os.makedirs(DST, exist_ok=True)

    for src_name, dst_name in MERGES:
        src_dir = os.path.join(SRC, src_name)
        dst_dir = os.path.join(DST, dst_name)
        if not os.path.isdir(src_dir):
            print("skip (missing):", src_dir)
            continue
        copy_tree(src_dir, dst_dir)
        print("generated:", dst_name)

    # 根级单文件模板
    for name, dest in ((".gitignore.tmpl", ".gitignore"),
                       ("analysis_options.yaml.tmpl", "analysis_options.yaml")):
        src_file = os.path.join(SRC, name)
        if os.path.isfile(src_file):
            with open(src_file, "r", encoding="utf-8") as fh:
                content = render(fh.read(), CTX)
            with open(os.path.join(DST, dest), "w", encoding="utf-8", newline="\n") as fh:
                fh.write(content)
            print("generated:", dest)

    # gradle wrapper jar（模板里没有，Flutter 从 artifacts 复制）
    jar_src = os.path.join(FLUTTER_SDK, "bin", "cache", "artifacts", "gradle_wrapper",
                           "gradle", "wrapper", "gradle-wrapper.jar")
    if os.path.isfile(jar_src):
        jar_dir = os.path.join(DST, "android", "gradle", "wrapper")
        os.makedirs(jar_dir, exist_ok=True)
        shutil.copy2(jar_src, os.path.join(jar_dir, "gradle-wrapper.jar"))
        print("generated: android/gradle/wrapper/gradle-wrapper.jar")

    # gradlew 启动脚本
    for script in ("gradlew", "gradlew.bat"):
        s = os.path.join(FLUTTER_SDK, "bin", "cache", "artifacts", "gradle_wrapper", script)
        if os.path.isfile(s):
            shutil.copy2(s, os.path.join(DST, "android", script))
            print("generated: android/" + script)

    # .metadata（flutter 工具用于识别项目类型与平台）
    try:
        rev = subprocess.check_output(["git", "-C", FLUTTER_SDK, "rev-parse", "HEAD"],
                                      stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        rev = ""
    metadata = """# This file tracks properties of this Flutter project.
# Used by Flutter tool to assess capabilities and perform upgrades etc.
#
# This file should be version controlled and should not be manually edited.

version:
  revision: {rev}
  channel: stable

project_type: app

migrate:
  platforms:
    - android
    - ios
    - web
  unmanaged_files:
    - 'lib/main.dart'
    - 'ios/Runner.xcodeproj/project.pbxproj'
""".format(rev=rev)
    with open(os.path.join(DST, ".metadata"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(metadata)
    print("generated: .metadata")

    # Android local.properties（让 gradle 能定位 sdk）
    android_sdk = os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME") \
        or os.path.join(os.path.expanduser("~"), "AppData", "Local", "Android", "Sdk")
    android_sdk = android_sdk.replace("\\", "\\\\").replace(":", "\\:")
    local_props = "sdk.dir={sdk}\nflutter.sdk={flutter}\nflutter.buildMode=debug\n".format(
        sdk=android_sdk, flutter=FLUTTER_SDK.replace("\\", "\\\\").replace(":", "\\:"))
    with open(os.path.join(DST, "android", "local.properties"), "w",
              encoding="utf-8", newline="\n") as fh:
        fh.write(local_props)
    print("generated: android/local.properties")
    return 0


if __name__ == "__main__":
    sys.exit(main())
