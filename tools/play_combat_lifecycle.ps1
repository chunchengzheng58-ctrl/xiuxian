param([string]$Godot = $env:GODOT4, [switch]$Preview)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $Godot) {
  $candidates = @()
  foreach ($pattern in @('Godot*_console.exe', 'Godot*.exe')) {
    $candidates += Get-ChildItem -Path (Join-Path $repo '.tools') -Filter $pattern -Recurse -ErrorAction SilentlyContinue |
      ForEach-Object { $_.FullName }
  }
  foreach ($name in @('Godot_v4.7.2-stable_win64_console.exe', 'Godot_v4.7.2-stable_win64.exe', 'godot.exe')) {
    $found = Get-Command $name -ErrorAction SilentlyContinue
    if ($found) { $candidates += $found.Source }
  }
  $Godot = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}
if (-not $Godot -or -not (Test-Path -LiteralPath $Godot)) {
  throw 'Godot 4.7.2 not found. Set GODOT4, pass -Godot <path>, or place the portable build under .tools\godot-4.7.2\.'
}
$env:APPDATA = Join-Path $repo 'work/play-a/appdata'
$env:XIUXIAN_A_OUTPUT_DIR = Join-Path $repo 'outputs/combat-lifecycle'
New-Item -ItemType Directory -Force -Path $env:APPDATA, $env:XIUXIAN_A_OUTPUT_DIR | Out-Null
& $Godot --headless --path $repo --editor --import --quit --log-file (Join-Path $repo 'work/play-a/import.log')
if ($LASTEXITCODE -ne 0) { throw 'Project import failed.' }
$arguments = @('--path', $repo, '--scene', 'res://scenes/main.tscn', '--log-file', (Join-Path $repo 'work/play-a/play.log'), '--', '--kernel-ephemeral')
if ($Preview) { $arguments += @('--preview', '--skip-intro') }
& $Godot @arguments
exit $LASTEXITCODE
