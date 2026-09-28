#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 不跑 Gradle，用本机 JDK + Gradle 缓存里的 kotlin-compiler-embeddable
# 直接编译 Flutter 工程的 MainActivity.kt，几十秒内验证「语法/类型/符号」。
#
# 用途：改了 android/app/src/main/kotlin/** 之后，先在这里验一遍，
#       别拿 15 分钟的 flutter build 去试错。
#
# 用法：bash .workbuddy/tools/compile_kotlin.sh
#       bash .workbuddy/tools/compile_kotlin.sh <某个 .kt>     # 只编一个文件
# ─────────────────────────────────────────────────────────────────────────────
set -u

PROJ="${PROJ:-$(cd "$(dirname "$0")/../.." && pwd)}"
OUT="${TMPDIR:-/tmp}/offline_kotlinc"

# ---------- JDK ----------
JAVA=$(command -v java 2>/dev/null || true)
[ -z "$JAVA" ] && JAVA=$(find /c/Java /c/Program\ Files/Java /c/Program\ Files/Android -maxdepth 4 -name java.exe 2>/dev/null | head -1)
if [ -z "$JAVA" ]; then
  echo "找不到 java，请把 JDK 加进 PATH 或设置 JAVA_HOME"; exit 2
fi

# ---------- kotlin 编译器 ----------
KVER=$(grep -oE 'kotlin\.android"\) version "[0-9.]+"' "$PROJ/android/settings.gradle.kts" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
KVER="${KVER:-2.1.0}"
KC=$(find /c/Users/*/.gradle/caches/modules-2/files-2.1/org.jetbrains.kotlin/kotlin-compiler-embeddable/"$KVER" \
        "$HOME/.gradle/caches/modules-2/files-2.1/org.jetbrains.kotlin/kotlin-compiler-embeddable/$KVER" \
        -name "kotlin-compiler-embeddable-*.jar" 2>/dev/null | head -1)
if [ -z "$KC" ]; then
  KC=$(find /c/Users/*/.gradle/caches "$HOME/.gradle/caches" -name "kotlin-compiler-embeddable-*.jar" 2>/dev/null \
       | sort -V | tail -1)
fi
if [ -z "$KC" ]; then
  echo "找不到 kotlin-compiler-embeddable，先让 Gradle 至少构建过一次"; exit 2
fi

KSTD=$(find /c/Users/*/.gradle/caches "$HOME/.gradle/caches" -name "kotlin-stdlib-${KVER}.jar" ! -name "*sources*" 2>/dev/null | head -1)
KREF=$(find /c/Users/*/.gradle/caches "$HOME/.gradle/caches" -name "kotlin-reflect-${KVER}.jar" 2>/dev/null | head -1)
TROVE=$(find /c/Users/*/.gradle/caches "$HOME/.gradle/caches" -name "trove4j-*.jar" 2>/dev/null | head -1)

# ---------- android.jar / flutter.jar ----------
ANDROID_JAR=$(ls -1 /c/Android/Sdk/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)
[ -z "$ANDROID_JAR" ] && ANDROID_JAR=$(ls -1 "${ANDROID_HOME:-/nonexistent}/platforms/"*/android.jar 2>/dev/null | sort -V | tail -1)
FLUTTER_JAR=/c/flutter/bin/cache/artifacts/engine/android-arm64/flutter.jar
[ -f "$FLUTTER_JAR" ] || FLUTTER_JAR=$(find /c/flutter/bin/cache/artifacts/engine -maxdepth 2 -name flutter.jar 2>/dev/null | head -1)

echo "java        : $JAVA"
echo "kotlinc     : $KVER  ($(basename "$KC"))"
echo "android.jar : ${ANDROID_JAR:-<未找到>}"
echo "flutter.jar : ${FLUTTER_JAR:-<未找到>}"
echo "工程        : $PROJ"
echo

SRC="$PROJ/android/app/src/main/kotlin"
if [ "$#" -ge 1 ]; then
  SOURCES="$1"
else
  SOURCES=$(find "$SRC" -name "*.kt" 2>/dev/null | tr '\n' ' ')
fi
if [ -z "$SOURCES" ]; then
  echo "没有找到 .kt 源文件"; exit 2
fi

rm -rf "$OUT"
mkdir -p "$OUT"

# 编译器自身的 classpath（embeddable 需要 stdlib/reflect/trove）
CPC="$KC"
[ -n "$KSTD" ] && CPC="$CPC:$KSTD"
[ -n "$KREF" ] && CPC="$CPC:$KREF"
[ -n "$TROVE" ] && CPC="$CPC:$TROVE"

# 被编译代码的 classpath
CPD="$ANDROID_JAR"
[ -n "$FLUTTER_JAR" ] && CPD="$CPD:$FLUTTER_JAR"

# ⚠️ 不要加 -no-stdlib：Flutter 的 embedding jar 里没有 kotlin 标准库，
#    加了会满屏「unresolved reference: String / Unit / Boolean」
"$JAVA" -Dfile.encoding=UTF-8 -cp "$CPC" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -nowarn -cp "$CPD" -jvm-target 17 -d "$OUT" $SOURCES > "$OUT/kotlinc_raw.txt" 2>&1
RC=$?

tr -d '\000' < "$OUT/kotlinc_raw.txt" | grep -v "^warning:" | head -40

N=$(find "$OUT" -name "*.class" 2>/dev/null | wc -l | tr -d ' ')
echo
echo "---- classes: $N  exit: $RC"
if [ "$RC" -eq 0 ]; then
  echo "KOTLIN_COMPILE_OK"
else
  echo "KOTLIN_COMPILE_FAIL"
fi
