param(
  [Parameter(Mandatory=$true)][string]$InputDirectory,
  [Parameter(Mandatory=$true)][string]$Destination
)
$ErrorActionPreference = 'Stop'
$sourceRoot = (Resolve-Path -LiteralPath $InputDirectory).Path
$zipPath = [System.IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $zipPath) { throw 'ZIP target already exists; choose a fresh filename.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$manifest = Get-Content -LiteralPath (Join-Path $sourceRoot 'manifest.json') -Raw | ConvertFrom-Json
$archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
  foreach ($file in $manifest.files) {
    $full = [System.IO.Path]::GetFullPath((Join-Path $sourceRoot $file.name))
    if (-not $full.StartsWith($sourceRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid manifest path.' }
    if ((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.sha256) { throw "File changed after manifest: $($file.name)" }
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $full, $file.name, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
  }
  [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $sourceRoot 'manifest.json'), 'manifest.json', [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
} finally { $archive.Dispose() }
Get-Item -LiteralPath $zipPath | Select-Object FullName, Length
