@echo off
title Strakalari
cd /d "%~dp0"

echo ========================================================
echo   Spoustim Strakalari...
echo ========================================================

if exist ".\.venv\Scripts\python.exe" (
    ".\.venv\Scripts\python.exe" main.py %*
) else (
    echo [VAROVANI] .venv nenalezen, pouzivam systemovy python ^(vyzadovano 3.11-3.12^).
    python main.py %*
)

if %ERRORLEVEL% neq 0 (
    echo.
    echo [CHYBA] Aplikace se ukoncila s chybou ^(%ERRORLEVEL%^).
    pause
)
