param([Parameter(Mandatory=$true)][string]$Changes)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\backend.ps1" -Mode Library
$resolved=(Resolve-Path -LiteralPath $Changes).Path
if (-not (Test-Under $resolved (Join-Path $script:DataRoot 'history'))) { throw '请使用本工具 history 目录中的 changes.json' }
$records=@(Get-Content -LiteralPath $resolved -Raw -Encoding UTF8 | ConvertFrom-Json)
$snapshot=Get-Content -LiteralPath (Join-Path (Split-Path $resolved -Parent) 'snapshot.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($snapshot.UserSid -and $snapshot.UserSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw '备份属于其他用户，未恢复任何项目' }
foreach ($r in $records) {
    # Reconcile every prepared record: a post-change verification error can
    # leave Changed=false even though the OS state was already changed.
    $e=$r.Entry
    try {
        switch ($e.Kind) {
            Run {
                $key=Get-Item -LiteralPath $e.Key
                if ($e.Name -in $key.GetValueNames()) {
                    if ($key.GetValue($e.Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -ceq $e.Value) { Write-Output ('已经恢复/未发生变更：'+$e.Name); continue }
                    throw '已有同名启动项，未覆盖，请手动核对'
                }
                New-ItemProperty -LiteralPath $e.Key -Name $e.Name -Value $e.Value -PropertyType $e.ValueKind | Out-Null
            }
            Folder {
                if (Test-Path -LiteralPath $e.File) {
                    if (Test-FolderIdentity $e) { Write-Output ('已经恢复/未发生变更：'+$e.Name); continue }
                    throw '原位置已有其他文件，未覆盖'
                }
                if (-not (Test-Under $r.SavedFile (Split-Path $resolved -Parent))) { throw '备份位置无效' }
                if ((Get-FileHash -LiteralPath $r.SavedFile -Algorithm SHA256).Hash -ne $e.Hash) { throw '备份文件已变化，未恢复' }
                Move-Item -LiteralPath $r.SavedFile -Destination $e.File
            }
            Task {
                $xml=Export-ScheduledTask -TaskName $e.Name -TaskPath $e.TaskPath
                if ((Get-TaskIdentity $xml) -cne (Get-TaskIdentity $e.Fingerprint)) { throw '任务定义已变化，未启用同名任务' }
                if (-not (Get-ScheduledTask -TaskName $e.Name -TaskPath $e.TaskPath).Settings.Enabled) { Enable-ScheduledTask -TaskName $e.Name -TaskPath $e.TaskPath | Out-Null }
                if (-not (Get-ScheduledTask -TaskName $e.Name -TaskPath $e.TaskPath).Settings.Enabled) { throw '任务仍未启用' }
            }
            Service {
                $current=Get-ServiceIdentity $e.Name
                if (-not (Test-ServiceOwnership $current $e) -or $current.StartMode -notin @('Auto','Disabled')) { throw '服务身份或配置已变化，未恢复' }
                Set-Service -Name $e.Name -StartupType Automatic
                $key='HKLM:\SYSTEM\CurrentControlSet\Services\'+$e.Name
                if ($null -ne $e.DelayedAutoStart) { Set-ItemProperty -LiteralPath $key -Name DelayedAutoStart -Value ([int]$e.DelayedAutoStart) }
                if ((Get-ServiceIdentity $e.Name).StartMode -ne 'Auto') { throw '服务仍未恢复自动启动' }
            }
            default { throw '未知类型' }
        }
        Write-Output ('已恢复：'+$e.Kind+' / '+$e.Name)
    } catch { Write-Output ('恢复失败：'+$e.Name+' / '+$_.Exception.Message) }
}
