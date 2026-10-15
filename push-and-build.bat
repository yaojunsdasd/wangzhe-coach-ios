@echo off
setlocal
cd /d "%~dp0"

echo ============================================================
echo   Wangzhe Coach - iOS Build Script
echo ============================================================
echo.

where git >nul 2>nul
if errorlevel 1 (
    echo [ERROR] git not found
    echo         Install: https://git-scm.com/download/win
    pause
    exit /b 1
)

set "GHUSER="
set /p GHUSER=GitHub username: 
if "%GHUSER%"=="" (
    echo [ERROR] username required
    pause
    exit /b 1
)

set "GHREPO="
set /p GHREPO=Repo name [default: wangzhe-coach-ios]: 
if "%GHREPO%"=="" set "GHREPO=wangzhe-coach-ios"

echo.
echo Target: https://github.com/%GHUSER%/%GHREPO%.git
echo.

if not exist ".git" (
    echo [1/3] git init ...
    git init -q
    git branch -M main
) else (
    echo [1/3] .git exists, skip init
)

git add -A
git commit -q -m "iOS v0.1 test build" 2>nul

echo [2/3] push ...
echo.
echo   NOTE: create an EMPTY repo on GitHub first (no README)
echo.
pause

git remote remove origin 2>nul
git remote add origin https://github.com/%GHUSER%/%GHREPO%.git
git push -u origin main

if errorlevel 1 (
    echo.
    echo [FAILED] common causes:
    echo   1. repo not created yet
    echo   2. need login - browser will open
    echo   3. wrong username/repo
    pause
    exit /b 1
)

echo.
echo ============================================================
echo   PUSHED OK
echo ============================================================
echo.
echo Next:
echo   1. open https://github.com/%GHUSER%/%GHREPO%/actions
echo   2. wait for "Build iOS IPA" (5-10 min)
echo   3. download Artifacts at bottom of the run page
echo   4. unzip to get WangzheCoach-unsigned.ipa
echo   5. sign with your certificate and install
echo.
echo   If build fails, download build-log and send it to me
echo.
pause
