@echo off
setlocal
title Disable 360 / Xunlei kernel components

net session >nul 2>&1
if errorlevel 1 goto need_admin

echo ================================================================
echo   Disable 360 / Xunlei kernel components
echo ================================================================
echo.
echo This stops and disables the following services and drivers:
echo   360Sensor  360Sensor_DM  360Hvm  360Safe HVM
echo   360FileService  360SPService
echo   360FsFlt  360Box64  360AntiSteal
echo   XLGuard  XLWFP  XLServicePlatform
echo.
echo All of them are kernel-level components of leftover 360 products
echo and of Xunlei. They are the prime suspects for the named-pipe
echo block that stops Dart from spawning subprocesses.
echo.
echo Skipped automatically if a name does not exist on this machine.
echo Everything is reversible - run restore_security_kernel.bat.
echo.
pause

echo Working ...
sc stop "360Sensor" >nul 2>&1
sc config "360Sensor" start= disabled >nul 2>&1
sc stop "360Sensor_DM" >nul 2>&1
sc config "360Sensor_DM" start= disabled >nul 2>&1
sc stop "360Hvm" >nul 2>&1
sc config "360Hvm" start= disabled >nul 2>&1
sc stop "360Safe HVM" >nul 2>&1
sc config "360Safe HVM" start= disabled >nul 2>&1
sc stop "360FileService" >nul 2>&1
sc config "360FileService" start= disabled >nul 2>&1
sc stop "360SPService" >nul 2>&1
sc config "360SPService" start= disabled >nul 2>&1
sc stop "360FsFlt" >nul 2>&1
sc config "360FsFlt" start= disabled >nul 2>&1
sc stop "360Box64" >nul 2>&1
sc config "360Box64" start= disabled >nul 2>&1
sc stop "360AntiSteal" >nul 2>&1
sc config "360AntiSteal" start= disabled >nul 2>&1
sc stop "XLGuard" >nul 2>&1
sc config "XLGuard" start= disabled >nul 2>&1
sc stop "XLWFP" >nul 2>&1
sc config "XLWFP" start= disabled >nul 2>&1
sc stop "XLServicePlatform" >nul 2>&1
sc config "XLServicePlatform" start= disabled >nul 2>&1

echo.
echo Current state of the same list:
sc query "360Sensor" | findstr STATE
sc query "360Sensor_DM" | findstr STATE
sc query "360Hvm" | findstr STATE
sc query "360Safe HVM" | findstr STATE
sc query "XLGuard" | findstr STATE
sc query "XLWFP" | findstr STATE
sc query "XLServicePlatform" | findstr STATE

echo.
echo ================================================================
echo   DONE
echo ================================================================
echo   1. Reboot the computer now.
echo   2. After the reboot, double-click build_apk.bat again.
echo.
goto done

:need_admin
echo.
echo   ERROR - administrator rights are required.
echo   Right-click this file, then choose "Run as administrator".
echo.

:done
echo   Press any key to close this window.
pause >nul
