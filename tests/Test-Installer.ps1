param([Parameter(Mandatory=$true)][string]$OriginalDirectory,[Parameter(Mandatory=$true)][string]$WorkDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$manifest=Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (Test-Path -LiteralPath $WorkDirectory) { throw 'Test directory must not exist' }
New-Item -ItemType Directory -Path $WorkDirectory | Out-Null
$work=(Resolve-Path -LiteralPath $WorkDirectory).Path
$script:checks=0
function Check($value,[string]$message) { $script:checks++; if (-not $value) { throw ('FAIL: '+$message) } }
function Fixture([string]$name) {
    $destination=Join-Path $work $name
    foreach ($entry in $manifest.OriginalFiles) {
        $to=Join-Path $destination $entry.Path
        New-Item -ItemType Directory -Path (Split-Path $to -Parent) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $OriginalDirectory $entry.Path) -Destination $to
    }
    return $destination
}
function Install([string]$package,[string]$original) {
    $log=Join-Path $work ('install-'+$script:checks+'.log')
    $oldPreference=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        $result=& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package 'Install-Zh.ps1') -OriginalDirectory $original 2> $log
        $code=$LASTEXITCODE
    } finally { $ErrorActionPreference=$oldPreference }
    $result | Out-File -LiteralPath $log -Append -Encoding UTF8
    return $code
}
function Copy-Package([string]$name) {
    $destination=Join-Path $work $name
    New-Item -ItemType Directory -Path $destination | Out-Null
    foreach ($entry in $manifest.PayloadFiles) {
        $to=Join-Path $destination $entry.Path
        New-Item -ItemType Directory -Path (Split-Path $to -Parent) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root $entry.Path) -Destination $to
    }
    Copy-Item -LiteralPath (Join-Path $root 'manifest.json') -Destination $destination
    return $destination
}
$good=Fixture 'official'
Check ((Install $root $good) -eq 0) 'fresh matching baseline installs'
$target=Join-Path $good 'ZH'
$state=Get-Content -LiteralPath (Join-Path $target 'installation.json') -Raw | ConvertFrom-Json
Check ($state.Ready -eq $true) 'ready marker only after successful installation'
Add-Type -Path (Join-Path $root 'src/ResourcePatch.cs')
foreach ($entry in $manifest.Patches) {
    [SiZh.ResourcePatch]::Verify((Join-Path $target $entry.Module),[IO.File]::ReadAllBytes((Join-Path $root $entry.Resource)))
}
Check ($manifest.Patches.Count -eq 16) 'all 16 patched modules read back exactly'
foreach ($entry in $manifest.OriginalFiles) {
    Check ((Get-FileHash -LiteralPath (Join-Path $good $entry.Path)).Hash -eq $entry.SHA256) ('source unchanged: '+$entry.Path)
}
Check (-not (Test-Path -LiteralPath (Join-Path $target 'SystemInformer.sys'))) 'driver not copied'
$settings=Get-Content -LiteralPath (Join-Path $target 'SystemInformer.exe.settings.json') -Raw | ConvertFrom-Json
Check (@($settings.PSObject.Properties).Count -eq 6 -and $settings.KsiEnable -eq '0') 'clean settings without personal configuration'
$marker=(Get-FileHash -LiteralPath (Join-Path $target 'installation.json')).Hash
Check ((Install $root $good) -ne 0) 'existing ZH refused'
Check ((Get-FileHash -LiteralPath (Join-Path $target 'installation.json')).Hash -eq $marker) 'existing marker unchanged'
$bad=Fixture 'bad-hash'
$badFile=Join-Path $bad 'plugins/DotNetTools.dll'
$bytes=[IO.File]::ReadAllBytes($badFile); $bytes[100]=$bytes[100] -bxor 1; [IO.File]::WriteAllBytes($badFile,$bytes)
Check ((Install $root $bad) -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $bad 'ZH'))) 'bad original hash refused before writes'
$tamper=Copy-Package 'tamper'
$badFile=Join-Path $tamper 'payload/x64/ThirdPartyManager.dll'
$bytes=[IO.File]::ReadAllBytes($badFile); $bytes[100]=$bytes[100] -bxor 1; [IO.File]::WriteAllBytes($badFile,$bytes)
$fresh=Fixture 'fresh'
Check ((Install $tamper $fresh) -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $fresh 'ZH'))) 'bad payload hash refused before writes'
$junction=Join-Path $work 'junction'
New-Item -ItemType Junction -Path $junction -Target $fresh | Out-Null
Check ((Install $root $junction) -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $fresh 'ZH'))) 'directory junction refused'
$escape=Copy-Package 'escape'
$altered=Get-Content -LiteralPath (Join-Path $escape 'manifest.json') -Raw | ConvertFrom-Json
$altered.OriginalFiles[0].Path='../outside.txt'
$altered | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $escape 'manifest.json') -Encoding UTF8
Check ((Install $escape $fresh) -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $fresh 'ZH'))) 'manifest path escape refused'
$partial=Copy-Package 'partial'
$altered=Get-Content -LiteralPath (Join-Path $partial 'manifest.json') -Raw | ConvertFrom-Json
$altered.Patches[0].Module='nonexistent.exe'
$altered | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $partial 'manifest.json') -Encoding UTF8
Check ((Install $partial $fresh) -ne 0) 'resource application failure reported'
Check ((Test-Path -LiteralPath (Join-Path $fresh 'ZH/INSTALL-FAILED.txt')) -and -not (Test-Path -LiteralPath (Join-Path $fresh 'ZH/installation.json'))) 'partial installation has failure marker and no ready marker'
Write-Output ('PASS: installer checks='+$script:checks)
