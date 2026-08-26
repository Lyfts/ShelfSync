@echo off
setlocal
set "SCRIPT_DIR=%~dp0"

rem Prefer uv: it reads the dependency metadata at the top of fetch_cookies.py
rem and installs browser_cookie3 into an ephemeral env automatically, so
rem there's no separate `pip install` step.
where uv >nul 2>nul
if not errorlevel 1 (
    uv run "%SCRIPT_DIR%support\fetch_cookies.py" %*
    exit /b %errorlevel%
)

where python >nul 2>nul
if not errorlevel 1 (
    python "%SCRIPT_DIR%support\fetch_cookies.py" %*
    exit /b %errorlevel%
)

where py >nul 2>nul
if not errorlevel 1 (
    py -3 "%SCRIPT_DIR%support\fetch_cookies.py" %*
    exit /b %errorlevel%
)

echo error: neither uv nor Python found -- install uv (https://docs.astral.sh/uv/) or Python 3 (https://www.python.org/downloads/) 1>&2
exit /b 1
