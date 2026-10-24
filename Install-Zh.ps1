param([Parameter(Mandatory=$true)][string]$OriginalDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if (-not [Environment]::Is64BitOperatingSystem) { throw '本版仅面向 Windows x64 系统' }
function Assert-NoReparse([string]$Path) {
    $cursor=[IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('拒绝目录联接或符号链接：'+$cursor) }
        }
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }; $cursor=$parent
    }
}
function Join-Contained([string]$Root,[string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':')) { throw '不允许绝对路径或数据流' }
    $full=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $full.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '路径越界' }
    Assert-NoReparse $full
    return $full
}
$source=(Resolve-Path -LiteralPath $OriginalDirectory).Path.TrimEnd('\')
if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw '官方程序目录不存在' }
Assert-NoReparse $source
Assert-NoReparse $PSScriptRoot
$target=Join-Path $source 'ZH'
if (Test-Path -LiteralPath $target) { throw 'ZH 已存在。为保护现有文件，不会覆盖；请使用另一份干净的官方程序副本。' }
$manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$main=Join-Contained $source 'SystemInformer.exe'
if ([Diagnostics.FileVersionInfo]::GetVersionInfo($main).FileVersion -ne $manifest.HostVersion) { throw ('仅支持官方版本 '+$manifest.HostVersion) }
# Validate every input before creating ZH. A version string alone is insufficient.
foreach ($entry in $manifest.OriginalFiles) {
    $path=Join-Contained $source $entry.Path
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.SHA256) { throw ('官方文件不匹配，未开始安装：'+$entry.Path) }
}
foreach ($entry in $manifest.PayloadFiles) {
    $path=Join-Contained $PSScriptRoot $entry.Path
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.SHA256) { throw ('补丁文件校验失败：'+$entry.Path) }
}
Add-Type -Path (Join-Path $PSScriptRoot 'src/ResourcePatch.cs')
foreach ($entry in $manifest.Patches) {
    [SiZh.ResourcePatch]::Read([IO.File]::ReadAllBytes((Join-Contained $PSScriptRoot $entry.Resource))) | Out-Null
}
New-Item -ItemType Directory -Path $target | Out-Null
try {
    foreach ($entry in $manifest.OriginalFiles) {
        $from=Join-Contained $source $entry.Path; $to=Join-Contained $target $entry.Path
        New-Item -ItemType Directory -Path (Split-Path $to -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $from -Destination $to
        if ((Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash -ne $entry.SHA256) { throw ('复制后校验失败：'+$entry.Path) }
    }
    foreach ($entry in $manifest.Patches) {
        [SiZh.ResourcePatch]::Apply((Join-Contained $target $entry.Module),[IO.File]::ReadAllBytes((Join-Contained $PSScriptRoot $entry.Resource)))
    }
    foreach ($entry in $manifest.InstallFiles) {
        $from=Join-Contained $PSScriptRoot $entry.From; $to=Join-Contained $target $entry.To
        New-Item -ItemType Directory -Path (Split-Path $to -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $from -Destination $to
    }
    $settings='{"EnablePlugins":"1","EnableDefaultSafePlugins":"0","AllowOnlyOneInstance":"0","KsiEnable":"0","DisabledPlugins":"Updater.dll","UpdateChecker.PromptStart":"0"}'
    foreach ($relative in @('SystemInformer.exe.settings.json','x86\SystemInformer.exe.settings.json')) {
        [IO.File]::WriteAllText((Join-Contained $target $relative),$settings,(New-Object Text.UTF8Encoding($false)))
    }
    foreach ($relative in @('work','work\third-party','x86\work','outputs\third-party')) { New-Item -ItemType Directory -Path (Join-Contained $target $relative) -Force | Out-Null }
    foreach ($relative in @('Start-ZH.cmd','x86\Start-ZH.cmd')) {
        [IO.File]::WriteAllText((Join-Contained $target $relative),"@echo off`r`nstart `"`" `"%~dp0SystemInformer.exe`" -nokph -newinstance -v`r`n",[Text.Encoding]::ASCII)
    }
    $state=[ordered]@{Release=$manifest.Release;HostVersion=$manifest.HostVersion;ModifiedModules=@($manifest.Patches.Module);DriverMode='Disabled';Ready=$true}
    [IO.File]::WriteAllText((Join-Contained $target 'installation.json'),($state | ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
    Write-Output ('完成。请运行：'+(Join-Path $target 'Start-ZH.cmd'))
    Write-Output '非官方预览版；修改过的模块不再具有原发行方有效数字签名。原目录和系统安全设置未修改。'
} catch {
    $errorMessage=$_.Exception.Message
    [IO.File]::WriteAllText((Join-Contained $target 'INSTALL-FAILED.txt'),$errorMessage,(New-Object Text.UTF8Encoding($false)))
    throw ('安装未完成，不能将此 ZH 作为可用版本。原程序未修改。原因：'+$errorMessage)
}
