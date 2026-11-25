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
start "" "%GODOT%" --path "%~dp0." --scene res://scenes/lowpoly.tscn --rendering-method gl_compatibility --log-file "%~dp0output\lowpoly-play.log"
endlocal
