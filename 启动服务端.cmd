@echo off
setlocal
REM Start the local game server at http://127.0.0.1:8080
REM Node lookup: %NODE24% -> system install (%ProgramFiles%\nodejs) -> node on PATH
set "NODE="
if defined NODE24 if exist "%NODE24%" set "NODE=%NODE24%"
if not defined NODE if exist "%ProgramFiles%\nodejs\node.exe" set "NODE=%ProgramFiles%\nodejs\node.exe"
if not defined NODE (
  for /f "delims=" %%P in ('where node.exe 2^>nul') do if not defined NODE set "NODE=%%P"
)
if not defined NODE (
  echo Node.js not found. This project needs Node 24.13.x or a later Node 24 release.
  pause
  exit /b 1
)
"%NODE%" -e "const [major,minor]=process.versions.node.split('.').map(Number);process.exit(major===24 && minor>=13 ? 0 : 1)"
if errorlevel 1 (
  echo Unsupported Node version. Set NODE24 to Node 24.13.x or a later Node 24 release.
  "%NODE%" -v
  pause
  exit /b 1
)
pushd "%~dp0server"
if not exist "node_modules\tsx\dist\cli.mjs" (
  echo Server dependencies missing. Run "npm ci" inside the server folder first.
  popd
  pause
  exit /b 1
)
echo Using Node: %NODE%
"%NODE%" node_modules\tsx\dist\cli.mjs src\main.ts
popd
endlocal
