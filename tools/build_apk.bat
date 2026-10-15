@echo off
setlocal
title ZY-Player APK Builder

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
set "APK=%PROJ%\build\app\outputs\flutter-apk\app-release.apk"
rem --- derive version from pubspec.yaml so the APK name never goes stale ---
set "APPVER="
for /f "tokens=2" %%V in ('findstr /b /c:"version:" "%PROJ%\pubspec.yaml"') do set "APPVER=%%V"
if not defined APPVER set "APPVER=0.0.0+0"
for /f "tokens=1 delims=+" %%B in ("%APPVER%") do set "APPVER=%%B"
set "OUT=%PROJ%\ZY-Player-v%APPVER%-arm64-release.apk"

echo ================================================================
echo   ZY-Player Flutter  -  release APK builder
echo ================================================================
echo   Version: %APPVER%
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

echo [2/4] Clearing old APK ...
if exist "%APK%" del /q "%APK%"

echo [3/4] Building. This takes about 6 to 15 minutes.
echo       The window will look frozen - please DO NOT close it.
echo.
call "%FLUTTER%" build apk --release --target-platform android-arm64 > "%LOG%" 2>&1
if errorlevel 1 goto build_failed
if not exist "%APK%" goto build_failed

echo [4/4] Copying APK to project root ...
copy /y "%APK%" "%OUT%" >nul

echo.
echo ================================================================
echo   BUILD OK
echo ================================================================
echo   File: %OUT%
for %%F in ("%OUT%") do echo   Size: %%~zF bytes
powershell -NoProfile -Command "(Get-FileHash -LiteralPath '%OUT%' -Algorithm SHA1).Hash"
echo.
echo   Install it on the phone and test it now.
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
