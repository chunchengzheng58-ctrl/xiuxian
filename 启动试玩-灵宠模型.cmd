@echo off
setlocal
REM Start the companion chat service (DeepSeek) and point the game at it.
call "%~dp0tools\resolve-godot.cmd"
if not defined GODOT (
  echo Godot 4.7.2 not found.
  echo   - set GODOT4 to Godot_v4.7.2-stable_win64.exe, or
  echo   - put the portable build under .tools\godot-4.7.2\, or
  echo   - open project.godot with Godot and press F5.
  pause
  exit /b 1
)
if not exist "%~dp0companion-service\.env" (
  echo companion-service\.env is missing.
  echo Run: copy companion-service\.env.example companion-service\.env
  echo Then put a DeepSeek key into LLM_API_KEY. Without it the service still starts in stub mode.
)
start "companion chat service" /min cmd /c ""%~dp0companion-service\启动灵宠聊天服务.cmd""
timeout /t 3 >nul
set "XIUXIAN_COMPANION_API_URL=http://127.0.0.1:8031/api/v1/companion/chat"
set "XIUXIAN_COMPANION_AUTH_ORIGIN=http://127.0.0.1:8031"
if not exist "%~dp0work\appdata" mkdir "%~dp0work\appdata"
set "APPDATA=%~dp0work\appdata"
start "" "%GODOT%" --path "%~dp0." --rendering-method gl_compatibility --log-file "%~dp0work\play.log"
endlocal
