@echo off
setlocal
title Restore 360 / Xunlei kernel components

net session >nul 2>&1
if errorlevel 1 goto need_admin

echo ================================================================
echo   Restore 360 / Xunlei kernel components
echo ================================================================
echo.
echo This undoes disable_security_kernel.bat and puts the original
echo start type back for every component. A reboot is required.
echo.
pause

echo Working ...
sc config "360Sensor" start= auto >nul 2>&1
sc config "360Sensor_DM" start= auto >nul 2>&1
sc config "360Hvm" start= auto >nul 2>&1
sc config "360Safe HVM" start= auto >nul 2>&1
sc config "360FileService" start= auto >nul 2>&1
sc config "360SPService" start= auto >nul 2>&1
sc config "360FsFlt" start= auto >nul 2>&1
sc config "360Box64" start= auto >nul 2>&1
sc config "360AntiSteal" start= auto >nul 2>&1
sc config "XLGuard" start= system >nul 2>&1
sc config "XLWFP" start= auto >nul 2>&1
sc config "XLServicePlatform" start= auto >nul 2>&1

echo.
echo ================================================================
echo   DONE - reboot to apply.
echo ================================================================
goto done

:need_admin
echo.
echo   ERROR - administrator rights are required.
echo   Right-click this file, then choose "Run as administrator".
echo.

:done
echo   Press any key to close this window.
pause >nul
