$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $root 'src/ResourcePatch.cs')
$res=Get-ChildItem -LiteralPath (Join-Path $root 'patches') -Filter '*.res' | Select-Object -First 1
$items=[SiZh.ResourcePatch]::Read([IO.File]::ReadAllBytes($res.FullName))
if ($items.Count -lt 1) { throw 'DIALOG resources not parsed' }
foreach ($item in $items) { if ($item.Type -ne 5 -or $item.Data.Length -lt 4) { throw 'Unexpected resource entry' } }
$bad=[byte[]](1,2,3,4,5,6,7)
$refused=$false; try { [SiZh.ResourcePatch]::Read($bad) | Out-Null } catch { $refused=$true }
if (-not $refused) { throw 'Truncated resource accepted' }
$bytes=[IO.File]::ReadAllBytes($res.FullName)
$bytes[4]=255; $bytes[5]=255; $bytes[6]=255; $bytes[7]=127
$refused=$false; try { [SiZh.ResourcePatch]::Read($bytes) | Out-Null } catch { $refused=$true }
if (-not $refused) { throw 'Out of bounds header accepted' }
Write-Output ('PASS: resource parse, DIALOG-only validation, truncated file and oversized header refusal; entries='+$items.Count)
$named=0; $total=0
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'patches') -Filter '*.res') {
    $entries=[SiZh.ResourcePatch]::Read([IO.File]::ReadAllBytes($file.FullName))
    $total += $entries.Count
    foreach ($entry in $entries) { if ($entry.TextName) { $named++ } }
}
if ($named -eq 0) { throw 'Named DIALOG resources not parsed' }
Write-Output ('PASS: all 16 resource files; entries='+$total+'; named='+$named)
