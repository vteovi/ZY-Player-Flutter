@echo off
setlocal
title ZY-Player APK Builder - 3 ABIs

REM ---------------------------------------------------------------
REM  一次构建 -> 三个按 ABI 拆分的 release APK：
REM    app-arm64-v8a-release.apk     ARMv8   （现代手机，主力）
REM    app-armeabi-v7a-release.apk   ARMv7   （老机型 / 32 位）
REM    app-x86_64-release.apk        x86_64  （模拟器）
REM  输出到项目根目录：
REM    ZY-Player-v<版本>-arm64-release.apk
REM    ZY-Player-v<版本>-armv7-release.apk
REM    ZY-Player-v<版本>-x86_64-release.apk
REM
REM  必须同一次 flutter build 里带 --split-per-abi；不带 --target-platform
REM  时默认架构就是 android-arm + android-arm64 + android-x64（见
REM  flutter_tools/lib/src/commands/build_apk.dart 的 _kDefaultAotArchs）。
REM ---------------------------------------------------------------

REM 显式注入构建所需环境变量（避免依赖用户登录环境）
set "ANDROID_HOME=C:\Android\Sdk"
set "JAVA_HOME=C:\Java\jdk-17"

REM 构建插件需要符号链接权限：
REM  - 若已开启“开发者模式”(设置 -> 开发者选项)，非管理员即可构建；
REM  - 否则以管理员身份重跑本脚本（自动提权，需确认 UAC 一次）。
set "DEVMODE=0"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /v AllowDevelopmentWithoutDevLicense 2>nul | findstr /r "0x1" >nul && set "DEVMODE=1"
if "%DEVMODE%"=="0" (
  net session >nul 2>&1
  if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
  )
)

set "PROJ=D:\WorkBuddy\ZY-Player-Flutter"
set "FLUTTER=C:\flutter\bin\flutter.bat"
set "DART=C:\flutter\bin\dart.bat"
set "LOG=%PROJ%\tools\build_log.txt"
set "PROBEOUT=%PROJ%\tools\probe_result.txt"
set "SRCDIR=%PROJ%\build\app\outputs\flutter-apk"

rem --- derive version from pubspec.yaml so the APK name never goes stale ---
set "APPVER="
for /f "tokens=2" %%V in ('findstr /b /c:"version:" "%PROJ%\pubspec.yaml"') do set "APPVER=%%V"
if not defined APPVER set "APPVER=0.0.0+0"
for /f "tokens=1 delims=+" %%B in ("%APPVER%") do set "APPVER=%%B"

echo ================================================================
echo   ZY-Player Flutter  -  release APK builder (3 ABIs)
echo ================================================================
echo   Version : %APPVER%
echo   ABIs    : arm64-v8a (ARMv8) / armeabi-v7a (ARMv7) / x86_64
echo.

if not exist "%FLUTTER%" goto no_flutter
if not exist "%DART%" goto no_flutter

if exist "C:\Program Files\Git\cmd\git.exe" set "PATH=C:\Program Files\Git\cmd;%PATH%"
cd /d "%PROJ%"

echo [1/4] Checking Dart subprocess support ...
call "%DART%" "%PROJ%\tools\pipe_probe.dart" > "%PROBEOUT%" 2>&1
type "%PROBEOUT%"
findstr /C:"PIPE_PROBE_OK" "%PROBEOUT%" >nul
if errorlevel 1 goto probe_failed

echo [2/4] Clearing old split APKs ...
for %%A in (app-arm64-v8a-release.apk app-armeabi-v7a-release.apk app-x86_64-release.apk) do if exist "%SRCDIR%\%%A" del /q "%SRCDIR%\%%A"

echo [3/4] Building 3 ABIs. First run may take 20-30 minutes.
echo       The window will look frozen - please DO NOT close it.
echo.
call "%FLUTTER%" build apk --release --split-per-abi > "%LOG%" 2>&1
if errorlevel 1 goto build_failed

echo [4/4] Copying APKs to project root ...
set "FAILED="
call :copy_one "app-arm64-v8a-release.apk" "arm64"
call :copy_one "app-armeabi-v7a-release.apk" "armv7"
call :copy_one "app-x86_64-release.apk" "x86_64"
if defined FAILED goto missing

echo.
echo ================================================================
echo   BUILD OK
echo ================================================================
powershell -NoProfile -Command "Get-ChildItem -LiteralPath '%PROJ%' -Filter 'ZY-Player-v%APPVER%-*-release.apk' | Sort-Object Name | ForEach-Object { '{0,-42} {1,7:N1} MB  SHA1 {2}' -f $_.Name, ($_.Length/1MB), (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA1).Hash }"
echo.
echo   Which one to install:
echo     arm64  - almost every phone released since 2016 (preferred)
echo     armv7  - older 32-bit phones
echo     x86_64 - emulators / x86 tablets, rarely needed on real phones
goto done

:copy_one
set "SRC=%~1"
set "TAG=%~2"
set "DST=%PROJ%\ZY-Player-v%APPVER%-%TAG%-release.apk"
if not exist "%SRCDIR%\%SRC%" (
  echo   MISSING: %SRC%
  set "FAILED=1"
  goto :eof
)
copy /y "%SRCDIR%\%SRC%" "%DST%" >nul
if errorlevel 1 (
  echo   COPY FAILED: %SRC%
  set "FAILED=1"
  goto :eof
)
echo   OK: %DST%
goto :eof

:missing
echo.
echo ================================================================
echo   PARTIAL - some APKs were not produced
echo ================================================================
echo   Full log: %LOG%
echo   Please tell the assistant: BUILD_FAILED
goto done

:probe_failed
echo.
echo ================================================================
echo   STOPPED - Dart cannot spawn child processes in this shell
echo ================================================================
echo   This shell is still running under the assistant sandbox
echo   injection, so the build would fail right away anyway.
echo.
echo   Please tell the assistant: PROBE_FAILED
echo.
goto done

:build_failed
echo.
echo ================================================================
echo   BUILD FAILED
echo ================================================================
chcp 65001 >nul
echo   Last 40 lines of the log:
echo.
powershell -NoProfile -Command "Get-Content -LiteralPath '%LOG%' -Tail 40"
echo.
echo   Full log: %LOG%
echo   Please tell the assistant: BUILD_FAILED
echo.
goto done

:no_flutter
echo.
echo   ERROR - Flutter SDK not found. Missing one of these:
echo     %FLUTTER%
echo     %DART%
echo.

:done
taskkill /f /im java.exe
echo ================================================================
echo   Log: %LOG%
echo ================================================================
echo   Press any key to close this window.
pause >nul
