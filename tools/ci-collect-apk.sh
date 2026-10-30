#!/usr/bin/env bash
# CI 专用：把 build/app/outputs/flutter-apk 下刚构建出的 APK
# 按 ABI 重命名后复制到 dist/（同名已存在则跳过，可重复调用）。
# 用法: bash tools/ci-collect-apk.sh <versionName>
set -euo pipefail

V="${1:?用法: bash tools/ci-collect-apk.sh <versionName>}"
SRC="build/app/outputs/flutter-apk"

mkdir -p dist
shopt -s nullglob

n=0
for f in "$SRC"/*.apk; do
  b=$(basename "$f" .apk)
  case "$b" in
    *arm64*)   tag=arm64 ;;
    *armeabi*) tag=armv7 ;;
    *x86_64*)  tag=x86_64 ;;
    *)         tag=universal ;;
  esac
  out="dist/ZY-Player-v${V}-${tag}.apk"
  [ -f "$out" ] && continue
  cp "$f" "$out"
  n=$((n + 1))
done

echo "本次新收集 ${n} 个 APK"
echo "===== dist ====="
ls -lh dist || true
echo "===== SHA1 ====="
(cd dist && sha1sum ./*.apk) || true
