@echo off
setlocal
title ZY-Player Windows Builder

set "PROJ=D:\WorkBuddy\ZY-Player-Flutter"
set "FLUTTER=C:\flutter\bin\flutter.bat"
set "LOG=%PROJ%\tools\build_windows_log.txt"
set "REL=%PROJ%\build\windows\x64\runner\Release"
set "EXE=%REL%\zy_player.exe"
rem --- derive version from pubspec.yaml so the zip name never goes stale ---
set "APPVER="
for /f "tokens=2" %%V in ('findstr /b /c:"version:" "%PROJ%\pubspec.yaml"') do set "APPVER=%%V"
if not defined APPVER set "APPVER=0.0.0+0"
for /f "tokens=1 delims=+" %%B in ("%APPVER%") do set "APPVER=%%B"
set "ZIP=%PROJ%\ZY-Player-v%APPVER%-windows-x64.zip"

echo ================================================================
echo   ZY-Player Flutter  -  Windows x64 release builder
echo ================================================================
echo   Version: %APPVER%
echo.

if not exist "%FLUTTER%" goto no_flutter

if exist "C:\Program Files\Git\cmd\git.exe" set "PATH=C:\Program Files\Git\cmd;%PATH%"
cd /d "%PROJ%"

echo [1/4] Clearing old zip ...
if exist "%ZIP%" del /q "%ZIP%"

echo [2/4] Building. First build downloads the fvp SDK and compiles
echo       C++ code. This takes about 5 to 15 minutes.
echo       The window will look frozen - please DO NOT close it.
echo.
call "%FLUTTER%" build windows --release > "%LOG%" 2>&1
if errorlevel 1 goto build_failed
if not exist "%EXE%" goto build_failed

echo [3/4] Packing portable zip ...
powershell -NoProfile -Command "Compress-Archive -Path '%REL%\*' -DestinationPath '%ZIP%' -Force" >> "%LOG%" 2>&1
if errorlevel 1 goto zip_failed

echo [4/4] Done.
echo.
echo ================================================================
echo   BUILD OK
echo ================================================================
echo   EXE : %EXE%
echo   ZIP : %ZIP%
for %%F in ("%ZIP%") do echo   Size: %%~zF bytes
echo.
echo   The Release folder is fully portable - you can copy
echo   zy_player.exe together with its dll files and data folder.
echo.
goto done

:zip_failed
echo.
echo   WARN - zip packing failed, but the build itself is OK.
echo   You can still run the app directly:
echo     %EXE%
echo   See log for the Compress-Archive error.
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
echo   ERROR - Flutter SDK not found:
echo     %FLUTTER%
echo.

:done
echo ================================================================
echo   Log: %LOG%
echo ================================================================
echo   Press any key to close this window.
pause >nul
