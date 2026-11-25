@echo off
REM Resolve the Godot 4.7.2 executable into the GODOT variable.
REM Lookup order: %GODOT4% -> .tools\godot-* in this repo -> PATH.
set "GODOT="
if defined GODOT4 if exist "%GODOT4%" set "GODOT=%GODOT4%"
if not defined GODOT (
  for /d %%D in ("%~dp0..\.tools\godot-*") do (
    if not defined GODOT if exist "%%~fD\Godot_v4.7.2-stable_win64.exe" set "GODOT=%%~fD\Godot_v4.7.2-stable_win64.exe"
  )
)
if not defined GODOT (
  for /d %%D in ("%~dp0..\.tools\godot-*") do (
    if not defined GODOT for %%F in ("%%~fD\Godot*.exe") do if exist "%%~fF" set "GODOT=%%~fF"
  )
)
if not defined GODOT (
  for /f "delims=" %%P in ('where Godot_v4.7.2-stable_win64.exe 2^>nul') do if not defined GODOT set "GODOT=%%P"
)
if not defined GODOT (
  for /f "delims=" %%P in ('where godot.exe 2^>nul') do if not defined GODOT set "GODOT=%%P"
)
exit /b 0
