@echo off
rem One-click clean rebuild of Strakalari.exe + the Windows installer.
rem Double-click, no admin needed. Requires 'uv' on PATH (first run only)
rem and Inno Setup 6 (winget install JRSoftware.InnoSetup).
setlocal
cd /d "%~dp0"

if not exist ".venv-build\Scripts\python.exe" (
  echo [build] Creating Python 3.11 build env, this takes a while on first run...
  uv venv --python 3.11 .venv-build || (echo [build] FAILED: uv venv & exit /b 1)
)
echo [build] Syncing build dependencies...
uv pip install --python .venv-build\Scripts\python.exe -r requirements.txt || (echo [build] FAILED: pip install & exit /b 1)

echo [build] Removing old artifacts...
rmdir /s /q dist 2>nul
rmdir /s /q build 2>nul
del /q output\*.exe 2>nul

echo [build] PyInstaller...
.venv-build\Scripts\python.exe -m PyInstaller strakalari.spec || (echo [build] FAILED: PyInstaller & exit /b 1)

set RAW=
for /f "tokens=2 delims== " %%v in ('findstr /b "__version__" strakalari\__init__.py') do set RAW=%%v
set VER=%RAW:"=%
set VER=%VER:'=%
if not defined VER (echo [build] FAILED: version detect & exit /b 1)
echo [build] Version: %VER%

set "ISCC=%LocalAppData%\Programs\Inno Setup 6\ISCC.exe"
if not exist "%ISCC%" set "ISCC=%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"
if not exist "%ISCC%" (
  echo [build] FAILED: ISCC.exe not found. Install Inno Setup 6 first.
  exit /b 1
)

echo [build] Inno Setup...
"%ISCC%" /DMyAppVersion="%VER%" installer.iss || (echo [build] FAILED: ISCC. If EndUpdateResource error 110, delete output\*.exe and retry - antivirus lock. & exit /b 1)

echo [build] Done: output\Strakalari-Setup-%VER%.exe
