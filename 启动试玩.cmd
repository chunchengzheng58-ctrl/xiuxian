@echo off
setlocal
call "%~dp0tools\resolve-godot.cmd"
if not defined GODOT (
  echo Godot 4.7.2 not found.
  echo   - set GODOT4 to Godot_v4.7.2-stable_win64.exe, or
  echo   - put the portable build under .tools\godot-4.7.2\, or
  echo   - open project.godot with Godot and press F5.
  pause
  exit /b 1
)
if not exist "%~dp0work\appdata" mkdir "%~dp0work\appdata"
set "APPDATA=%~dp0work\appdata"
REM 老人端微信绑定走 D 侧车（8002），客户端默认写的是 8000。
if not defined XIUXIAN_WECHAT_URL set "XIUXIAN_WECHAT_URL=http://127.0.0.1:8002"
start "" "%GODOT%" --path "%~dp0." --rendering-method gl_compatibility --log-file "%~dp0work\play.log"
endlocal
