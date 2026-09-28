#!/usr/bin/env bash
# 离线编译 Flutter Android 插件的 Java 源码（不跑 Gradle）。
#
# 用途：改完 third_party/ 里 fork 的插件 Java 后，20 秒内验证语法/类型/符号。
# 用法：bash compile_plugin_java.sh [插件根目录]
#   默认插件根目录取环境变量 PLUGIN_DIR，再退回
#   /d/WorkBuddy/ZY-Player-Flutter/third_party/video_player_android
#
# 输出末行为 COMPILE_OK / COMPILE_FAILED。
set -u

PLUGIN_DIR="${1:-${PLUGIN_DIR:-D:/WorkBuddy/ZY-Player-Flutter/third_party/video_player_android}}"
WORK=/tmp/offline_javac
OUT="$WORK/out"
CP="$WORK/cp"

# ---------- 定位工具链 ----------
JAVAC=$(command -v javac 2>/dev/null || true)
[ -z "$JAVAC" ] && JAVAC=$(find /c/Java /c/Program\ Files/Java -maxdepth 3 -name javac.exe 2>/dev/null | head -1)
if [ -z "$JAVAC" ]; then
  echo "找不到 javac，请把 JDK 加进 PATH 或设置 JAVA_HOME"
  exit 2
fi

ANDROID_JAR=$(ls -1 /c/Android/Sdk/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)
[ -z "$ANDROID_JAR" ] && ANDROID_JAR=$(ls -1 "${ANDROID_HOME:-/nonexistent}/platforms/"*/android.jar 2>/dev/null | sort -V | tail -1)

FLUTTER_JAR=$(ls -1 /c/flutter/bin/cache/artifacts/engine/android-arm64/flutter.jar 2>/dev/null | head -1)

GRADLE_CACHE="${GRADLE_USER_HOME:-$HOME/.gradle}/caches"

echo "javac       : $JAVAC"
echo "android.jar : ${ANDROID_JAR:-<未找到>}"
echo "flutter.jar : ${FLUTTER_JAR:-<未找到>}"
echo "插件目录    : $PLUGIN_DIR"

rm -rf "$WORK"
mkdir -p "$OUT" "$CP"

# ---------- 解出 Gradle 缓存里各依赖的 classes.jar ----------
# ⚠️ 每个 artifact 只取**最高版本**：缓存里常同时存在多个版本（比如 media3 1.3.1 与
#    1.5.1），全塞进 classpath 会让 javac 用错版本去校验，等于白验。
extract_group() {
  local group_dir="$1" label="$2"
  local n=0
  if [ ! -d "$group_dir" ]; then
    echo "  $label: 0 个（缓存里没有）"
    return
  fi
  local art_dir ver aar dir
  for art_dir in "$group_dir"/*/; do
    ver=$(ls -1 "$art_dir" 2>/dev/null | sort -V | tail -1)
    [ -z "$ver" ] && continue
    aar=$(find "$art_dir/$ver" -name "*.aar" 2>/dev/null | head -1)
    [ -z "$aar" ] && continue
    dir="$CP/$(basename "$art_dir")"
    mkdir -p "$dir"
    if (cd "$dir" && unzip -o -q "$aar" classes.jar 2>/dev/null); then
      n=$((n + 1))
    fi
  done
  echo "  $label: $n 个"
}

echo "=== 解出依赖 classes.jar ==="
extract_group "$GRADLE_CACHE/modules-2/files-2.1/androidx.media3" "androidx.media3"
# 其它 androidx 依赖按需补（插件用了什么就加什么）
extract_group "$GRADLE_CACHE/modules-2/files-2.1/androidx.core" "androidx.core"

# ---------- annotation ----------
# ⚠️ androidx.annotation.OptIn 在 annotation-experimental 里，不在 annotation 里。
#    annotation-experimental 不是 aar，藏在 transforms 目录下的 *-api.jar。
ANNOTATION_JARS=$(find "$GRADLE_CACHE" -name "annotation-jvm-*.jar" ! -name "*sources*" 2>/dev/null | head -1)
ANNOTATION_EXPERIMENTAL_JAR=$(find "$GRADLE_CACHE" -name "annotation-experimental-*-api.jar" 2>/dev/null | head -1)
echo "annotation  : ${ANNOTATION_JARS:-<未找到>}"
echo "annotation-experimental: ${ANNOTATION_EXPERIMENTAL_JAR:-<未找到>}"

CLASSPATH=""
for j in "$ANDROID_JAR" "$FLUTTER_JAR" "$ANNOTATION_JARS" "$ANNOTATION_EXPERIMENTAL_JAR"; do
  [ -n "$j" ] && [ -f "$j" ] && CLASSPATH="$CLASSPATH:$j"
done
for d in "$CP"/*/; do
  [ -f "$d/classes.jar" ] && CLASSPATH="$CLASSPATH:$d/classes.jar"
done
CLASSPATH="${CLASSPATH#:}"

SRC_DIR="$PLUGIN_DIR/android/src/main/java"
[ -d "$SRC_DIR" ] || SRC_DIR="$PLUGIN_DIR/android/src/main/kotlin"
if [ ! -d "$SRC_DIR" ]; then
  echo "找不到源码目录: $PLUGIN_DIR/android/src/main/java"
  exit 2
fi

SOURCES=$(find "$SRC_DIR" -name "*.java")
COUNT=$(printf '%s\n' "$SOURCES" | grep -c . )
echo "=== 编译 $COUNT 个 java 文件 ==="

# ⚠️ 不要加 -bootclasspath（JDK 17 + target>=9 会被拒绝），
#    也不要加 --release（会和 android.jar 里的 java.* 冲突）。
# shellcheck disable=SC2086
"$JAVAC" -nowarn -encoding UTF-8 -J-Dfile.encoding=UTF-8 \
  -classpath "$CLASSPATH" \
  -d "$OUT" \
  $SOURCES > "$WORK/javac_raw.txt" 2>&1

# ⚠️ javac 的中文报错是 GBK 字节，直接 grep 会被当二进制，先清 NUL/CR。
tr -d '\000' < "$WORK/javac_raw.txt" | tr -d '\r' | grep -av "^Note:" | head -60

echo "=== 结果 ==="
if [ -z "$(find "$OUT" -name '*.class' 2>/dev/null | head -1)" ]; then
  echo "COMPILE_FAILED"
  exit 1
fi
find "$OUT" -name "*.class" | wc -l | sed 's/^/  生成 class: /'
echo "COMPILE_OK"
