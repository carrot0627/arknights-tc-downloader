@echo off
setlocal
cd /d "%~dp0"
echo ============================================================
echo  AkDownloader - HyperGryph launcher package accelerator
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0AkDownloader.ps1" %*
set RC=%errorlevel%
if not "%RC%"=="0" (
  echo.
  echo [script exited with code %RC%] press any key to close
  pause >nul
)
endlocal
