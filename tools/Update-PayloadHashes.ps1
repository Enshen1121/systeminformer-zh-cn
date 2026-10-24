$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$file=Join-Path $root 'manifest.json'
$manifest=Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
$manifest.PayloadFiles=@(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
    $relative=$_.FullName.Substring($root.Length+1)
    $relative -ne 'manifest.json' -and $relative -notmatch '^(\.git|build|test-work)[\\/]'
} | Sort-Object FullName | ForEach-Object {
    [pscustomobject]@{Path=$_.FullName.Substring($root.Length+1).Replace('\','/');SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
})
[IO.File]::WriteAllText($file,($manifest | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
Write-Output ('Payload hashes: '+$manifest.PayloadFiles.Count)
