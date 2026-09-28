#!/usr/bin/env bash
# 本机环境专用：等待「Dart 命名管道」能力恢复后，自动构建 release APK。
#
# 背景：本机 360 安全卫士的主动防御（ZhuDongFangYu.exe）会拦截
#       PIPE_ACCESS_OUTBOUND 命名管道的客户端读打开（恒定 err=231
#       ERROR_PIPE_BUSY），导致 Dart/Node 无法以管道方式派生子进程，
#       flutter 命令一律失败。Python 用匿名管道不受影响。
#
# 用法：bash .workbuddy/tools/wait_and_build_apk.sh
#       （可放后台跑；脚本会一直轮询，直到探测通过再开始构建）

set -u

DART="/c/flutter/bin/cache/dart-sdk/bin/dart.exe"
PROBE="/c/Users/VTE/AppData/Local/Temp/probe.dart"
PROJ="/d/WorkBuddy/ZY-Player-Flutter"
LOG="/c/Users/VTE/AppData/Local/Temp/zybuild_watch.log"
APK_DIR="$PROJ/build/app/outputs/flutter-apk"

MIN_FREE_GB=4

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

: > "$LOG"
log "=== 等待 Dart 管道能力恢复 ==="

# --- 阶段 1：轮询探测 ---
while true; do
  OUT="$("$DART" "$PROBE" 2>&1 || true)"
  case "$OUT" in
    *PROBE_SUCCESS*)
      log "管道能力已恢复，开始构建"
      break
      ;;
  esac
  log "等待中（$(echo "$OUT" | head -1)）"
  sleep 30
done

# --- 阶段 2：磁盘空间检查 ---
FREE_GB=$(/c/Python312/python.exe -c "import shutil;print(round(shutil.disk_usage('D:/').free/2**30,1))")
log "D 盘剩余 ${FREE_GB}G"
if /c/Python312/python.exe -c "import sys;sys.exit(0 if $FREE_GB >= $MIN_FREE_GB else 1)"; then
  log "空间充足，继续"
else
  log "空间不足（<${MIN_FREE_GB}G），中止构建"
  exit 1
fi

# --- 阶段 3：构建 ---
# 前置一个真正的 Git，避免 PortableGit 带来的额外子进程问题
export PATH="/c/Program Files/Git/cmd:$PATH"
hash -r
cd "$PROJ" || exit 1

rm -f "$PROJ"/flutter_0*.log
log "执行 flutter pub get"
/c/flutter/bin/flutter pub get >> "$LOG" 2>&1
log "pub get exit=$?"

log "执行 flutter build apk --release --target-platform android-arm64"
/c/flutter/bin/flutter build apk --release \
  --no-version-check --target-platform android-arm64 >> "$LOG" 2>&1
RC=$?
log "build exit=$RC"

if [ -d "$APK_DIR" ]; then
  log "APK 产出："
  ls -lh "$APK_DIR" 2>&1 | tee -a "$LOG"
fi
log "=== 结束 ==="
