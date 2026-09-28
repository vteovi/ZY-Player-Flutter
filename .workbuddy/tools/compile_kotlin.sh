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
# ⚠️ 别用 /tmp：沙箱的 rm 包装器会拒绝「带盘符前缀」的路径，
#    导致复用时残留上一次的 class。放在 build/ 下（本来就被忽略、也会被 flutter clean 清掉）
OUT="$PROJ/build/offline_kotlinc"

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
# ⚠️ kotlin-compiler-embeddable 自己还要 coroutines（KotlinCoreApplicationEnvironment
#    初始化时就会 NoClassDefFoundError: kotlinx/coroutines/CoroutineScope）
KCORO=$(find /c/Users/*/.gradle/caches "$HOME/.gradle/caches" -name "kotlinx-coroutines-core-jvm-*.jar" ! -name "*sources*" 2>/dev/null | sort -V | tail -1)
[ -z "$KCORO" ] && KCORO=$(find /c/Users/*/.gradle/caches "$HOME/.gradle/caches" -name "kotlinx-coroutines-core-*.jar" ! -name "*sources*" 2>/dev/null | sort -V | tail -1)
# ⚠️ 后端 IR 代码生成阶段要给参数写 @NotNull，会反射加载 org.jetbrains.annotations.NotNull。
#    缺了它前端全过、到 codegen 才抛
#    「Backend Internal error: Exception during IR lowering」
#    → Caused by: NoClassDefFoundError: org/jetbrains/annotations/NotNull
#    极容易被误判成「代码有问题」，其实是编译器自己的 classpath 缺件。
JANN=$(find /c/Users/*/.gradle/caches "$HOME/.gradle/caches" -path "*/org.jetbrains/annotations/*" -name "annotations-*.jar" ! -name "*sources*" 2>/dev/null | sort -V | tail -1)

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

# ---------- 解出 FlutterActivity 依赖的 androidx classes.jar ----------
# FlutterActivity 实现了 androidx 的 LifecycleOwner 等接口，这些类不在 android.jar
# 里，缺了会报「cannot access 'androidx.lifecycle.LifecycleOwner' which is a
# supertype of ...」。⚠️ 每个 artifact 只取缓存里的最高版本，混版本会校验错。
GRADLE_ROOT=$(dirname "$(dirname "$KC")/../../..")
GCACHE=""
for c in "$HOME/.gradle/caches" /c/Users/*/.gradle/caches; do
  [ -d "$c/modules-2/files-2.1" ] && GCACHE="$c/modules-2/files-2.1" && break
done

extract_group() {
  local group_dir="$1" label="$2" n=0 art_dir art ver dir aar jar
  [ -d "$group_dir" ] || { echo "  $label: 0"; return; }
  for art_dir in "$group_dir"/*/; do
    [ -d "$art_dir" ] || continue
    art=$(basename "$art_dir")
    dir="$OUT/cp/$art"
    # ⚠️ 两个坑：
    # 1) 产物在 `版本号/哈希/xxx.aar|jar` 两层下，`-maxdepth 1` 永远找不到 → 必须 2。
    # 2) 版本目录里常有「只有 .pom/.module 没有产物」的（BOM、-jvm 变体等），
    #    从高版本往低找，取第一个真有产物的版本。
    for ver in $(ls -1 "$art_dir" 2>/dev/null | sort -Vr); do
      aar=$(find "$art_dir/$ver" -maxdepth 2 -name "*.aar" 2>/dev/null | head -1)
      if [ -n "$aar" ]; then
        mkdir -p "$dir"
        if (cd "$dir" && unzip -o -q "$aar" classes.jar 2>/dev/null); then
          n=$((n + 1)); break
        fi
        continue
      fi
      # ⚠️ 有些构件是纯 jar 不是 aar —— 比如 `androidx.lifecycle.LifecycleOwner`
      #    其实在 lifecycle-common(.jar) 里。只解 aar 会报
      #    「cannot access LifecycleOwner which is a supertype of FlutterActivity」，
      #    进而级联出一堆假的 unresolved / syntax error。
      jar=$(find "$art_dir/$ver" -maxdepth 2 -name "*.jar" ! -name "*sources*" 2>/dev/null | head -1)
      if [ -n "$jar" ]; then
        mkdir -p "$dir"
        if cp "$jar" "$dir/deps.jar"; then n=$((n + 1)); break; fi
      fi
    done
  done
  echo "  $label: $n"
}

echo "=== 解出 androidx classes.jar ==="
for g in androidx.lifecycle androidx.annotation androidx.core androidx.activity androidx.savedstate androidx.window; do
  extract_group "$GCACHE/$g" "$g"
done

# ---------- 编译器自身的 classpath ----------
# ⚠️ kotlin-compiler-embeddable 还需要 coroutines：KotlinCoreApplicationEnvironment
#    初始化时就会 NoClassDefFoundError: kotlinx/coroutines/CoroutineScope
CPC="$KC"
for j in "$KSTD" "$KREF" "$TROVE" "$KCORO" "$JANN"; do
  [ -n "$j" ] && CPC="$CPC:$j"
done

# ---------- 被编译代码的 classpath ----------
# ⚠️ 必须带上 kotlin-stdlib，否则满屏
#    「cannot access built-in declaration 'kotlin.Unit'. Ensure that you have a
#      dependency on the Kotlin standard library」
CPD="$ANDROID_JAR"
for j in "$FLUTTER_JAR" "$KSTD"; do
  [ -n "$j" ] && [ -f "$j" ] && CPD="$CPD:$j"
done
for f in "$OUT"/cp/*/*.jar; do
  [ -f "$f" ] && CPD="$CPD:$f"
done

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
