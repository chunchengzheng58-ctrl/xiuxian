param([Parameter(Mandatory=$true)][string]$ArchivePath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead([System.IO.Path]::GetFullPath($ArchivePath))
try {
  $reader = [System.IO.StreamReader]::new($archive.GetEntry('manifest.json').Open())
  try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
  if ($archive.Entries.Count -ne $manifest.files.Count + 1) { throw 'Unexpected archive entry count.' }
  foreach ($file in $manifest.files) {
    if ($file.name -match '(^|/)(data-save|override\.cfg|desktop-test\.|\.env)') { throw 'Unexpected data or test file in release.' }
    $entry = $archive.GetEntry($file.name)
    if ($null -eq $entry -or $entry.Length -ne $file.bytes) { throw "ZIP length mismatch: $($file.name)" }
    $stream = $entry.Open()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $actual = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
    if ($actual -ne $file.sha256) { throw "ZIP hash mismatch: $($file.name)" }
  }
  [pscustomobject]@{ passed = $true; checkedFiles = $manifest.files.Count; zipBytes = (Get-Item -LiteralPath $ArchivePath).Length; zipSha256 = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant() } | ConvertTo-Json -Compress
} finally { $archive.Dispose() }
